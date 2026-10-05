import Foundation
import XCTest

/// Source-contract coverage for the app's exit/restart state hand-off.
///
/// `AppDelegate`'s lifecycle wiring depends on shared stores that are not
/// unit-instantiable, so these tests assert the durable ordering and the
/// presence of the synchronous termination paths directly in the source
/// (same convention as `WidgetTimelineSelfHealingTests`):
///
/// - Normal quit / logout must finalize the open session, synchronously
///   commit the final focus-history publication to the combined snapshot,
///   and only then archive the day image — so HUD, Widget, and the archive
///   never keep a stale "focusing" state across a restart.
/// - SIGTERM (update installers, scripts) must be converted into the normal
///   termination flow instead of dying without `applicationWillTerminate`.
final class LifecycleStateHandoffTests: XCTestCase {
    func testTerminationFinalizesSessionBeforeFinalArchive() throws {
        let source = try appSource()
        let block = try terminationBlock(in: source)

        let terminate = try XCTUnwrap(block.range(of: "focusSessionBridge?.handleTerminate()"))
        let flush = try XCTUnwrap(block.range(of: "flushFinalFocusPublicationForTermination()"))
        let archive = try XCTUnwrap(block.range(of: "historyArchivalCoordinator.handleTermination()"))

        // The finalize (journal write) must precede the synchronous combined
        // snapshot commit, which must precede the final day archival.
        XCTAssertLessThan(terminate.lowerBound, flush.lowerBound)
        XCTAssertLessThan(flush.lowerBound, archive.lowerBound)
        // The flush is only legal outside a reset (the reset removes the
        // session journal and must not recreate pre-reset sessions).
        XCTAssertTrue(block.contains("if !isPerformingReset"))
    }

    func testTerminationFlushUsesJournaledSynchronizationPath() throws {
        let source = try appSource()
        let block = try flushBlock(in: source)

        // The final flush mirrors the startup replay path: same revision-bound
        // publication and the same status derivation, so a termination that is
        // killed mid-commit still leaves a durable replay candidate.
        XCTAssertTrue(block.contains("engine.focusHistoryPublication()"))
        XCTAssertTrue(block.contains("synchronizeFocusHistoryPublication("))
        XCTAssertTrue(block.contains("FocusHistoryPublicationStatus.status(for: publication)"))
    }

    func testSigtermIsConvertedToGracefulTerminationAtPrimaryStartup() throws {
        let source = try appSource()

        // The handler must only be installed after the process became the
        // primary instance (a secondary exits immediately without resources).
        let launchBlock = try launchBlock(in: source)
        let installCall = try XCTUnwrap(launchBlock.range(of: "installTerminationSignalHandlers()"))
        let primaryGuard = try XCTUnwrap(launchBlock.range(of: "guard role == .primary"))
        XCTAssertGreaterThan(installCall.lowerBound, primaryGuard.lowerBound)

        // Delivery must use a retained DispatchSource on the main queue. A raw
        // POSIX callback cannot safely call Dispatch or AppKit because neither
        // is async-signal-safe.
        XCTAssertTrue(source.contains("signal(SIGTERM, SIG_IGN)"))
        XCTAssertTrue(source.contains("DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)"))
        XCTAssertFalse(source.contains("signal(SIGTERM) {"))
        XCTAssertTrue(source.contains("NSApp.terminate(nil)"))
    }

    func testLaunchArchivesPriorDayBeforeFocusStateRecoveryAndDefersServicesUntilAfterHUD() throws {
        let source = try appSource()
        let launchBlock = try launchBlock(in: source)
        let calibration = try XCTUnwrap(launchBlock.range(of: "_ = timeCalibrator.calibrate()"))
        let prelaunchArchive = try XCTUnwrap(
            launchBlock.range(of: "historyArchivalCoordinator.archivePriorDaySnapshotBeforeLaunchWrites()")
        )
        let focusBridge = try XCTUnwrap(launchBlock.range(of: "FocusSessionAppBridge.createStandard("))
        let replay = try XCTUnwrap(launchBlock.range(of: "replayPendingFocusSessionPublicationIfNeeded()"))

        // The synchronous prior-day archive must precede focus replay and the
        // PetViewModel's first combined-snapshot publication.
        XCTAssertLessThan(calibration.lowerBound, prelaunchArchive.lowerBound)
        XCTAssertLessThan(prelaunchArchive.lowerBound, focusBridge.lowerBound)
        XCTAssertLessThan(prelaunchArchive.lowerBound, replay.lowerBound)

        // The first-frame path must not synchronously start unrelated services.
        XCTAssertFalse(launchBlock.contains("configCoordinator.start()"))
        XCTAssertFalse(launchBlock.contains("gitActivityRefreshCoordinator.start("))
        XCTAssertFalse(launchBlock.contains("historyArchivalCoordinator.runAtLaunch()"))
        XCTAssertFalse(launchBlock.contains("runProjectIdentityAutoMergeIfNeeded()"))
        XCTAssertTrue(launchBlock.contains("beginStartupProjectIdentityAutoMerge()"))

        let deferredStartup = try deferredStartupBlock(in: source)
        XCTAssertFalse(deferredStartup.contains("runProjectIdentityAutoMergeIfNeeded()"))
        let configStart = try XCTUnwrap(deferredStartup.range(of: "configCoordinator.start()"))
        let rootsReconcile = try XCTUnwrap(deferredStartup.range(of: "configCoordinator.reconcilePersistedScanRoots()"))
        let loginRefresh = try XCTUnwrap(deferredStartup.range(of: "loginItemManager.refreshStatus()"))
        let loginRepair = try XCTUnwrap(deferredStartup.range(of: "loginItemManager.recoverIfNeeded("))
        let loginReconcile = try XCTUnwrap(deferredStartup.range(of: "configCoordinator.reconcileLaunchAtLoginIntent()"))
        let refreshStart = try XCTUnwrap(deferredStartup.range(of: "gitActivityRefreshCoordinator.start("))
        let currentDayArchive = try XCTUnwrap(deferredStartup.range(of: "historyArchivalCoordinator.runAtLaunch()"))

        XCTAssertLessThan(configStart.lowerBound, rootsReconcile.lowerBound)
        XCTAssertLessThan(rootsReconcile.lowerBound, loginRefresh.lowerBound)
        XCTAssertLessThan(loginRefresh.lowerBound, loginRepair.lowerBound)
        XCTAssertLessThan(loginRepair.lowerBound, loginReconcile.lowerBound)
        XCTAssertLessThan(loginReconcile.lowerBound, refreshStart.lowerBound)
        XCTAssertLessThan(refreshStart.lowerBound, currentDayArchive.lowerBound)
    }

    func testVisibleHUDSchedulesPostHUDStartupExactlyOnce() throws {
        let source = try appSource()
        let readyBlock = try hudReadyBlock(in: source)
        let visibleCheck = try XCTUnwrap(readyBlock.range(of: "isSemanticallyVisible"))
        let gatePublication = try XCTUnwrap(readyBlock.range(of: "markVisibleReady()"))
        let startupDuration = try XCTUnwrap(readyBlock.range(of: "TinyBuddyStartupClock.elapsedMilliseconds()"))
        let readyLog = try XCTUnwrap(readyBlock.range(of: "HUD ready identifier=TinyBuddy.HUDWindow"))
        XCTAssertLessThan(visibleCheck.lowerBound, gatePublication.lowerBound)
        XCTAssertLessThan(gatePublication.lowerBound, readyLog.lowerBound)
        XCTAssertLessThan(readyLog.lowerBound, startupDuration.lowerBound)

        let launchBlock = try launchBlock(in: source)
        XCTAssertTrue(launchBlock.contains("hasFinishedCriticalStartup = true"))
        XCTAssertTrue(launchBlock.contains("revealHUDWhenStartupStateIsRestored()"))
        XCTAssertTrue(launchBlock.contains("installVisibleReadyHandler"))
        XCTAssertTrue(launchBlock.contains("self?.hudDidBecomeReady()"))
        XCTAssertTrue(launchBlock.contains("schedulePostHUDStartupIfReady()"))

        let schedulingBlock = try schedulingBlock(in: source)
        XCTAssertTrue(schedulingBlock.contains("hasFinishedCriticalStartup"))
        XCTAssertTrue(schedulingBlock.contains("hasObservedVisibleHUD"))
        XCTAssertTrue(schedulingBlock.contains("!hasScheduledPostHUDStartup"))
        XCTAssertTrue(schedulingBlock.contains("!hasStartedDeferredStartupServices"))
        XCTAssertTrue(schedulingBlock.contains("!isPerformingReset"))
        XCTAssertTrue(schedulingBlock.contains("!isTerminating"))
        XCTAssertTrue(schedulingBlock.contains(".now() + 0.25"))

        let startupBlock = try deferredStartupBlock(in: source)
        XCTAssertTrue(startupBlock.contains("hasStartedDeferredStartupServices = true"))
        XCTAssertTrue(startupBlock.contains("hasStartedGitActivityRefresh = true"))
        XCTAssertTrue(startupBlock.contains("powerStateMonitor.start()"))
        XCTAssertTrue(startupBlock.contains("hudVisibilityMonitor.start()"))
        XCTAssertTrue(startupBlock.contains("Deferred startup services completed"))

        let launchArchive = try XCTUnwrap(startupBlock.range(of: "historyArchivalCoordinator.runAtLaunch()"))
        let widgetReload = try XCTUnwrap(startupBlock.range(of: "flushPendingStartupWidgetReload()"))
        XCTAssertLessThan(launchArchive.lowerBound, widgetReload.lowerBound)

        let petViewModel = try petViewModelBlock(in: source)
        XCTAssertTrue(petViewModel.contains("reloadWidgetForNewCurrentDaySnapshot: true"))
        XCTAssertTrue(petViewModel.contains("widgetReloader: { [weak self] in"))
        XCTAssertTrue(petViewModel.contains("self?.requestWidgetTimelineReload()"))

        let widgetReloadRequest = try methodBlock(
            named: "private func requestWidgetTimelineReload()",
            next: "private func flushPendingStartupWidgetReload()",
            in: source
        )
        XCTAssertTrue(widgetReloadRequest.contains("guard hasStartedDeferredStartupServices else"))
        XCTAssertTrue(widgetReloadRequest.contains("hasPendingStartupWidgetReload = true"))

        let archiveRequest = try methodBlock(
            named: "private func archiveCommittedSnapshotAfterStartup(dayIdentifier: String)",
            next: "private func replayPendingFocusSessionPublicationIfNeeded()",
            in: source
        )
        XCTAssertTrue(archiveRequest.contains("guard hasStartedDeferredStartupServices else"))

        let termination = try terminationBlock(in: source)
        let terminating = try XCTUnwrap(termination.range(of: "isTerminating = true"))
        let refreshStop = try XCTUnwrap(termination.range(of: "gitActivityRefreshCoordinator.stop()"))
        XCTAssertLessThan(terminating.lowerBound, refreshStop.lowerBound)
    }

    func testDeferredStartupHasBoundedFallbackWhenHUDNeverBecomesVisible() throws {
        let source = try appSource()
        let launchBlock = try launchBlock(in: source)
        XCTAssertTrue(launchBlock.contains("scheduleDeferredStartupFallback()"))

        let fallback = try fallbackBlock(in: source)
        XCTAssertTrue(fallback.contains(".now() + 5"))
        XCTAssertTrue(fallback.contains("hasFinishedCriticalStartup"))
        XCTAssertTrue(fallback.contains("!self.hasObservedVisibleHUD"))
        XCTAssertTrue(fallback.contains("startDeferredStartupServices(trigger: \"hud-visibility-timeout\")"))
        XCTAssertFalse(fallback.contains("HUD ready"))
    }

    func testStartupProjectIdentityMergeRunsOffMainAndGatesFirstHUDPresentation() throws {
        let source = try appSource()
        let merge = try startupIdentityMergeBlock(in: source)
        XCTAssertTrue(merge.contains("DispatchQueue.global(qos: .userInitiated).async"))
        XCTAssertTrue(merge.contains("projectRegistry.autoMergeDuplicates()"))
        XCTAssertTrue(merge.contains("completion.leave()"))
        XCTAssertTrue(merge.contains("Task { @MainActor"))
        XCTAssertTrue(merge.contains("hasCompletedStartupProjectIdentityMerge = true"))

        let presentationRestore = try methodBlock(
            named: "private func revealHUDWhenStartupStateIsRestored()",
            next: "private func schedulePostHUDStartupIfReady()",
            in: source
        )
        XCTAssertTrue(presentationRestore.contains("hasFinishedCriticalStartup"))
        XCTAssertTrue(presentationRestore.contains("hasCompletedStartupProjectIdentityMerge"))
        XCTAssertTrue(presentationRestore.contains("TinyBuddyHUDPresentationGate.shared.restoreCriticalState()"))

        let presentationGate = try methodBlock(
            named: "private final class TinyBuddyHUDPresentationGate",
            next: "@MainActor\nprivate func publishTinyBuddyHUDReadyWhenVisible",
            in: source
        )
        XCTAssertTrue(presentationGate.contains("window.alphaValue = hasRestoredCriticalState ? 1 : 0"))
        XCTAssertTrue(presentationGate.contains("window.alphaValue = 1"))

        let termination = try terminationBlock(in: source)
        XCTAssertTrue(termination.contains("startupProjectIdentityAutoMergeCompletion.wait()"))
        let quiesce = try methodBlock(
            named: "private func quiesceRuntimeForReset()",
            next: "private func presentResetFailureAndTerminate",
            in: source
        )
        XCTAssertTrue(quiesce.contains("startupProjectIdentityAutoMergeCompletion.wait()"))
    }

    func testEarlyLifecycleCallbacksDoNotInstantiateGitRefreshBeforeStartup() throws {
        let source = try appSource()
        let becameActive = try methodBlock(
            named: "func applicationDidBecomeActive",
            next: "func applicationDidResignActive",
            in: source
        )
        let becameInactive = try methodBlock(
            named: "func applicationDidResignActive",
            next: "func applicationShouldTerminateAfterLastWindowClosed",
            in: source
        )
        let reopen = try methodBlock(
            named: "func applicationShouldHandleReopen",
            next: "private func registerAuthorizationCommandObservers",
            in: source
        )

        XCTAssertTrue(becameActive.contains("if hasStartedGitActivityRefresh"))
        XCTAssertTrue(becameInactive.contains("if hasStartedGitActivityRefresh"))
        XCTAssertTrue(reopen.contains("if hasStartedGitActivityRefresh"))
    }

    // MARK: - Source extraction

    private func terminationBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "func applicationWillTerminate"))
        let end = try XCTUnwrap(
            source.range(of: "func applicationDidBecomeActive")
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func flushBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(
            source.range(of: "private func flushFinalFocusPublicationForTermination()")
        )
        // The flush body ends where the next private method begins.
        let end = try XCTUnwrap(
            source.range(of: "private func synchronizeFocusHistoryPublication")
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func launchBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(
            source.range(of: "func hudDidBecomeReady()")
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func hudReadyBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "private func publishTinyBuddyHUDReadyWhenVisible"))
        let end = try XCTUnwrap(source.range(of: "@main\nstruct TinyBuddyApp"))
        return source[start.lowerBound..<end.lowerBound]
    }

    private func schedulingBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "private func schedulePostHUDStartupIfReady()"))
        let end = try XCTUnwrap(source.range(of: "private func scheduleDeferredStartupFallback()"))
        return source[start.lowerBound..<end.lowerBound]
    }

    private func deferredStartupBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "private func startDeferredStartupServices(trigger: String)"))
        let end = try XCTUnwrap(source.range(of: "private func reconcileProjectDiscovery"))
        return source[start.lowerBound..<end.lowerBound]
    }

    private func fallbackBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "private func scheduleDeferredStartupFallback()"))
        let end = try XCTUnwrap(source.range(of: "private func startDeferredStartupServices(trigger: String)"))
        return source[start.lowerBound..<end.lowerBound]
    }

    private func startupIdentityMergeBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "private func beginStartupProjectIdentityAutoMerge()"))
        let end = try XCTUnwrap(source.range(of: "private func runProjectIdentityAutoMergeIfNeeded()"))
        return source[start.lowerBound..<end.lowerBound]
    }

    private func petViewModelBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "lazy var petViewModel = PetViewModel("))
        let end = try XCTUnwrap(source.range(of: "private lazy var gitActivityRefreshCoordinator"))
        return source[start.lowerBound..<end.lowerBound]
    }

    private func methodBlock(named method: String, next nextMethod: String, in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: method))
        let end = try XCTUnwrap(source.range(of: nextMethod))
        return source[start.lowerBound..<end.lowerBound]
    }

    private func appSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Sources/TinyBuddy/TinyBuddyApp.swift"),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
