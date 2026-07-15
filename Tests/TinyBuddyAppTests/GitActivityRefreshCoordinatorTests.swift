import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore
import Foundation

final class GitActivityRefreshCoordinatorTests: XCTestCase {
    func testScriptFailureSummaryClassifiesSandboxAndPathErrorsWithoutEchoingOutput() {
        let summary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "repo path",
            standardError: "open /Users/alice/SecretRepo: Operation not permitted"
        )

        XCTAssertEqual(summary, "status=1 stdout_bytes=9 stderr_bytes=53 permission=denied sandbox=blocked path=present command=unknown error=operation-not-permitted line=unknown")
        XCTAssertFalse(summary.contains("SecretRepo"))
        XCTAssertFalse(summary.contains("alice"))
    }

    func testScriptFailureSummaryIdentifiesDeniedCommand() {
        let summary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "find: /Users/alice/Projects: Operation not permitted"
        )

        XCTAssertTrue(summary.contains("command=find"))
        XCTAssertFalse(summary.contains("Projects"))
    }

    func testScriptFailureSummaryIdentifiesDeniedDateTool() {
        let summary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "date: Operation not permitted"
        )

        XCTAssertTrue(summary.contains("command=date"))
    }

    func testScriptFailureSummaryDoesNotTreatAppGroupPlistDiagnosticAsPlistBuddyCommand() {
        let diagnosticSummary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "diagnostics: app_group_plist=/private/tmp/shared.plist gitdir-resolution-failed"
        )
        let plistBuddySummary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "/usr/libexec/PlistBuddy: Entry, \"count\", Does Not Exist"
        )

        XCTAssertTrue(diagnosticSummary.contains("command=unknown"))
        XCTAssertFalse(diagnosticSummary.contains("command=plistbuddy"))
        XCTAssertTrue(plistBuddySummary.contains("command=plistbuddy"))
    }

    func testScriptFailureSummaryIdentifiesShellBoundaryWithoutEchoingDeniedPath() {
        let summary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "bash: line 7: /usr/libexec/unknown-tool: Operation not permitted"
        )

        XCTAssertTrue(summary.contains("command=unknown-tool"))
        XCTAssertTrue(summary.contains("error=operation-not-permitted"))
        XCTAssertFalse(summary.contains("/usr/libexec"))
    }

    func testScriptFailureSummaryExtractsDeniedExecutableBasenameOnly() {
        let summary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "bash: line 7: /usr/local/bin/private-tool: Operation not permitted"
        )

        XCTAssertTrue(summary.contains("command=private-tool"))
        XCTAssertFalse(summary.contains("/usr/local/bin"))
    }

    func testScriptFailureSummaryDoesNotTreatRepositoryPathAsAnExecutable() {
        let summary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "bash: line 7: /Users/alice/Code/private-project-v1.2: Operation not permitted"
        )

        XCTAssertTrue(summary.contains("command=shell"))
        XCTAssertFalse(summary.contains("private-project-v1.2"))
        XCTAssertFalse(summary.contains("alice"))
    }

    func testScriptFailureSummaryRejectsTraversalDisguisedAsTrustedExecutablePath() {
        let summary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "bash: line 7: /usr/bin/../../Users/alice/Secret-Repo: Operation not permitted"
        )

        XCTAssertTrue(summary.contains("command=shell"))
        XCTAssertFalse(summary.contains("Secret-Repo"))
        XCTAssertFalse(summary.contains("alice"))
    }

    func testScriptFailureSummaryIncludesDeniedShellLineNumber() {
        let summary = GitActivityRefreshCoordinator.scriptFailureSummary(
            terminationStatus: 1,
            standardOutput: "",
            standardError: "bash: line 972: /usr/bin/tool: Operation not permitted"
        )

        XCTAssertTrue(summary.contains("line=972"))
    }

    func testScriptUsesTheAppSandboxTemporaryDirectoryForChildProcessScratchFiles() {
        XCTAssertEqual(
            GitActivityRefreshCoordinator.scriptTemporaryDirectoryEnvironment(
                URL(fileURLWithPath: "/private/var/folders/tinybuddy", isDirectory: true)
            ),
            "/private/var/folders/tinybuddy/"
        )
    }

    func testRefreshInvokesBundledScriptThroughSandboxSafeStandardInput() {
        XCTAssertEqual(GitActivityRefreshCoordinator.scriptProcessArguments(), ["-s"])
    }

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
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.reason, .gitScanSkipped)
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.recovery, .stopped)
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
                outcome: .failed,
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
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.reason, .gitScanSkipped)
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
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.reason, .gitScanFailed)
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

    func testVisibleRefreshReloadsWidgetWhenPublishingPreviouslyUnavailableActivity() {
        let harness = makeHarness()
        harness.setActivitySnapshot(
            focusBlockCount: 5,
            commitCount: 8,
            recentProjectName: "DevPulse"
        )

        harness.performAndWaitForRefresh {
            harness.coordinator.handleDidBecomeActive()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(
            harness.combinedSnapshot?.activitySnapshot,
            GitTodayActivitySnapshot(
                focusBlockCount: 5,
                commitCount: 8,
                recentProjectName: "DevPulse"
            )
        )
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.widgetReloaded, true)
    }

    func testTimelineReloadFailureKeepsSuccessfulGitRefreshStatus() {
        enum ReloadError: Error { case unavailable }

        let harness = makeHarness()
        harness.setActivitySnapshot(
            focusBlockCount: 5,
            commitCount: 8,
            recentProjectName: "DevPulse"
        )
        harness.setWidgetReloaderHook { throw ReloadError.unavailable }

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
        XCTAssertNil(harness.lastRefreshStatus?.diagnostic)
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.widgetReloaded, false)
        XCTAssertEqual(
            harness.latestHiddenDiagnosticSummary?.identifier,
            "tinybuddy.sharedSnapshot.timelineReload.timelineReloadFailed"
        )
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.recovery, .stopped)
    }

    func testVisibleRefreshReloadsWidgetWhenRepairPublishesPreviouslyStagedActivity() {
        let harness = makeHarness()
        let initial = harness.seedCombinedSnapshot(
            activity: GitTodayActivitySnapshot(
                focusBlockCount: 0,
                commitCount: 0,
                recentProjectName: nil
            ),
            revision: 1
        )
        let stagedActivity = GitTodayActivitySnapshot(
            focusBlockCount: 5,
            commitCount: 8,
            recentProjectName: "DevPulse"
        )
        let staged = TinyBuddyCombinedSnapshot(
            revision: initial.revision + 1,
            dayIdentifier: initial.dayIdentifier,
            snapshot: initial.snapshot,
            activitySnapshot: stagedActivity,
            activityRevision: 2
        )
        harness.stageCombinedSnapshot(staged)
        harness.setTrustedActivitySnapshot(stagedActivity, revision: 2)
        XCTAssertEqual(harness.readOnlyCombinedSnapshot, initial)

        harness.performAndWaitForRefresh {
            harness.coordinator.handleDidBecomeActive()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.combinedSnapshot, staged)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.widgetReloaded, true)
        XCTAssertNil(harness.lastRefreshStatus?.diagnostic)
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
            harness.combinedSnapshot?.activitySnapshot,
            GitTodayActivitySnapshot(focusBlockCount: 4, commitCount: 7, recentProjectName: "TinyBuddy")
        )
        XCTAssertEqual(harness.combinedSnapshot?.revision, 1)
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

    func testPartialScriptRefreshPropagatesWarningWithoutFalseSuccess() {
        let harness = makeHarness()
        harness.setScriptMetrics(
            GitRefreshScriptMetrics(
                repositoryCount: 3,
                invalidRepositoryCount: 1,
                cacheHitCount: 2,
                reflogUnchangedSkipCount: 1,
                recomputedRepositoryCount: 1,
                sharedDataWritten: true
            )
        )
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            harness.setActivitySnapshot(focusBlockCount: 2, commitCount: 3, recentProjectName: "DevPulse")
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.handleDidBecomeActive()
        }

        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .partial)
        XCTAssertEqual(
            harness.lastRefreshStatus?.diagnostic,
            GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .scriptExecution,
                reason: .partialRecovery
            )
        )
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.invalidRepositoryCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.reason, .gitScanPartial)
        XCTAssertEqual(
            harness.latestHiddenDiagnosticSummary?.recovery,
            TinyBuddySharedSnapshotRecovery.none
        )
    }

    func testRefreshFailsWhenUnifiedSnapshotRevisionCannotAdvance() {
        let harness = makeHarness()
        let committedActivity = GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 2,
            recentProjectName: "Committed"
        )
        _ = harness.seedCombinedSnapshot(activity: committedActivity)
        harness.exhaustCombinedSnapshotRevision()
        harness.setScriptRunnerHook { _ in
            harness.setActivitySnapshot(
                focusBlockCount: 4,
                commitCount: 7,
                recentProjectName: "Uncommitted"
            )
        }

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot, committedActivity)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
        XCTAssertEqual(
            harness.lastRefreshStatus?.diagnostic,
            GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .combinedSnapshotCommit,
                reason: .combinedSnapshotCommitFailed
            )
        )
        XCTAssertEqual(
            harness.lastRefreshStatus?.metrics?.reason,
            "gitActivityRefresh.combinedSnapshotCommit.combinedSnapshotCommitFailed"
        )
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.phase, .snapshotWrite)
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.reason, .persistenceFailed)
    }

    func testPostCommitReadFailureDoesNotReportGitRefreshSuccess() {
        let harness = makeHarness()
        harness.failValidatedSnapshotRead(
            number: 2,
            with: .sandboxReadDenied
        )
        harness.setActivitySnapshot(
            focusBlockCount: 4,
            commitCount: 7,
            recentProjectName: "TinyBuddy"
        )

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
        XCTAssertEqual(
            harness.lastRefreshStatus?.diagnostic?.reason,
            .combinedSnapshotCommitFailed
        )
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.phase, .snapshotRead)
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.reason, .sandboxReadDenied)
    }

    func testSuccessfulActivityCommitPostsCommittedSnapshotNotificationAfterPersistence() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { _ in
            harness.setActivitySnapshot(focusBlockCount: 4, commitCount: 7, recentProjectName: "TinyBuddy")
        }
        var observedSnapshot: TinyBuddyCombinedSnapshot?
        let notificationExpectation = expectation(description: "committed activity notification")
        let observer = harness.statusNotificationCenterForTesting.addObserver(
            forName: .gitActivitySnapshotDidChange,
            object: nil,
            queue: nil
        ) { _ in
            observedSnapshot = harness.combinedSnapshot
            notificationExpectation.fulfill()
        }
        defer { harness.statusNotificationCenterForTesting.removeObserver(observer) }

        harness.performAndWaitForRefresh {
            harness.coordinator.handleDidBecomeActive()
        }
        wait(for: [notificationExpectation], timeout: 1.0)

        XCTAssertEqual(observedSnapshot?.activitySnapshot.focusBlockCount, 4)
        XCTAssertEqual(observedSnapshot?.activitySnapshot.commitCount, 7)
        XCTAssertEqual(observedSnapshot?.activitySnapshot.recentProjectName, "TinyBuddy")
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
            let trustedCombinedSnapshot = harness.combinedSnapshot

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

            let newerTrustedActivity = GitTodayActivitySnapshot(
                focusBlockCount: 8,
                commitCount: 13,
                recentProjectName: "Project B"
            )
            let newerTrustedSnapshot = harness.seedCombinedSnapshot(
                activity: newerTrustedActivity,
                revision: 200
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
            XCTAssertNotEqual(trustedCombinedSnapshot, newerTrustedSnapshot)
            XCTAssertEqual(harness.combinedSnapshot, newerTrustedSnapshot)
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
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.reason, .gitScanFailed)
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

    func testRepeatedStartDoesNotCreateAdditionalRefreshWork() {
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
        harness.coordinator.start()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
    }

    func testBackgroundForegroundCyclesKeepResourceCountsAndWidgetReloadStable() {
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
        XCTAssertEqual(harness.coordinator.workspaceNotificationObserverCount, 3)

        for _ in 0..<25 {
            harness.coordinator.handleDidResignActive()
            XCTAssertFalse(harness.coordinator.isPeriodicRefreshScheduled)

            harness.coordinator.handleDidBecomeActive()
            XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
            XCTAssertEqual(harness.coordinator.workspaceNotificationObserverCount, 3)
        }

        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)

        harness.coordinator.stop()
        XCTAssertFalse(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.coordinator.workspaceNotificationObserverCount, 0)

        harness.advanceCurrentDate(by: 120)
        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
    }

    func testStopDropsInFlightRefreshCompletionAndAllowsCleanRestart() {
        let harness = makeHarness()
        let trustedSnapshot = harness.seedCombinedSnapshot(
            activity: GitTodayActivitySnapshot(focusBlockCount: 9, commitCount: 12, recentProjectName: "Trusted")
        )
        let allowFirstRefreshToFinish = DispatchSemaphore(value: 0)
        let firstRefreshStarted = expectation(description: "first refresh started")
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 0, recentProjectName: "TinyBuddy")
                firstRefreshStarted.fulfill()
                allowFirstRefreshToFinish.wait()
            }
        }

        harness.coordinator.start()
        wait(for: [firstRefreshStarted], timeout: 1.0)
        harness.coordinator.stop()
        allowFirstRefreshToFinish.signal()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(harness.combinedSnapshot, trustedSnapshot)

        harness.performAndWaitForScriptRunCount(2) {
            harness.coordinator.start()
        }
        XCTAssertEqual(harness.scriptRunCount, 2)
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
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
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
    private let dailyStatsStore: DailyStatsStore
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let sharedSnapshotDiagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder
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
        self.dailyStatsStore = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { [state] in state.currentDate }
        )
        self.combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                defaults.synchronize()
            },
            readFailureProvider: { [state] in
                state.validatedSnapshotReadCount += 1
                return state.validatedSnapshotReadFailures[state.validatedSnapshotReadCount]
            }
        )
        self.sharedSnapshotDiagnosticRecorder = TinyBuddySharedSnapshotDiagnosticRecorder()
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
            trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil }
            ),
            focusBlockCountStore: focusBlockCountStore,
            commitCountStore: commitCountStore,
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { [state] in state.currentDate },
                sharedFallbacksEnabled: false
            ),
            calendar: calendar,
            dateProvider: { [state] in state.currentDate }
        )

        self.coordinator = GitActivityRefreshCoordinator(
            activityStore: activityStore,
            dailyStatsStore: dailyStatsStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            refreshInterval: 300,
            minimumRefreshSpacing: 60,
            widgetReloader: { [weak testCase, state] in
                guard testCase != nil else {
                    return
                }

                try state.widgetReloaderHook?()
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
            },
            sharedSnapshotDiagnosticRecorder: sharedSnapshotDiagnosticRecorder
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
    var latestHiddenDiagnosticSummary: TinyBuddyHiddenSnapshotDiagnosticSummary? {
        sharedSnapshotDiagnosticRecorder.latestSummary
    }
    var combinedSnapshot: TinyBuddyCombinedSnapshot? { combinedSnapshotStore.load() }
    var readOnlyCombinedSnapshot: TinyBuddyCombinedSnapshot? { combinedSnapshotStore.loadReadOnly() }
    var statusNotificationCenterForTesting: NotificationCenter { statusNotificationCenter }
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

    func setWidgetReloaderHook(_ hook: @escaping () throws -> Void) {
        state.widgetReloaderHook = hook
    }

    func failValidatedSnapshotRead(
        number: Int,
        with reason: TinyBuddySharedSnapshotReason
    ) {
        state.validatedSnapshotReadFailures[number] = reason
    }

    func setScriptMetrics(_ metrics: GitRefreshScriptMetrics?) {
        state.scriptMetrics = metrics
    }

    func seedCombinedSnapshot(
        activity: GitTodayActivitySnapshot,
        revision: Int64? = nil
    ) -> TinyBuddyCombinedSnapshot {
        combinedSnapshotStore.updateActivitySlice(
            activity,
            activityRevision: revision,
            fallbackSnapshot: dailyStatsStore.loadSnapshot()
        ).snapshot!
    }

    func stageCombinedSnapshot(_ snapshot: TinyBuddyCombinedSnapshot) {
        activityDefaults.set(
            TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB
        )
        activityDefaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(snapshot.revision),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )
        activityDefaults.set(
            snapshot.revision,
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision
        )
        activityDefaults.synchronize()
    }

    func setTrustedActivitySnapshot(
        _ activity: GitTodayActivitySnapshot,
        revision: Int64
    ) {
        activityDefaults.set(
            GitTodayActivityTrustedSnapshotStore.encode(
                GitTodayActivityTrustedSnapshot(
                    revision: revision,
                    dayIdentifier: currentDayIdentifier,
                    activity: activity
                )
            ),
            forKey: GitTodayActivityTrustedSnapshotStore.Key.snapshot
        )
        activityDefaults.synchronize()
    }

    func exhaustCombinedSnapshotRevision() {
        activityDefaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(Int64.max),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )
        activityDefaults.set(
            Int64.max,
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision
        )
        activityDefaults.synchronize()
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
        var widgetReloaderHook: (() throws -> Void)?
        var scriptMetrics: GitRefreshScriptMetrics?
        var validatedSnapshotReadCount = 0
        var validatedSnapshotReadFailures: [Int: TinyBuddySharedSnapshotReason] = [:]
        var statusHistory: [GitActivityRefreshStatus] = []
        var diagnosticEventIdentifiers: [String] = []

        init(currentDate: Date) {
            self.currentDate = currentDate
        }
    }
}
