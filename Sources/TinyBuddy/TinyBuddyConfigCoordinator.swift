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
        notificationCenter: NotificationCenter = .default
    ) {
        self.configStore = configStore
        self.scanRootsProvider = scanRootsProvider
        self.rebuildRepositoryChangeMonitor = rebuildRepositoryChangeMonitor
        self.rescheduleTimer = rescheduleTimer
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

    func proposeScanRootsChange() {
        guard let current = lastPublishedConfig ?? buildCurrentConfig() else {
            return
        }
        let accessResult = scanRootsProvider()
        let newPaths = accessResult.roots.map { $0.url.standardizedFileURL.path }
        let currentRoots = Set(current.scanRootPaths)
        let proposedRoots = Set(newPaths)
        guard currentRoots != proposedRoots else {
            return
        }
        let updated = current.withIncrementedVersion(scanRootPaths: newPaths.sorted())
        coalesceConfigUpdate(updated)
    }

    func proposeLaunchAtLoginChange(_ enabled: Bool) {
        guard let current = lastPublishedConfig ?? buildCurrentConfig() else {
            return
        }
        guard current.launchAtLoginEnabled != enabled else {
            return
        }
        let updated = current.withIncrementedVersion(launchAtLoginEnabled: enabled)
        coalesceConfigUpdate(updated)
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

        lastPublishedConfig = config
        configGeneration &+= 1

        Self.logger.info(
            "config published version=\(config.configVersion, privacy: .public) generation=\(self.configGeneration, privacy: .public)"
        )

        if previousRoots != newRoots || previousStrategy != newStrategy {
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
        let scanRootPaths = accessResult.roots.map { $0.url.standardizedFileURL.path }.sorted()
        accessResult.roots.forEach { $0.stopAccessing() }

        guard let loaded else {
            return TinyBuddyAppConfig(
                configVersion: 1,
                scanRootPaths: scanRootPaths,
                launchAtLoginEnabled: TinyBuddyLoginItemManager.shared.isEnabled,
                hudEnabled: true,
                refreshStrategy: .automatic,
                dayIdentifier: dayIdentifier()
            )
        }

        let currentRoots = Set(loaded.scanRootPaths)
        let liveRoots = Set(scanRootPaths)
        let updated = loaded.withIncrementedVersion(
            scanRootPaths: currentRoots != liveRoots ? scanRootPaths : nil,
            launchAtLoginEnabled: TinyBuddyLoginItemManager.shared.isEnabled,
            dayIdentifier: dayIdentifier()
        )
        return updated
    }

    private func dayIdentifier() -> String {
        let env = TinyBuddyTimeEnvironment()
        return env.capture()?.dayIdentifier ?? "unknown"
    }
}
