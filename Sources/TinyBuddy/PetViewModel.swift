import AppKit
import Foundation
import OSLog
import WidgetKit
import TinyBuddyCore

struct TinyBuddyHUDSnapshotConsumption: Equatable {
    let schemaVersion: Int
    let revision: Int64
    let dayIdentifier: String
}

private enum TinyBuddySharedSnapshotTelemetry {
    private static let logger = Logger(
        subsystem: "local.tinybuddy",
        category: "SharedSnapshot"
    )

    static func recordHUDConsumption(_ consumption: TinyBuddyHUDSnapshotConsumption) {
        logger.info(
            "HUD consumed schema=\(consumption.schemaVersion, privacy: .public) revision=\(consumption.revision, privacy: .public) day=\(consumption.dayIdentifier, privacy: .public)"
        )
    }
}

@MainActor
final class PetViewModel: ObservableObject {
    private struct CombinedHUDState {
        let snapshot: TinyBuddySnapshot
        let activitySnapshot: GitTodayActivitySnapshot
        let didPersist: Bool
        let committedSnapshot: TinyBuddyCombinedSnapshot?
        let dataAvailability: TinyBuddyDisplayDataAvailability

        init(
            committedSnapshot: TinyBuddyCombinedSnapshot,
            didPersist: Bool,
            dataAvailability: TinyBuddyDisplayDataAvailability = .available
        ) {
            snapshot = committedSnapshot.snapshot
            activitySnapshot = committedSnapshot.activitySnapshot
            self.didPersist = didPersist
            self.committedSnapshot = committedSnapshot
            self.dataAvailability = dataAvailability
        }

        init(
            snapshot: TinyBuddySnapshot,
            activitySnapshot: GitTodayActivitySnapshot,
            didPersist: Bool,
            dataAvailability: TinyBuddyDisplayDataAvailability
        ) {
            self.snapshot = snapshot
            self.activitySnapshot = activitySnapshot
            self.didPersist = didPersist
            committedSnapshot = nil
            self.dataAvailability = dataAvailability
        }
    }

    enum DisplayState: Equatable {
        case idle
        case focusing
        case completed
        case active

        var selectedStatus: PetStatus? {
            switch self {
            case .idle:
                return .idle
            case .focusing:
                return .focusing
            case .completed:
                return .completedOnce
            case .active:
                return nil
            }
        }
    }

    struct RefreshDiagnostics: Equatable {
        let badgeTitle: String
        let summary: String
        let detail: String
        let reason: String?
        let outcome: GitActivityRefreshOutcome?
        let actionTitle: String?
    }

    @Published private(set) var status: PetStatus
    @Published private(set) var stats: DailyStats
    @Published private(set) var displayPresentation: TinyBuddyDisplayPresentation
    @Published private(set) var refreshDiagnostics: RefreshDiagnostics
    @Published private(set) var hiddenSnapshotDiagnosticSummary: TinyBuddyHiddenSnapshotDiagnosticSummary?
    @Published private(set) var developmentInterruptionSnapshot: DevelopmentInterruptionSnapshot?
    /// The same revision-bound session history that the Widget and Settings
    /// report consume. HUD rendering never re-derives it from raw sessions.
    @Published private(set) var focusHistoryPublication: FocusHistoryPublication?
    /// Live state of the manual focus control system, published for HUD, menu bar, and Widget.
    @Published private(set) var manualControlState: ManualFocusControlState = .idle

    var hudPresentation: TinyBuddyWidgetPresentation {
        displayPresentation
    }

    var displayState: DisplayState {
        Self.makeDisplayState(from: displayPresentation)
    }

    var gitActivityExperience: GitActivityExperiencePresentation {
        GitActivityExperiencePresentation.make(from: displayPresentation)
    }

    var selectedStatus: PetStatus {
        status
    }

    var notificationObserverCount: Int {
        observers.count
    }

    /// Testable lifecycle signal for the manual-control timer. The timer is
    /// deliberately present only while an active session is accumulating.
    var isManualControlRefreshTimerRunning: Bool {
        manualControlTimer != nil
    }

    private let onboardingStore: TinyBuddyOnboardingStore
    private let store: DailyStatsStore
    private let session: PetSession
    private let activityStore: GitTodayActivityStore
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let developmentInterruptionStore: DevelopmentInterruptionSnapshotStore
    private let notificationCenter: NotificationCenter
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let widgetReloader: () throws -> Void
    private let sharedSnapshotDiagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder
    private let hudSnapshotConsumptionRecorder: (TinyBuddyHUDSnapshotConsumption) -> Void
    private var rebuiltSnapshotFaultIdentifiers: Set<String>
    private var latestRefreshStatus: GitActivityRefreshStatus?
    private var latestActivitySnapshot: GitTodayActivitySnapshot
    private var latestDataAvailability: TinyBuddyDisplayDataAvailability
    private var isGitActivityRefreshing = false
    private var latestLifecycleGeneration = 0
    private var latestLifecycleNotificationSequence = 0
    private var lastRecordedHUDRevision: Int64?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    /// Focus session engine for manual control. Set by AppDelegate after bridge creation.
    private nonisolated(unsafe) var focusSessionEngine: FocusSessionEngine?
    /// Timer for periodically refreshing the live manual-control duration display.
    private nonisolated(unsafe) var manualControlTimer: Timer?

    init(
        onboardingStore: TinyBuddyOnboardingStore = TinyBuddyOnboardingStore(),
        store: DailyStatsStore = DailyStatsStore(),
        activityStore: GitTodayActivityStore = GitTodayActivityStore(),
        combinedSnapshotStore: TinyBuddyCombinedSnapshotStore? = nil,
        refreshStatusStore: GitActivityRefreshStatusStore = GitActivityRefreshStatusStore(),
        developmentInterruptionStore: DevelopmentInterruptionSnapshotStore = DevelopmentInterruptionSnapshotStore(),
        notificationCenter: NotificationCenter = .default,
        timeEnvironment: TinyBuddyTimeEnvironment = TinyBuddyTimeEnvironment(),
        widgetReloader: @escaping () throws -> Void = {
            TinyBuddyWidgetReloadCoordinator.shared.requestReload()
        },
        sharedSnapshotDiagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder = .shared,
        hudSnapshotConsumptionRecorder: @escaping (TinyBuddyHUDSnapshotConsumption) -> Void =
            TinyBuddySharedSnapshotTelemetry.recordHUDConsumption
    ) {
        self.onboardingStore = onboardingStore
        self.store = store
        let session = PetSession(store: store)
        let combinedSnapshotStore = combinedSnapshotStore ?? store.makeCombinedSnapshotStore()
        let timeContext = timeEnvironment.capture()
        let interruptionReadDate = timeContext?.now ?? Date()
        _ = developmentInterruptionStore.clearIfExpired(at: interruptionReadDate)
        let developmentInterruptionSnapshot = developmentInterruptionStore.load(
            at: interruptionReadDate
        )
        let latestRefreshStatus = Self.displayRefreshStatus(
            refreshStatusStore.load(),
            timeContext: timeContext
        )
        let fallbackSnapshot = store.loadSnapshot()
        let expectedDayIdentifier = timeContext?.dayIdentifier
            ?? fallbackSnapshot.stats.dayIdentifier
        var rebuiltSnapshotFaultIdentifiers: Set<String> = []
        let committedReadBeforePublication = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        committedReadBeforePublication.observation.map(sharedSnapshotDiagnosticRecorder.record)
        let committedSnapshotBeforePublication = committedReadBeforePublication.snapshot
        let hadSameDayCommittedSnapshot = committedSnapshotBeforePublication?.dayIdentifier
            == expectedDayIdentifier
        let widgetPresentationBeforePublication: TinyBuddyDisplayPresentation
        if let committedSnapshot = committedSnapshotBeforePublication,
           committedSnapshot.dayIdentifier == expectedDayIdentifier {
            widgetPresentationBeforePublication = TinyBuddyDisplayPresentation(
                snapshot: committedSnapshot.snapshot,
                activitySnapshot: committedSnapshot.activitySnapshot,
                focusHistoryPublication: committedSnapshot.focusHistoryPublication
            )
        } else {
            widgetPresentationBeforePublication = TinyBuddyDisplayPresentation(
                snapshot: fallbackSnapshot,
                activitySnapshot: GitTodayActivitySnapshot(
                    focusBlockCount: nil,
                    commitCount: nil,
                    recentProjectName: nil
                )
            )
        }
        let combinedHUDState = Self.publishAndLoadCombinedSnapshot(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            includeTrustedActivity: Self.shouldIncludeTrustedActivity(
                for: latestRefreshStatus
            ),
            expectedDayIdentifier: expectedDayIdentifier,
            diagnosticRecorder: sharedSnapshotDiagnosticRecorder,
            rebuiltSnapshotFaultIdentifiers: &rebuiltSnapshotFaultIdentifiers,
            preloadedSnapshot: fallbackSnapshot,
            preloadedValidatedRead: committedReadBeforePublication
        )
        let snapshot = combinedHUDState.snapshot
        let activitySnapshot = combinedHUDState.activitySnapshot
        let displayPresentation = Self.makeDisplayPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot,
            focusHistoryPublication: combinedHUDState.committedSnapshot?.focusHistoryPublication,
            refreshStatus: latestRefreshStatus,
            dataAvailability: combinedHUDState.dataAvailability,
            isRefreshing: false,
            onboardingCompleted: onboardingStore.isCompleted,
            timeContext: timeContext
        )
        let widgetPresentation = TinyBuddyDisplayPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot,
            focusHistoryPublication: combinedHUDState.committedSnapshot?.focusHistoryPublication
        )
        self.session = session
        self.activityStore = activityStore
        self.combinedSnapshotStore = combinedSnapshotStore
        self.refreshStatusStore = refreshStatusStore
        self.developmentInterruptionStore = developmentInterruptionStore
        self.notificationCenter = notificationCenter
        self.timeEnvironment = timeEnvironment
        self.widgetReloader = widgetReloader
        self.sharedSnapshotDiagnosticRecorder = sharedSnapshotDiagnosticRecorder
        self.hudSnapshotConsumptionRecorder = hudSnapshotConsumptionRecorder
        self.rebuiltSnapshotFaultIdentifiers = rebuiltSnapshotFaultIdentifiers
        self.latestRefreshStatus = latestRefreshStatus
        self.latestActivitySnapshot = activitySnapshot
        self.latestDataAvailability = combinedHUDState.dataAvailability
        self.status = snapshot.status
        self.stats = snapshot.stats
        self.displayPresentation = displayPresentation
        self.refreshDiagnostics = Self.makeRefreshDiagnostics(
            from: latestRefreshStatus,
            timeContext: timeContext
        )
        self.hiddenSnapshotDiagnosticSummary = sharedSnapshotDiagnosticRecorder.latestSummary
        self.developmentInterruptionSnapshot = developmentInterruptionSnapshot
        self.focusHistoryPublication = combinedHUDState.committedSnapshot?.focusHistoryPublication
        recordHUDConsumptionIfMatching(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot,
            committedSnapshot: combinedHUDState.committedSnapshot
        )
        // Trigger a Widget timeline reload when the combined snapshot was
        // just committed for a day the Widget may not have seen yet, or
        // when data availability is not optimal.  The refresh coordinator
        // also independently reloads widget timelines after its content-
        // change check; this additional path ensures the Widget picks up
        // the snapshot even when the coordinator skips the reload (e.g.
        // when the activity data happened to match a day-boundary rebuild).
        if combinedHUDState.dataAvailability != .available
            || (combinedHUDState.didPersist
                && (hadSameDayCommittedSnapshot
                    || widgetPresentationBeforePublication != widgetPresentation))
            || (!hadSameDayCommittedSnapshot
                && combinedHUDState.dataAvailability == .available
                && committedSnapshotBeforePublication != nil) {
            reloadWidgetIfPossible()
        }
        observers.append(notificationCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let generation = notification.userInfo?[TinyBuddyLifecycleNotification.generationKey] as? Int
            let sequence = notification.userInfo?[TinyBuddyLifecycleNotification.sequenceKey] as? Int
            let notificationObject = notification.object as? GitActivityRefreshStatus
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                guard self.acceptLifecycleGeneration(generation, sequence: sequence) else {
                    return
                }

                let timeContext = self.timeEnvironment.capture()
                let candidate = notificationObject
                    ?? self.newestRefreshStatus(self.refreshStatusStore.load())
                let refreshStatus = Self.displayRefreshStatus(
                    candidate,
                    timeContext: timeContext
                )
                self.isGitActivityRefreshing = false
                self.latestRefreshStatus = refreshStatus
                self.updateRefreshDiagnostics(for: refreshStatus)
                self.reloadDevelopmentInterruption(at: timeContext?.now)
                let previousHistory = self.focusHistoryPublication
                let didChange = self.reloadCommittedHUDState()
                // A refresh-status notification is also emitted for retries
                // that commit no new content. Only reload WidgetKit when the
                // rendered presentation or authoritative focus slice changed.
                if didChange || previousHistory != self.focusHistoryPublication {
                    self.reloadWidgetIfPossible()
                }
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: .gitActivityRefreshDidStart,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let generation = notification.userInfo?[TinyBuddyLifecycleNotification.generationKey] as? Int
            let sequence = notification.userInfo?[TinyBuddyLifecycleNotification.sequenceKey] as? Int
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                guard self.acceptLifecycleGeneration(generation, sequence: sequence) else {
                    return
                }
                self.latestRefreshStatus = Self.displayRefreshStatus(
                    self.refreshStatusStore.load(),
                    timeContext: self.timeEnvironment.capture()
                )
                self.updateRefreshDiagnostics(for: self.latestRefreshStatus)
                self.isGitActivityRefreshing = true
                _ = self.reloadHUDState()
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: .gitScanRootAuthorizationsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDisplayPresentation()
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: .gitActivitySnapshotDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let generation = notification.userInfo?[TinyBuddyLifecycleNotification.generationKey] as? Int
            let sequence = notification.userInfo?[TinyBuddyLifecycleNotification.sequenceKey] as? Int
            MainActor.assumeIsolated {
                guard let self,
                      self.acceptLifecycleGeneration(generation, sequence: sequence) else {
                    return
                }
                self.reloadCommittedHUDState()
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: .tinyBuddyTimeEnvironmentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let generation = notification.userInfo?[TinyBuddyLifecycleNotification.generationKey] as? Int
            let sequence = notification.userInfo?[TinyBuddyLifecycleNotification.sequenceKey] as? Int
            MainActor.assumeIsolated {
                guard let self,
                      self.acceptLifecycleGeneration(generation, sequence: sequence) else {
                    return
                }
                self.handleTimeEnvironmentDidChange()
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restorePersistedState()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .tinyBuddySharedSnapshotDiagnosticDidChange,
            object: sharedSnapshotDiagnosticRecorder,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.updateHiddenSnapshotDiagnosticSummary()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .focusSessionSnapshotSynchronizationDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Read the flag outside the main-actor hop so a Sendable Bool is
            // all that crosses the isolation boundary.
            let reloadWidget = (notification.userInfo?["reloadWidget"] as? Bool) ?? true
            MainActor.assumeIsolated {
                // Safety net: re-read the committed snapshot and reload the
                // Widget after every focus-history publication. This supplements
                // the direct focusSessionStatsDidChange() call in the publication
                // handler, ensuring the Widget always sees the latest data even
                // if that direct path was bypassed. Periodic live-minute
                // re-emissions opt out via the published flag so the Widget
                // self-schedules its refresh instead.
                self?.focusSessionStatsDidChange(reloadWidget: reloadWidget)
            }
        })
    }

    func select(_ nextStatus: PetStatus) {
        session.select(nextStatus)
        if reloadHUDState() {
            reloadWidgetIfPossible()
        }
    }

    /// Applies an automatic focus-state transition without incrementing the
    /// compatibility counters used by the manual pet controls. The combined
    /// snapshot keeps its committed focus-history slice while status changes.
    /// This writes the combined snapshot and triggers a widget reload.
    func synchronizeFocusSessionStatus(_ status: PetStatus) {
        guard self.status != status else { return }
        let synchronizedStats = session.synchronizeStatus(status)
        let snapshot = TinyBuddySnapshot(status: status, stats: synchronizedStats)
        let update = combinedSnapshotStore.updatePetSlice(
            snapshot,
            fallbackActivitySnapshot: nil
        )
        guard update.didPersist || update.outcome == .alreadyCurrent else {
            return
        }
        let previousHistory = focusHistoryPublication
        let didChange = reloadCommittedHUDState()
        // `updatePetSlice` may already be current when a delayed status
        // callback arrives. Do not wake WidgetKit unless the committed
        // presentation or history payload actually changed.
        if didChange || previousHistory != focusHistoryPublication {
            reloadWidgetIfPossible()
        }
    }

    /// Lightweight status update for the combined publication path.  Writes
    /// the legacy DailyStats store and updates the in-memory status property,
    /// but does NOT write the combined snapshot or reload the Widget — the
    /// caller merges the status into the same combined-snapshot write that
    /// carries the focus history slice.
    func applyFocusStatusForPublication(_ status: PetStatus) {
        guard self.status != status else { return }
        let synchronizedStats = session.synchronizeStatus(status)
        // Only update HUD state from the legacy store; the combined snapshot
        // write (with focus history) happens in the caller. Update the source
        // values first so any derived presentation cannot observe the old
        // status for one render pass.
        if self.status != status {
            self.status = status
        }
        if self.stats != synchronizedStats {
            self.stats = synchronizedStats
        }
        updateDisplayPresentation()
    }

    func requestGitScanAuthorization() {
        notificationCenter.post(name: .gitScanRootAuthorizationRequested, object: nil)
    }

    func performGitActivityAction() {
        guard let action = displayPresentation.action else {
            return
        }

        switch action {
        case .chooseDirectories, .addDirectory:
            notificationCenter.post(name: .gitScanRootAuthorizationRequested, object: nil)
        case .reauthorize:
            notificationCenter.post(name: .gitScanRootAuthorizationRepairRequested, object: nil)
        case .rescan:
            notificationCenter.post(name: .gitActivityRefreshRequested, object: nil)
        }
    }

    // MARK: - Manual Focus Control

    // Manual commands update the control projection immediately. WidgetKit is
    // intentionally reloaded only by the committed history-publication path,
    // after the same transition reaches the combined shared snapshot.

    /// Called by AppDelegate to set the engine reference after bridge creation.
    /// The timer starts only when an active manual session exists.
    func setFocusSessionEngine(_ engine: FocusSessionEngine?) {
        focusSessionEngine = engine
        if engine == nil {
            stopManualControlRefresh()
        }
        refreshManualControlState()
    }

    /// Start a manual focus session for the given project.
    func startManualFocus(project: FocusProjectContext) {
        guard let engine = focusSessionEngine else { return }
        let token = UUID()
        _ = engine.startManualFocus(project: project, at: Date(), commandToken: token)
        // The refreshed state is the single timer gate. A failed/no-op command
        // therefore cannot briefly create a needless timer.
        refreshManualControlState()
    }

    /// Pause the current manual focus session.
    func pauseManualFocus() {
        guard let engine = focusSessionEngine else { return }
        let token = UUID()
        _ = engine.pauseManualFocus(at: Date(), commandToken: token)
        refreshManualControlState()
    }

    /// Resume the current paused manual focus session.
    func resumeManualFocus() {
        guard let engine = focusSessionEngine else { return }
        let token = UUID()
        _ = engine.resumeManualFocus(at: Date(), commandToken: token)
        refreshManualControlState()
    }

    /// End the current manual focus session.
    func endManualFocus() {
        guard let engine = focusSessionEngine else { return }
        let token = UUID()
        _ = engine.endManualFocus(at: Date(), commandToken: token)
        refreshManualControlState()
    }

    /// Refresh the published manual control state from the engine.
    /// Automatically stops the 1-second timer when the session ends.
    func refreshManualControlState() {
        guard let engine = focusSessionEngine else {
            stopManualControlRefresh()
            if manualControlState != .idle {
                manualControlState = .idle
            }
            return
        }
        let newState = engine.manualControlState
        if manualControlState != newState {
            manualControlState = newState
        }
        // Only an actively accumulating session needs a one-second tick.
        // Paused duration is stable, so leaving the timer stopped avoids wakeups
        // and prevents a paused panel from being needlessly re-rendered.
        switch newState {
        case .focusing:
            startManualControlRefreshIfNeeded()
        case .paused, .idle:
            stopManualControlRefresh()
        }
    }

    private func startManualControlRefreshIfNeeded() {
        guard manualControlTimer == nil else { return }
        manualControlTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshManualControlState()
            }
        }
    }

    func stopManualControlRefresh() {
        manualControlTimer?.invalidate()
        manualControlTimer = nil
    }

    deinit {
        manualControlTimer?.invalidate()
        for observer in observers {
            notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func restorePersistedState() {
        // Foreground notifications can arrive while a refresh is still in
        // flight. Do not clear its indicator or let this older read masquerade
        // as the refresh result; the generation/sequence completion remains
        // authoritative.
        let persistedStatus = Self.displayRefreshStatus(
            refreshStatusStore.load(),
            timeContext: timeEnvironment.capture()
        )
        if let persistedStatus {
            if let newestStatus = newestRefreshStatus(persistedStatus) {
                latestRefreshStatus = newestStatus
            }
        } else {
            latestRefreshStatus = nil
        }
        updateRefreshDiagnostics(for: latestRefreshStatus)
        reloadDevelopmentInterruption()
        let previousHistory = focusHistoryPublication
        let didChange = reloadHUDState()
        if didChange || previousHistory != focusHistoryPublication {
            reloadWidgetIfPossible()
        }
    }

    private func acceptLifecycleGeneration(_ generation: Int?, sequence: Int?) -> Bool {
        guard let generation else {
            return true
        }
        guard generation >= latestLifecycleGeneration else {
            return false
        }
        if generation > latestLifecycleGeneration {
            latestLifecycleNotificationSequence = 0
        }
        latestLifecycleGeneration = generation

        guard let sequence else {
            return true
        }
        guard sequence > latestLifecycleNotificationSequence else {
            return false
        }
        latestLifecycleNotificationSequence = sequence
        return true
    }

    private func newestRefreshStatus(
        _ candidates: GitActivityRefreshStatus?...
    ) -> GitActivityRefreshStatus? {
        var newestCandidate: GitActivityRefreshStatus?
        for candidate in candidates.compactMap({ $0 }) {
            if let latestRefreshStatus,
               candidate.refreshedAt < latestRefreshStatus.refreshedAt {
                continue
            }
            if let newestCandidate,
               candidate.refreshedAt <= newestCandidate.refreshedAt {
                continue
            }
            newestCandidate = candidate
        }
        return newestCandidate
    }

    private func handleTimeEnvironmentDidChange() {
        // A time-boundary revalidation must not cancel an already accepted
        // refresh. Its completion notification is still the only path allowed
        // to clear the in-flight marker.
        let timeContext = timeEnvironment.capture()
        latestRefreshStatus = Self.displayRefreshStatus(
            refreshStatusStore.load(),
            timeContext: timeContext
        )
        updateRefreshDiagnostics(for: latestRefreshStatus)
        reloadDevelopmentInterruption(at: timeContext?.now)

        let combinedHUDState = Self.publishAndLoadCombinedSnapshot(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            includeTrustedActivity: Self.shouldIncludeTrustedActivity(
                for: latestRefreshStatus
            ),
            expectedDayIdentifier: timeContext?.dayIdentifier
                ?? store.loadSnapshot().stats.dayIdentifier,
            diagnosticRecorder: sharedSnapshotDiagnosticRecorder,
            rebuiltSnapshotFaultIdentifiers: &rebuiltSnapshotFaultIdentifiers
        )
        let previousHistory = focusHistoryPublication
        let didChange = applyHUDState(
            snapshot: combinedHUDState.snapshot,
            activitySnapshot: combinedHUDState.activitySnapshot,
            committedSnapshot: combinedHUDState.committedSnapshot,
            dataAvailability: combinedHUDState.dataAvailability
        )
        if didChange || previousHistory != focusHistoryPublication {
            reloadWidgetIfPossible()
        }
        updateHiddenSnapshotDiagnosticSummary()
    }

    private func reloadDevelopmentInterruption(at date: Date? = nil) {
        let now = date ?? timeEnvironment.capture()?.now ?? Date()
        _ = developmentInterruptionStore.clearIfExpired(at: now)
        let nextSnapshot = developmentInterruptionStore.load(at: now)
        if developmentInterruptionSnapshot != nextSnapshot {
            developmentInterruptionSnapshot = nextSnapshot
        }
    }

    private static func makeRefreshDiagnostics(
        from status: GitActivityRefreshStatus?,
        timeContext: TinyBuddyTimeContext?
    ) -> RefreshDiagnostics {
        guard let status else {
            return RefreshDiagnostics(
                badgeTitle: "未刷新",
                summary: "等待首次 Git 刷新",
                detail: "启动后会自动尝试刷新",
                reason: nil,
                outcome: nil,
                actionTitle: nil
            )
        }

        let diagnosticReason = status.diagnostic?.reason
        let actionTitle = authorizationActionTitle(for: diagnosticReason)

        return RefreshDiagnostics(
            badgeTitle: badgeTitle(for: status.outcome),
            summary: summaryTitle(for: status, diagnosticReason: diagnosticReason),
            detail: refreshDateFormatter(timeContext: timeContext).string(from: status.refreshedAt),
            reason: localizedReason(for: diagnosticReason, fallbackReason: status.reason),
            outcome: status.outcome,
            actionTitle: actionTitle
        )
    }

    @discardableResult
    private func reloadHUDState() -> Bool {
        let timeContext = timeEnvironment.capture()
        let combinedHUDState = Self.publishAndLoadCombinedSnapshot(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            includeTrustedActivity: Self.shouldIncludeTrustedActivity(
                for: latestRefreshStatus
            ),
            expectedDayIdentifier: timeContext?.dayIdentifier
                ?? store.loadSnapshot().stats.dayIdentifier,
            diagnosticRecorder: sharedSnapshotDiagnosticRecorder,
            rebuiltSnapshotFaultIdentifiers: &rebuiltSnapshotFaultIdentifiers
        )
        let snapshot = combinedHUDState.snapshot
        let activitySnapshot = combinedHUDState.activitySnapshot
        let didChange = applyHUDState(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot,
            committedSnapshot: combinedHUDState.committedSnapshot,
            dataAvailability: combinedHUDState.dataAvailability
        )
        updateHiddenSnapshotDiagnosticSummary()
        return didChange
    }

    @discardableResult
    private func reloadCommittedHUDState() -> Bool {
        let fallbackSnapshot = store.loadSnapshot()
        let expectedDayIdentifier = timeEnvironment.capture()?.dayIdentifier
            ?? fallbackSnapshot.stats.dayIdentifier
        let snapshot: TinyBuddySnapshot
        let activitySnapshot: GitTodayActivitySnapshot

        let combinedRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        combinedRead.observation.map(sharedSnapshotDiagnosticRecorder.record)
        if let observation = combinedRead.observation,
           combinedRead.snapshot == nil,
           observation.reason == .snapshotCorrupt || observation.reason == .staleData {
            let didChange = reloadHUDState()
            updateHiddenSnapshotDiagnosticSummary()
            // The reloadHUDState call above may have written a new combined
            // snapshot for today via publishAndLoadCombinedSnapshot.  Ensure
            // the Widget gets a chance to consume it, even when the refresh
            // coordinator's own content-change check did not trigger a reload.
            if didChange {
                reloadWidgetIfPossible()
            }
            return didChange
        }
        if let combinedSnapshot = combinedRead.snapshot {
            snapshot = combinedSnapshot.snapshot
            activitySnapshot = combinedSnapshot.activitySnapshot
        } else {
            snapshot = fallbackSnapshot
            activitySnapshot = GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            )
        }
        let didChange = applyHUDState(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot,
            committedSnapshot: combinedRead.snapshot,
            dataAvailability: TinyBuddyDisplayDataAvailability(
                observation: combinedRead.observation,
                hasSnapshot: combinedRead.snapshot != nil
            )
        )
        updateHiddenSnapshotDiagnosticSummary()
        return didChange
    }

    /// A focus-session journal transaction already reached disk. Re-read the
    /// same committed combined snapshot path used by HUD and Widget, rather
    /// than applying an optimistic in-memory presentation.  The combined
    /// snapshot was already written by the caller; this re-reads without
    /// re-writing to avoid an unnecessary revision increment.
    ///
    /// - Parameter reloadWidget: When `false` (periodic live-minute
    ///   re-emissions) the HUD refreshes from the committed snapshot but the
    ///   Widget is not reloaded — it self-schedules its refresh while a
    ///   session is live, so a per-minute reload would waste WidgetKit budget.
    func focusSessionStatsDidChange(reloadWidget: Bool = true) {
        let previousHistory = focusHistoryPublication
        let didChange = reloadCommittedHUDState()
        // Elapsed focus duration lives in the history publication rather than
        // the legacy count-based display presentation. Reload WidgetKit when
        // that authoritative slice changes even if the status/count UI did not.
        if reloadWidget, didChange || focusHistoryPublication != previousHistory {
            reloadWidgetIfPossible()
        }
    }

    @discardableResult
    private func applyHUDState(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot,
        committedSnapshot: TinyBuddyCombinedSnapshot? = nil,
        dataAvailability: TinyBuddyDisplayDataAvailability = .available
    ) -> Bool {
        let nextFocusHistoryPublication = committedSnapshot?.focusHistoryPublication
        let displayPresentation = Self.makeDisplayPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot,
            focusHistoryPublication: nextFocusHistoryPublication,
            refreshStatus: latestRefreshStatus,
            dataAvailability: dataAvailability,
            isRefreshing: isGitActivityRefreshing,
            onboardingCompleted: onboardingStore.isCompleted,
            timeContext: timeEnvironment.capture()
        )
        let didChange = self.displayPresentation != displayPresentation
        if status != snapshot.status {
            status = snapshot.status
        }
        if stats != snapshot.stats {
            stats = snapshot.stats
        }
        if didChange {
            self.displayPresentation = displayPresentation
        }
        latestActivitySnapshot = activitySnapshot
        latestDataAvailability = dataAvailability
        if focusHistoryPublication != nextFocusHistoryPublication {
            focusHistoryPublication = nextFocusHistoryPublication
        }
        recordHUDConsumptionIfMatching(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot,
            committedSnapshot: committedSnapshot
        )
        return didChange
    }

    private func recordHUDConsumptionIfMatching(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot,
        committedSnapshot: TinyBuddyCombinedSnapshot?
    ) {
        guard let committedSnapshot,
              committedSnapshot.dayIdentifier == snapshot.stats.dayIdentifier,
              committedSnapshot.snapshot == snapshot,
              committedSnapshot.activitySnapshot == activitySnapshot,
              status == committedSnapshot.snapshot.status,
              stats == committedSnapshot.snapshot.stats,
              latestActivitySnapshot == committedSnapshot.activitySnapshot else {
            return
        }

        let committedPresentation = Self.makeDisplayPresentation(
            snapshot: committedSnapshot.snapshot,
            activitySnapshot: committedSnapshot.activitySnapshot,
            focusHistoryPublication: committedSnapshot.focusHistoryPublication,
            refreshStatus: latestRefreshStatus,
            dataAvailability: latestDataAvailability,
            isRefreshing: isGitActivityRefreshing,
            onboardingCompleted: onboardingStore.isCompleted,
            timeContext: timeEnvironment.capture()
        )
        guard displayPresentation == committedPresentation,
              displayState == Self.makeDisplayState(from: committedPresentation) else {
            return
        }

        guard lastRecordedHUDRevision != committedSnapshot.revision else {
            return
        }
        lastRecordedHUDRevision = committedSnapshot.revision

        hudSnapshotConsumptionRecorder(TinyBuddyHUDSnapshotConsumption(
            schemaVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            revision: committedSnapshot.revision,
            dayIdentifier: committedSnapshot.dayIdentifier
        ))
    }

    private func updateDisplayPresentation() {
        let nextPresentation = Self.makeDisplayPresentation(
            snapshot: TinyBuddySnapshot(status: status, stats: stats),
            activitySnapshot: latestActivitySnapshot,
            focusHistoryPublication: focusHistoryPublication,
            refreshStatus: latestRefreshStatus,
            dataAvailability: latestDataAvailability,
            isRefreshing: isGitActivityRefreshing,
            onboardingCompleted: onboardingStore.isCompleted,
            timeContext: timeEnvironment.capture()
        )
        if displayPresentation != nextPresentation {
            displayPresentation = nextPresentation
        }
    }

    private func updateRefreshDiagnostics(for status: GitActivityRefreshStatus?) {
        let nextDiagnostics = Self.makeRefreshDiagnostics(
            from: status,
            timeContext: timeEnvironment.capture()
        )
        if refreshDiagnostics != nextDiagnostics {
            refreshDiagnostics = nextDiagnostics
        }
    }

    private func updateHiddenSnapshotDiagnosticSummary() {
        let nextSummary = sharedSnapshotDiagnosticRecorder.latestSummary
        if hiddenSnapshotDiagnosticSummary != nextSummary {
            hiddenSnapshotDiagnosticSummary = nextSummary
        }
    }

    private static func makeDisplayPresentation(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot,
        focusHistoryPublication: FocusHistoryPublication? = nil,
        refreshStatus: GitActivityRefreshStatus?,
        dataAvailability: TinyBuddyDisplayDataAvailability,
        isRefreshing: Bool,
        onboardingCompleted: Bool,
        timeContext: TinyBuddyTimeContext?
    ) -> TinyBuddyDisplayPresentation {
        TinyBuddyDisplayPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot,
            focusHistoryPublication: focusHistoryPublication,
            refreshStatus: refreshStatus,
            dataAvailability: dataAvailability,
            isRefreshing: isRefreshing,
            onboardingCompleted: onboardingCompleted,
            locale: Locale(identifier: timeContext?.signature.localeIdentifier ?? "zh_CN"),
            timeZone: timeContext?.timeZone ?? .current
        )
    }

    private static func displayRefreshStatus(
        _ status: GitActivityRefreshStatus?,
        timeContext: TinyBuddyTimeContext?
    ) -> GitActivityRefreshStatus? {
        guard let status, let timeContext else {
            return status
        }
        return status.isForDisplayDay(in: timeContext) ? status : nil
    }

    private static func publishAndLoadCombinedSnapshot(
        store: DailyStatsStore,
        activityStore: GitTodayActivityStore,
        combinedSnapshotStore: TinyBuddyCombinedSnapshotStore,
        includeTrustedActivity: Bool,
        expectedDayIdentifier: String,
        diagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder,
        rebuiltSnapshotFaultIdentifiers: inout Set<String>,
        preloadedSnapshot: TinyBuddySnapshot? = nil,
        preloadedValidatedRead: TinyBuddyValidatedCombinedSnapshotRead? = nil
    ) -> CombinedHUDState {
        let snapshot = preloadedSnapshot ?? store.loadSnapshot()
        let validatedRead = preloadedValidatedRead
            ?? combinedSnapshotStore.readValidated(
                expectedDayIdentifier: expectedDayIdentifier
            )
        validatedRead.observation.map(diagnosticRecorder.record)
        if validatedRead.observation == nil, validatedRead.snapshot != nil {
            rebuiltSnapshotFaultIdentifiers = Set(
                rebuiltSnapshotFaultIdentifiers.filter {
                    !$0.hasSuffix(".\(expectedDayIdentifier)")
                }
            )
        }
        let activityRead = includeTrustedActivity
            ? activityStore.loadTodaySnapshotRead()
            : nil

        if let observation = validatedRead.observation {
            if let recoveredSnapshot = validatedRead.snapshot {
                let faultBudgetIdentifier = "\(observation.identifier).\(expectedDayIdentifier)"
                if observation.reason == .snapshotCorrupt,
                   rebuiltSnapshotFaultIdentifiers.insert(faultBudgetIdentifier).inserted {
                    guard combinedSnapshotStore.repairValidatedSnapshot(recoveredSnapshot) else {
                        diagnosticRecorder.record(
                            phase: .snapshotWrite,
                            reason: .persistenceFailed,
                            recovery: .stopped
                        )
                        return CombinedHUDState(
                            committedSnapshot: recoveredSnapshot,
                            didPersist: false,
                            dataAvailability: .failed(.persistenceFailed)
                        )
                    }
                    let repairedRead = combinedSnapshotStore.readValidated(
                        expectedDayIdentifier: expectedDayIdentifier
                    )
                    repairedRead.observation.map(diagnosticRecorder.record)
                    guard let repairedSnapshot = repairedRead.snapshot,
                          repairedRead.observation == nil else {
                        diagnosticRecorder.record(
                            phase: .snapshotWrite,
                            reason: .persistenceFailed,
                            recovery: .stopped
                        )
                        return CombinedHUDState(
                            committedSnapshot: recoveredSnapshot,
                            didPersist: false,
                            dataAvailability: .failed(.persistenceFailed)
                        )
                    }
                    diagnosticRecorder.record(
                        phase: .snapshotRead,
                        reason: .snapshotCorrupt,
                        recovery: .rebuilt,
                        attemptCount: observation.attemptCount + 1
                    )
                    rebuiltSnapshotFaultIdentifiers.remove(faultBudgetIdentifier)
                    return CombinedHUDState(
                        committedSnapshot: repairedSnapshot,
                        didPersist: true
                    )
                }
                return CombinedHUDState(
                    committedSnapshot: recoveredSnapshot,
                    didPersist: false,
                    dataAvailability: observation.reason == .staleData
                        ? .stale
                        : .failed(observation.reason)
                )
            }

            if observation.reason == .staleData,
               let retainedSnapshot = combinedSnapshotStore.loadReadOnly(
                   minimumDayIdentifier: expectedDayIdentifier
               ) {
                return CombinedHUDState(
                    committedSnapshot: retainedSnapshot,
                    didPersist: false,
                    dataAvailability: .stale
                )
            }
            let faultBudgetIdentifier = "\(observation.identifier).\(expectedDayIdentifier)"
            guard observation.reason == .snapshotCorrupt || observation.reason == .staleData,
                  rebuiltSnapshotFaultIdentifiers.insert(faultBudgetIdentifier).inserted else {
                return neutralHUDState(snapshot, reason: observation.reason)
            }

            let rebuiltUpdate = combinedSnapshotStore.updatePetSlice(
                snapshot,
                fallbackActivitySnapshot: activityRead?.snapshot,
                fallbackActivityRevision: activityRead?.trustedRevision
            )
            rebuiltUpdate.observation.map(diagnosticRecorder.record)
            guard rebuiltUpdate.didPersist || rebuiltUpdate.outcome == .alreadyCurrent else {
                if rebuiltUpdate.observation == nil {
                    diagnosticRecorder.record(
                        phase: .snapshotWrite,
                        reason: .persistenceFailed,
                        recovery: .stopped
                    )
                }
                return neutralHUDState(
                    snapshot,
                    reason: rebuiltUpdate.observation?.reason ?? .persistenceFailed
                )
            }
            diagnosticRecorder.record(
                phase: .snapshotRead,
                reason: observation.reason,
                recovery: rebuiltUpdate.didPersist ? .rebuilt : .rereadSucceeded,
                attemptCount: observation.attemptCount + 1
            )
            let rebuiltRead = combinedSnapshotStore.readValidated(
                expectedDayIdentifier: expectedDayIdentifier
            )
            rebuiltRead.observation.map(diagnosticRecorder.record)
            guard let rebuiltSnapshot = rebuiltRead.snapshot else {
                return neutralHUDState(
                    snapshot,
                    reason: rebuiltRead.observation?.reason ?? observation.reason
                )
            }
            rebuiltSnapshotFaultIdentifiers.remove(faultBudgetIdentifier)
            return CombinedHUDState(
                committedSnapshot: rebuiltSnapshot,
                didPersist: true
            )
        }

        // Cold-start fast path: skip writing when the existing combined
        // snapshot is already current for the expected day, the pet stats
        // have not changed, and the activity store does not have a newer
        // revision.  This prevents an unnecessary revision increment and
        // downstream cascade (Widget reload, HUD re-render) on every cold
        // start when nothing has changed.
        if validatedRead.observation == nil,
           let existingSnapshot = validatedRead.snapshot,
           existingSnapshot.dayIdentifier == expectedDayIdentifier,
           snapshot == existingSnapshot.snapshot,
           activityRead?.trustedRevision.map({ $0 > (existingSnapshot.activityRevision ?? -1) }) != true {
            return CombinedHUDState(
                committedSnapshot: existingSnapshot,
                didPersist: false,
                dataAvailability: .available
            )
        }

        let combinedUpdate = combinedSnapshotStore.updatePetSlice(
            snapshot,
            fallbackActivitySnapshot: activityRead?.snapshot,
            fallbackActivityRevision: activityRead?.trustedRevision
        )
        combinedUpdate.observation.map(diagnosticRecorder.record)

        guard combinedUpdate.didPersist || combinedUpdate.outcome == .alreadyCurrent else {
            if let retainedSnapshot = validatedRead.snapshot {
                return CombinedHUDState(
                    committedSnapshot: retainedSnapshot,
                    didPersist: false,
                    dataAvailability: .failed(
                        combinedUpdate.observation?.reason ?? .persistenceFailed
                    )
                )
            }
            return neutralHUDState(
                snapshot,
                reason: combinedUpdate.observation?.reason ?? .persistenceFailed
            )
        }
        let publishedRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        publishedRead.observation.map(diagnosticRecorder.record)
        guard let combinedSnapshot = publishedRead.snapshot else {
            return neutralHUDState(
                snapshot,
                reason: publishedRead.observation?.reason ?? .persistenceFailed
            )
        }

        return CombinedHUDState(
            committedSnapshot: combinedSnapshot,
            didPersist: combinedUpdate.didPersist
        )
    }

    private static func neutralHUDState(
        _ snapshot: TinyBuddySnapshot,
        reason: TinyBuddySharedSnapshotReason?
    ) -> CombinedHUDState {
        CombinedHUDState(
            snapshot: snapshot,
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            didPersist: false,
            dataAvailability: reason == .staleData ? .stale : .failed(reason)
        )
    }

    private func reloadWidgetIfPossible() {
        do {
            try widgetReloader()
        } catch {
            sharedSnapshotDiagnosticRecorder.record(
                phase: .timelineReload,
                reason: .timelineReloadFailed,
                recovery: .stopped
            )
            updateHiddenSnapshotDiagnosticSummary()
        }
    }

    private static func shouldIncludeTrustedActivity(
        for refreshStatus: GitActivityRefreshStatus?
    ) -> Bool {
        refreshStatus?.outcome != .failed
            || refreshStatus?.diagnostic?.reason != .combinedSnapshotCommitFailed
    }

    private static func makeDisplayState(from presentation: TinyBuddyWidgetPresentation) -> DisplayState {
        switch presentation.displayState {
        case .idle:
            return .idle
        case .focusing:
            return .focusing
        case .paused:
            // Preserve the source-compatible compatibility enum; callers use
            // `displayPresentation.state` for the full cross-surface state.
            return .focusing
        case .completed:
            return .completed
        case .active:
            return .active
        }
    }

    private static func localizedReason(
        for diagnosticReason: GitActivityRefreshDiagnosticReason?,
        fallbackReason: String?
    ) -> String? {
        if let diagnosticReason {
            switch diagnosticReason {
            case .scriptMissing:
                return "刷新组件缺失，暂时无法读取 Git 活动。"
            case .authorizationRequired:
                return "还没有可用的 Git 目录授权，授权后即可恢复 Git 刷新。"
            case .authorizationInvalid:
                return "之前授权的 Git 扫描目录已失效，可能已被移动、删除或系统权限失效，请重新授权。"
            case .scriptExecutionFailed:
                return "Git 刷新执行失败，请稍后再试。"
            case .refreshedActivityUnavailable:
                return "Git 刷新完成，但暂时无法恢复活动快照。"
            case .partialAuthorizationRecovery:
                return "部分 Git 目录授权已失效；可用仓库已刷新，请直接重新授权失效目录。"
            case .partialRecovery:
                return "部分 Git 仓库已刷新；有失效 worktree 被跳过，请检查授权目录中的仓库。"
            case .combinedSnapshotCommitFailed:
                return "Git 活动已读取，但统一快照提交失败；当前继续显示上次完整数据。"
            }
        }

        guard let fallbackReason = fallbackReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              fallbackReason.isEmpty == false else {
            return nil
        }

        if fallbackReason.lowercased().contains("minimum refresh spacing not reached") {
            return "刚刚刷新过，稍后会自动再次尝试。"
        }

        return "刷新暂时不可用，请稍后再试。"
    }

    private static func authorizationActionTitle(
        for diagnosticReason: GitActivityRefreshDiagnosticReason?
    ) -> String? {
        guard let diagnosticReason else {
            return nil
        }

        if diagnosticReason == .authorizationRequired
            || diagnosticReason == .authorizationInvalid
            || diagnosticReason == .partialAuthorizationRecovery
            || diagnosticReason == .partialRecovery {
            return "管理 Git 目录"
        }

        return nil
    }

    private static func summaryTitle(
        for status: GitActivityRefreshStatus,
        diagnosticReason: GitActivityRefreshDiagnosticReason?
    ) -> String {
        if diagnosticReason == .authorizationInvalid {
            return "Git 目录授权已失效"
        }

        if diagnosticReason == .authorizationRequired {
            return "等待 Git 目录授权"
        }

        if diagnosticReason == .partialAuthorizationRecovery {
            return "部分 Git 目录授权已失效"
        }

        if diagnosticReason == .partialRecovery {
            return "Git 活动已部分刷新"
        }

        return "\(triggerTitle(for: status.trigger))触发 \(outcomeTitle(for: status.outcome))"
    }

    private static func badgeTitle(for outcome: GitActivityRefreshOutcome) -> String {
        switch outcome {
        case .succeeded:
            return "成功"
        case .partial:
            return "有警告"
        case .skipped:
            return "跳过"
        case .failed:
            return "失败"
        }
    }

    private static func outcomeTitle(for outcome: GitActivityRefreshOutcome) -> String {
        switch outcome {
        case .succeeded:
            return "刷新成功"
        case .partial:
            return "刷新部分成功"
        case .skipped:
            return "刷新跳过"
        case .failed:
            return "刷新失败"
        }
    }

    private static func triggerTitle(for trigger: GitTodayActivityRefreshTrigger) -> String {
        switch trigger {
        case .launch:
            return "启动"
        case .becameActive:
            return "前台"
        case .reopen:
            return "重开"
        case .didWake:
            return "系统唤醒"
        case .screensDidWake:
            return "屏幕唤醒"
        case .sessionDidBecomeActive:
            return "会话激活"
        case .timeEnvironmentChanged:
            return "时间环境变化"
        case .timer:
            return "定时器"
        }
    }

    private static func refreshDateFormatter(
        timeContext: TinyBuddyTimeContext?
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeContext?.timeZone ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }
}
