import AppKit
@preconcurrency import Foundation
import OSLog
import SwiftUI
import TinyBuddyCore
import WidgetKit

private let tinyBuddyHUDWindowIdentifier = NSUserInterfaceItemIdentifier("TinyBuddy.HUDWindow")
private let tinyBuddyHUDLogger = Logger(subsystem: "local.tinybuddy", category: "HUD")
private let tinyBuddyStartupLogger = Logger(subsystem: "local.tinybuddy", category: "Startup")

private let appColdStartTime = CFAbsoluteTimeGetCurrent()

@MainActor
private func publishTinyBuddyHUDReadyWhenVisible(
    _ window: NSWindow,
    remainingAttempts: Int = 150
) {
    let targetSize = NSSize(width: 284, height: 520)
    let isTargetSize = abs(window.contentLayoutRect.width - targetSize.width) < 0.5
        && abs(window.contentLayoutRect.height - targetSize.height) < 0.5
    let isSemanticallyVisible = window.isVisible
        && !window.isMiniaturized
        && window.screen != nil
        && window.alphaValue > 0

    if window.identifier == tinyBuddyHUDWindowIdentifier,
       isTargetSize,
       isSemanticallyVisible {
        tinyBuddyHUDLogger.notice(
            "HUD ready identifier=TinyBuddy.HUDWindow width=284 height=520"
        )
        let startupDuration = Int((CFAbsoluteTimeGetCurrent() - appColdStartTime) * 1000)
        tinyBuddyStartupLogger.notice(
            "Cold start completed duration=\(startupDuration, privacy: .public)ms"
        )
        return
    }

    guard remainingAttempts > 0 else {
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        publishTinyBuddyHUDReadyWhenVisible(
            window,
            remainingAttempts: remainingAttempts - 1
        )
    }
}

@main
struct TinyBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if let recoveryError = appDelegate.startupRecoveryError {
                TinyBuddyResetRecoveryBlockedView(error: recoveryError)
            } else {
                PetView(viewModel: appDelegate.petViewModel)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            if let recoveryError = appDelegate.startupRecoveryError {
                TinyBuddyResetRecoveryBlockedView(error: recoveryError)
            } else {
                TabView {
                    GitScanRootSettingsView()
                        .tabItem { Label("Git 项目", systemImage: "folder") }
                    ProjectManagementView(
                        registryProvider: { appDelegate.projectIdentityRegistry },
                        sessionEngineProvider: { appDelegate.focusSessionEngine },
                        recentProjectStore: appDelegate.recentProjectStore
                    )
                        .tabItem { Label("项目身份", systemImage: "point.3.connected.trianglepath.dotted") }
                    FocusSessionReviewView(
                        engineProvider: { appDelegate.focusSessionEngine },
                        historyController: appDelegate.historyQueryController ?? HistoryQueryController(
                            queryService: FocusSessionQueryService(sessionProvider: { [] })
                        )
                    )
                        .tabItem { Label("专注记录", systemImage: "clock.arrow.circlepath") }
                    FocusHistoryView(
                        publicationProvider: { appDelegate.focusHistoryPublication },
                        refresh: { appDelegate.refreshFocusHistoryForPresentation() },
                        historyController: appDelegate.historyQueryController
                    )
                        .tabItem { Label("历史与周报", systemImage: "chart.bar.xaxis") }
                    FocusGoalSettingsView(
                        engineProvider: { appDelegate.focusSessionEngine },
                        coordinator: appDelegate.focusGoalCoordinator,
                        onConfigurationSaved: { appDelegate.refreshFocusHistoryForPresentation() }
                    )
                        .tabItem { Label("专注目标", systemImage: "target") }
                }
                .frame(minWidth: 720, minHeight: 480)
            }
        }
    }
}

private struct TinyBuddyResetRecoveryBlockedView: View {
    let error: TinyBuddyResetError

    var body: some View {
        ContentUnavailableView(
            "TinyBuddy 重置未完成",
            systemImage: "exclamationmark.triangle.fill",
            description: Text("\(error.localizedDescription) 修复后请退出并重新打开 TinyBuddy。")
        )
        .frame(minWidth: 460, minHeight: 260)
        .scenePadding()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingStore: TinyBuddyOnboardingStore!
    private var gitScanRootAuthorizationStore: GitScanRootAuthorizationStore!
    private let notificationCenter = NotificationCenter.default
    private let timeEnvironment = TinyBuddyTimeEnvironment()
    private lazy var timeCalibrator = TinyBuddyTimeCalibrator(
        timeEnvironment: timeEnvironment,
        onChange: { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleCalibrationOutcome(outcome)
            }
        }
    )
    private let resetService: TinyBuddyResetService
    private let resetRecoveryError: TinyBuddyResetError?
    private var authorizationCommandObservers: [NSObjectProtocol] = []
    private var isPerformingReset = false
    private lazy var resetExecutionCoordinator = TinyBuddyResetExecutionCoordinator(
        quiesceRuntime: { [weak self] in
            self?.quiesceRuntimeForReset()
        },
        performReset: { [weak self] level in
            self?.resetService.perform(level: level) ?? .failure(.removalFailed)
        },
        reloadWidget: {
            WidgetCenter.shared.reloadAllTimelines()
        },
        terminate: {
            NSApp.terminate(nil)
        },
        reportFailure: { [weak self] error in
            self?.presentResetFailureAndTerminate(error)
        }
    )
    private lazy var dailyStatsStore = DailyStatsStore(timeEnvironment: timeEnvironment)
    private lazy var activityStore = GitTodayActivityStore(timeEnvironment: timeEnvironment)
    lazy var recentProjectStore = GitTodayRecentProjectStore(timeEnvironment: timeEnvironment)
    private lazy var projectDiscoveryStore = TinyBuddyProjectDiscoveryStore()
    private lazy var projectRegistry: TinyBuddyProjectRegistry? = {
        guard let url = TinyBuddySharedData.projectRegistryURL() else { return nil }
        return TinyBuddyProjectRegistry(store: TinyBuddyProjectRegistryFileStore(fileURL: url))
    }()
    private lazy var refreshStatusStore = GitActivityRefreshStatusStore(
        timeEnvironment: timeEnvironment
    )
    private lazy var combinedSnapshotStore = dailyStatsStore.makeCombinedSnapshotStore()
    private lazy var focusSessionPublicationJournal = FocusSessionSnapshotPublicationJournal()
    lazy var petViewModel = PetViewModel(
        onboardingStore: onboardingStore,
        store: dailyStatsStore,
        activityStore: activityStore,
        combinedSnapshotStore: combinedSnapshotStore,
        refreshStatusStore: refreshStatusStore,
        notificationCenter: notificationCenter,
        timeEnvironment: timeEnvironment
    )
    private lazy var gitActivityRefreshCoordinator = GitActivityRefreshCoordinator(
        activityStore: activityStore,
        dailyStatsStore: dailyStatsStore,
        combinedSnapshotStore: combinedSnapshotStore,
        refreshStatusStore: refreshStatusStore,
        gitScanRootStore: gitScanRootAuthorizationStore,
        exclusionRulesProvider: { [configStore] in
            configStore.load()?.exclusionRules.map(\.pattern) ?? []
        },
        timeEnvironment: timeEnvironment,
        activityDidCommit: { [weak self] previous, current in
            Task { @MainActor [weak self] in
                self?.handleCommittedGitActivity(previous: previous, current: current)
            }
        },
        projectDiscoveryCommit: { [weak self] completeScan in
            Task { @MainActor [weak self] in
                self?.reconcileProjectDiscovery(completeScan: completeScan)
            }
        },
        repositoryChangeMonitorFactory: { [weak self, gitScanRootAuthorizationStore] changeHandler in
            GitRepositoryChangeMonitor(
                authorizedRootsProvider: gitScanRootAuthorizationStore!.accessAuthorizedRootResult,
                changeHandler: { impact in
                    Task { @MainActor [weak self] in
                        self?.pendingFocusGitChange = true
                    }
                    changeHandler(impact)
                }
            )
        }
    )
    private lazy var powerStateMonitor = TinyBuddyPowerStateMonitor { [weak self] state in
        self?.gitActivityRefreshCoordinator.handlePowerStateChanged(state)
    }
    // Focus sessions have an independent, App Group-backed journal. It never
    // mutates Git refresh inputs; its lifecycle is deliberately tied to the
    // primary app instance so secondary launches cannot race session writes.
    private var focusSessionBridge: FocusSessionAppBridge?
    /// Ephemeral only: it connects an existing FSEvent-triggered refresh to the
    /// next committed activity delta without persisting a repository path.
    private var pendingFocusGitChange = false
    private lazy var manualFocusMenuBarController = ManualFocusMenuBarController(
        recentProjectNameProvider: { [weak self] in
            self?.petViewModel.displayPresentation.recentProjectName
        },
        registeredProjectsProvider: { [weak self] in
            self?.projectRegistry?.currentSnapshot.projects
                .filter { $0.state == .active }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                ?? []
        }
    )
    private var pendingCommittedGitActivity: (
        previous: GitTodayActivitySnapshot?,
        current: GitTodayActivitySnapshot
    )?
    private lazy var hudVisibilityMonitor = HUDVisibilityMonitor(
        visibilityProvider: { [weak self] in
            self?.isHUDVisible ?? false
        }
    ) { [weak self] isVisible in
        self?.gitActivityRefreshCoordinator.handleInterfaceVisibilityChanged(
            isVisible: isVisible
        )
    }
    private lazy var timeEnvironmentChangeMonitor = TimeEnvironmentChangeMonitor<TinyBuddyTimeContext>(
        notificationCenter: notificationCenter,
        capture: { [timeEnvironment] in
            timeEnvironment.capture()
        }
    ) { [weak self] event in
        guard let self else {
            return
        }
        switch event {
        case .environmentChanged(let context):
            self.gitActivityRefreshCoordinator.handleTimeEnvironmentChanged(context)
            // Run calibration after the coordinator processes the change.
            // The calibrator's monotonic-clock comparison may detect a
            // discontinuity that the notification alone does not reveal.
            self.timeCalibrator.calibrate()
        case .willSleep:
            self.gitActivityRefreshCoordinator.handleWillSleep()
        }
    }

    /// Reacts to time-calibration outcomes.  Meaningful changes trigger a
    /// notification that in-app listeners (including the Widget reload path)
    /// can observe, and advance the shared continuity record so cross-process
    /// readers detect the change.
    private func handleCalibrationOutcome(_ outcome: TinyBuddyCalibrationOutcome) {
        let continuity: TinyBuddyTimeContinuityRecord?
        switch outcome {
        case .dayChanged(_, _, let c),
             .discontinuityDetected(_, _, _, _, let c),
             .timeZoneChanged(_, _, let c):
            continuity = c
        case .stable(let c):
            continuity = c
        case .invalid:
            continuity = nil
        }

        guard let continuity else { return }

        let isMeaningful: Bool
        switch outcome {
        case .dayChanged, .discontinuityDetected, .timeZoneChanged:
            isMeaningful = true
        case .stable, .invalid:
            isMeaningful = false
        }

        // Always persist the observation in userInfo for diagnostics.
        let userInfo: [String: Any] = [
            "calibrationGeneration": continuity.calibrationGeneration,
            "discontinuityCount": continuity.discontinuityCount,
            "dayIdentifier": continuity.lastObservedDayIdentifier,
            "timeZoneIdentifier": continuity.lastObservedTimeZoneIdentifier
        ]

        if isMeaningful {
            notificationCenter.post(
                name: .tinyBuddyTimeRecalibrationRequired,
                object: outcome,
                userInfo: userInfo
            )
            // The refresh coordinator already handles widget reloads when its
            // own time-context invalidation triggers a refresh cycle.  For
            // changes detected purely through the calibrator (e.g., a manual
            // clock adjustment without a system notification), request a
            // widget reload so the Widget picks up the new continuity record.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private lazy var gitScanRootAuthorizationController = GitScanRootAuthorizationController(
        store: gitScanRootAuthorizationStore,
        onboardingStore: onboardingStore
    )
    private lazy var configCoordinator: TinyBuddyConfigCoordinator = {
        TinyBuddyConfigCoordinator(
            configStore: configStore,
            scanRootsProvider: { [gitScanRootAuthorizationStore] in
                gitScanRootAuthorizationStore!.accessAuthorizedRootResult()
            },
            rebuildRepositoryChangeMonitor: { [weak self] in
                self?.gitActivityRefreshCoordinator.handleConfigChanged()
            },
            rescheduleTimer: { [weak self] in
                self?.gitActivityRefreshCoordinator.handleConfigStrategyChanged()
            }
        )
    }()
    private lazy var configStore = TinyBuddyConfigStore()

    var startupRecoveryError: TinyBuddyResetError? {
        resetRecoveryError
    }

    var focusSessionEngine: FocusSessionEngine? {
        focusSessionBridge?.sessionEngine
    }

    var projectIdentityRegistry: TinyBuddyProjectRegistry? {
        projectRegistry
    }

    lazy var focusGoalCoordinator = FocusGoalCoordinator()

    /// Lazy-initialised history query controller shared by the history list and
    /// review views. Created once the focus session engine is available.
    lazy var historyQueryController: HistoryQueryController? = {
        guard let engine = focusSessionBridge?.sessionEngine else { return nil }
        let queryService = FocusSessionQueryService(sessionProvider: { [weak engine] in
            engine?.allSessions ?? []
        })
        return HistoryQueryController(queryService: queryService)
    }()

    override init() {
        let resetService = TinyBuddyResetService()
        self.resetService = resetService
        switch resetService.recoverInterruptedResetIfNeeded() {
        case .success:
            resetRecoveryError = nil
        case .failure(let error):
            resetRecoveryError = error
        }
        super.init()
        if resetRecoveryError == nil {
            initializePersistentStores()
        }
    }

    private func initializePersistentStores() {
        // This runs only after reset recovery succeeds. A failed recovery must
        // not migrate bookmarks, infer onboarding, or republish stale state.
        let gitScanRootAuthorizationStore = GitScanRootAuthorizationStore()
        self.gitScanRootAuthorizationStore = gitScanRootAuthorizationStore
        onboardingStore = TinyBuddyOnboardingStore(
            legacyAuthorizationIsValid: {
                let result = gitScanRootAuthorizationStore.accessAuthorizedRootResult()
                result.roots.forEach { $0.stopAccessing() }
                return result.issue == nil && !result.roots.isEmpty
            }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let resetRecoveryError {
            NSApp.setActivationPolicy(.regular)
            tinyBuddyStartupLogger.error(
                "reset recovery blocked normal startup reason=\(resetRecoveryError.localizedDescription, privacy: .public)"
            )
            return
        }
        // === Single-instance enforcement ===
        //
        // Attempt to become the primary instance. If another instance is already
        // running, we send a wake request and exit immediately without creating
        // any timers, monitors, Git subprocesses, or writing any shared state.
        let coordinator = TinyBuddyInstanceCoordinator.shared
        let role = coordinator.claimInstance { [weak self] in
            // A secondary requested wake — trigger a reopen refresh.
            self?.gitActivityRefreshCoordinator.handleReopen()
        }

        guard role == .primary else {
            coordinator.wakePrimaryInstance()
            // Exit immediately. No resources have been created because lazy
            // property initialization only happens when first accessed. The
            // existing primary instance owns all timers, monitors, and state.
            Darwin.exit(0)
        }

        NSApp.setActivationPolicy(.accessory)
        HUDWindowPositionController.shared.start()
        registerAuthorizationCommandObservers()
        registerSettingsChangeObserver()
        timeEnvironmentChangeMonitor.start()
        _ = timeCalibrator.calibrate()
        configCoordinator.start()
        gitActivityRefreshCoordinator.start(
            isApplicationActive: NSApp.isActive,
            isInterfaceVisible: isHUDVisible,
            powerState: TinyBuddyPowerState.current()
        )
        let focusBridge = FocusSessionAppBridge.createStandard(projectRegistry: projectRegistry)
        focusSessionBridge = focusBridge
        // Keep the legacy callback solely for existing manual-reminder
        // behavior. History publication below is the one source for App/HUD/
        // Widget/weekly presentation and also covers automatic completions.
        focusBridge?.sessionEngine.committedSnapshotHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.evaluateFocusRemindersAfterManualCorrection()
            }
        }
        focusBridge?.sessionEngine.committedHistorySnapshotHandler = { [weak self] publication in
            DispatchQueue.main.async {
                self?.synchronizeFocusHistoryPublication(publication)
            }
        }
        focusBridge?.start()
        // Wire the session engine to the HUD for manual focus control.
        petViewModel.setFocusSessionEngine(focusBridge?.sessionEngine)
        // Wire the menu bar controller to the same engine.
        manualFocusMenuBarController.setEngine(focusBridge?.sessionEngine)
        replayPendingFocusSessionPublicationIfNeeded()
        refreshFocusHistoryForPresentation()
        powerStateMonitor.start()
        hudVisibilityMonitor.start()
    }

    private func reconcileProjectDiscovery(completeScan: Bool) {
        guard let projectRegistry,
              let manifest = projectDiscoveryStore.loadManifest(),
              TinyBuddyProjectDiscoveryReconciler.reconcile(
                manifest,
                registry: projectRegistry,
                completeScan: completeScan,
                at: Date()
              ) != nil else { return }

        if !completeScan {
            let unavailableRoots = Set(gitScanRootAuthorizationStore.authorizationStatuses().compactMap {
                authorization -> String? in
                guard case .unavailable = authorization.state,
                      !authorization.lastKnownPath.isEmpty else { return nil }
                return authorization.lastKnownPath
            })
            if !unavailableRoots.isEmpty {
                _ = projectRegistry.markTemporarilyUnavailable(
                    aliasPrefixes: unavailableRoots,
                    at: Date()
                )
            }
        }

        if let fingerprint = projectDiscoveryStore.loadRecentRepositoryFingerprint(),
           let project = projectRegistry.resolve(projectKey: fingerprint) {
            recentProjectStore.saveTodayProject(id: project.id, displayName: project.displayName)
        } else {
            recentProjectStore.saveTodayProject(id: nil, displayName: nil)
        }
        publishPendingFocusGitActivityIfPossible()
        focusSessionBridge?.sessionEngine.refreshProjectIdentityPresentation()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("TinyBuddy.projectRegistryDidChange"),
                object: nil
            )
        }
    }

    private func handleCommittedGitActivity(
        previous: GitTodayActivitySnapshot?,
        current: GitTodayActivitySnapshot
    ) {
        guard pendingFocusGitChange else { return }
        pendingCommittedGitActivity = (previous, current)
        publishPendingFocusGitActivityIfPossible()
    }

    private func publishPendingFocusGitActivityIfPossible() {
        guard pendingFocusGitChange,
              let pendingCommittedGitActivity else { return }

        let previousCommitCount = pendingCommittedGitActivity.previous?.commitCount
            ?? pendingCommittedGitActivity.current.commitCount ?? 0
        let previousFocusCount = pendingCommittedGitActivity.previous?.focusBlockCount
            ?? pendingCommittedGitActivity.current.focusBlockCount ?? 0
        guard (pendingCommittedGitActivity.current.commitCount ?? 0) > previousCommitCount
                || (pendingCommittedGitActivity.current.focusBlockCount ?? 0) > previousFocusCount else {
            pendingFocusGitChange = false
            self.pendingCommittedGitActivity = nil
            return
        }
        guard let fingerprint = projectDiscoveryStore.loadRecentRepositoryFingerprint(),
              let project = projectRegistry?.resolve(projectKey: fingerprint) else {
            return
        }
        pendingFocusGitChange = false
        self.pendingCommittedGitActivity = nil
        focusSessionBridge?.reportGitActivity(
            project: FocusProjectContext(
                key: project.id.rawValue,
                displayName: project.displayName
            ),
            at: Date()
        )
    }

    /// The Settings report reads the same committed payload as the Widget.
    /// It never opens or aggregates the raw session journal itself.
    var focusHistoryPublication: FocusHistoryPublication? {
        let fallback = dailyStatsStore.loadSnapshot()
        let expectedDay = timeEnvironment.capture()?.dayIdentifier
            ?? fallback.stats.dayIdentifier
        return combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDay
        ).snapshot?.focusHistoryPublication
    }

    /// User-driven and lifecycle-driven refresh. The engine only re-emits its
    /// in-memory aggregation cache; this does not start a scanner or timer.
    func refreshFocusHistoryForPresentation() {
        guard let engine = focusSessionBridge?.sessionEngine else { return }
        if let context = timeEnvironment.capture(),
           engine.currentDayIdentifier != context.dayIdentifier {
            _ = engine.timeChanged(at: context.now, dayIdentifier: context.dayIdentifier)
        }
        engine.republishFocusHistory()
    }

    private func synchronizeFocusHistoryPublication(
        _ publication: FocusHistoryPublication
    ) {
        switch focusSessionPublicationJournal.stage(publication) {
        case .persistenceFailed:
            postFocusHistorySynchronization(succeeded: false)
            return
        case .rejectedStale:
            // A newer archive revision is already staged for recovery. The
            // delayed callback is intentionally invisible to all consumers.
            return
        case .staged, .alreadyCurrent:
            break
        }

        let current = dailyStatsStore.loadSnapshot()
        guard publication.snapshot.recentDays.last?.dayIdentifier == current.stats.dayIdentifier else {
            _ = focusSessionPublicationJournal.clear(expected: publication)
            return
        }

        let update = combinedSnapshotStore.updateFocusHistorySlice(
            publication,
            fallbackSnapshot: current
        )
        guard update.didPersist || update.outcome == .alreadyCurrent else {
            postFocusHistorySynchronization(succeeded: false)
            return
        }
        guard update.snapshot?.focusHistoryPublication == publication else {
            // A later session archive is already committed. Do not make an
            // older callback visible through DailyStats or the HUD.
            if update.snapshot?.focusHistoryPublication?.revision ?? -1 >= publication.revision {
                _ = focusSessionPublicationJournal.clear(expected: publication)
            }
            return
        }

        if let completedSessionCount = publication.snapshot.recentDays.last?.completedSessionCount {
            _ = dailyStatsStore.replaceFocusCount(
                completedSessionCount,
                forDayIdentifier: current.stats.dayIdentifier
            )
        }
        petViewModel.focusSessionStatsDidChange()
        guard focusSessionPublicationJournal.clear(expected: publication) else {
            postFocusHistorySynchronization(succeeded: false)
            return
        }
        // An equal publication has already reached every reader. Emitting a
        // success notification here would make a report view re-publish the
        // same payload and create a feedback loop.
        if update.didPersist {
            postFocusHistorySynchronization(succeeded: true)
        }
    }

    private func replayPendingFocusSessionPublicationIfNeeded() {
        if let legacy = focusSessionPublicationJournal.pending {
            synchronizeLegacyFocusSessionPublication(legacy)
        }
        if let history = focusSessionPublicationJournal.pendingHistory {
            synchronizeFocusHistoryPublication(history)
        }
    }

    /// Supports one surviving pre-history journal entry during upgrade. New
    /// commits use `FocusHistoryPublication` exclusively.
    private func synchronizeLegacyFocusSessionPublication(
        _ derived: FocusSessionDerivedSnapshot
    ) {
        let current = dailyStatsStore.loadSnapshot()
        guard current.stats.dayIdentifier == derived.dayIdentifier else {
            _ = focusSessionPublicationJournal.clear(expected: derived)
            return
        }
        let fallback = TinyBuddySnapshot(
            status: current.status,
            stats: DailyStats(
                dayIdentifier: derived.dayIdentifier,
                focusCount: derived.completedSessionCount,
                completionCount: current.stats.completionCount
            )
        )
        let update = combinedSnapshotStore.updateFocusSessionSlice(
            derived,
            fallbackSnapshot: fallback
        )
        guard update.didPersist || update.outcome == .alreadyCurrent else { return }
        guard update.snapshot?.focusSessionSnapshot?.revision == derived.revision else { return }
        _ = dailyStatsStore.replaceFocusCount(
            derived.completedSessionCount,
            forDayIdentifier: derived.dayIdentifier
        )
        _ = focusSessionPublicationJournal.clear(expected: derived)
    }

    private func evaluateFocusRemindersAfterManualCorrection() {
        guard let engine = focusSessionBridge?.sessionEngine else { return }
        let snapshot = engine.derivedSnapshot()
        focusGoalCoordinator.evaluateReminders(
            sessions: engine.allSessions,
            now: Date(),
            dayIdentifier: snapshot.dayIdentifier
        )
    }

    private func postFocusHistorySynchronization(succeeded: Bool) {
        notificationCenter.post(
            name: .focusSessionSnapshotSynchronizationDidFinish,
            object: nil,
            userInfo: ["succeeded": succeeded]
        )
    }

    private func registerSettingsChangeObserver() {
        authorizationCommandObservers.append(
            notificationCenter.addObserver(
                forName: .tinyBuddySettingsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    if notification.userInfo?[GitScanRootAuthorizationCommand.exclusionsDidChangeKey] as? Bool == true {
                        self?.configCoordinator.reloadPersistedConfig()
                    } else {
                        self?.configCoordinator.proposeScanRootsChange()
                    }
                }
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Relinquish primary instance ownership so the next launch can claim it.
        TinyBuddyInstanceCoordinator.shared.relinquishOwnership(
            removingStateFile: isPerformingReset
        )
        guard resetRecoveryError == nil else {
            return
        }
        authorizationCommandObservers.forEach(notificationCenter.removeObserver)
        authorizationCommandObservers.removeAll()
        hudVisibilityMonitor.stop()
        powerStateMonitor.stop()
        timeEnvironmentChangeMonitor.stop()
        gitActivityRefreshCoordinator.stop()
        focusSessionBridge?.handleTerminate()
        focusSessionBridge?.stop()
        manualFocusMenuBarController.stop()
        HUDWindowPositionController.shared.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        gitActivityRefreshCoordinator.handleDidBecomeActive()
        // A foreground return is a user-driven chance to roll the week/day
        // view forward. This only reuses the in-memory session cache.
        refreshFocusHistoryForPresentation()
    }

    func applicationDidResignActive(_ notification: Notification) {
        gitActivityRefreshCoordinator.handleDidResignActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if gitScanRootAuthorizationStore.hasAuthorizedRoots {
            gitActivityRefreshCoordinator.handleReopen()
        } else {
            handleAuthorizationRequest(
                result: gitScanRootAuthorizationController.requestAuthorizationResult()
            )
        }
        restoreHUDWindow(from: sender)
        return true
    }

    private func registerAuthorizationCommandObservers() {
        guard authorizationCommandObservers.isEmpty else {
            return
        }

        authorizationCommandObservers = [
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRequested) { [weak self] _ in
                self?.handleAuthorizationRequest(
                    result: self?.gitScanRootAuthorizationController.requestAuthorizationResult()
                        ?? GitScanRootAuthorizationRequestResult(
                            didChangeAuthorization: false,
                            didCompleteOnboarding: false
                        )
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationAddRequested) { [weak self] _ in
                self?.handleAuthorizationRequest(
                    result: self?.gitScanRootAuthorizationController.requestAuthorizationResult()
                        ?? GitScanRootAuthorizationRequestResult(
                            didChangeAuthorization: false,
                            didCompleteOnboarding: false
                        )
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRepairRequested) { [weak self] _ in
                self?.handleAuthorizationRequest(
                    result: GitScanRootAuthorizationRequestResult(
                        didChangeAuthorization: self?.gitScanRootAuthorizationController.requestReauthorizationForFirstUnavailableRoot() ?? false,
                        didCompleteOnboarding: false
                    )
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationReauthorizationRequested) { [weak self] notification in
                guard let identifier = notification.userInfo?[GitScanRootAuthorizationCommand.authorizationIdentifierKey] as? String else {
                    return
                }
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.requestReauthorization(for: identifier) ?? false
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRemovalRequested) { [weak self] notification in
                guard let identifier = notification.userInfo?[GitScanRootAuthorizationCommand.authorizationIdentifierKey] as? String else {
                    return
                }
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.removeAuthorization(id: identifier) ?? false
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRemoveAllRequested) { [weak self] _ in
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.removeAllAuthorizations() ?? false
                )
            },
            observeAuthorizationCommand(named: .gitActivityRefreshRequested) { [weak self] _ in
                self?.gitActivityRefreshCoordinator.handleManualRefresh()
            },
            observeAuthorizationCommand(named: .tinyBuddyResetRequested) { [weak self] notification in
                guard let level = notification.object as? TinyBuddyResetLevel else {
                    return
                }
                self?.performReset(level)
            }
        ]
    }

    private func performReset(_ level: TinyBuddyResetLevel) {
        guard !isPerformingReset else { return }
        isPerformingReset = true
        _ = resetExecutionCoordinator.execute(level)
    }

    private func quiesceRuntimeForReset() {
        // Stop every component that can schedule work or write state before
        // the journal is consumed. `stop()` advances the refresh generation,
        // cancels its child process and makes late queue completions no-ops.
        hudVisibilityMonitor.stop()
        powerStateMonitor.stop()
        timeEnvironmentChangeMonitor.stop()
        gitActivityRefreshCoordinator.stop()
        focusSessionBridge?.stop()
        manualFocusMenuBarController.stop()
        HUDWindowPositionController.shared.stop()
        authorizationCommandObservers.forEach(notificationCenter.removeObserver)
        authorizationCommandObservers.removeAll()
    }

    private func presentResetFailureAndTerminate(_ error: TinyBuddyResetError) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "TinyBuddy 重置未完成"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func observeAuthorizationCommand(
        named name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                handler(notification)
            }
        }
    }

    private func handleAuthorizationChange(didChange: Bool) {
        guard didChange else {
            return
        }

        notificationCenter.post(name: .gitScanRootAuthorizationsDidChange, object: nil)
        gitActivityRefreshCoordinator.handleAuthorizationChanged()
        configCoordinator.proposeScanRootsChange()
        restoreHUDWindow(from: NSApp)
    }

    private func handleAuthorizationRequest(result: GitScanRootAuthorizationRequestResult) {
        notificationCenter.post(name: .gitScanRootAuthorizationsDidChange, object: nil)
        if result.didChangeAuthorization {
            gitActivityRefreshCoordinator.handleAuthorizationChanged()
            restoreHUDWindow(from: NSApp)
            return
        }

        if result.requiresStandaloneWidgetReload {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func restoreHUDWindow(from application: NSApplication, shouldPresent: Bool = true) {
        guard let window = application.windows.first(where: {
            $0.identifier == tinyBuddyHUDWindowIdentifier
        }) else {
            return
        }

        if shouldPresent, window.isMiniaturized {
            window.deminiaturize(nil)
        }

        HUDWindowPositionController.shared.prepare(window: window)
        guard shouldPresent else {
            return
        }

        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        publishTinyBuddyHUDReadyWhenVisible(window)
        notificationCenter.post(name: .tinyBuddyHUDWindowDidConfigure, object: window)
    }

    private var isHUDVisible: Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier == tinyBuddyHUDWindowIdentifier
        }) else {
            return false
        }

        return window.isVisible
            && !window.isMiniaturized
            && window.screen != nil
            && window.alphaValue > 0
    }
}

struct WindowConfigurator: NSViewRepresentable {
    private let fixedWidth: CGFloat = 284
    private let fixedHeight: CGFloat = 520

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }

        let isFirstConfiguration = window.identifier != tinyBuddyHUDWindowIdentifier
        window.title = "TinyBuddy"
        window.identifier = tinyBuddyHUDWindowIdentifier
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView?.layoutSubtreeIfNeeded()

        // Accessibility: ensure the HUD window is recognized as a panel
        window.setAccessibilityRole(.popover)
        window.setAccessibilitySubrole(.unknown)
        window.setAccessibilityLabel("TinyBuddy 状态面板")
        window.setAccessibilityHelp("显示当前的 Git 活动状态和宠物情绪")

        let targetSize = NSSize(width: fixedWidth, height: fixedHeight)

        if window.contentLayoutRect.size != targetSize {
            window.setContentSize(targetSize)
        }

        window.minSize = targetSize
        window.maxSize = targetSize
        window.standardWindowButton(.zoomButton)?.isHidden = true
        HUDWindowPositionController.shared.attach(to: window)
        NotificationCenter.default.post(
            name: .tinyBuddyHUDWindowDidConfigure,
            object: window
        )
        if isFirstConfiguration {
            publishTinyBuddyHUDReadyWhenVisible(window)
        }
    }
}
