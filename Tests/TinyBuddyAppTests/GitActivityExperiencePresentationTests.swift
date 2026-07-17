import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class GitActivityExperiencePresentationTests: XCTestCase {
    private let emptyActivity = GitTodayActivitySnapshot(
        focusBlockCount: 0,
        commitCount: 0,
        recentProjectName: nil
    )

    func testFirstLaunchHasOneDirectorySelectionActionInsteadOfZeroMetrics() {
        let presentation = GitActivityExperiencePresentation.make(
            refreshStatus: nil,
            activitySnapshot: emptyActivity,
            isRefreshing: false,
            onboardingCompleted: false
        )

        XCTAssertEqual(presentation.title, "从选择仓库目录开始")
        XCTAssertEqual(presentation.action, .chooseDirectories)
        XCTAssertEqual(presentation.actionTitle, "选择仓库目录")
        XCTAssertFalse(presentation.state.showsActivityMetrics)
    }

    func testDeniedAndExpiredAuthorizationHaveDirectSingleRecoveryActions() {
        let denied = GitActivityExperiencePresentation.make(
            refreshStatus: status(outcome: .skipped, diagnosticReason: .authorizationRequired),
            activitySnapshot: emptyActivity,
            isRefreshing: false,
            onboardingCompleted: true
        )
        let expired = GitActivityExperiencePresentation.make(
            refreshStatus: status(outcome: .failed, diagnosticReason: .authorizationInvalid),
            activitySnapshot: emptyActivity,
            isRefreshing: false,
            onboardingCompleted: true
        )

        XCTAssertEqual(denied.action, .chooseDirectories)
        XCTAssertEqual(denied.actionTitle, "选择仓库目录")
        XCTAssertEqual(expired.action, .reauthorize)
        XCTAssertEqual(expired.actionTitle, "重新授权")
    }

    func testPartialAuthorizationFailureKeepsMetricsAndOffersDirectReauthorization() {
        let presentation = GitActivityExperiencePresentation.make(
            refreshStatus: status(
                outcome: .partial,
                diagnosticReason: .partialAuthorizationRecovery,
                authorizedRootCount: 1,
                repositoryCount: 2
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 1,
                commitCount: 2,
                recentProjectName: "TinyBuddy"
            ),
            isRefreshing: false,
            onboardingCompleted: true
        )

        XCTAssertEqual(presentation.state, .partial)
        XCTAssertTrue(presentation.state.showsActivityMetrics)
        XCTAssertEqual(presentation.title, "部分仓库目录授权已失效")
        XCTAssertEqual(presentation.action, .reauthorize)
        XCTAssertEqual(presentation.actionTitle, "重新授权")
    }

    func testEmptyDirectoryNoActivityFailureAndLoadingUseAccurateCopyAndOneNextStep() {
        let cases: [(GitActivityExperiencePresentation, String, GitActivityExperienceAction?)] = [
            (
                .make(
                    refreshStatus: status(outcome: .skipped, authorizedRootCount: 1, repositoryCount: 0),
                    activitySnapshot: emptyActivity,
                    isRefreshing: false,
                    onboardingCompleted: true
                ),
                "未发现 Git 仓库",
                .addDirectory
            ),
            (
                .make(
                    refreshStatus: status(outcome: .succeeded, authorizedRootCount: 1, repositoryCount: 1),
                    activitySnapshot: emptyActivity,
                    isRefreshing: false,
                    onboardingCompleted: true
                ),
                "今日无活动",
                .rescan
            ),
            (
                .make(
                    refreshStatus: status(outcome: .failed, diagnosticReason: .scriptExecutionFailed),
                    activitySnapshot: emptyActivity,
                    isRefreshing: false,
                    onboardingCompleted: true
                ),
                "数据读取失败",
                .rescan
            ),
            (
                .make(
                    refreshStatus: nil,
                    activitySnapshot: emptyActivity,
                    isRefreshing: true,
                    onboardingCompleted: true
                ),
                "数据加载中",
                nil
            )
        ]

        for (presentation, title, action) in cases {
            XCTAssertEqual(presentation.title, title)
            XCTAssertEqual(presentation.action, action)
            XCTAssertEqual(presentation.action == nil, presentation.actionTitle == nil)
            XCTAssertFalse(presentation.state.showsActivityMetrics)
        }
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
