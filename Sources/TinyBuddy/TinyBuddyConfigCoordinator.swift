import Foundation
import OSLog
import TinyBuddyCore

extension Notification.Name {
    static let tinyBuddyAppConfigDidChange = Notification.Name(
        "TinyBuddy.appConfigDidChange"
    )
}

@MainActor
final class TinyBuddyConfigCoordinator {
    typealias ScanRootsProvider = () -> GitScanRootAccessResult
    typealias RepositoryChangeMonitorRebuilder = () -> Void
    typealias TimerRescheduler = () -> Void

    private let configStore: TinyBuddyConfigStore
    private let scanRootsProvider: ScanRootsProvider
    private let rebuildRepositoryChangeMonitor: RepositoryChangeMonitorRebuilder
    private let rescheduleTimer: TimerRescheduler
    private let loginItemManager: TinyBuddyLoginItemManager
    private let notificationCenter: NotificationCenter

    private var lastPublishedConfig: TinyBuddyAppConfig?
    private var coalesceWorkItem: DispatchWorkItem?
    private var pendingConfig: TinyBuddyAppConfig?
    private var configGeneration = 0

    private static let coalesceInterval: TimeInterval = 0.3
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ryukeili.TinyBuddy",
        category: "ConfigCoordinator"
    )

    var currentConfigGeneration: Int {
        configGeneration
    }

    init(
        configStore: TinyBuddyConfigStore = TinyBuddyConfigStore(),
        scanRootsProvider: @escaping ScanRootsProvider,
        rebuildRepositoryChangeMonitor: @escaping RepositoryChangeMonitorRebuilder = {},
        rescheduleTimer: @escaping TimerRescheduler = {},
        loginItemManager: TinyBuddyLoginItemManager? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.configStore = configStore
        self.scanRootsProvider = scanRootsProvider
        self.rebuildRepositoryChangeMonitor = rebuildRepositoryChangeMonitor
        self.rescheduleTimer = rescheduleTimer
        self.loginItemManager = loginItemManager ?? .shared
        self.notificationCenter = notificationCenter
    }

    func start() {
        let loaded = configStore.load()
        lastPublishedConfig = loaded
        if let loaded {
            Self.logger.info(
                "config loaded version=\(loaded.configVersion, privacy: .public)"
            )
        } else {
            publishInitialConfig()
        }
    }

    func currentConfig() -> TinyBuddyAppConfig? {
        lastPublishedConfig
    }

    func reloadPersistedConfig() {
        guard let persisted = configStore.load() else {
            return
        }

        // A coalesced proposal may still be queued (not yet flushed) when a
        // direct-store write such as an exclusion-rule change lands. Merge the
        // queued intent on top of the freshly loaded config so neither the
        // direct write nor the pending proposal is silently lost.
        if let pending = pendingConfig, pending != lastPublishedConfig {
            let merged = mergingPendingIntent(pending, into: persisted)
            if merged != persisted {
                coalesceConfigUpdate(merged)
                return
            }
        }

        guard persisted != lastPublishedConfig else {
            return
        }
        pendingConfig = nil
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        publishConfig(persisted)
    }

    /// Applies the fields a queued proposal actually changed (relative to what
    /// was last published) onto the freshly loaded persisted config. Exclusion
    /// rules are intentionally not carried over: the direct settings-view write
    /// that triggered this reload is the source of truth for exclusions.
    private func mergingPendingIntent(
        _ pending: TinyBuddyAppConfig,
        into persisted: TinyBuddyAppConfig
    ) -> TinyBuddyAppConfig {
        guard let last = lastPublishedConfig else {
            return persisted
        }
        var merged = persisted
        if pending.scanRootPaths != last.scanRootPaths {
            merged = merged.withIncrementedVersion(scanRootPaths: pending.scanRootPaths)
        }
        if pending.launchAtLoginEnabled != last.launchAtLoginEnabled {
            merged = merged.withIncrementedVersion(launchAtLoginEnabled: pending.launchAtLoginEnabled)
        }
        if pending.hudEnabled != last.hudEnabled {
            merged = merged.withIncrementedVersion(hudEnabled: pending.hudEnabled)
        }
        if pending.refreshStrategy != last.refreshStrategy {
            merged = merged.withIncrementedVersion(refreshStrategy: pending.refreshStrategy)
        }
        return merged
    }

    func proposeScanRootsChange() {
        guard let current = lastPublishedConfig ?? buildCurrentConfig() else {
            return
        }
        let accessResult = scanRootsProvider()
        defer { accessResult.roots.forEach { $0.stopAccessing() } }
        guard accessResult.issue == nil else {
            // Do not replace a complete projection with a partial/empty view
            // while a disk is offline or one bookmark is temporarily invalid.
            return
        }
        let newPaths = accessResult.roots.map { $0.url.standardizedFileURL.path }
        let currentRoots = Set(current.scanRootPaths)
        let proposedRoots = Set(newPaths)
        guard currentRoots != proposedRoots else {
            return
        }
        let updated = current.withIncrementedVersion(scanRootPaths: newPaths.sorted())
        coalesceConfigUpdate(updated)
    }

    /// Reconciles the secondary persisted path projection after authorization
    /// recovery (for example, a bookmark following a moved directory) without
    /// rebuilding monitors or starting another Git scan. The authorization
    /// store remains the source of truth; this only prevents stale paths from
    /// surviving a restart or upgrade in the app configuration.
    func reconcilePersistedScanRoots() {
        guard let current = lastPublishedConfig else {
            return
        }
        let accessResult = scanRootsProvider()
        defer { accessResult.roots.forEach { $0.stopAccessing() } }
        guard accessResult.issue == nil else {
            // A missing volume or partial authorization must not look like an
            // explicit removal in the secondary config projection.
            return
        }
        let newPaths = accessResult.roots.map { $0.url.standardizedFileURL.path }.sorted()
        guard Set(current.scanRootPaths) != Set(newPaths) else {
            return
        }

        let updated = current.withIncrementedVersion(scanRootPaths: newPaths)
        switch configStore.save(updated) {
        case .saved, .unchanged:
            lastPublishedConfig = updated
            configGeneration &+= 1
        case .persistenceFailed:
            Self.logger.error("reconciled scan roots could not be persisted")
        }
    }

    /// Drives the real SMAppService state first so the persisted intent only
    /// moves when the actual registration/removal succeeded. The idempotent
    /// manager call makes repeated proposes harmless.
    func proposeLaunchAtLoginChange(_ enabled: Bool) throws {
        guard let current = lastPublishedConfig ?? buildCurrentConfig() else {
            return
        }
        guard current.launchAtLoginEnabled != enabled else {
            return
        }
        try loginItemManager.setEnabled(enabled)
        let updated = current.withIncrementedVersion(launchAtLoginEnabled: enabled)
        coalesceConfigUpdate(updated)
    }

    /// Rewrites the persisted intent to match the actual SMAppService state
    /// when that state is unambiguous. Ambiguous states (`.notFound`/`.error`)
    /// are left to the bounded launch recovery and never erase user intent.
    /// Uses the same coalesced persistence path; no second persistence lane.
    func reconcileLaunchAtLoginIntent() {
        guard let current = lastPublishedConfig else {
            return
        }
        let target: Bool?
        switch loginItemManager.cachedStatus {
        case .enabled:
            target = true
        case .notRegistered:
            target = false
        case .requiresApproval:
            // A pending approval still expresses the user's enable intent.
            target = true
        case .notFound, .error:
            target = nil
        }
        guard let target else {
            return
        }
        guard current.launchAtLoginEnabled != target else {
            return
        }
        // A propose() may already have queued the identical intent; do not
        // write the same value through a second coalesce slot.
        if pendingConfig?.launchAtLoginEnabled == target {
            return
        }
        coalesceConfigUpdate(current.withIncrementedVersion(launchAtLoginEnabled: target))
    }

    func proposeHUDEnabledChange(_ enabled: Bool) {
        guard let current = lastPublishedConfig ?? buildCurrentConfig() else {
            return
        }
        guard current.hudEnabled != enabled else {
            return
        }
        let updated = current.withIncrementedVersion(hudEnabled: enabled)
        coalesceConfigUpdate(updated)
    }

    func proposeRefreshStrategyChange(_ strategy: TinyBuddyRefreshStrategy) {
        guard let current = lastPublishedConfig ?? buildCurrentConfig() else {
            return
        }
        guard current.refreshStrategy != strategy else {
            return
        }
        let updated = current.withIncrementedVersion(refreshStrategy: strategy)
        coalesceConfigUpdate(updated)
    }

    func proposeExclusionRulesChange(_ rules: [TinyBuddyExclusionRule]) {
        guard let current = lastPublishedConfig ?? buildCurrentConfig() else {
            return
        }
        guard current.exclusionRules != rules else {
            return
        }
        coalesceConfigUpdate(current.withIncrementedVersion(exclusionRules: rules))
    }

    private func coalesceConfigUpdate(_ config: TinyBuddyAppConfig) {
        pendingConfig = config
        coalesceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyPendingConfig()
            }
        }
        coalesceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.coalesceInterval,
            execute: workItem
        )
    }

    private func applyPendingConfig() {
        guard let config = pendingConfig else {
            return
        }
        pendingConfig = nil
        coalesceWorkItem = nil

        guard config != lastPublishedConfig else {
            return
        }

        let outcome = configStore.save(config)
        switch outcome {
        case .saved, .unchanged:
            publishConfig(config)
        case .persistenceFailed:
            Self.logger.error(
                "config persistence failed version=\(config.configVersion, privacy: .public)"
            )
        }
    }

    private func publishConfig(_ config: TinyBuddyAppConfig) {
        let previousRoots = Set(lastPublishedConfig?.scanRootPaths ?? [])
        let newRoots = Set(config.scanRootPaths)
        let previousStrategy = lastPublishedConfig?.refreshStrategy ?? .automatic
        let newStrategy = config.refreshStrategy
        let previousExclusions = Set(lastPublishedConfig?.exclusionRules.map(\.pattern) ?? [])
        let newExclusions = Set(config.exclusionRules.map(\.pattern))

        lastPublishedConfig = config
        configGeneration &+= 1

        Self.logger.info(
            "config published version=\(config.configVersion, privacy: .public) generation=\(self.configGeneration, privacy: .public)"
        )

        if previousRoots != newRoots || previousStrategy != newStrategy || previousExclusions != newExclusions {
            if previousRoots != newRoots {
                Self.logger.info(
                    "config roots changed: \(previousRoots.count, privacy: .public) -> \(newRoots.count, privacy: .public)"
                )
            }
            if previousStrategy != newStrategy {
                Self.logger.info(
                    "config strategy changed: \(previousStrategy.rawValue, privacy: .public) -> \(newStrategy.rawValue, privacy: .public)"
                )
            }
            if previousExclusions != newExclusions {
                Self.logger.info(
                    "config exclusion rules changed: \(previousExclusions.count, privacy: .public) -> \(newExclusions.count, privacy: .public)"
                )
            }
            rebuildRepositoryChangeMonitor()
            rescheduleTimer()
        }

        notificationCenter.post(
            name: .tinyBuddyAppConfigDidChange,
            object: config,
            userInfo: ["configGeneration": self.configGeneration]
        )
    }

    private func publishInitialConfig() {
        let config = buildCurrentConfig() ?? TinyBuddyAppConfig(
            configVersion: 1,
            dayIdentifier: dayIdentifier()
        )
        let outcome = configStore.save(config)
        if outcome == .saved {
            lastPublishedConfig = config
        }
    }

    private func buildCurrentConfig() -> TinyBuddyAppConfig? {
        let loaded = configStore.load()
        let accessResult = scanRootsProvider()
        let scanRootPaths: [String]
        if accessResult.issue == nil {
            scanRootPaths = accessResult.roots.map { $0.url.standardizedFileURL.path }.sorted()
        } else {
            // Preserve last-known paths in the secondary projection while a
            // volume is offline or authorization is temporarily invalid. The
            // bookmark records remain authoritative and are never cleared by
            // an empty resolution result.
            scanRootPaths = accessResult.authorizations
                .compactMap { $0.lastKnownPath.isEmpty ? nil : $0.lastKnownPath }
                .sorted()
        }
        accessResult.roots.forEach { $0.stopAccessing() }

        guard let loaded else {
            // No persisted config yet: seed the intent from the live login-item
            // state once so the first persisted config matches reality.
            return TinyBuddyAppConfig(
                configVersion: 1,
                scanRootPaths: scanRootPaths,
                launchAtLoginEnabled: loginItemManager.isEnabled,
                hudEnabled: true,
                refreshStrategy: .automatic,
                dayIdentifier: dayIdentifier()
            )
        }

        let currentRoots = Set(loaded.scanRootPaths)
        let liveRoots = Set(scanRootPaths)
        // A persisted intent is authoritative and must never be clobbered by
        // the live status; external changes are folded back in by
        // reconcileLaunchAtLoginIntent() instead.
        let updated = loaded.withIncrementedVersion(
            scanRootPaths: currentRoots != liveRoots ? scanRootPaths : nil,
            dayIdentifier: dayIdentifier()
        )
        return updated
    }

    private func dayIdentifier() -> String {
        let env = TinyBuddyTimeEnvironment()
        return env.capture()?.dayIdentifier ?? "unknown"
    }
}
