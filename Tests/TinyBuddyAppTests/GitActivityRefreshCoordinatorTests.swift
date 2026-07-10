import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore
import Foundation

final class GitActivityRefreshCoordinatorTests: XCTestCase {
    func testRefreshSkipsScriptWhenNoGitScanRootsAreAuthorized() {
        let harness = makeHarness(authorizedRoots: [])

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 0)
        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .skipped,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .authorizationResolution,
                    reason: .authorizationRequired
                ),
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: 0,
                    widgetReloaded: false,
                    reason: "gitActivityRefresh.authorizationResolution.authorizationRequired"
                )
            )
        )
        XCTAssertEqual(
            harness.diagnosticEventIdentifiers,
            ["gitActivityRefresh.authorizationResolution.authorizationRequired"]
        )
    }

    func testRefreshReportsInvalidSavedGitAuthorizationWhenBookmarksNoLongerResolve() {
        let harness = makeHarness(authorizedRoots: [], authorizationIssue: .authorizationInvalid)

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 0)
        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .skipped,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .authorizationResolution,
                    reason: .authorizationInvalid
                ),
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: 0,
                    widgetReloaded: false,
                    reason: "gitActivityRefresh.authorizationResolution.authorizationInvalid"
                )
            )
        )
        XCTAssertEqual(
            harness.diagnosticEventIdentifiers,
            ["gitActivityRefresh.authorizationResolution.authorizationInvalid"]
        )
    }

    func testRefreshReportsStructuredDiagnosticWhenScriptIsMissing() {
        let harness = makeHarness(scriptURL: nil)

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 0)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .failed,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .scriptLookup,
                    reason: .scriptMissing
                ),
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    widgetReloaded: false,
                    reason: "gitActivityRefresh.scriptLookup.scriptMissing"
                )
            )
        )
        XCTAssertEqual(
            harness.diagnosticEventIdentifiers,
            ["gitActivityRefresh.scriptLookup.scriptMissing"]
        )
    }

    func testRefreshPassesAuthorizedGitScanRootsToScript() {
        let roots = [
            URL(fileURLWithPath: "/Authorized/TinyBuddy Projects/ProjectA"),
            URL(fileURLWithPath: "/Authorized/TinyBuddy Projects/ProjectB")
        ]
        let harness = makeHarness(authorizedRoots: roots)

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.capturedRootPaths, roots.map(\.standardizedFileURL.path))
        XCTAssertEqual(harness.stopAccessCount, roots.count)
    }

    func testVisibleRefreshSkipsWidgetReloadWhenGitActivityIsUnchanged() {
        let harness = makeHarness()

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .succeeded,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: 1,
                    widgetReloaded: false
                )
            )
        )
    }

    func testVisibleRefreshReloadsWidgetWhenGitActivityChanges() {
        let harness = makeHarness()
        harness.setScriptMetrics(
            GitRefreshScriptMetrics(
                repositoryCount: 5,
                cacheHitCount: 3,
                reflogUnchangedSkipCount: 2,
                recomputedRepositoryCount: 3,
                sharedDataWritten: true
            )
        )
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else {
                return
            }

            harness.setActivitySnapshot(focusBlockCount: 4, commitCount: 7, recentProjectName: "TinyBuddy")
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.handleDidBecomeActive()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(
            harness.lastRefreshStatus?.metrics,
            GitActivityRefreshMetrics(
                durationMilliseconds: 0,
                authorizedRootCount: 1,
                repositoryCount: 5,
                cacheHitCount: 3,
                reflogUnchangedSkipCount: 2,
                recomputedRepositoryCount: 3,
                sharedDataWritten: true,
                widgetReloaded: true
            )
        )
    }

    func testRefreshMirrorsValidGitActivityWithoutClearingItWhenRefreshedSnapshotIsUnavailable() {
        withRestoredStandardDefaults(keys: mirroredGitActivityKeys) {
            let harness = makeHarness()
            harness.setScriptRunnerHook { runCount in
                switch runCount {
                case 1:
                    harness.setActivitySnapshot(focusBlockCount: 4, commitCount: 7, recentProjectName: "  TinyBuddy  ")
                case 2:
                    harness.clearActivitySnapshot()
                default:
                    return
                }
            }

            harness.performAndWaitForRefresh {
                harness.coordinator.handleDidBecomeActive()
            }

            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayFocusBlockCountStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: GitTodayFocusBlockCountStore.Key.count),
                4
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayCommitCountStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: GitTodayCommitCountStore.Key.count),
                7
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayRecentProjectStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayRecentProjectStore.Key.projectName),
                "TinyBuddy"
            )

            harness.advanceCurrentDate(by: 60)
            harness.performAndWaitForScriptRunCount(2) {
                harness.coordinator.handleReopen()
            }
            harness.waitForNoRefresh()

            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayFocusBlockCountStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: GitTodayFocusBlockCountStore.Key.count),
                4
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayCommitCountStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: GitTodayCommitCountStore.Key.count),
                7
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayRecentProjectStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayRecentProjectStore.Key.projectName),
                "TinyBuddy"
            )
            XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
            XCTAssertEqual(
                harness.lastRefreshStatus?.diagnostic,
                GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .activitySnapshotLoad,
                    reason: .refreshedActivityUnavailable
                )
            )
            XCTAssertEqual(harness.widgetReloadCount, 1)
        }
    }

    func testRefreshFailureStoresStructuredSanitizedDiagnostic() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { _ in
            struct ScriptFailure: LocalizedError {
                var errorDescription: String? {
                    "refresh script exited with status 1:\n/Users/alice/Code/SecretRepo\nalice"
                }
            }

            throw ScriptFailure()
        }

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .failed,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .scriptExecution,
                    reason: .scriptExecutionFailed
                ),
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: 1,
                    widgetReloaded: false,
                    reason: "gitActivityRefresh.scriptExecution.scriptExecutionFailed"
                )
            )
        )
        XCTAssertEqual(
            harness.diagnosticEventIdentifiers,
            ["gitActivityRefresh.scriptExecution.scriptExecutionFailed"]
        )
        XCTAssertFalse(harness.lastRefreshStatus?.reason?.contains("/Users/alice") ?? false)
        XCTAssertFalse(harness.lastRefreshStatus?.reason?.contains("SecretRepo") ?? false)
        XCTAssertFalse(harness.lastRefreshStatus?.reason?.contains("alice") ?? false)
    }

    func testFailedRefreshBacksOffWakeRetriesAndAutomaticallyRecoversLater() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                struct ScriptFailure: LocalizedError {
                    var errorDescription: String? { "git temporarily unavailable" }
                }
                throw ScriptFailure()
            }

            harness.setActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 2,
                recentProjectName: "TinyBuddy"
            )
        }

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 1)

        harness.advanceCurrentDate(by: 6)
        harness.coordinator.handleDidWake()
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 1)

        harness.advanceCurrentDate(by: 294)
        harness.performAndWaitForScriptRunCount(2) {
            harness.coordinator.handleDidWake()
        }
        harness.waitForWidgetReloadCount(1)

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
        XCTAssertEqual(harness.widgetReloadCount, 1)
    }

    func testStartTriggersLaunchRefreshAndWidgetReload() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else {
                return
            }

            harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
    }

    func testResigningActiveSuspendsPeriodicAndWakeRefreshUntilNextActivation() {
        let harness = makeHarness()

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.start()
        }
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)

        harness.coordinator.handleDidResignActive()
        XCTAssertFalse(harness.coordinator.isPeriodicRefreshScheduled)

        harness.advanceCurrentDate(by: 120)
        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        harness.postWorkspaceNotification(named: NSWorkspace.screensDidWakeNotification)
        harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 1)

        harness.performAndWaitForScriptRunCount(2) {
            harness.coordinator.handleDidBecomeActive()
        }
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.scriptRunCount, 2)
    }

    func testDidBecomeActiveSkipsWhenMinimumRefreshSpacingNotReached() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else {
                return
            }

            harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.advanceCurrentDate(by: 30)
        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(
            harness.lastRefreshStatus?.trigger,
            .launch
        )
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
    }

    func testUnavailableAuthorizationSuspendsPeriodicRefreshUntilAuthorizationChanges() {
        let harness = makeHarness(authorizedRoots: [])

        harness.coordinator.start()
        harness.waitForNoRefresh()

        XCTAssertFalse(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.scriptRunCount, 0)

        harness.authorizedRoots = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")]
        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleAuthorizationChanged()
        }

        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.scriptRunCount, 1)
    }

    func testInvalidSavedAuthorizationKeepsLowFrequencyRecoveryAndRecoversAutomatically() {
        let harness = makeHarness(authorizedRoots: [], authorizationIssue: .authorizationInvalid)

        harness.coordinator.start()
        harness.waitForNoRefresh()

        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.scriptRunCount, 0)

        harness.advanceCurrentDate(by: 6)
        harness.coordinator.handleDidWake()
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 0)

        harness.authorizationIssue = nil
        harness.authorizedRoots = [URL(fileURLWithPath: "/Authorized/RecoveredProject")]
        harness.advanceCurrentDate(by: 294)
        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidWake()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
    }

    func testPartialAuthorizationFailureDoesNotPublishPartialResultsAndRecoversAutomatically() {
        let liveRoot = URL(fileURLWithPath: "/Authorized/LiveProject")
        let recoveredRoot = URL(fileURLWithPath: "/Authorized/RecoveredProject")
        let harness = makeHarness(
            authorizedRoots: [liveRoot],
            authorizationIssue: .authorizationInvalid
        )

        harness.coordinator.start()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 0)
        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .skipped)
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)

        harness.advanceCurrentDate(by: 6)
        harness.coordinator.handleDidWake()
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 0)

        harness.authorizationIssue = nil
        harness.authorizedRoots = [liveRoot, recoveredRoot]
        harness.advanceCurrentDate(by: 294)
        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidWake()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.capturedRootPaths, [liveRoot.path, recoveredRoot.path])
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
    }

    func testReopenRestoresPeriodicRefreshAfterAuthorizationBecomesAvailable() {
        let harness = makeHarness(authorizedRoots: [])

        harness.coordinator.start()
        harness.waitForNoRefresh()
        XCTAssertFalse(harness.coordinator.isPeriodicRefreshScheduled)

        harness.authorizedRoots = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")]
        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleReopen()
        }

        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.scriptRunCount, 1)
    }

    func testReopenDoesNotDuplicateRecentForegroundRefresh() {
        let harness = makeHarness()

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.start()
        }
        harness.coordinator.handleDidBecomeActive()
        harness.coordinator.handleReopen()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.lastRefreshStatus?.trigger, .launch)
    }

    func testReopenTriggersRefreshAndWidgetReload() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else {
                return
            }

            harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 1, recentProjectName: "TinyBuddy")
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.handleReopen()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
    }

    func testDidWakeNotificationTriggersRefreshAndWidgetReload() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
            case 2:
                harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 0, recentProjectName: "TinyBuddy")
            default:
                return
            }
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testScreensDidWakeNotificationTriggersRefreshAndWidgetReload() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
            case 2:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 1, recentProjectName: "TinyBuddy")
            default:
                return
            }
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.screensDidWakeNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testSessionDidBecomeActiveNotificationTriggersRefreshAndWidgetReload() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
            case 2:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "Project B")
            default:
                return
            }
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testWakeNotificationBurstCoalescesQueuedWakeRefreshAfterSuccessfulRefresh() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
            case 2:
                harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 0, recentProjectName: "TinyBuddy")
            default:
                return
            }
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
            harness.postWorkspaceNotification(named: NSWorkspace.screensDidWakeNotification)
            harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        }

        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testWakeNotificationDuringRefreshCoalescesQueuedWakeRefreshWithinWakeWindow() {
        let harness = makeHarness()
        let allowWakeRefreshToFinish = DispatchSemaphore(value: 0)
        let queuedWakeNotificationPosted = expectation(description: "queued wake notification posted")

        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
                return
            }

            guard runCount == 2 else {
                return
            }

            harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 0, recentProjectName: "TinyBuddy")
            DispatchQueue.main.async {
                harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
                queuedWakeNotificationPosted.fulfill()
            }
            allowWakeRefreshToFinish.wait()
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        wait(for: [queuedWakeNotificationPosted], timeout: 1.0)
        allowWakeRefreshToFinish.signal()
        harness.waitForWidgetReloadCount(2)
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testWakeNotificationDuringLongRefreshRunsFollowUpAfterCoalescingWindow() {
        let harness = makeHarness()
        let allowWakeRefreshToFinish = DispatchSemaphore(value: 0)
        let queuedWakeNotificationPosted = expectation(description: "queued wake notification posted")

        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
            case 2:
                harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 0, recentProjectName: "TinyBuddy")
                harness.advanceCurrentDate(by: 6)
                DispatchQueue.main.async {
                    harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
                    queuedWakeNotificationPosted.fulfill()
                }
                allowWakeRefreshToFinish.wait()
            case 3:
                harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 1, recentProjectName: "TinyBuddy")
            default:
                return
            }
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        wait(for: [queuedWakeNotificationPosted], timeout: 1.0)
        allowWakeRefreshToFinish.signal()
        harness.waitForWidgetReloadCount(3)

        XCTAssertEqual(harness.scriptRunCount, 3)
        XCTAssertEqual(harness.widgetReloadCount, 3)
    }

    func testResigningActiveDropsQueuedWakeRefreshAfterSuccessfulRefresh() {
        let harness = makeHarness()
        let allowWakeRefreshToFinish = DispatchSemaphore(value: 0)
        let applicationResigned = expectation(description: "application resigned with wake refresh queued")

        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
            case 2:
                harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 0, recentProjectName: "TinyBuddy")
                harness.advanceCurrentDate(by: 6)
                DispatchQueue.main.async {
                    harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
                    harness.coordinator.handleDidResignActive()
                    applicationResigned.fulfill()
                }
                allowWakeRefreshToFinish.wait()
            default:
                XCTFail("background transition must not start a queued wake refresh")
            }
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        wait(for: [applicationResigned], timeout: 1.0)
        allowWakeRefreshToFinish.signal()
        harness.waitForWidgetReloadCount(2)
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertFalse(harness.coordinator.isPeriodicRefreshScheduled)
    }

    func testResigningActiveDropsQueuedWakeRefreshAfterFailedRefresh() {
        let harness = makeHarness()
        let allowWakeRefreshToFinish = DispatchSemaphore(value: 0)
        let applicationResigned = expectation(description: "application resigned with wake refresh queued")

        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
                return
            }

            guard runCount == 2 else {
                XCTFail("background transition must not start a queued wake refresh")
                return
            }

            harness.advanceCurrentDate(by: 6)
            DispatchQueue.main.async {
                harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
                harness.coordinator.handleDidResignActive()
                applicationResigned.fulfill()
            }
            allowWakeRefreshToFinish.wait()

            struct ScriptFailure: LocalizedError {
                var errorDescription: String? { "refresh script exited with status 1" }
            }
            throw ScriptFailure()
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        wait(for: [applicationResigned], timeout: 1.0)
        allowWakeRefreshToFinish.signal()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.lastRefreshStatus?.trigger, .didWake)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
        XCTAssertFalse(harness.coordinator.isPeriodicRefreshScheduled)
    }

    func testWakeNotificationRetriesWhenFirstWakeRefreshCannotStart() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
            case 2:
                harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 0, recentProjectName: "TinyBuddy")
            default:
                return
            }
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        harness.authorizedRoots = []
        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)

        harness.authorizedRoots = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")]
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testFailedRefreshBackoffPreservesFailureStatusAndDropsQueuedWakeRetry() {
        let harness = makeHarness()
        let queuedWakeNotificationPosted = expectation(description: "queued wake notification posted")

        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
                return
            }

            guard runCount == 2 else {
                return
            }

            DispatchQueue.main.async {
                harness.authorizedRoots = []
                harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
                queuedWakeNotificationPosted.fulfill()
            }

            struct ScriptFailure: LocalizedError {
                var errorDescription: String? {
                    "refresh script exited with status 1"
                }
            }

            throw ScriptFailure()
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        wait(for: [queuedWakeNotificationPosted], timeout: 1.0)
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .didWake,
                outcome: .failed,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .scriptExecution,
                    reason: .scriptExecutionFailed
                ),
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: 1,
                    widgetReloaded: false,
                    reason: "gitActivityRefresh.scriptExecution.scriptExecutionFailed"
                )
            )
        )
    }

    func testSuccessfulRefreshesDoNotPersistDiagnosticsAcrossRepeatedTriggers() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
            case 2:
                harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 0, recentProjectName: "TinyBuddy")
            case 3:
                harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 1, recentProjectName: "TinyBuddy")
            default:
                return
            }
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.advanceCurrentDate(by: 6)
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        }
        harness.advanceCurrentDate(by: 6)
        harness.performAndWaitForWidgetReloadCount(3) {
            harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 3)
        XCTAssertEqual(harness.statusHistory.count, 3)
        XCTAssertEqual(harness.statusHistory.filter { $0.diagnostic != nil }.count, 0)
        XCTAssertEqual(harness.statusHistory.filter { $0.reason != nil }.count, 0)
        XCTAssertTrue(harness.diagnosticEventIdentifiers.isEmpty)
    }

    private func makeHarness(
        authorizedRoots: [URL] = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")],
        authorizationIssue: GitScanRootAccessIssue? = nil,
        scriptURL: URL? = URL(fileURLWithPath: "/tmp/tinybuddy-test-refresh.sh")
    ) -> RefreshHarness {
        RefreshHarness(
            testCase: self,
            authorizedRoots: authorizedRoots,
            authorizationIssue: authorizationIssue,
            scriptURL: scriptURL
        )
    }

    private var mirroredGitActivityKeys: [String] {
        [
            GitTodayFocusBlockCountStore.Key.dayIdentifier,
            GitTodayFocusBlockCountStore.Key.count,
            GitTodayCommitCountStore.Key.dayIdentifier,
            GitTodayCommitCountStore.Key.count,
            GitTodayRecentProjectStore.Key.dayIdentifier,
            GitTodayRecentProjectStore.Key.projectName
        ]
    }

    private func withRestoredStandardDefaults(
        keys: [String],
        operation: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let originalValues = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, defaults.object(forKey: key))
        })

        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.synchronize()

        defer {
            for key in keys {
                if let value = originalValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            defaults.synchronize()
        }

        operation()
    }
}

private final class RefreshHarness {
    private let testCase: XCTestCase
    private let state: State
    private let refreshExpectationQueue = DispatchQueue(label: "TinyBuddyTests.RefreshHarness")
    private let workspaceNotificationCenter = NotificationCenter()
    private let statusNotificationCenter = NotificationCenter()
    private var pendingRefreshExpectation: XCTestExpectation?
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let activityDefaults: UserDefaults
    private let calendar: Calendar
    private var statusObserver: NSObjectProtocol?

    let coordinator: GitActivityRefreshCoordinator

    init(
        testCase: XCTestCase,
        authorizedRoots: [URL],
        authorizationIssue: GitScanRootAccessIssue? = nil,
        scriptURL: URL? = URL(fileURLWithPath: "/tmp/tinybuddy-test-refresh.sh")
    ) {
        self.testCase = testCase
        self.state = State(currentDate: Self.makeDate(second: 0))
        self.state.authorizedRoots = authorizedRoots
        self.state.authorizationIssue = authorizationIssue

        let defaults = UserDefaults(suiteName: "TinyBuddyAppTests.\(UUID().uuidString)")!
        self.activityDefaults = defaults
        let calendar = Self.makeCalendar()
        self.calendar = calendar
        self.refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { [state] in state.currentDate }
        )
        let focusBlockCountStore = GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { [state] in state.currentDate },
            sharedFallbacksEnabled: false
        )
        let commitCountStore = GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { [state] in state.currentDate },
            sharedFallbacksEnabled: false
        )
        focusBlockCountStore.saveTodayCount(0)
        commitCountStore.saveTodayCount(0)
        let activityStore = GitTodayActivityStore(
            focusBlockCountStore: focusBlockCountStore,
            commitCountStore: commitCountStore,
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { [state] in state.currentDate },
                sharedFallbacksEnabled: false
            )
        )

        self.coordinator = GitActivityRefreshCoordinator(
            activityStore: activityStore,
            refreshStatusStore: refreshStatusStore,
            refreshInterval: 300,
            minimumRefreshSpacing: 60,
            widgetReloader: { [weak testCase, state] in
                guard testCase != nil else {
                    return
                }

                state.widgetReloadCount += 1
                state.onWidgetReload?(state.widgetReloadCount)
            },
            scriptURLProvider: { scriptURL },
            scriptRunner: { [state] _, rootURLs in
                state.scriptRunCount += 1
                state.capturedRootPaths = rootURLs.map(\.standardizedFileURL.path)
                try state.scriptRunnerHook?(state.scriptRunCount)
                state.onScriptRun?(state.scriptRunCount)
                return GitRefreshScriptResult(
                    standardOutput: "",
                    standardError: "",
                    metrics: state.scriptMetrics
                )
            },
            authorizedRootsProvider: { [state] in
                let roots = state.authorizedRoots.map { url in
                    ScopedGitScanRoot(url: url) {
                        state.stopAccessCount += 1
                    }
                }
                return GitScanRootAccessResult(
                    roots: roots,
                    issue: state.authorizationIssue
                )
            },
            dateProvider: { [state] in
                state.currentDate
            },
            workspaceNotificationCenter: workspaceNotificationCenter,
            statusNotificationCenter: statusNotificationCenter,
            diagnosticRecorder: { [state] diagnostic, _ in
                state.diagnosticEventIdentifiers.append(diagnostic.stableIdentifier)
            }
        )
        statusObserver = statusNotificationCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { [state] notification in
            guard let status = notification.object as? GitActivityRefreshStatus else {
                return
            }

            state.statusHistory.append(status)
        }
        state.onWidgetReload = { [weak self] _ in
            self?.fulfillPendingRefreshExpectation()
        }
        state.onScriptRun = { [weak self] _ in
            self?.fulfillPendingRefreshExpectation()
        }
    }

    deinit {
        if let statusObserver {
            statusNotificationCenter.removeObserver(statusObserver)
        }
    }

    var scriptRunCount: Int { state.scriptRunCount }
    var widgetReloadCount: Int { state.widgetReloadCount }
    var capturedRootPaths: [String] { state.capturedRootPaths }
    var stopAccessCount: Int { state.stopAccessCount }
    var currentDate: Date { state.currentDate }
    var currentDayIdentifier: String { Self.dayIdentifier(for: currentDate, calendar: calendar) }
    var lastRefreshStatus: GitActivityRefreshStatus? { refreshStatusStore.load() }
    var statusHistory: [GitActivityRefreshStatus] { state.statusHistory }
    var diagnosticEventIdentifiers: [String] { state.diagnosticEventIdentifiers }
    var authorizedRoots: [URL] {
        get { state.authorizedRoots }
        set { state.authorizedRoots = newValue }
    }
    var authorizationIssue: GitScanRootAccessIssue? {
        get { state.authorizationIssue }
        set { state.authorizationIssue = newValue }
    }

    func advanceCurrentDate(by seconds: TimeInterval) {
        state.currentDate = state.currentDate.addingTimeInterval(seconds)
    }

    func postWorkspaceNotification(named name: Notification.Name) {
        workspaceNotificationCenter.post(name: name, object: nil)
    }

    func setScriptRunnerHook(_ hook: @escaping (Int) throws -> Void) {
        state.scriptRunnerHook = hook
    }

    func setScriptMetrics(_ metrics: GitRefreshScriptMetrics?) {
        state.scriptMetrics = metrics
    }

    func setActivitySnapshot(
        focusBlockCount: Int?,
        commitCount: Int?,
        recentProjectName: String?
    ) {
        let focusStore = GitTodayFocusBlockCountStore(
            userDefaults: activityDefaults,
            calendar: calendar,
            dateProvider: { self.currentDate },
            sharedFallbacksEnabled: false
        )
        let commitStore = GitTodayCommitCountStore(
            userDefaults: activityDefaults,
            calendar: calendar,
            dateProvider: { self.currentDate },
            sharedFallbacksEnabled: false
        )
        let recentProjectStore = GitTodayRecentProjectStore(
            userDefaults: activityDefaults,
            calendar: calendar,
            dateProvider: { self.currentDate },
            sharedFallbacksEnabled: false
        )

        focusStore.saveTodayCount(focusBlockCount ?? 0)
        commitStore.saveTodayCount(commitCount ?? 0)
        recentProjectStore.saveTodayProjectName(recentProjectName)
    }

    func clearActivitySnapshot() {
        activityDefaults.removeObject(forKey: GitTodayFocusBlockCountStore.Key.dayIdentifier)
        activityDefaults.removeObject(forKey: GitTodayFocusBlockCountStore.Key.count)
        activityDefaults.removeObject(forKey: GitTodayCommitCountStore.Key.dayIdentifier)
        activityDefaults.removeObject(forKey: GitTodayCommitCountStore.Key.count)
        activityDefaults.removeObject(forKey: GitTodayRecentProjectStore.Key.dayIdentifier)
        activityDefaults.removeObject(forKey: GitTodayRecentProjectStore.Key.projectName)
    }

    func performAndWaitForRefresh(_ action: () -> Void) {
        performAndWaitForWidgetReloadCount(1, action: action)
    }

    func performAndWaitForScriptRunCount(_ expectedRunCount: Int, action: () -> Void) {
        let expectation = testCase.expectation(description: "script run count \(expectedRunCount)")
        refreshExpectationQueue.sync {
            pendingRefreshExpectation = expectation
            state.expectedScriptRunCount = expectedRunCount
            if state.scriptRunCount >= expectedRunCount {
                expectation.fulfill()
                pendingRefreshExpectation = nil
                state.expectedScriptRunCount = 0
            }
        }
        action()
        testCase.wait(for: [expectation], timeout: 1.0)
    }

    func performAndWaitForWidgetReloadCount(_ expectedReloadCount: Int, action: () -> Void) {
        let expectation = testCase.expectation(description: "refresh completed")
        refreshExpectationQueue.sync {
            pendingRefreshExpectation = expectation
            state.expectedWidgetReloadCount = expectedReloadCount
            if state.widgetReloadCount >= expectedReloadCount {
                expectation.fulfill()
                pendingRefreshExpectation = nil
                state.expectedWidgetReloadCount = 0
            }
        }
        action()
        testCase.wait(for: [expectation], timeout: 1.0)
    }

    func waitForWidgetReloadCount(_ expectedReloadCount: Int) {
        let expectation = testCase.expectation(description: "refresh count \(expectedReloadCount)")
        refreshExpectationQueue.sync {
            pendingRefreshExpectation = expectation
            state.expectedWidgetReloadCount = expectedReloadCount
            if state.widgetReloadCount >= expectedReloadCount {
                expectation.fulfill()
                pendingRefreshExpectation = nil
                state.expectedWidgetReloadCount = 0
            }
        }
        testCase.wait(for: [expectation], timeout: 1.0)
    }

    func waitForNoRefresh() {
        let expectation = testCase.expectation(description: "no refresh completed")
        expectation.isInverted = true
        state.onWidgetReload = { _ in
            expectation.fulfill()
        }
        testCase.wait(for: [expectation], timeout: 0.2)
        state.onWidgetReload = { [weak self] _ in
            self?.fulfillPendingRefreshExpectation()
        }
    }

    private func fulfillPendingRefreshExpectation() {
        refreshExpectationQueue.sync {
            guard let expectation = pendingRefreshExpectation else {
                return
            }

            if state.expectedWidgetReloadCount > 0,
               state.widgetReloadCount < state.expectedWidgetReloadCount {
                return
            }

            if state.expectedScriptRunCount > 0,
               state.scriptRunCount < state.expectedScriptRunCount {
                return
            }

            expectation.fulfill()
            pendingRefreshExpectation = nil
            state.expectedWidgetReloadCount = 0
            state.expectedScriptRunCount = 0
        }
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func makeDate(second: Int) -> Date {
        var components = DateComponents()
        components.calendar = makeCalendar()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 7
        components.day = 2
        components.hour = 12
        components.minute = 0
        components.second = second
        return components.date!
    }

    private static func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private final class State {
        var currentDate: Date
        var authorizedRoots: [URL] = []
        var authorizationIssue: GitScanRootAccessIssue?
        var capturedRootPaths: [String] = []
        var scriptRunCount = 0
        var widgetReloadCount = 0
        var stopAccessCount = 0
        var expectedWidgetReloadCount = 0
        var expectedScriptRunCount = 0
        var onWidgetReload: ((Int) -> Void)?
        var onScriptRun: ((Int) -> Void)?
        var scriptRunnerHook: ((Int) throws -> Void)?
        var scriptMetrics: GitRefreshScriptMetrics?
        var statusHistory: [GitActivityRefreshStatus] = []
        var diagnosticEventIdentifiers: [String] = []

        init(currentDate: Date) {
            self.currentDate = currentDate
        }
    }
}
