import AppKit
@preconcurrency import Foundation
import OSLog
import SwiftUI
import TinyBuddyCore
import WidgetKit

private let tinyBuddyHUDWindowIdentifier = NSUserInterfaceItemIdentifier("TinyBuddy.HUDWindow")
private let tinyBuddyHUDLogger = Logger(subsystem: "local.tinybuddy", category: "HUD")

/// Derives the presentation status from the same revision-bound payload that
/// is written to the combined snapshot. This is shared by the live callback
/// and startup journal replay so a crash cannot restore history from one
/// transition while retaining the pet state from an older one.
enum FocusHistoryPublicationStatus {
    static func status(for publication: FocusHistoryPublication) -> PetStatus {
        // A paused session is still open. Keep the legacy status in the
        // focusing bucket while the shared publication carries the explicit
        // paused fact consumed by HUD and Widget presentation.
        if publication.isFocusSessionActive || publication.isFocusSessionPaused {
            return .focusing
        }
        let completedCount = publication.snapshot.recentDays.last?.completedSessionCount ?? 0
        return completedCount > 0 ? .completedOnce : .idle
    }
}
private let tinyBuddyStartupLogger = Logger(subsystem: "local.tinybuddy", category: "Startup")

@MainActor
private enum TinyBuddyStartupClock {
    private(set) static var processStartedAt = CFAbsoluteTimeGetCurrent()

    static func markProcessStart() {
        processStartedAt = CFAbsoluteTimeGetCurrent()
    }

    static func elapsedMilliseconds() -> Int {
        Int((CFAbsoluteTimeGetCurrent() - processStartedAt) * 1000)
    }
}

@MainActor
private final class TinyBuddyHUDPresentationGate {
    static let shared = TinyBuddyHUDPresentationGate()

    private weak var window: NSWindow?
    private(set) var hasRestoredCriticalState = false
    private var hasPublishedVisibleReady = false
    private var visibleReadyHandler: (@MainActor () -> Void)?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.alphaValue = hasRestoredCriticalState ? 1 : 0
    }

    func installVisibleReadyHandler(_ handler: @escaping @MainActor () -> Void) {
        visibleReadyHandler = handler
        if hasPublishedVisibleReady {
            handler()
        }
    }

    func restoreCriticalState() {
        guard !hasRestoredCriticalState else { return }
        hasRestoredCriticalState = true
        guard let window else { return }
        window.alphaValue = 1
        publishTinyBuddyHUDReadyWhenVisible(window)
    }

    func markVisibleReady() -> Bool {
        guard hasRestoredCriticalState, !hasPublishedVisibleReady else { return false }
        hasPublishedVisibleReady = true
        visibleReadyHandler?()
        return true
    }
}

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
        guard TinyBuddyHUDPresentationGate.shared.markVisibleReady() else { return }
        tinyBuddyHUDLogger.notice(
            "HUD ready identifier=TinyBuddy.HUDWindow width=284 height=520"
        )
        let startupDuration = TinyBuddyStartupClock.elapsedMilliseconds()
        tinyBuddyStartupLogger.notice(
            "Cold start completed duration=\(startupDuration, privacy: .public)ms"
        )
        return
    }

    scheduleNextHUDReadyCheck(window, remainingAttempts: remainingAttempts)
}

@MainActor
private func scheduleNextHUDReadyCheck(_ window: NSWindow, remainingAttempts: Int) {
    guard remainingAttempts > 0 else { return }
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

    init() {
        TinyBuddyStartupClock.markProcessStart()
    }

    var body: some Scene {
        WindowGroup {
            if let recoveryError = appDelegate.startupRecoveryError {
                TinyBuddyResetRecoveryBlockedView(error: recoveryError)
            } else {
                PetView(
                    viewModel: appDelegate.petViewModel,
                    registeredProjectsProvider: { appDelegate.activeManualFocusProjects }
                )
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
                        recentProjectStore: appDelegate.recentProjectStore,
                        autoMergeUndoProvider: { appDelegate.lastProjectAutoMergeUndo },
                        clearAutoMergeUndo: { appDelegate.lastProjectAutoMergeUndo = nil }
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
                        historyController: appDelegate.historyQueryController,
                        recentProjectNameProvider: {
                            appDelegate.petViewModel.displayPresentation.recentProjectName
                        },
                        registeredProjectsProvider: { appDelegate.activeManualFocusProjects },
                        onStartFocus: { project in
                            appDelegate.petViewModel.startManualFocus(project: project)
                        }
                    )
                        .tabItem { Label("历史与周报", systemImage: "chart.bar.xaxis") }
                    FocusGoalSettingsView(
                        engineProvider: { appDelegate.focusSessionEngine },
                        coordinator: appDelegate.focusGoalCoordinator,
                        onConfigurationSaved: {
                            appDelegate.refreshFocusHistoryForPresentation()
                            appDelegate.evaluateFocusRemindersNow()
                        }
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
    private let startupProjectIdentityAutoMergeCompletion = DispatchGroup()
    private var authorizationCommandObservers: [NSObjectProtocol] = []
    private var terminationSignalSource: DispatchSourceSignal?
    private var isPerformingReset = false
    private var hasFinishedCriticalStartup = false
    private var hasCompletedStartupProjectIdentityMerge = false
    private var hasObservedVisibleHUD = false
    private var hasScheduledPostHUDStartup = false
    private var hasScheduledStartupFallback = false
    private var hasStartedDeferredStartupServices = false
    private var hasStartedGitActivityRefresh = false
    private var hasPendingStartupWidgetReload = false
    private var isTerminating = false
    private lazy var resetExecutionCoordinator = TinyBuddyResetExecutionCoordinator(
        quiesceRuntime: { [weak self] in
            self?.quiesceRuntimeForReset()
        },
        performReset: { [weak self] level in
            self?.resetService.perform(level: level) ?? .failure(.removalFailed)
        },
        reloadWidget: {
            TinyBuddyWidgetReloadCoordinator.shared.requestReload()
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
    /// Archives per-day snapshots and runs the storage cleanup flow across
    /// launch, cross-day transitions, snapshot commits, termination, and
    /// disk-pressure events. Never blocks or fails HUD/history/Widget reads.
    private lazy var historyArchivalCoordinator = TinyBuddyHistoryArchivalCoordinator(
        snapshotReader: { [combinedSnapshotStore] expectedDay in
            combinedSnapshotStore.readValidated(expectedDayIdentifier: expectedDay)
        },
        historyStore: TinyBuddyHistoryStore(),
        cleanupService: TinyBuddyStorageCleanupService(),
        timeContextProvider: { [timeEnvironment] in
            timeEnvironment.capture()
        }
    )
    private lazy var focusSessionPublicationJournal = FocusSessionSnapshotPublicationJournal()
    lazy var petViewModel = PetViewModel(
        onboardingStore: onboardingStore,
        store: dailyStatsStore,
        activityStore: activityStore,
        combinedSnapshotStore: combinedSnapshotStore,
        refreshStatusStore: refreshStatusStore,
        reloadWidgetForNewCurrentDaySnapshot: true,
        notificationCenter: notificationCenter,
        timeEnvironment: timeEnvironment,
        registeredProjectsProvider: { [weak self] in
            self?.activeManualFocusProjects ?? []
        },
        widgetReloader: { [weak self] in
            self?.requestWidgetTimelineReload()
        }
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
    /// Undo token of the most recent automatic duplicate merge. Cleared by any
    /// later explicit identity modification; the registry's revision guard
    /// rejects a stale undo attempt safely.
    fileprivate var lastProjectAutoMergeUndo: TinyBuddyProjectMergeUndo?
    private lazy var manualFocusMenuBarController = ManualFocusMenuBarController(
        recentProjectNameProvider: { [weak self] in
            self?.petViewModel.displayPresentation.recentProjectName
        },
        registeredProjectsProvider: { [weak self] in
            self?.activeManualFocusProjects ?? []
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
            // Archive the closing snapshot of the day that just ended BEFORE
            // the refresh coordinator invalidates and re-initializes the
            // snapshot store for the new day. The current day's file is never
            // touched by archival or cleanup.
            self.historyArchivalCoordinator.handleDayTransition(to: context.dayIdentifier)
            if self.hasStartedGitActivityRefresh {
                self.gitActivityRefreshCoordinator.handleTimeEnvironmentChanged(context)
            }
            // Run calibration after the coordinator processes the change.
            // The calibrator's monotonic-clock comparison may detect a
            // discontinuity that the notification alone does not reveal.
            self.timeCalibrator.calibrate()
        case .willSleep:
            if self.hasStartedGitActivityRefresh {
                self.gitActivityRefreshCoordinator.handleWillSleep()
            }
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

        // A day change detected through the calibrator (for example after
        // sleep across midnight) follows the same archival rule as the system
        // notification path: archive the closing day before any new-day write.
        let transitionDay: String?
        switch outcome {
        case .dayChanged(_, let to, _),
             .discontinuityDetected(_, let to, _, _, _):
            transitionDay = to
        case .timeZoneChanged, .stable, .invalid:
            transitionDay = nil
        }
        if let transitionDay {
            historyArchivalCoordinator.handleDayTransition(to: transitionDay)
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
            requestWidgetTimelineReload()
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
                guard let self, self.hasStartedGitActivityRefresh else { return }
                self.gitActivityRefreshCoordinator.handleConfigChanged()
            },
            rescheduleTimer: { [weak self] in
                guard let self, self.hasStartedGitActivityRefresh else { return }
                self.gitActivityRefreshCoordinator.handleConfigStrategyChanged()
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

    /// Both manual-control surfaces receive this exact registry projection so
    /// choosing the same named project never creates divergent manual keys.
    var activeManualFocusProjects: [TinyBuddyProject] {
        projectRegistry?.currentSnapshot.projects
            .filter { $0.state == .active }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            ?? []
    }

    lazy var focusGoalCoordinator = FocusGoalCoordinator()

    /// Lazy-initialised history query controller shared by the history list and
    /// review views. Created once the focus session engine is available.
    lazy var historyQueryController: HistoryQueryController? = {
        guard let engine = focusSessionBridge?.sessionEngine else { return nil }
        let registry = projectRegistry
        let queryService = FocusSessionQueryService(sessionProvider: { [weak engine] in
            engine?.allSessions ?? []
        }, projectResolver: { context in
            guard let project = registry?.resolve(projectKey: context.key) else { return context }
            return FocusProjectContext(key: project.id.rawValue, displayName: project.displayName)
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

    /// Update installers and repository scripts terminate a running app with
    /// SIGTERM; macOS' default disposition kills the process without posting
    /// `NSApplication.willTerminateNotification`, silently degrading state
    /// hand-off to crash recovery (the open session ends at its last event
    /// instead of the exit moment and the combined snapshot keeps the live
    /// state). Converting SIGTERM into a normal termination preserves the
    /// final session settlement, the combined snapshot commit, and the
    /// per-day archive. SIGKILL cannot be intercepted; its recovery is
    /// handled by the launch-time session journal reconciliation.
    private func installTerminationSignalHandlers() {
        guard terminationSignalSource == nil else { return }

        // A raw POSIX signal callback may only call async-signal-safe APIs;
        // dispatching a closure or touching AppKit from that callback can
        // deadlock in allocator/runtime state interrupted by SIGTERM. Ignore
        // the default disposition and let a retained DispatchSource deliver
        // the event safely on the main queue instead.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
        terminationSignalSource = source
        source.resume()
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
            guard let self, self.hasStartedGitActivityRefresh else { return }
            self.gitActivityRefreshCoordinator.handleReopen()
        }

        guard role == .primary else {
            coordinator.wakePrimaryInstance()
            // Exit immediately. No resources have been created because lazy
            // property initialization only happens when first accessed. The
            // existing primary instance owns all timers, monitors, and state.
            Darwin.exit(0)
        }

        installTerminationSignalHandlers()
        TinyBuddyHUDPresentationGate.shared.installVisibleReadyHandler { [weak self] in
            self?.hudDidBecomeReady()
        }
        beginStartupProjectIdentityAutoMerge()
        NSApp.setActivationPolicy(.accessory)
        HUDWindowPositionController.shared.start()
        registerAuthorizationCommandObservers()
        registerSettingsChangeObserver()
        registerLoginItemChangeObserver()
        timeEnvironmentChangeMonitor.start()
        _ = timeCalibrator.calibrate()
        // Calibration delivers meaningful changes through a MainActor Task,
        // so it may not archive the previous day until after startup work has
        // advanced the combined snapshot. Recover the exact older snapshot
        // synchronously before config/refresh startup can write a new day.
        // Archival is best-effort; failure is logged and does not block launch.
        _ = historyArchivalCoordinator.archivePriorDaySnapshotBeforeLaunchWrites()
        let focusBridge = FocusSessionAppBridge.createStandard(
            projectRegistry: projectRegistry,
            exclusionRulesProvider: { [configStore] in
                configStore.load()?.exclusionRules.map(\.pattern) ?? []
            }
        )
        focusSessionBridge = focusBridge
        // Evaluate reminders from every durable session mutation, including
        // automatic/manual lifecycle transitions. The bridge heartbeat below
        // covers elapsed time in an unchanged open session.
        focusBridge?.sessionEngine.committedReminderEvaluationHandler = { [weak self, weak focusBridge] reminderSnapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                // The engine is the single lifecycle authority. Refresh both
                // in-process control projections from that committed state so
                // a command issued by the menu bar, HUD, or a lifecycle event
                // cannot leave the other surface showing a stale session.
                self.petViewModel.refreshManualControlState()
                self.manualFocusMenuBarController.refresh()
                guard let currentDay = focusBridge?.sessionEngine.currentDayIdentifier,
                      reminderSnapshot.dayIdentifier == currentDay else { return }
                self.evaluateFocusReminders(
                    FocusReminderEvaluationInput(
                        sessions: reminderSnapshot.sessions,
                        dayIdentifier: reminderSnapshot.dayIdentifier,
                        now: reminderSnapshot.committedAt
                    )
                )
            }
        }
        focusBridge?.reminderEvaluationHandler = { [weak self] input in
            self?.evaluateFocusReminders(input)
        }
        focusBridge?.sessionEngine.committedHistorySnapshotHandler = { [weak self] publication in
            DispatchQueue.main.async {
                guard let self else { return }
                // A fast start/pause/end sequence can enqueue more than one
                // publication before the main queue drains. Do not make an
                // already-superseded transition visible in the shared snapshot
                // (and therefore WidgetKit) just because its callback arrived
                // first.
                if let latestRevision = self.focusSessionEngine?.focusHistoryPublication()?.revision,
                   publication.revision < latestRevision {
                    return
                }
                // The callback can be delayed behind a later engine mutation.
                // Derive status from the revision-bound publication itself so
                // this combined-snapshot write never mixes history from one
                // transition with live state from another.
                let status = FocusHistoryPublicationStatus.status(for: publication)
                // The publication path atomically commits both the history and
                // status slices, then updates HUD and Widget from that durable
                // combined snapshot.
                self.synchronizeFocusHistoryPublication(publication, status: status)
            }
        }
        // Periodic live-minute re-emissions advance the authoritative snapshot
        // for HUD and persistence but deliberately skip the WidgetKit reload:
        // the Widget self-schedules its next refresh while a session is live,
        // so a per-minute reload here would waste WidgetKit's refresh budget.
        focusBridge?.sessionEngine.liveMinuteRepublishHandler = { [weak self] publication in
            DispatchQueue.main.async {
                guard let self else { return }
                // The same superseded-publication guard as the committed path:
                // a delayed live re-emission must never overwrite a newer
                // transition that already reached the shared snapshot.
                if let latestRevision = self.focusSessionEngine?.focusHistoryPublication()?.revision,
                   publication.revision < latestRevision {
                    return
                }
                self.synchronizeFocusHistoryPublication(
                    publication,
                    status: nil,
                    reloadWidget: false
                )
            }
        }
        focusBridge?.start()
        // Wire the session engine to the HUD for manual focus control.
        petViewModel.setFocusSessionEngine(focusBridge?.sessionEngine)
        // Wire the menu bar controller to the same engine.
        manualFocusMenuBarController.setEngine(focusBridge?.sessionEngine)
        replayPendingFocusSessionPublicationIfNeeded()
        refreshFocusHistoryForPresentation()
        hasFinishedCriticalStartup = true
        revealHUDWhenStartupStateIsRestored()
        scheduleDeferredStartupFallback()
        schedulePostHUDStartupIfReady()
    }

    /// Called only after the configured HUD window is actually visible.
    /// Durable state recovery and presentation wiring remain in
    /// `applicationDidFinishLaunching`; this gate starts launch-time services
    /// once the first frame can be seen and accepted.
    func hudDidBecomeReady() {
        guard resetRecoveryError == nil else { return }
        hasObservedVisibleHUD = true
        schedulePostHUDStartupIfReady()
    }

    private func revealHUDWhenStartupStateIsRestored() {
        guard hasFinishedCriticalStartup,
              hasCompletedStartupProjectIdentityMerge,
              !isPerformingReset,
              resetRecoveryError == nil else {
            return
        }
        TinyBuddyHUDPresentationGate.shared.restoreCriticalState()
    }

    private func schedulePostHUDStartupIfReady() {
        guard hasFinishedCriticalStartup,
              hasObservedVisibleHUD,
              hasCompletedStartupProjectIdentityMerge,
              !hasScheduledPostHUDStartup,
              !hasStartedDeferredStartupServices,
              !isPerformingReset,
              !isTerminating,
              resetRecoveryError == nil else {
            return
        }
        hasScheduledPostHUDStartup = true
        // Let AppKit return to its event loop after the visible frame before
        // running synchronous launch reconciliation on the main actor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.hasScheduledPostHUDStartup = false
            self.startDeferredStartupServices(trigger: "hud-visible")
        }
    }

    private func scheduleDeferredStartupFallback() {
        guard !hasScheduledStartupFallback else { return }
        hasScheduledStartupFallback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.hasScheduledStartupFallback = false
            guard !self.isTerminating,
                  !self.isPerformingReset,
                  self.resetRecoveryError == nil,
                  !self.hasObservedVisibleHUD else { return }
            guard self.hasFinishedCriticalStartup,
                  self.hasCompletedStartupProjectIdentityMerge else {
                self.scheduleDeferredStartupFallback()
                return
            }
            self.startDeferredStartupServices(trigger: "hud-visibility-timeout")
        }
    }

    private func startDeferredStartupServices(trigger: String) {
        guard !hasStartedDeferredStartupServices,
              hasFinishedCriticalStartup,
              hasCompletedStartupProjectIdentityMerge,
              !isPerformingReset,
              !isTerminating,
              resetRecoveryError == nil else {
            return
        }
        hasStartedDeferredStartupServices = true
        tinyBuddyStartupLogger.notice(
            "Deferred startup services starting trigger=\(trigger, privacy: .public)"
        )

        configCoordinator.start()
        // Keep bookmark path reconciliation before the first Git scan, but
        // after the initial HUD frame is available.
        configCoordinator.reconcilePersistedScanRoots()

        // SMAppService status and repair are best-effort and independent of
        // the first HUD state. Keep them in the same startup order and fold
        // the actual result back into the persisted intent.
        let loginItemManager = TinyBuddyLoginItemManager.shared
        loginItemManager.refreshStatus()
        do {
            try loginItemManager.recoverIfNeeded(
                intentEnabled: configCoordinator.currentConfig()?.launchAtLoginEnabled ?? false
            )
        } catch {
            tinyBuddyStartupLogger.error(
                "login item recovery failed reason=\(error.localizedDescription, privacy: .public)"
            )
        }
        configCoordinator.reconcileLaunchAtLoginIntent()

        gitActivityRefreshCoordinator.start(
            isApplicationActive: NSApp.isActive,
            isInterfaceVisible: isHUDVisible,
            powerState: TinyBuddyPowerState.current()
        )
        hasStartedGitActivityRefresh = true

        // PetViewModel has already loaded the committed snapshot and repaired
        // today's combined presentation before the HUD became visible. Archive
        // it and schedule cleanup here, after the prior-day recovery above.
        historyArchivalCoordinator.runAtLaunch()
        flushPendingStartupWidgetReload()

        // The launch refresh is active before upgrade recovery is requested;
        // preserve the existing single-refresh and Widget self-healing order.
        let upgradeState = TinyBuddyVersionUpgradeTracker.checkForUpgrade()
        if upgradeState.isUpgrade {
            tinyBuddyStartupLogger.notice(
                "Version upgrade detected: \(upgradeState.previousShortVersion ?? "nil", privacy: .public) -> \(upgradeState.currentShortVersion ?? "nil", privacy: .public) build \(upgradeState.previousBuildVersion ?? "nil", privacy: .public) -> \(upgradeState.currentBuildVersion ?? "nil", privacy: .public)"
            )
            gitActivityRefreshCoordinator.handleManualRefresh()
            registerPostUpgradeWidgetReloadObserver()
        }
        TinyBuddyVersionUpgradeTracker.recordCurrentVersion()

        powerStateMonitor.start()
        hudVisibilityMonitor.start()
        tinyBuddyStartupLogger.notice(
            "Deferred startup services completed trigger=\(trigger, privacy: .public)"
        )
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

        runProjectIdentityAutoMergeIfNeeded()

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

    private func beginStartupProjectIdentityAutoMerge() {
        guard let projectRegistry else {
            hasCompletedStartupProjectIdentityMerge = true
            return
        }

        let completion = startupProjectIdentityAutoMergeCompletion
        completion.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self, projectRegistry, completion] in
            let outcome = projectRegistry.autoMergeDuplicates()
            completion.leave()
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isPerformingReset,
                      !self.isTerminating,
                      self.resetRecoveryError == nil else {
                    return
                }
                self.applyProjectIdentityAutoMergeOutcome(outcome)
                self.hasCompletedStartupProjectIdentityMerge = true
                self.revealHUDWhenStartupStateIsRestored()
                self.schedulePostHUDStartupIfReady()
            }
        }
    }

    /// Merges duplicate project identities that share one repository
    /// fingerprint. Runs after launch and after every committed discovery so
    /// moved/renamed/re-authorized repositories converge on one identity even
    /// when only one of the duplicate rows is still observed. Explicit
    /// archives are never merged automatically; the manual preview/merge path
    /// in the project settings covers them. The last undo token stays
    /// available to the project settings until the next identity change.
    private func runProjectIdentityAutoMergeIfNeeded() {
        guard let projectRegistry else { return }
        applyProjectIdentityAutoMergeOutcome(projectRegistry.autoMergeDuplicates())
    }

    private func applyProjectIdentityAutoMergeOutcome(
        _ outcome: TinyBuddyProjectAutoMergeOutcome
    ) {
        switch outcome {
        case .completed(let mergeCount, let undo):
            if mergeCount > 0 {
                lastProjectAutoMergeUndo = undo
                focusSessionBridge?.sessionEngine.refreshProjectIdentityPresentation()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("TinyBuddy.projectRegistryDidChange"),
                        object: nil
                    )
                }
            }
        case .persistenceFailed:
            tinyBuddyStartupLogger.error(
                "automatic project identity merge could not be persisted; registry and history unchanged"
            )
        }
    }

    private func handleCommittedGitActivity(
        previous: GitTodayActivitySnapshot?,
        current: GitTodayActivitySnapshot
    ) {
        // Archive the committed snapshot for today (throttled, atomic, and
        // idempotent) so history tracks the latest committed state.
        if let currentDay = timeEnvironment.capture()?.dayIdentifier {
            archiveCommittedSnapshotAfterStartup(dayIdentifier: currentDay)
        }
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
        // Attribution is limited to active projects (the same rule as
        // `TinyBuddyProjectRegistry.automaticContext`): a project archived
        // between the scan and this commit must not receive new automatic
        // focus. The pending delta is consumed either way so a permanently
        // archived project does not retry the same stale report forever; a
        // later restore reconnects attribution through the next committed
        // activity.
        guard let fingerprint = projectDiscoveryStore.loadRecentRepositoryFingerprint(),
              let project = projectRegistry?.automaticContext(for: fingerprint) else {
            pendingFocusGitChange = false
            self.pendingCommittedGitActivity = nil
            return
        }
        pendingFocusGitChange = false
        self.pendingCommittedGitActivity = nil
        focusSessionBridge?.reportGitActivity(project: project, at: Date())
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

    /// Commits the engine's latest focus-history publication to the combined
    /// snapshot synchronously at termination. The regular committed-history
    /// callback is dispatched asynchronously and cannot be relied on to run
    /// before the process exits; without this flush the last combined snapshot
    /// would keep the open-session state and the per-day archive would capture
    /// a stale day image. Mirrors the startup journal-replay path (same status
    /// derivation, same revision guards), so a termination that is killed in
    /// the middle still leaves a durable replay candidate behind.
    private func flushFinalFocusPublicationForTermination() {
        guard let engine = focusSessionBridge?.sessionEngine,
              let publication = engine.focusHistoryPublication() else {
            return
        }
        synchronizeFocusHistoryPublication(
            publication,
            status: FocusHistoryPublicationStatus.status(for: publication)
        )
    }

    private func synchronizeFocusHistoryPublication(
        _ publication: FocusHistoryPublication,
        status: PetStatus? = nil,
        reloadWidget: Bool = true
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

        // Build a snapshot override when a status change accompanies this
        // publication, so the combined snapshot atomically reflects both the
        // new pet status and the focus history in a single write.
        let snapshotOverride: TinyBuddySnapshot?
        if let status {
            snapshotOverride = TinyBuddySnapshot(
                status: status,
                stats: current.stats
            )
        } else {
            snapshotOverride = nil
        }

        let update = combinedSnapshotStore.updateFocusHistorySlice(
            publication,
            fallbackSnapshot: current,
            snapshotOverride: snapshotOverride
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
            // If the committed publication is different but the writer was a
            // concurrent caller, the newer publication was already written and
            // the Widget should have been reloaded by that caller.
            return
        }

        // A same-revision callback can race with a user status selection: the
        // selection retains the already-committed history publication but may
        // intentionally have a different legacy status. Only mirror the
        // callback when the durable combined snapshot still carries the
        // callback's status; otherwise the old callback is a no-op.
        if let status, update.snapshot?.snapshot.status != status {
            _ = focusSessionPublicationJournal.clear(expected: publication)
            return
        }

        if let completedSessionCount = publication.snapshot.recentDays.last?.completedSessionCount {
            _ = dailyStatsStore.replaceFocusCount(
                completedSessionCount,
                forDayIdentifier: current.stats.dayIdentifier
            )
        }
        // Update the legacy compatibility store only after this publication is
        // known to be the current combined snapshot. A stale asynchronous
        // callback must not alter HUD state ahead of the durable authority.
        if let status {
            self.petViewModel.applyFocusStatusForPublication(status)
        }
        petViewModel.focusSessionStatsDidChange(reloadWidget: reloadWidget)
        guard focusSessionPublicationJournal.clear(expected: publication) else {
            postFocusHistorySynchronization(succeeded: false)
            return
        }

        if update.didPersist {
            // Full notification path: Widget reload + event broadcast.
            postFocusHistorySynchronization(succeeded: true, reloadWidget: reloadWidget)
        } else {
            // The publication is already current (same revision and content).
            // Reload the Widget directly so it picks up any latest in-memory
            // state from the combined snapshot, but skip the event broadcast
            // to avoid a notification loop when FocusHistoryView calls the
            // engine republish in response to the notification.
            Logger(
                subsystem: "local.tinybuddy",
                category: "SharedSnapshot"
            ).notice(
                "focus history already current, reloading widget without notification"
            )
            if reloadWidget {
                requestWidgetTimelineReload()
            }
        }

        // Track the committed snapshot in the per-day history archive. This
        // runs after the durable write so the archive always reflects the
        // latest committed state; a failure here never affects HUD, history
        // views, or Widget reads (the combined snapshot stays authoritative).
        if let currentDay = timeEnvironment.capture()?.dayIdentifier {
            archiveCommittedSnapshotAfterStartup(dayIdentifier: currentDay)
        }
    }

    private func requestWidgetTimelineReload() {
        guard hasStartedDeferredStartupServices else {
            hasPendingStartupWidgetReload = true
            return
        }
        TinyBuddyWidgetReloadCoordinator.shared.requestReload()
    }

    private func flushPendingStartupWidgetReload() {
        guard hasPendingStartupWidgetReload else { return }
        hasPendingStartupWidgetReload = false
        TinyBuddyWidgetReloadCoordinator.shared.requestReload()
    }

    private func archiveCommittedSnapshotAfterStartup(dayIdentifier: String) {
        // The launch archive reads the latest committed combined snapshot, so
        // focus publications that race first-frame restoration are included
        // without writing an archive synchronously on the HUD path.
        guard hasStartedDeferredStartupServices else { return }
        historyArchivalCoordinator.handleCommittedSnapshot(dayIdentifier: dayIdentifier)
    }

    private func replayPendingFocusSessionPublicationIfNeeded() {
        if let legacy = focusSessionPublicationJournal.pending {
            synchronizeLegacyFocusSessionPublication(legacy)
        }
        if let history = focusSessionPublicationJournal.pendingHistory {
            synchronizeFocusHistoryPublication(
                history,
                status: FocusHistoryPublicationStatus.status(for: history)
            )
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

    private func evaluateFocusReminders(_ input: FocusReminderEvaluationInput) {
        focusGoalCoordinator.enqueueReminderEvaluation(input)
    }

    func evaluateFocusRemindersNow() {
        guard let engine = focusSessionBridge?.sessionEngine,
              let context = timeEnvironment.capture() else { return }
        evaluateFocusReminders(
            FocusReminderEvaluationInput(
                sessions: engine.allSessions,
                dayIdentifier: engine.currentDayIdentifier,
                now: context.now
            )
        )
    }

    private func postFocusHistorySynchronization(succeeded: Bool, reloadWidget: Bool = true) {
        if succeeded {
            if reloadWidget {
                // Safety net: reload widget timelines directly so consumers
                // always see the latest committed focus history, even if the
                // PetViewModel callback path is not triggered (e.g. early
                // return in the caller). Live-minute re-emissions skip this:
                // the Widget self-schedules its refresh while a session is live.
                requestWidgetTimelineReload()
            }
        } else {
            // A failed focus-history write may indicate disk pressure. Run
            // cleanup immediately; it reclaims caches and age-expired temp
            // artifacts and never deletes the current day, active focus
            // sessions, recovery backups, or still-referenced data.
            historyArchivalCoordinator.handleDiskSpacePressure()
        }
        notificationCenter.post(
            name: .focusSessionSnapshotSynchronizationDidFinish,
            object: nil,
            userInfo: ["succeeded": succeeded, "reloadWidget": reloadWidget]
        )
    }

    private func registerSettingsChangeObserver() {
        authorizationCommandObservers.append(
            observeAuthorizationCommand(
                named: .tinyBuddySettingsDidChange,
                payload: { notification in
                    notification.userInfo?[GitScanRootAuthorizationCommand.exclusionsDidChangeKey]
                        as? Bool == true
                }
            ) { [weak self] exclusionsDidChange in
                if exclusionsDidChange {
                    self?.configCoordinator.reloadPersistedConfig()
                } else {
                    self?.configCoordinator.proposeScanRootsChange()
                }
            }
        )
    }

    private func registerLoginItemChangeObserver() {
        // A successful settings-toggle change persists the intent through the
        // coordinator's single coalesced path. The manager call inside propose
        // is idempotent, so this cannot double-register.
        authorizationCommandObservers.append(
            observeAuthorizationCommand(
                named: .tinyBuddyLaunchAtLoginChangeRequested,
                payload: { notification in
                    notification.userInfo?[TinyBuddyLoginItemCommand.enabledKey] as? Bool ?? false
                }
            ) { [weak self] enabled in
                self?.handleLaunchAtLoginChangeRequested(enabled: enabled)
            }
        )
        // Any observed actual-state change (launch refresh, activation refresh,
        // settings view onAppear) folds back into the persisted intent.
        authorizationCommandObservers.append(
            observeAuthorizationCommand(named: .tinyBuddyLoginItemStatusDidChange) { [weak self] in
                self?.configCoordinator.reconcileLaunchAtLoginIntent()
            }
        )
    }

    private func handleLaunchAtLoginChangeRequested(enabled: Bool) {
        do {
            try configCoordinator.proposeLaunchAtLoginChange(enabled)
        } catch {
            // The settings view already surfaced the failure; only the
            // persisted intent must not move.
            tinyBuddyStartupLogger.error(
                "launch-at-login change failed reason=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        startupProjectIdentityAutoMergeCompletion.wait()
        // Relinquish primary instance ownership so the next launch can claim it.
        TinyBuddyInstanceCoordinator.shared.relinquishOwnership(
            removingStateFile: isPerformingReset
        )
        guard resetRecoveryError == nil else {
            return
        }
        if !isPerformingReset {
            flushPendingStartupWidgetReload()
        }
        authorizationCommandObservers.forEach(notificationCenter.removeObserver)
        authorizationCommandObservers.removeAll()
        if hasStartedDeferredStartupServices {
            hudVisibilityMonitor.stop()
            powerStateMonitor.stop()
        }
        timeEnvironmentChangeMonitor.stop()
        if hasStartedGitActivityRefresh {
            gitActivityRefreshCoordinator.stop()
        }
        // Normal termination finalizes the open session synchronously: the
        // session journal write is atomic and immediate. During a reset the
        // session journal has already been removed and the engine must not
        // finalize (and thereby recreate) pre-reset sessions.
        if !isPerformingReset {
            focusSessionBridge?.handleTerminate()
            // The finalize publication is normally delivered through an async
            // main-queue callback that is not guaranteed to run before the
            // process exits. Commit it synchronously here so the combined
            // snapshot — and therefore HUD, Widget, and the per-day archive —
            // reflects the ended session and never resurrects a stale
            // "focusing" state on relaunch.
            flushFinalFocusPublicationForTermination()
        }
        focusSessionBridge?.stop()
        // Final archival of today's committed snapshot — now including the
        // finalized session state — before the process exits; best-effort and
        // never blocking termination recovery.
        historyArchivalCoordinator.handleTermination()
        manualFocusMenuBarController.stop()
        HUDWindowPositionController.shared.stop()
        terminationSignalSource?.cancel()
        terminationSignalSource = nil
        signal(SIGTERM, SIG_DFL)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if hasStartedGitActivityRefresh {
            gitActivityRefreshCoordinator.handleDidBecomeActive()
            // The user may have changed the login item in System Settings while
            // the app was in the background; refresh only after startup sync began.
            TinyBuddyLoginItemManager.shared.refreshStatus()
            // Initial history publication already ran on the critical path;
            // activation refreshes only apply to later foreground returns.
            refreshFocusHistoryForPresentation()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if hasStartedGitActivityRefresh {
            gitActivityRefreshCoordinator.handleDidResignActive()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if gitScanRootAuthorizationStore.hasAuthorizedRoots {
            if hasStartedGitActivityRefresh {
                gitActivityRefreshCoordinator.handleReopen()
            }
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

        let identifierPayload: @Sendable (Notification) -> String? = { notification in
            notification.userInfo?[GitScanRootAuthorizationCommand.authorizationIdentifierKey]
                as? String
        }
        authorizationCommandObservers = [
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRequested) { [weak self] in
                self?.handleAuthorizationRequest(
                    result: self?.gitScanRootAuthorizationController.requestAuthorizationResult()
                        ?? GitScanRootAuthorizationRequestResult(
                            didChangeAuthorization: false,
                            didCompleteOnboarding: false
                        )
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationAddRequested) { [weak self] in
                self?.handleAuthorizationRequest(
                    result: self?.gitScanRootAuthorizationController.requestAuthorizationResult()
                        ?? GitScanRootAuthorizationRequestResult(
                            didChangeAuthorization: false,
                            didCompleteOnboarding: false
                        )
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRepairRequested) { [weak self] in
                self?.handleAuthorizationRequest(
                    result: GitScanRootAuthorizationRequestResult(
                        didChangeAuthorization: self?.gitScanRootAuthorizationController.requestReauthorizationForFirstUnavailableRoot() ?? false,
                        didCompleteOnboarding: false
                    )
                )
            },
            observeAuthorizationCommand(
                named: .gitScanRootAuthorizationReauthorizationRequested,
                payload: identifierPayload
            ) { [weak self] identifier in
                guard let identifier else { return }
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.requestReauthorization(for: identifier) ?? false
                )
            },
            observeAuthorizationCommand(
                named: .gitScanRootAuthorizationRemovalRequested,
                payload: identifierPayload
            ) { [weak self] identifier in
                guard let identifier else { return }
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.removeAuthorization(id: identifier) ?? false
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRemoveAllRequested) { [weak self] in
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.removeAllAuthorizations() ?? false
                )
            },
            observeAuthorizationCommand(named: .gitActivityRefreshRequested) { [weak self] in
                guard let self, self.hasStartedGitActivityRefresh else { return }
                self.gitActivityRefreshCoordinator.handleManualRefresh()
            },
            observeAuthorizationCommand(
                named: .tinyBuddyResetRequested,
                payload: { $0.object as? TinyBuddyResetLevel }
            ) { [weak self] level in
                guard let level else { return }
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
        startupProjectIdentityAutoMergeCompletion.wait()
        hasPendingStartupWidgetReload = false
        // Stop every component that can schedule work or write state before
        // the journal is consumed. `stop()` advances the refresh generation,
        // cancels its child process and makes late queue completions no-ops.
        if hasStartedDeferredStartupServices {
            hudVisibilityMonitor.stop()
            powerStateMonitor.stop()
        }
        timeEnvironmentChangeMonitor.stop()
        if hasStartedGitActivityRefresh {
            gitActivityRefreshCoordinator.stop()
        }
        petViewModel.stopManualControlRefresh()
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

    /// Registers an observer on `.gitActivityRefreshStatusDidChange`.
    /// When the post-upgrade rebuild flag is still set and a refresh status
    /// arrives, it clears the flag and reloads all widget timelines so the
    /// Widget recovers with committed state rather than pre-upgrade data.
    /// The observer is cleaned up automatically on app termination.
    private func registerPostUpgradeWidgetReloadObserver() {
        guard TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired() else {
            return
        }
        authorizationCommandObservers.append(
            observeAuthorizationCommand(named: .gitActivityRefreshStatusDidChange) { [weak self] in
                self?.handlePostUpgradeRefreshCompletion()
            }
        )
    }

    private func handlePostUpgradeRefreshCompletion() {
        guard TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired() else {
            return
        }
        TinyBuddyVersionUpgradeTracker.clearPostUpgradeRebuildRequired()
        tinyBuddyStartupLogger.notice(
            "Post-upgrade rebuild completed; reloading widget timelines"
        )
        TinyBuddyWidgetReloadCoordinator.shared.requestReload()
    }

    /// Notification itself is not Sendable. Extract only a typed Sendable
    /// command value before entering the main-actor closure so Swift 6 does
    /// not transfer Foundation's mutable userInfo container across isolation.
    private func observeAuthorizationCommand<Payload: Sendable>(
        named name: Notification.Name,
        payload: @escaping @Sendable (Notification) -> Payload,
        handler: @escaping @MainActor @Sendable (Payload) -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { notification in
            let value = payload(notification)
            MainActor.assumeIsolated {
                handler(value)
            }
        }
    }

    private func observeAuthorizationCommand(
        named name: Notification.Name,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> NSObjectProtocol {
        observeAuthorizationCommand(named: name, payload: { _ in () }) { _ in
            handler()
        }
    }

    private func handleAuthorizationChange(didChange: Bool) {
        guard didChange else {
            return
        }

        notificationCenter.post(name: .gitScanRootAuthorizationsDidChange, object: nil)
        if hasStartedGitActivityRefresh {
            gitActivityRefreshCoordinator.handleAuthorizationChanged()
        }
        // Authorization changes already start the replacement refresh above;
        // update the secondary config projection without scheduling another one.
        configCoordinator.reconcilePersistedScanRoots()
        restoreHUDWindow(from: NSApp)
    }

    private func handleAuthorizationRequest(result: GitScanRootAuthorizationRequestResult) {
        notificationCenter.post(name: .gitScanRootAuthorizationsDidChange, object: nil)
        if result.didChangeAuthorization {
            if hasStartedGitActivityRefresh {
                gitActivityRefreshCoordinator.handleAuthorizationChanged()
            }
            configCoordinator.reconcilePersistedScanRoots()
            restoreHUDWindow(from: NSApp)
            return
        }

        if result.requiresStandaloneWidgetReload {
            TinyBuddyWidgetReloadCoordinator.shared.requestReload()
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
        TinyBuddyHUDPresentationGate.shared.attach(window)
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
