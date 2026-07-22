import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore
import Foundation

final class GitActivityRefreshCoordinatorTests: XCTestCase {
    func testScriptMetricsParserPreservesRefreshOutcome() throws {
        let metrics = try XCTUnwrap(
            GitRefreshScriptResultParser.parseMetrics(
                from: "TINYBUDDY_REFRESH_METRICS\trepository_count=0\trefresh_outcome=skipped\tshared_data_written=0"
            )
        )

        XCTAssertEqual(metrics.refreshOutcome, .skipped)
    }

    func testScriptMetricsParserMapsUnrecognizedRefreshOutcomeToUnknown() throws {
        let metrics = try XCTUnwrap(
            GitRefreshScriptResultParser.parseMetrics(
                from: "TINYBUDDY_REFRESH_METRICS\trepository_count=1\trefresh_outcome=future-value\tshared_data_written=0"
            )
        )

        XCTAssertEqual(metrics.refreshOutcome, .unknown)
    }

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
        XCTAssertEqual(harness.widgetReloadCount, 1)
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
                    widgetContentChanged: true,
                    widgetReloaded: true,
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
        XCTAssertEqual(harness.widgetReloadCount, 1)
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
                    widgetContentChanged: true,
                    widgetReloaded: true,
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

    func testAllInvalidSavedAuthorizationsPreserveTheLastCommittedActivity() {
        let harness = makeHarness(authorizedRoots: [], authorizationIssue: .authorizationInvalid)
        let committedActivity = GitTodayActivitySnapshot(
            focusBlockCount: 4,
            commitCount: 7,
            recentProjectName: "StillAvailable"
        )
        let committedSnapshot = harness.seedCombinedSnapshot(activity: committedActivity, revision: 1)

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 0)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.combinedSnapshot, committedSnapshot)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .authorizationInvalid)
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
                    widgetContentChanged: true,
                    widgetReloaded: true,
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

    func testRefreshPassesExplicitExclusionRulesToScript() {
        let exclusions = ["Teams/Private", "Archived"]
        let harness = makeHarness(exclusionRules: exclusions)

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }

        XCTAssertEqual(harness.capturedExclusionRules, exclusions)
    }

    func testFirstVisibleRefreshReloadsWidgetWhenReadyStateReplacesLoading() {
        let harness = makeHarness()

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .succeeded,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: 1,
                    widgetContentChanged: true,
                    widgetReloaded: true
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
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.widgetContentChanged, true)
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
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.widgetContentChanged, true)
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
                widgetContentChanged: true,
                widgetReloaded: true
            )
        )
    }

    func testSharedWriteAndRefreshTimestampDoNotReloadUnchangedWidgetPresentation() {
        let harness = makeHarness()
        harness.setScriptMetrics(unchangedScriptMetrics)
        harness.performAndWaitForRefresh {
            harness.coordinator.handleDidBecomeActive()
        }
        XCTAssertEqual(harness.widgetReloadCount, 1)

        harness.advanceCurrentDate(by: 61)
        harness.setScriptMetrics(changedScriptMetrics)
        harness.performAndWaitForStatusCount(2) {
            harness.coordinator.handleManualRefresh()
        }

        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.sharedDataWritten, true)
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.widgetContentChanged, false)
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.widgetReloaded, false)
    }

    func testPartialScriptRefreshPropagatesWarningWithoutFalseSuccess() {
        let harness = makeHarness()
        harness.setScriptMetrics(
            GitRefreshScriptMetrics(
                repositoryCount: 3,
                invalidRepositoryCount: 1,
                refreshOutcome: .partial,
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

    func testSkippedScriptRefreshIsNotRecordedAsSucceeded() {
        let harness = makeHarness()
        let committedActivity = GitTodayActivitySnapshot(
            focusBlockCount: 2,
            commitCount: 3,
            recentProjectName: "Committed"
        )
        let initialSnapshot = harness.seedCombinedSnapshot(activity: committedActivity)
        harness.setScriptMetrics(
            GitRefreshScriptMetrics(
                repositoryCount: 0,
                refreshOutcome: .skipped,
                cacheHitCount: 0,
                reflogUnchangedSkipCount: 0,
                recomputedRepositoryCount: 0,
                sharedDataWritten: false
            )
        )
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            harness.setActivitySnapshot(focusBlockCount: 0, commitCount: 0, recentProjectName: nil)
        }

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .skipped)
        XCTAssertNil(harness.lastRefreshStatus?.diagnostic)
        XCTAssertEqual(harness.combinedSnapshot, initialSnapshot)
        XCTAssertEqual(harness.widgetReloadCount, 1)
    }

    func testFailedScriptOutcomeDoesNotCommitActivitySnapshot() {
        let harness = makeHarness()
        let committedActivity = GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 2,
            recentProjectName: "Committed"
        )
        let initialSnapshot = harness.seedCombinedSnapshot(activity: committedActivity)
        harness.setScriptMetrics(
            GitRefreshScriptMetrics(
                repositoryCount: 1,
                refreshOutcome: .failed,
                cacheHitCount: 0,
                reflogUnchangedSkipCount: 0,
                recomputedRepositoryCount: 1,
                sharedDataWritten: false
            )
        )
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            harness.setActivitySnapshot(focusBlockCount: 9, commitCount: 10, recentProjectName: "Uncommitted")
        }

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.combinedSnapshot, initialSnapshot)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .scriptExecutionFailed)
    }

    func testUnknownScriptOutcomeDoesNotCommitActivitySnapshot() {
        let harness = makeHarness()
        let committedActivity = GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 2,
            recentProjectName: "Committed"
        )
        let initialSnapshot = harness.seedCombinedSnapshot(activity: committedActivity)
        harness.setScriptMetrics(
            GitRefreshScriptMetrics(
                repositoryCount: 1,
                refreshOutcome: .unknown,
                cacheHitCount: 0,
                reflogUnchangedSkipCount: 0,
                recomputedRepositoryCount: 1,
                sharedDataWritten: false
            )
        )
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            harness.setActivitySnapshot(focusBlockCount: 9, commitCount: 10, recentProjectName: "Uncommitted")
        }

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.combinedSnapshot, initialSnapshot)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .scriptExecutionFailed)
        XCTAssertEqual(harness.widgetReloadCount, 1)
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

        XCTAssertEqual(harness.widgetReloadCount, 1)
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

        XCTAssertEqual(harness.widgetReloadCount, 1)
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

    func testActivityAggregationAndPersistenceRunOffMainThread() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            harness.setActivitySnapshot(focusBlockCount: 3, commitCount: 5, recentProjectName: "Background")
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.commitCount, 5)
        XCTAssertEqual(harness.combinedSnapshotWriteWasOnMainThread, false)
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
            XCTAssertEqual(harness.widgetReloadCount, 2)
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
        XCTAssertEqual(harness.widgetReloadCount, 1)
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
                    widgetContentChanged: true,
                    widgetReloaded: true,
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
        harness.waitForWidgetReloadCount(2)

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
        XCTAssertEqual(harness.widgetReloadCount, 2)
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
            XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
            XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 30 * 60)

            harness.coordinator.handleDidBecomeActive()
            XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
            XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 5 * 60)
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

    func testResigningActiveUsesBackgroundCadenceAndDefersWakeRefreshUntilNextActivation() {
        let harness = makeHarness()

        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)

        harness.coordinator.handleDidResignActive()
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 30 * 60)

        harness.advanceCurrentDate(by: 120)
        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        harness.postWorkspaceNotification(named: NSWorkspace.screensDidWakeNotification)
        harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 1)

        harness.performAndWaitForScriptRunCount(2) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.performAndWaitForStatusCount(2) {}
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

        XCTAssertEqual(harness.scriptRunCount, 1)
        harness.waitForWidgetReloadCount(2)
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testRefreshPublishesLoadingBeforeCompleting() {
        let harness = makeHarness()
        let didStart = expectation(description: "loading notification")
        let observer = harness.statusNotificationCenterForTesting.addObserver(
            forName: .gitActivityRefreshDidStart,
            object: nil,
            queue: nil
        ) { _ in
            didStart.fulfill()
        }
        defer { harness.statusNotificationCenterForTesting.removeObserver(observer) }

        harness.coordinator.handleDidBecomeActive()

        wait(for: [didStart], timeout: 1.0)
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
    }

    func testWidgetReloadReadsPersistedAuthorizationStateInsteadOfPreviousStatus() {
        let harness = makeHarness(authorizedRoots: [])
        var statusObservedByWidgetReload: GitActivityRefreshStatus?
        harness.setWidgetReloaderHook {
            statusObservedByWidgetReload = harness.lastRefreshStatus
        }

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(statusObservedByWidgetReload?.diagnostic?.reason, .authorizationRequired)
        XCTAssertEqual(harness.lastRefreshStatus?.metrics?.widgetReloaded, true)
    }

    func testRepeatedSameEmptyStateDoesNotReloadWidgetAgain() {
        let harness = makeHarness(authorizedRoots: [])

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.widgetReloadCount, 1)

        harness.advanceCurrentDate(by: 61)
        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .authorizationRequired)
    }

    func testRemovingAllAuthorizationsPublishesAndReloadsTheWidgetExactlyOnce() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        XCTAssertEqual(harness.widgetReloadCount, 1)

        harness.authorizedRoots = []
        harness.coordinator.handleAuthorizationChanged()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.widgetReloadCount, 2)
        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .authorizationRequired)
    }

    func testManualRefreshForUnchangedAuthorizationStateDoesNotReloadWidget() {
        let harness = makeHarness(authorizedRoots: [])

        harness.coordinator.start()
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.widgetReloadCount, 1)

        harness.coordinator.handleManualRefresh()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .authorizationRequired)
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

    func testPartialAuthorizationFailureScansValidRootsAndRecordsPartialRecovery() {
        let liveRoot = URL(fileURLWithPath: "/Authorized/LiveProject")
        let harness = makeHarness(
            authorizedRoots: [liveRoot],
            authorizationIssue: .authorizationInvalid
        )
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            harness.setActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "LiveProject")
        }

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.capturedRootPaths, [liveRoot.path])
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .partial)
        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .partialAuthorizationRecovery)
        XCTAssertEqual(harness.latestHiddenDiagnosticSummary?.reason, .gitScanPartial)
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
    }

    func testRestoredPartialAuthorizationIsImmediatelyReincludedInTheNextRefresh() {
        let liveRoot = URL(fileURLWithPath: "/Authorized/LiveProject")
        let restoredRoot = URL(fileURLWithPath: "/Authorized/RestoredProject")
        let harness = makeHarness(
            authorizedRoots: [liveRoot],
            authorizationIssue: .authorizationInvalid
        )

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.start()
        }
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .partial)

        harness.authorizationIssue = nil
        harness.authorizedRoots = [liveRoot, restoredRoot]
        harness.performAndWaitForScriptRunCount(2) {
            harness.coordinator.handleAuthorizationChanged()
        }
        harness.waitForWidgetReloadCount(2)

        XCTAssertEqual(harness.capturedRootPaths, [liveRoot.path, restoredRoot.path])
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
        XCTAssertNil(harness.lastRefreshStatus?.diagnostic)
    }

    func testAuthorizationChangeDuringRefreshQueuesImmediateRefreshWithCurrentRoots() {
        let oldRoot = URL(fileURLWithPath: "/Authorized/OldProject")
        let currentRoot = URL(fileURLWithPath: "/Authorized/CurrentProject")
        let harness = makeHarness(authorizedRoots: [oldRoot])
        let firstRunStarted = expectation(description: "first authorization refresh started")
        let releaseFirstRun = DispatchSemaphore(value: 0)
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            firstRunStarted.fulfill()
            releaseFirstRun.wait()
        }

        harness.coordinator.start()
        wait(for: [firstRunStarted], timeout: 1.0)

        harness.authorizedRoots = [currentRoot]
        harness.coordinator.handleAuthorizationChanged()
        harness.performAndWaitForScriptRunCount(2) {
            releaseFirstRun.signal()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.capturedRootPaths, [currentRoot.path])
        XCTAssertEqual(harness.stopAccessCount, 2)
        XCTAssertEqual(harness.lastRefreshStatus?.trigger, .reopen)
    }

    func testAuthorizationChangeCancelsInFlightRefreshBeforeStartingReplacement() {
        let oldRoot = URL(fileURLWithPath: "/Authorized/OldProject")
        let currentRoot = URL(fileURLWithPath: "/Authorized/CurrentProject")
        let harness = makeHarness(authorizedRoots: [oldRoot])
        let firstRunStarted = expectation(description: "first authorization refresh started")
        let cancellationReleasedRun = DispatchSemaphore(value: 0)
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            firstRunStarted.fulfill()
            cancellationReleasedRun.wait()
            throw CancellationError()
        }
        harness.setScriptCancellationHook {
            cancellationReleasedRun.signal()
        }

        harness.coordinator.start()
        wait(for: [firstRunStarted], timeout: 1.0)

        harness.authorizedRoots = [currentRoot]
        harness.coordinator.handleAuthorizationChanged()
        harness.performAndWaitForScriptRunCount(2) {}
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptCancellationCount, 1)
        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.statusHistory.count, 1)
        XCTAssertEqual(harness.capturedRootPaths, [currentRoot.path])
        XCTAssertEqual(harness.lastRefreshStatus?.trigger, .reopen)
    }

    func testAuthorizationReplacementDiscardsLateSuccessfulResultBeforeSnapshotAndWidgetPublication() {
        let oldRoot = URL(fileURLWithPath: "/Authorized/OldProject")
        let currentRoot = URL(fileURLWithPath: "/Authorized/CurrentProject")
        let harness = makeHarness(authorizedRoots: [oldRoot])
        let firstRunStarted = expectation(description: "old refresh started")
        let releaseOldRun = DispatchSemaphore(value: 0)

        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                firstRunStarted.fulfill()
                releaseOldRun.wait()
                harness.setActivitySnapshot(
                    focusBlockCount: 9,
                    commitCount: 9,
                    recentProjectName: "OldProject"
                )
            case 2:
                harness.setActivitySnapshot(
                    focusBlockCount: 2,
                    commitCount: 3,
                    recentProjectName: "CurrentProject"
                )
            default:
                return
            }
        }

        harness.coordinator.start()
        wait(for: [firstRunStarted], timeout: 1.0)

        harness.authorizedRoots = [currentRoot]
        harness.coordinator.handleAuthorizationChanged()
        harness.performAndWaitForScriptRunCount(2) {
            releaseOldRun.signal()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.statusHistory.count, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.focusBlockCount, 2)
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.commitCount, 3)
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.recentProjectName, "CurrentProject")
        XCTAssertEqual(harness.lastRefreshStatus?.trigger, .reopen)
    }

    func testRepeatedAuthorizationChangesCoalesceObsoleteQueuedReplacements() {
        let firstRoot = URL(fileURLWithPath: "/Authorized/FirstProject")
        let finalRoot = URL(fileURLWithPath: "/Authorized/FinalProject")
        let harness = makeHarness(authorizedRoots: [firstRoot])
        let firstRunStarted = expectation(description: "first refresh started")
        let releaseFirstRun = DispatchSemaphore(value: 0)

        harness.setScriptRunnerHook { runCount in
            switch runCount {
            case 1:
                firstRunStarted.fulfill()
                releaseFirstRun.wait()
                harness.setActivitySnapshot(
                    focusBlockCount: 8,
                    commitCount: 8,
                    recentProjectName: "FirstProject"
                )
            case 2:
                harness.setActivitySnapshot(
                    focusBlockCount: 1,
                    commitCount: 4,
                    recentProjectName: "FinalProject"
                )
            default:
                XCTFail("obsolete replacement must not run the script")
            }
        }

        harness.coordinator.start()
        wait(for: [firstRunStarted], timeout: 1.0)

        for _ in 0..<3 {
            harness.authorizedRoots = [finalRoot]
            harness.coordinator.handleAuthorizationChanged()
        }
        harness.performAndWaitForScriptRunCount(2) {
            releaseFirstRun.signal()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.statusHistory.count, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.capturedRootPaths, [finalRoot.path])
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.recentProjectName, "FinalProject")
    }

    func testPartialAuthorizationWithSkippedScriptPreservesCommittedActivity() {
        let liveRoot = URL(fileURLWithPath: "/Authorized/LiveProject")
        let harness = makeHarness(
            authorizedRoots: [liveRoot],
            authorizationIssue: .authorizationInvalid
        )
        let committedActivity = GitTodayActivitySnapshot(
            focusBlockCount: 2,
            commitCount: 3,
            recentProjectName: "Committed"
        )
        let initialSnapshot = harness.seedCombinedSnapshot(activity: committedActivity)
        harness.setScriptMetrics(
            GitRefreshScriptMetrics(
                repositoryCount: 0,
                refreshOutcome: .skipped,
                cacheHitCount: 0,
                reflogUnchangedSkipCount: 0,
                recomputedRepositoryCount: 0,
                sharedDataWritten: false
            )
        )
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else { return }
            harness.setActivitySnapshot(focusBlockCount: 0, commitCount: 0, recentProjectName: nil)
        }

        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.combinedSnapshot, initialSnapshot)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .partial)
        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .partialAuthorizationRecovery)
        XCTAssertEqual(harness.widgetReloadCount, 1)
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

        harness.waitForWidgetReloadCount(2)
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

    func testCommittedActivityHookReceivesAuthoritativePreviousAndCurrentSnapshots() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(
                    focusBlockCount: 1,
                    commitCount: 0,
                    recentProjectName: "TinyBuddy"
                )
            } else if runCount == 2 {
                harness.setActivitySnapshot(
                    focusBlockCount: 2,
                    commitCount: 1,
                    recentProjectName: "TinyBuddy"
                )
            }
        }

        harness.performAndWaitForRefresh { harness.coordinator.start() }
        harness.advanceMonotonicTime(by: 61)
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.coordinator.handleManualRefresh()
        }

        XCTAssertEqual(harness.committedActivityPairs.count, 2)
        XCTAssertEqual(harness.committedActivityPairs.last?.previous?.commitCount, 0)
        XCTAssertEqual(harness.committedActivityPairs.last?.current.commitCount, 1)
        XCTAssertEqual(harness.committedActivityPairs.last?.current.focusBlockCount, 2)
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
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
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
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
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
        XCTAssertEqual(harness.widgetReloadCount, 2)

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
        XCTAssertEqual(harness.widgetReloadCount, 2)
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
                    widgetContentChanged: true,
                    widgetReloaded: true,
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

    func testCrossMidnightInvalidatesInFlightRefreshAndPublishesOnlyNewGeneration() {
        let harness = makeHarness()
        let firstRefreshStarted = expectation(description: "first refresh started")
        let releaseFirstRefresh = DispatchSemaphore(value: 0)
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(
                    focusBlockCount: 9,
                    commitCount: 9,
                    recentProjectName: "OldDay"
                )
                firstRefreshStarted.fulfill()
                releaseFirstRefresh.wait()
            } else if runCount == 2 {
                harness.setActivitySnapshot(
                    focusBlockCount: 2,
                    commitCount: 3,
                    recentProjectName: "NewDay"
                )
            }
        }

        harness.coordinator.start()
        wait(for: [firstRefreshStarted], timeout: 1.0)
        harness.advanceCurrentDate(by: 12 * 60 * 60)
        harness.coordinator.handleTimeEnvironmentChanged(harness.currentTimeContext)

        harness.performAndWaitForScriptRunCount(2) {
            releaseFirstRefresh.signal()
        }
        harness.waitForNoRefresh()

        XCTAssertGreaterThanOrEqual(harness.scriptCancellationCount, 1)
        XCTAssertEqual(harness.combinedSnapshot?.dayIdentifier, "2026-07-03")
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.commitCount, 3)
        XCTAssertEqual(harness.lastRefreshStatus?.trigger, .timeEnvironmentChanged)
    }

    func testCrossMidnightReloadsWidgetOnceWhenNewDayContentValuesAreUnchanged() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            harness.setActivitySnapshot(
                focusBlockCount: 0,
                commitCount: 0,
                recentProjectName: nil
            )
            harness.setScriptMetrics(
                runCount == 2 ? self.changedScriptMetrics : self.unchangedScriptMetrics
            )
        }
        harness.performAndWaitForWidgetReloadCount(1) {
            harness.coordinator.start()
        }

        harness.advanceCurrentDate(by: 12 * 60 * 60)
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.coordinator.handleTimeEnvironmentChanged(harness.currentTimeContext)
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.currentDayIdentifier, "2026-07-03")
        XCTAssertEqual(harness.combinedSnapshot?.dayIdentifier, "2026-07-03")
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.commitCount, 0)
        XCTAssertEqual(harness.widgetReloadCount, 2)

        harness.advanceCurrentDate(by: 6)
        harness.performAndWaitForStatusCount(3) {
            harness.coordinator.handleManualRefresh()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testSameDayEnvironmentChangeAfterValidationPreventsOldGenerationCommit() {
        let harness = makeHarness()
        let oldCommitReached = expectation(description: "old generation reached commit boundary")
        let releaseOldCommit = DispatchSemaphore(value: 0)
        let newRefreshStarted = expectation(description: "new environment refresh started")
        let releaseNewRefresh = DispatchSemaphore(value: 0)
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(
                    focusBlockCount: 9,
                    commitCount: 9,
                    recentProjectName: "OldDay"
                )
            } else if runCount == 2 {
                newRefreshStarted.fulfill()
                releaseNewRefresh.wait()
                harness.setActivitySnapshot(
                    focusBlockCount: 2,
                    commitCount: 3,
                    recentProjectName: "NewDay"
                )
            }
        }
        harness.setBeforeActivityCommitHook {
            guard harness.scriptRunCount == 1 else {
                return
            }
            oldCommitReached.fulfill()
            releaseOldCommit.wait()
        }

        harness.coordinator.start()
        wait(for: [oldCommitReached], timeout: 1.0)
        harness.setLocale(Locale(identifier: "fr_FR"))
        harness.coordinator.handleTimeEnvironmentChanged(harness.currentTimeContext)

        releaseOldCommit.signal()
        wait(for: [newRefreshStarted], timeout: 1.0)
        XCTAssertNil(harness.combinedSnapshot)

        let expectedReloadCount = harness.widgetReloadCount + 1
        harness.performAndWaitForWidgetReloadCount(expectedReloadCount) {
            releaseNewRefresh.signal()
        }

        XCTAssertEqual(harness.combinedSnapshot?.dayIdentifier, "2026-07-02")
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.commitCount, 3)
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.recentProjectName, "NewDay")
    }

    func testTimeScopeLeasePublicationFailurePreservesCommittedSnapshotAndSkipsReplacementScript() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            guard runCount == 1 else {
                return
            }
            harness.setActivitySnapshot(
                focusBlockCount: 4,
                commitCount: 5,
                recentProjectName: "Committed"
            )
        }
        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.start()
        }
        harness.waitForNoRefresh()
        let committed = harness.combinedSnapshot

        harness.setTimeScopePublisherHook { _ in nil }
        harness.setLocale(Locale(identifier: "fr_FR"))
        harness.coordinator.handleTimeEnvironmentChanged(harness.currentTimeContext)
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.combinedSnapshot, committed)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)
        XCTAssertEqual(
            harness.lastRefreshStatus?.diagnostic?.reason,
            .scriptExecutionFailed
        )
    }

    func testClockRollbackDoesNotFreezeFailureBackoff() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                struct ScriptFailure: Error {}
                throw ScriptFailure()
            }
            harness.setActivitySnapshot(
                focusBlockCount: 1,
                commitCount: 2,
                recentProjectName: "Recovered"
            )
        }

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .failed)

        harness.adjustWallClock(by: -60 * 60)
        harness.advanceMonotonicTime(by: 300)
        harness.performAndWaitForScriptRunCount(2) {
            harness.coordinator.handleDidWake()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.lastRefreshStatus?.outcome, .succeeded)
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.commitCount, 2)
    }

    func testRepeatedTimeEnvironmentInvalidationsCoalesceToOneReplacementRefresh() {
        let harness = makeHarness()
        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.start()
        }
        harness.waitForNoRefresh()

        let secondRefreshStarted = expectation(description: "replacement refresh started")
        let releaseSecondRefresh = DispatchSemaphore(value: 0)
        harness.setScriptRunnerHook { runCount in
            if runCount == 2 {
                secondRefreshStarted.fulfill()
                releaseSecondRefresh.wait()
            }
        }
        harness.advanceCurrentDate(by: 12 * 60 * 60)
        harness.coordinator.handleTimeEnvironmentChanged(harness.currentTimeContext)
        wait(for: [secondRefreshStarted], timeout: 1.0)

        for _ in 0..<8 {
            harness.coordinator.handleTimeEnvironmentChanged(harness.currentTimeContext)
        }
        releaseSecondRefresh.signal()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
    }

    func testSleepInvalidatesInFlightRefreshAndWakeStartsOneReplacement() {
        let harness = makeHarness()
        let firstRefreshStarted = expectation(description: "sleeping refresh started")
        let releaseFirstRefresh = DispatchSemaphore(value: 0)
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(
                    focusBlockCount: 8,
                    commitCount: 8,
                    recentProjectName: "BeforeSleep"
                )
                firstRefreshStarted.fulfill()
                releaseFirstRefresh.wait()
            } else if runCount == 2 {
                harness.setActivitySnapshot(
                    focusBlockCount: 1,
                    commitCount: 1,
                    recentProjectName: "AfterWake"
                )
            }
        }

        harness.coordinator.start()
        wait(for: [firstRefreshStarted], timeout: 1.0)
        harness.coordinator.handleWillSleep()

        harness.performAndWaitForScriptRunCount(2) {
            releaseFirstRefresh.signal()
            harness.coordinator.handleDidBecomeActive()
        }
        harness.waitForNoRefresh()

        XCTAssertGreaterThanOrEqual(harness.scriptCancellationCount, 1)
        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.statusHistory.count, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.recentProjectName, "AfterWake")
    }

    func testWestwardTimeZoneChangePreservesNewestCommittedDayInsteadOfPublishingRollback() throws {
        let harness = makeHarness()
        harness.adjustWallClock(by: -11 * 60 * 60)
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                harness.setActivitySnapshot(
                    focusBlockCount: 4,
                    commitCount: 5,
                    recentProjectName: "UTC"
                )
            }
        }
        harness.performAndWaitForScriptRunCount(1) {
            harness.coordinator.start()
        }
        harness.waitForNoRefresh()
        let committed = try XCTUnwrap(harness.combinedSnapshot)

        harness.setTimeZone(try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        harness.performAndWaitForScriptRunCount(2) {
            harness.coordinator.handleTimeEnvironmentChanged(harness.currentTimeContext)
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.combinedSnapshot, committed)
        XCTAssertEqual(harness.combinedSnapshot?.dayIdentifier, "2026-07-02")
        XCTAssertEqual(harness.combinedSnapshot?.activitySnapshot.commitCount, 5)
    }

    func testUnchangedRefreshesBackOffAndRepositoryChangeRestoresFastCadence() {
        let harness = makeHarness()
        harness.setScriptMetrics(unchangedScriptMetrics)
        harness.setScriptRunnerHook { runCount in
            if runCount == 4 {
                harness.setScriptMetrics(self.changedScriptMetrics)
                harness.setActivitySnapshot(
                    focusBlockCount: 1,
                    commitCount: 0,
                    recentProjectName: "TinyBuddy"
                )
            }
        }

        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        XCTAssertEqual(harness.coordinator.currentUnchangedRefreshStreak, 1)
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 10 * 60)
        XCTAssertTrue(harness.coordinator.repositoryChangeMonitorIsRunning)

        harness.advanceCurrentDate(by: 601)
        harness.performAndWaitForStatusCount(2) {
            harness.coordinator.handleDidBecomeActive()
        }
        XCTAssertEqual(harness.coordinator.currentUnchangedRefreshStreak, 2)
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 10 * 60)

        harness.advanceCurrentDate(by: 601)
        harness.performAndWaitForStatusCount(3) {
            harness.coordinator.handleDidBecomeActive()
        }
        XCTAssertEqual(harness.coordinator.currentUnchangedRefreshStreak, 3)
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 20 * 60)

        harness.performAndWaitForStatusCount(4) {
            harness.emitRepositoryChanges(count: 100)
        }
        XCTAssertEqual(harness.scriptRunCount, 4)
        XCTAssertEqual(harness.coordinator.currentUnchangedRefreshStreak, 0)
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 5 * 60)
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 4)
    }

    func testPowerAndVisibilityTransitionsRescheduleOneTimerAndGateFileListening() {
        let harness = makeHarness()

        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 5 * 60)
        XCTAssertTrue(harness.coordinator.repositoryChangeMonitorIsRunning)
        XCTAssertEqual(harness.repositoryMonitorStartCount, 1)

        harness.setPowerState(
            TinyBuddyPowerState(isOnBatteryPower: true, isLowPowerModeEnabled: false)
        )
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 15 * 60)
        XCTAssertFalse(harness.coordinator.repositoryChangeMonitorIsRunning)
        XCTAssertEqual(harness.repositoryMonitorStopCount, 1)

        harness.coordinator.handleDidResignActive()
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 60 * 60)

        harness.setPowerState(
            TinyBuddyPowerState(isOnBatteryPower: false, isLowPowerModeEnabled: true)
        )
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 60 * 60)

        harness.coordinator.handleDidBecomeActive()
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 30 * 60)
        XCTAssertFalse(harness.coordinator.repositoryChangeMonitorIsRunning)

        harness.setPowerState(
            TinyBuddyPowerState(isOnBatteryPower: false, isLowPowerModeEnabled: false)
        )
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 5 * 60)
        XCTAssertTrue(harness.coordinator.repositoryChangeMonitorIsRunning)
        XCTAssertEqual(harness.repositoryMonitorStartCount, 2)
    }

    func testRapidForegroundBackgroundStormNeverStartsDelayedRepositoryMonitor() {
        let harness = makeHarness(
            repositoryMonitoringStartDelay: 60,
            foregroundActivationRefreshDelay: 60
        )
        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        harness.advanceCurrentDate(by: 61)

        XCTAssertTrue(harness.coordinator.isRepositoryMonitoringStartScheduled)
        XCTAssertEqual(harness.repositoryMonitorStartCount, 0)

        for _ in 0..<100 {
            harness.coordinator.handleDidResignActive()
            XCTAssertFalse(harness.coordinator.isRepositoryMonitoringStartScheduled)
            XCTAssertFalse(harness.coordinator.isForegroundActivationRefreshScheduled)
            harness.coordinator.handleDidBecomeActive()
            XCTAssertTrue(harness.coordinator.isRepositoryMonitoringStartScheduled)
            XCTAssertTrue(harness.coordinator.isForegroundActivationRefreshScheduled)
        }
        harness.coordinator.handleDidResignActive()
        harness.waitForNoRefresh()

        XCTAssertFalse(harness.coordinator.isRepositoryMonitoringStartScheduled)
        XCTAssertFalse(harness.coordinator.repositoryChangeMonitorIsRunning)
        XCTAssertEqual(harness.repositoryMonitorStartCount, 0)
        XCTAssertEqual(harness.repositoryMonitorStopCount, 0)
        XCTAssertEqual(harness.scriptRunCount, 1)
    }

    func testBecameActiveStormRunsOneRefreshAfterStableForegroundDelay() {
        let harness = makeHarness(foregroundActivationRefreshDelay: 0.01)
        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        harness.advanceCurrentDate(by: 61)
        harness.coordinator.handleDidResignActive()

        harness.performAndWaitForStatusCount(2) {
            for _ in 0..<100 {
                harness.coordinator.handleDidBecomeActive()
            }
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertFalse(harness.coordinator.isForegroundActivationRefreshScheduled)
    }

    func testRepositoryChangeStormDebouncesToOneRefresh() {
        let harness = makeHarness()
        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        harness.advanceCurrentDate(by: 61)

        harness.performAndWaitForStatusCount(2) {
            harness.emitRepositoryChanges(count: 250)
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.statusHistory.count, 2)
    }

    func testDiscoveryChangePassesAffectedRootWithoutGlobalCacheInvalidation() {
        let harness = makeHarness()
        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        harness.advanceCurrentDate(by: 61)

        harness.performAndWaitForStatusCount(2) {
            harness.emitRepositoryDiscoveryChange()
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.capturedInvalidatedRootPaths, ["/Authorized/TinyBuddyProject"])
        XCTAssertEqual(harness.repositoryDiscoveryCacheInvalidationCount, 0)
    }

    func testDiscoveryChangesCoalesceAffectedRootsBeforeOneRefresh() {
        let roots = ["/Authorized/A", "/Authorized/B"]
        let harness = makeHarness(authorizedRoots: roots.map(URL.init(fileURLWithPath:)))
        harness.performAndWaitForStatusCount(1) { harness.coordinator.start() }
        harness.advanceCurrentDate(by: 61)

        harness.performAndWaitForStatusCount(2) {
            for root in roots {
                harness.coordinator.handleRepositoryContentsChanged(impact: GitRepositoryChangeImpact(
                    requiresRepositoryDiscoveryRescan: true,
                    affectedRootPaths: [root]
                ))
            }
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.capturedInvalidatedRootPaths, roots)
        XCTAssertEqual(harness.repositoryDiscoveryCacheInvalidationCount, 0)
    }

    func testUnknownDiscoveryImpactFallsBackToGlobalDiscoveryCacheInvalidation() {
        let harness = makeHarness()
        harness.performAndWaitForStatusCount(1) { harness.coordinator.start() }
        harness.advanceCurrentDate(by: 61)

        harness.performAndWaitForStatusCount(2) {
            harness.coordinator.handleRepositoryContentsChanged(impact: GitRepositoryChangeImpact(
                requiresRepositoryDiscoveryRescan: true,
                affectedRootPaths: []
            ))
        }

        XCTAssertEqual(harness.repositoryDiscoveryCacheInvalidationCount, 1)
        XCTAssertEqual(harness.capturedInvalidatedRootPaths, [])
    }

    func testDiscoveryCacheInvalidationPreservesIncrementalRepositoryStats() throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyDiscoveryCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let discoveryFiles = [
            "repositories.txt",
            "authorized-roots.txt",
            "authorized-roots.signature",
            "excluded-paths.txt"
        ]
        for fileName in discoveryFiles + ["repository-stats.tsv", "repository-stats.cksum"] {
            try Data("fixture".utf8).write(to: cacheDirectory.appendingPathComponent(fileName))
        }

        GitActivityRefreshCoordinator.invalidateRepositoryDiscoveryCache(at: cacheDirectory)

        for fileName in discoveryFiles {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: cacheDirectory.appendingPathComponent(fileName).path
            ))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent("repository-stats.tsv").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent("repository-stats.cksum").path
        ))
    }

    func testManualRefreshStormDuringRefreshQueuesOnlyOneFollowUp() {
        let harness = makeHarness()
        let firstRunStarted = expectation(description: "first run started")
        let releaseFirstRun = DispatchSemaphore(value: 0)
        harness.setScriptRunnerHook { runCount in
            if runCount == 1 {
                firstRunStarted.fulfill()
                releaseFirstRun.wait()
            }
        }

        harness.coordinator.start()
        wait(for: [firstRunStarted], timeout: 1.0)
        for _ in 0..<100 {
            harness.coordinator.handleManualRefresh()
        }

        harness.performAndWaitForScriptRunCount(2) {
            releaseFirstRun.signal()
        }
        harness.performAndWaitForStatusCount(2) {}
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.statusHistory.count, 2)
    }

    func testWidgetReloadFingerprintDistinguishesPartialFailureReasons() {
        let harness = makeHarness(
            authorizedRoots: [URL(fileURLWithPath: "/Authorized/LiveProject")],
            authorizationIssue: .authorizationInvalid
        )
        harness.setScriptMetrics(
            GitRefreshScriptMetrics(
                repositoryCount: 1,
                invalidRepositoryCount: 1,
                refreshOutcome: .partial,
                cacheHitCount: 0,
                reflogUnchangedSkipCount: 0,
                recomputedRepositoryCount: 1,
                sharedDataWritten: false
            )
        )

        harness.performAndWaitForWidgetReloadCount(1) {
            harness.coordinator.start()
        }
        XCTAssertEqual(
            harness.lastRefreshStatus?.diagnostic?.reason,
            .partialAuthorizationRecovery
        )

        harness.authorizationIssue = nil
        harness.advanceCurrentDate(by: 61)
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.coordinator.handleManualRefresh()
        }

        XCTAssertEqual(harness.lastRefreshStatus?.diagnostic?.reason, .partialRecovery)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testBackgroundWakeAfterSleepRebuildsTimersWithoutImmediateDuplicateScan() {
        let harness = makeHarness()
        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        harness.coordinator.handleDidResignActive()
        harness.coordinator.handleWillSleep()
        XCTAssertFalse(harness.coordinator.isPeriodicRefreshScheduled)

        harness.advanceCurrentDate(by: 10)
        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertTrue(harness.coordinator.isPeriodicRefreshScheduled)
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 30 * 60)
    }

    func testWakeResamplesLowPowerStateBeforeSchedulingAndRefreshing() {
        let harness = makeHarness()
        harness.performAndWaitForStatusCount(1) {
            harness.coordinator.start()
        }
        harness.coordinator.handleWillSleep()
        harness.stagePowerState(
            TinyBuddyPowerState(isOnBatteryPower: true, isLowPowerModeEnabled: true)
        )
        harness.advanceCurrentDate(by: 10)

        harness.performAndWaitForStatusCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        }
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.coordinator.currentScheduledRefreshInterval, 30 * 60)
        XCTAssertFalse(harness.coordinator.repositoryChangeMonitorIsRunning)
        XCTAssertFalse(harness.coordinator.isRepositoryMonitoringStartScheduled)
    }

    private func makeHarness(
        authorizedRoots: [URL] = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")],
        exclusionRules: [String] = [],
        authorizationIssue: GitScanRootAccessIssue? = nil,
        scriptURL: URL? = URL(fileURLWithPath: "/tmp/tinybuddy-test-refresh.sh"),
        repositoryMonitoringStartDelay: TimeInterval = 0,
        foregroundActivationRefreshDelay: TimeInterval = 0
    ) -> RefreshHarness {
        RefreshHarness(
            testCase: self,
            authorizedRoots: authorizedRoots,
            exclusionRules: exclusionRules,
            authorizationIssue: authorizationIssue,
            scriptURL: scriptURL,
            repositoryMonitoringStartDelay: repositoryMonitoringStartDelay,
            foregroundActivationRefreshDelay: foregroundActivationRefreshDelay
        )
    }

    private var unchangedScriptMetrics: GitRefreshScriptMetrics {
        GitRefreshScriptMetrics(
            repositoryCount: 1,
            refreshOutcome: .success,
            cacheHitCount: 1,
            reflogUnchangedSkipCount: 1,
            recomputedRepositoryCount: 0,
            sharedDataWritten: false
        )
    }

    private var changedScriptMetrics: GitRefreshScriptMetrics {
        GitRefreshScriptMetrics(
            repositoryCount: 1,
            refreshOutcome: .success,
            cacheHitCount: 0,
            reflogUnchangedSkipCount: 0,
            recomputedRepositoryCount: 1,
            sharedDataWritten: true
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

private final class RefreshHarness: @unchecked Sendable {
    private let testCase: XCTestCase
    private let state: State
    private let refreshExpectationQueue = DispatchQueue(label: "TinyBuddyTests.RefreshHarness")
    private let workspaceNotificationCenter = NotificationCenter()
    private let statusNotificationCenter = NotificationCenter()
    private var pendingRefreshExpectation: XCTestExpectation?
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let activityDefaults: UserDefaults
    private let calendar: Calendar
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let dailyStatsStore: DailyStatsStore
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let sharedSnapshotDiagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder
    private var statusObserver: NSObjectProtocol?

    let coordinator: GitActivityRefreshCoordinator

    init(
        testCase: XCTestCase,
        authorizedRoots: [URL],
        exclusionRules: [String] = [],
        authorizationIssue: GitScanRootAccessIssue? = nil,
        scriptURL: URL? = URL(fileURLWithPath: "/tmp/tinybuddy-test-refresh.sh"),
        repositoryMonitoringStartDelay: TimeInterval = 0,
        foregroundActivationRefreshDelay: TimeInterval = 0
    ) {
        self.testCase = testCase
        self.state = State(currentDate: Self.makeDate(second: 0))
        self.state.authorizedRoots = authorizedRoots
        self.state.exclusionRules = exclusionRules
        self.state.authorizationIssue = authorizationIssue

        let defaults = UserDefaults(suiteName: "TinyBuddyAppTests.\(UUID().uuidString)")!
        self.activityDefaults = defaults
        let calendar = Self.makeCalendar()
        self.calendar = calendar
        let timeEnvironment = TinyBuddyTimeEnvironment(capture: { [state] in
            var sourceCalendar = Calendar(identifier: .gregorian)
            sourceCalendar.timeZone = state.currentTimeZone
            return TinyBuddyTimeContext(
                now: state.currentDate,
                timeZone: state.currentTimeZone,
                locale: state.currentLocale,
                sourceCalendar: sourceCalendar
            )
        })
        self.timeEnvironment = timeEnvironment
        self.dailyStatsStore = DailyStatsStore(
            userDefaults: defaults,
            timeEnvironment: timeEnvironment
        )
        self.combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { [state] value, key in
                state.combinedSnapshotWriteWasOnMainThread = Thread.isMainThread
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                _ = defaults.synchronize()
                return true
            },
            readFailureProvider: { [state] in
                state.validatedSnapshotReadCount += 1
                return state.validatedSnapshotReadFailures[state.validatedSnapshotReadCount]
            }
        )
        self.sharedSnapshotDiagnosticRecorder = TinyBuddySharedSnapshotDiagnosticRecorder()
        self.refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            timeEnvironment: timeEnvironment
        )
        let focusBlockCountStore = GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            timeEnvironment: timeEnvironment,
            sharedFallbacksEnabled: false
        )
        let commitCountStore = GitTodayCommitCountStore(
            userDefaults: defaults,
            timeEnvironment: timeEnvironment,
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
                timeEnvironment: timeEnvironment,
                sharedFallbacksEnabled: false
            ),
            timeEnvironment: timeEnvironment
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
            scriptRunner: { [state] _, rootURLs, exclusions, invalidatedRoots, _, _ in
                state.scriptRunCount += 1
                state.capturedRootPaths = rootURLs.map(\.standardizedFileURL.path)
                state.capturedExclusionRules = exclusions
                state.capturedInvalidatedRootPaths = invalidatedRoots
                try state.scriptRunnerHook?(state.scriptRunCount)
                state.onScriptRun?(state.scriptRunCount)
                return GitRefreshScriptResult(
                    standardOutput: "",
                    standardError: "",
                    metrics: state.scriptMetrics
                )
            },
            cancelScript: { [state] in
                state.scriptCancellationCount += 1
                state.scriptCancellationHook?()
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
            exclusionRulesProvider: { [state] in state.exclusionRules },
            timeEnvironment: timeEnvironment,
            dateProvider: { [state] in
                state.currentDate
            },
            monotonicTimeProvider: { [state] in
                state.monotonicTime
            },
            powerStateProvider: { [state] in
                state.powerState
            },
            timeScopePublisher: { [state] token in
                state.timeScopePublishCount += 1
                if let hook = state.timeScopePublisherHook {
                    return hook(token)
                }
                return URL(fileURLWithPath: "/tmp/tinybuddy-test-time-scope")
            },
            beforeActivityCommit: { [state] in
                state.beforeActivityCommitHook?()
            },
            activityDidCommit: { [state] previous, current in
                state.committedActivityPairs.append((previous, current))
            },
            repositoryChangeMonitorFactory: { [state] changeHandler in
                let monitor = TestGitRepositoryChangeMonitor(changeHandler: changeHandler)
                state.repositoryChangeMonitor = monitor
                return monitor
            },
            repositoryDiscoveryCacheInvalidator: { [state] in
                state.repositoryDiscoveryCacheInvalidationCount += 1
            },
            workspaceNotificationCenter: workspaceNotificationCenter,
            statusNotificationCenter: statusNotificationCenter,
            diagnosticRecorder: { [state] diagnostic, _ in
                state.diagnosticEventIdentifiers.append(diagnostic.stableIdentifier)
            },
            sharedSnapshotDiagnosticRecorder: sharedSnapshotDiagnosticRecorder,
            repositoryChangeDebounceInterval: 0.01,
            repositoryMonitoringStartDelay: repositoryMonitoringStartDelay,
            foregroundActivationRefreshDelay: foregroundActivationRefreshDelay,
            // The harness owns its clock and preferences. Reading the real
            // App Group continuity record would import an unrelated system
            // day/time-zone and turn ordinary lifecycle events into forced
            // time-environment refreshes.
            continuityRecordProvider: {
                TinyBuddyTimeContinuityRecord(
                    lastObservedDayIdentifier: "",
                    lastObservedTimeZoneIdentifier: ""
                )
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
            state.onStatusChange?(state.statusHistory.count)
        }
        state.onWidgetReload = { [weak self] _ in
            self?.fulfillPendingRefreshExpectation()
        }
        state.onScriptRun = { [weak self] _ in
            self?.fulfillPendingRefreshExpectation()
        }
        state.onStatusChange = { [weak self] _ in
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
    var capturedExclusionRules: [String] { state.capturedExclusionRules }
    var capturedInvalidatedRootPaths: [String] { state.capturedInvalidatedRootPaths }
    var stopAccessCount: Int { state.stopAccessCount }
    var scriptCancellationCount: Int { state.scriptCancellationCount }
    var currentDate: Date { state.currentDate }
    var currentDayIdentifier: String { currentTimeContext.dayIdentifier }
    var currentTimeContext: TinyBuddyTimeContext { timeEnvironment.capture()! }
    var lastRefreshStatus: GitActivityRefreshStatus? { refreshStatusStore.load() }
    var statusHistory: [GitActivityRefreshStatus] { state.statusHistory }
    var diagnosticEventIdentifiers: [String] { state.diagnosticEventIdentifiers }
    var latestHiddenDiagnosticSummary: TinyBuddyHiddenSnapshotDiagnosticSummary? {
        sharedSnapshotDiagnosticRecorder.latestSummary
    }
    var combinedSnapshot: TinyBuddyCombinedSnapshot? { combinedSnapshotStore.load() }
    var combinedSnapshotWriteWasOnMainThread: Bool? { state.combinedSnapshotWriteWasOnMainThread }
    var committedActivityPairs: [(
        previous: GitTodayActivitySnapshot?,
        current: GitTodayActivitySnapshot
    )] { state.committedActivityPairs }
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

    var repositoryMonitorStartCount: Int {
        state.repositoryChangeMonitor?.startCount ?? 0
    }

    var repositoryMonitorStopCount: Int {
        state.repositoryChangeMonitor?.stopCount ?? 0
    }

    var repositoryDiscoveryCacheInvalidationCount: Int {
        state.repositoryDiscoveryCacheInvalidationCount
    }

    func advanceCurrentDate(by seconds: TimeInterval) {
        state.currentDate = state.currentDate.addingTimeInterval(seconds)
        state.monotonicTime += max(0, seconds)
    }

    func adjustWallClock(by seconds: TimeInterval) {
        state.currentDate = state.currentDate.addingTimeInterval(seconds)
    }

    func advanceMonotonicTime(by seconds: TimeInterval) {
        state.monotonicTime += max(0, seconds)
    }

    func setTimeZone(_ timeZone: TimeZone) {
        state.currentTimeZone = timeZone
    }

    func setLocale(_ locale: Locale) {
        state.currentLocale = locale
    }

    func setPowerState(_ powerState: TinyBuddyPowerState) {
        state.powerState = powerState
        coordinator.handlePowerStateChanged(powerState)
    }

    func stagePowerState(_ powerState: TinyBuddyPowerState) {
        state.powerState = powerState
    }

    func postWorkspaceNotification(named name: Notification.Name) {
        workspaceNotificationCenter.post(name: name, object: nil)
    }

    func emitRepositoryChanges(count: Int) {
        for _ in 0..<count {
            state.repositoryChangeMonitor?.emitChange()
        }
    }

    func emitRepositoryDiscoveryChange() {
        state.repositoryChangeMonitor?.emitChange(requiresRepositoryDiscoveryRescan: true)
    }

    func setScriptRunnerHook(_ hook: @escaping (Int) throws -> Void) {
        state.scriptRunnerHook = hook
    }

    func setScriptCancellationHook(_ hook: @escaping () -> Void) {
        state.scriptCancellationHook = hook
    }

    func setBeforeActivityCommitHook(_ hook: @escaping () -> Void) {
        state.beforeActivityCommitHook = hook
    }

    func setTimeScopePublisherHook(_ hook: @escaping (String) -> URL?) {
        state.timeScopePublisherHook = hook
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
            timeEnvironment: timeEnvironment,
            sharedFallbacksEnabled: false
        )
        let commitStore = GitTodayCommitCountStore(
            userDefaults: activityDefaults,
            timeEnvironment: timeEnvironment,
            sharedFallbacksEnabled: false
        )
        let recentProjectStore = GitTodayRecentProjectStore(
            userDefaults: activityDefaults,
            timeEnvironment: timeEnvironment,
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

    func performAndWaitForStatusCount(_ expectedStatusCount: Int, action: () -> Void) {
        let expectation = testCase.expectation(description: "status count \(expectedStatusCount)")
        refreshExpectationQueue.sync {
            pendingRefreshExpectation = expectation
            state.expectedStatusCount = expectedStatusCount
            if state.statusHistory.count >= expectedStatusCount {
                expectation.fulfill()
                pendingRefreshExpectation = nil
                state.expectedStatusCount = 0
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
        testCase.wait(for: [expectation], timeout: 0.2)
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

            if state.expectedStatusCount > 0,
               state.statusHistory.count < state.expectedStatusCount {
                return
            }

            expectation.fulfill()
            pendingRefreshExpectation = nil
            state.expectedWidgetReloadCount = 0
            state.expectedScriptRunCount = 0
            state.expectedStatusCount = 0
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

    private final class State: @unchecked Sendable {
        var currentDate: Date
        var monotonicTime: TimeInterval = 1_000
        var currentTimeZone = TimeZone(secondsFromGMT: 0)!
        var currentLocale = Locale(identifier: "en_US_POSIX")
        var powerState = TinyBuddyPowerState(
            isOnBatteryPower: false,
            isLowPowerModeEnabled: false
        )
        var authorizedRoots: [URL] = []
        var exclusionRules: [String] = []
        var authorizationIssue: GitScanRootAccessIssue?
        var capturedRootPaths: [String] = []
        var capturedExclusionRules: [String] = []
        var capturedInvalidatedRootPaths: [String] = []
        var scriptRunCount = 0
        var repositoryDiscoveryCacheInvalidationCount = 0
        var scriptCancellationCount = 0
        var widgetReloadCount = 0
        var stopAccessCount = 0
        var expectedWidgetReloadCount = 0
        var expectedScriptRunCount = 0
        var expectedStatusCount = 0
        var onWidgetReload: ((Int) -> Void)?
        var onScriptRun: ((Int) -> Void)?
        var onStatusChange: ((Int) -> Void)?
        var scriptRunnerHook: ((Int) throws -> Void)?
        var scriptCancellationHook: (() -> Void)?
        var beforeActivityCommitHook: (() -> Void)?
        var committedActivityPairs: [(
            previous: GitTodayActivitySnapshot?,
            current: GitTodayActivitySnapshot
        )] = []
        var timeScopePublisherHook: ((String) -> URL?)?
        var timeScopePublishCount = 0
        var widgetReloaderHook: (() throws -> Void)?
        var scriptMetrics: GitRefreshScriptMetrics?
        var validatedSnapshotReadCount = 0
        var validatedSnapshotReadFailures: [Int: TinyBuddySharedSnapshotReason] = [:]
        var statusHistory: [GitActivityRefreshStatus] = []
        var diagnosticEventIdentifiers: [String] = []
        var combinedSnapshotWriteWasOnMainThread: Bool?
        var repositoryChangeMonitor: TestGitRepositoryChangeMonitor?

        init(currentDate: Date) {
            self.currentDate = currentDate
        }
    }
}

private final class TestGitRepositoryChangeMonitor: GitRepositoryChangeMonitoring {
    private let changeHandler: (GitRepositoryChangeImpact) -> Void
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(changeHandler: @escaping (GitRepositoryChangeImpact) -> Void) {
        self.changeHandler = changeHandler
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else {
            return true
        }
        isRunning = true
        startCount += 1
        return true
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        stopCount += 1
    }

    func emitChange(requiresRepositoryDiscoveryRescan: Bool = false) {
        guard isRunning else {
            return
        }
        changeHandler(GitRepositoryChangeImpact(
            requiresRepositoryDiscoveryRescan: requiresRepositoryDiscoveryRescan,
            affectedRootPaths: requiresRepositoryDiscoveryRescan ? ["/Authorized/TinyBuddyProject"] : []
        ))
    }
}
