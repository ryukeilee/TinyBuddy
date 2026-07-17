import XCTest
@testable import TinyBuddyCore

final class GitActivityExperienceStateTests: XCTestCase {
    private let emptyActivity = GitTodayActivitySnapshot(
        focusBlockCount: 0,
        commitCount: 0,
        recentProjectName: nil
    )

    func testMissingStatusAndActiveRefreshAreLoading() {
        XCTAssertEqual(
            GitActivityExperienceState(refreshStatus: nil, activitySnapshot: emptyActivity),
            .loading
        )
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(outcome: .succeeded, repositoryCount: 1),
                activitySnapshot: emptyActivity,
                isRefreshing: true
            ),
            .loading
        )
    }

    func testAuthorizationStatesStayDistinctFromGeneralFailure() {
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(outcome: .skipped, diagnosticReason: .authorizationRequired),
                activitySnapshot: emptyActivity
            ),
            .authorizationRequired
        )
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(outcome: .failed, diagnosticReason: .authorizationInvalid),
                activitySnapshot: emptyActivity
            ),
            .authorizationInvalid
        )
    }

    func testEmptyDirectoryAndNoActivityStayDistinct() {
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(outcome: .skipped, authorizedRootCount: 1, repositoryCount: 0),
                activitySnapshot: emptyActivity
            ),
            .noRepositories
        )
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(outcome: .succeeded, authorizedRootCount: 1, repositoryCount: 2),
                activitySnapshot: emptyActivity
            ),
            .noActivity
        )
    }

    func testFailurePartialAndReadyStatesAreClassifiedWithoutDiscardingValidActivity() {
        let active = GitTodayActivitySnapshot(
            focusBlockCount: 2,
            commitCount: 3,
            recentProjectName: "TinyBuddy"
        )
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(outcome: .failed, diagnosticReason: .scriptExecutionFailed),
                activitySnapshot: active
            ),
            .failed
        )
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(outcome: .partial, diagnosticReason: .partialRecovery),
                activitySnapshot: active
            ),
            .partial
        )
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(
                    outcome: .partial,
                    diagnosticReason: .partialAuthorizationRecovery
                ),
                activitySnapshot: active
            ),
            .partial
        )
        XCTAssertEqual(
            GitActivityExperienceState(
                refreshStatus: status(outcome: .succeeded, repositoryCount: 1),
                activitySnapshot: active
            ),
            .ready
        )
    }

    private func status(
        outcome: GitActivityRefreshOutcome,
        diagnosticReason: GitActivityRefreshDiagnosticReason? = nil,
        authorizedRootCount: Int? = nil,
        repositoryCount: Int? = nil
    ) -> GitActivityRefreshStatus {
        GitActivityRefreshStatus(
            refreshedAt: Date(),
            trigger: .launch,
            outcome: outcome,
            diagnostic: diagnosticReason.map {
                GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: $0 == .authorizationRequired
                        || $0 == .authorizationInvalid
                        || $0 == .partialAuthorizationRecovery
                        ? .authorizationResolution
                        : .scriptExecution,
                    reason: $0
                )
            },
            metrics: GitActivityRefreshMetrics(
                authorizedRootCount: authorizedRootCount,
                repositoryCount: repositoryCount
            )
        )
    }
}
