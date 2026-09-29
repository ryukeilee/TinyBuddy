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

    func testLiveFocusOverridesZeroGitActivityWithoutChangingSharedHudAndWidgetCopy() {
        let publication = focusHistoryPublication(
            active: true,
            paused: false,
            dayState: .sessions,
            focusDuration: 0,
            completedSessionCount: 0
        )
        let presentation = makePresentation(focusHistoryPublication: publication)

        XCTAssertEqual(presentation.state, .focusing)
        XCTAssertEqual(presentation.displayState, .focusing)
        XCTAssertEqual(presentation.title, "专注中")
        XCTAssertEqual(presentation.message, "保持当前专注，今天的投入会持续累积。")
        XCTAssertTrue(presentation.showsActivityMetrics)

        for size in [TinyBuddyDisplayLayoutSize.standard, .expanded] {
            XCTAssertTrue(
                TinyBuddyDisplayLayout(
                    presentation: presentation,
                    environment: TinyBuddyDisplayEnvironment(size: size)
                ).showsMetrics
            )
        }
    }

    func testPausedAndNoSessionPathsRemainDistinctWithZeroGitActivity() {
        let paused = makePresentation(
            focusHistoryPublication: focusHistoryPublication(
                active: false,
                paused: true,
                dayState: .sessions,
                focusDuration: 0,
                completedSessionCount: 0
            )
        )
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.title, "已暂停")

        let noSession = makePresentation(
            focusHistoryPublication: focusHistoryPublication(
                active: false,
                paused: false,
                dayState: .noSessions,
                focusDuration: 0,
                completedSessionCount: 0
            ),
            snapshotStatus: .idle
        )
        XCTAssertEqual(noSession.state, .noActivity)
        XCTAssertEqual(noSession.title, "今日无活动")
    }

    func testLiveFocusDoesNotOverrideDataQualityStates() {
        let activePublication = focusHistoryPublication(
            active: true,
            paused: false,
            dayState: .sessions,
            focusDuration: 0,
            completedSessionCount: 0
        )
        let cases: [(TinyBuddyDisplayPresentation, TinyBuddyDisplayState)] = [
            (makePresentation(focusHistoryPublication: activePublication, dataAvailability: .stale), .stale),
            (makePresentation(focusHistoryPublication: activePublication, dataAvailability: .failed(.sandboxReadDenied)), .readFailed),
            (
                makePresentation(
                    focusHistoryPublication: activePublication,
                    refreshStatus: status(outcome: .skipped, diagnosticReason: .authorizationRequired)
                ),
                .authorizationRequired
            ),
            (
                makePresentation(
                    focusHistoryPublication: activePublication,
                    refreshStatus: status(outcome: .failed, diagnosticReason: .authorizationInvalid)
                ),
                .authorizationInvalid
            ),
            (
                makePresentation(
                    focusHistoryPublication: activePublication,
                    refreshStatus: status(outcome: .failed, diagnosticReason: .scriptExecutionFailed)
                ),
                .readFailed
            )
        ]

        for (presentation, expectedState) in cases {
            XCTAssertEqual(presentation.state, expectedState)
            XCTAssertFalse(presentation.state.isActivityState)
        }
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

    private func makePresentation(
        focusHistoryPublication: FocusHistoryPublication? = nil,
        snapshotStatus: PetStatus = .focusing,
        refreshStatus: GitActivityRefreshStatus? = nil,
        dataAvailability: TinyBuddyDisplayDataAvailability = .available
    ) -> TinyBuddyDisplayPresentation {
        TinyBuddyDisplayPresentation(
            snapshot: TinyBuddySnapshot(
                status: snapshotStatus,
                stats: DailyStats(dayIdentifier: "2026-07-24", focusCount: 0, completionCount: 0)
            ),
            activitySnapshot: emptyActivity,
            focusHistoryPublication: focusHistoryPublication,
            refreshStatus: refreshStatus ?? status(
                outcome: .succeeded,
                authorizedRootCount: 1,
                repositoryCount: 1
            ),
            dataAvailability: dataAvailability
        )
    }

    private func focusHistoryPublication(
        active: Bool,
        paused: Bool,
        dayState: FocusHistoryDayState,
        focusDuration: TimeInterval,
        completedSessionCount: Int
    ) -> FocusHistoryPublication {
        let dayIdentifier = "2026-07-24"
        let day = FocusHistoryDay(
            dayIdentifier: dayIdentifier,
            state: dayState,
            focusDuration: focusDuration,
            completedSessionCount: completedSessionCount,
            goalMinutes: nil,
            goalCompletionRate: nil,
            isGoalMet: nil
        )
        let history = FocusHistorySnapshot(
            state: .available,
            sourceHealth: .available,
            recentDays: [day],
            currentWeek: FocusHistoryWeek(
                startDayIdentifier: dayIdentifier,
                endDayIdentifier: dayIdentifier,
                state: .available,
                focusDuration: focusDuration,
                completedSessionCount: completedSessionCount,
                goalCompletionRate: nil,
                goalMetDayCount: nil,
                configuredGoalDayCount: nil,
                projectDistribution: nil
            ),
            currentGoalStreakDays: nil
        )
        return FocusHistoryPublication(
            revision: 1,
            snapshot: history,
            isFocusSessionActive: active,
            isFocusSessionPaused: paused
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
