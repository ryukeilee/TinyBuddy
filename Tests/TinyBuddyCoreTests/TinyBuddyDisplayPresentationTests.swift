import XCTest
@testable import TinyBuddyCore

final class TinyBuddyDisplayPresentationTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 0)
    private let shanghaiTimeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!

    func testDisplayStatePrioritiesAreUniqueAndOrderedByCrossSurfaceContract() {
        let expectedPriorities: [TinyBuddyDisplayState: Int] = [
            .authorizationInvalid: 110,
            .authorizationRequired: 100,
            .readFailed: 90,
            .stale: 80,
            .loading: 70,
            .noRepositories: 60,
            .partial: 50,
            .noActivity: 40,
            .completedToday: 30,
            .focusing: 20,
            .idle: 10
        ]

        XCTAssertEqual(Set(expectedPriorities.values).count, TinyBuddyDisplayState.allCases.count)
        XCTAssertEqual(Set(expectedPriorities.keys), Set(TinyBuddyDisplayState.allCases))
        for state in TinyBuddyDisplayState.allCases {
            XCTAssertEqual(state.priority, expectedPriorities[state])
        }
    }

    func testStateMatrixClassifiesEveryDisplayState() {
        let cases: [(String, TinyBuddyDisplayPresentation, TinyBuddyDisplayState)] = [
            (
                "loading",
                presentation(dataAvailability: .loading),
                .loading
            ),
            (
                "authorization required",
                presentation(dataAvailability: .failed(.appGroupUnavailable), onboardingCompleted: false),
                .authorizationRequired
            ),
            (
                "authorization invalid",
                presentation(refreshStatus: status(outcome: .failed, diagnosticReason: .authorizationInvalid)),
                .authorizationInvalid
            ),
            (
                "read failed",
                presentation(dataAvailability: .failed(.sandboxReadDenied)),
                .readFailed
            ),
            (
                "stale",
                presentation(dataAvailability: .stale),
                .stale
            ),
            (
                "no repositories",
                presentation(refreshStatus: status(outcome: .succeeded, authorizedRootCount: 1, repositoryCount: 0)),
                .noRepositories
            ),
            (
                "partial",
                presentation(
                    activity: activity(focus: 2, completion: 3),
                    refreshStatus: status(outcome: .partial, repositoryCount: 1)
                ),
                .partial
            ),
            (
                "no activity",
                presentation(
                    activity: activity(focus: 0, completion: 0),
                    refreshStatus: status(outcome: .succeeded, repositoryCount: 1)
                ),
                .noActivity
            ),
            (
                "idle",
                presentation(snapshotStatus: .idle),
                .idle
            ),
            (
                "focusing",
                presentation(activity: activity(focus: 1, completion: 0)),
                .focusing
            ),
            (
                "completed today",
                presentation(activity: activity(focus: 1, completion: 1)),
                .completedToday
            )
        ]

        for (name, value, expectedState) in cases {
            XCTAssertEqual(value.state, expectedState, name)
        }
    }

    func testCompleteVisualStateMatrixSnapshot() {
        let values = [
            presentation(dataAvailability: .loading),
            presentation(dataAvailability: .failed(.appGroupUnavailable), onboardingCompleted: false),
            presentation(refreshStatus: status(outcome: .failed, diagnosticReason: .authorizationInvalid)),
            presentation(dataAvailability: .failed(.sandboxReadDenied)),
            presentation(dataAvailability: .stale),
            presentation(refreshStatus: status(outcome: .succeeded, authorizedRootCount: 1, repositoryCount: 0)),
            presentation(
                activity: activity(focus: 1, completion: 1),
                refreshStatus: status(outcome: .partial, repositoryCount: 1)
            ),
            presentation(activity: activity(focus: 0, completion: 0)),
            presentation(snapshotStatus: .idle),
            presentation(activity: activity(focus: 1, completion: 0)),
            presentation(activity: activity(focus: 1, completion: 1))
        ]
        let snapshot = values.map { value in
            [
                value.state.rawValue,
                value.title,
                value.message,
                value.systemImage,
                value.accentRole.rawValue,
                value.action?.rawValue ?? "-",
                value.expression,
                value.showsActivityMetrics ? "metrics" : "no-metrics"
            ].joined(separator: "|")
        }.joined(separator: "\n")

        XCTAssertEqual(
            snapshot,
            """
            loading|数据加载中|正在读取已授权仓库，完成后会自动同步所有入口。|arrow.triangle.2.circlepath|loading|-|…|no-metrics
            authorizationRequired|从选择仓库目录开始|TinyBuddy 只读取你授权目录中的 Git 元数据。|folder.badge.plus|warning|chooseDirectories|•?•|no-metrics
            authorizationInvalid|仓库目录授权已失效|目录可能已移动、移除或被撤销；重新授权后即可恢复。|lock.trianglebadge.exclamationmark|warning|reauthorize|•?•|no-metrics
            readFailed|数据读取失败|当前继续保留上次可信结果；可重试读取。|exclamationmark.triangle|error|rescan|×_×|no-metrics
            stale|数据已过期|当前快照不属于今天，刷新完成前不会当作今日数据展示。|clock.badge.exclamationmark|warning|rescan|•_•|no-metrics
            noRepositories|未发现 Git 仓库|已授权目录中没有可识别的 Git 仓库。|folder.badge.minus|warning|addDirectory|•ᴗ•|no-metrics
            partial|数据部分可用|可用仓库已更新，异常仓库已安全跳过。|exclamationmark.circle|warning|rescan|•~•|metrics
            noActivity|今日无活动|仓库读取正常，今天还没有提交、合并或专注记录。|moon.zzz|neutral|rescan|•ᴗ•|metrics
            idle|待机|TinyBuddy 已准备好，随时可以进入今天的节奏。|circle.dotted|neutral|-|•ᴗ•|no-metrics
            focusing|专注中|保持当前专注，今天的投入会持续累积。|scope|focus|-|–_–|metrics
            completedToday|今日完成|今天已经有完成记录，可以继续推进下一项。|checkmark.circle.fill|success|-|★ᴗ★|metrics
            """
        )
    }

    func testConflictingInputsFollowPriorityOrder() {
        XCTAssertEqual(
            presentation(
                refreshStatus: status(outcome: .failed, diagnosticReason: .authorizationInvalid),
                dataAvailability: .failed(.appGroupUnavailable),
                isRefreshing: true,
                onboardingCompleted: false
            ).state,
            .authorizationInvalid
        )
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 3, completion: 4),
                refreshStatus: status(outcome: .partial, authorizedRootCount: 1, repositoryCount: 0),
                dataAvailability: .failed(.appGroupUnavailable),
                isRefreshing: true
            ).state,
            .readFailed
        )
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 3, completion: 4),
                refreshStatus: status(outcome: .failed),
                dataAvailability: .stale,
                isRefreshing: true
            ).state,
            .readFailed
        )
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 3, completion: 4),
                refreshStatus: status(outcome: .failed),
                dataAvailability: .loading,
                isRefreshing: true
            ).state,
            .readFailed
        )
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 3, completion: 4),
                refreshStatus: status(outcome: .partial, authorizedRootCount: 1, repositoryCount: 0),
                dataAvailability: .stale,
                isRefreshing: true
            ).state,
            .stale
        )
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 3, completion: 4),
                refreshStatus: status(outcome: .partial, authorizedRootCount: 1, repositoryCount: 0),
                dataAvailability: .loading,
                isRefreshing: true
            ).state,
            .loading
        )
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 3, completion: 4),
                refreshStatus: status(outcome: .partial, authorizedRootCount: 1, repositoryCount: 0)
            ).state,
            .noRepositories
        )
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 3, completion: 4),
                refreshStatus: status(outcome: .partial, repositoryCount: 1)
            ).state,
            .partial
        )
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 0, completion: 0),
                snapshotStatus: .completedOnce,
                refreshStatus: status(outcome: .succeeded, repositoryCount: 1)
            ).state,
            .noActivity
        )
        XCTAssertEqual(
            presentation(activity: activity(focus: 3, completion: 4), snapshotStatus: .focusing).state,
            .completedToday
        )
        XCTAssertEqual(
            presentation(activity: activity(focus: 3, completion: 0), snapshotStatus: .completedOnce).state,
            .focusing
        )
    }

    func testRefreshingWithUsableDataPreservesContentAndEqualInputsAreEquatable() {
        let inputStatus = status(outcome: .succeeded, repositoryCount: 1)
        let first = presentation(
            activity: activity(focus: 2, completion: 0, project: "TinyBuddy"),
            refreshStatus: inputStatus,
            isRefreshing: true
        )
        let second = presentation(
            activity: activity(focus: 2, completion: 0, project: "TinyBuddy"),
            refreshStatus: inputStatus,
            isRefreshing: true
        )

        XCTAssertEqual(first.state, .focusing)
        XCTAssertTrue(first.isRefreshing)
        XCTAssertNotEqual(first.state, .loading)
        XCTAssertEqual(first, second)
    }

    func testRepeatedRefreshTimestampPreservesSnapshotDateAndTransitionIdentity() {
        let activity = activity(focus: 2, completion: 3, project: "TinyBuddy")
        let first = presentation(
            activity: activity,
            refreshStatus: status(outcome: .succeeded, repositoryCount: 1, refreshedAt: fixedDate)
        )
        let second = presentation(
            activity: activity,
            refreshStatus: status(
                outcome: .succeeded,
                repositoryCount: 1,
                refreshedAt: fixedDate.addingTimeInterval(60)
            )
        )

        XCTAssertEqual(first.dataDateText, "数据日期 07-18")
        XCTAssertEqual(first.dataDateText, second.dataDateText)
        XCTAssertEqual(first.transitionIdentity, second.transitionIdentity)
        XCTAssertEqual(first.state, second.state)
        XCTAssertEqual(first.focusCountText, second.focusCountText)
        XCTAssertEqual(first.completionCountText, second.completionCountText)
    }

    func testSemanticContentChangesUpdateTransitionIdentityWithinTheSameState() {
        let activity = activity(focus: 2, completion: 3, project: "TinyBuddy")
        let partialRecovery = presentation(
            activity: activity,
            refreshStatus: status(
                outcome: .partial,
                diagnosticReason: .partialRecovery,
                repositoryCount: 1
            )
        )
        let partialAuthorization = presentation(
            activity: activity,
            refreshStatus: status(
                outcome: .partial,
                diagnosticReason: .partialAuthorizationRecovery,
                repositoryCount: 1
            )
        )

        XCTAssertEqual(partialRecovery.state, .partial)
        XCTAssertEqual(partialAuthorization.state, .partial)
        XCTAssertNotEqual(partialRecovery.title, partialAuthorization.title)
        XCTAssertNotEqual(
            partialRecovery.transitionIdentity,
            partialAuthorization.transitionIdentity
        )

        let firstLaunch = presentation(onboardingCompleted: false)
        let missingAuthorization = presentation(
            refreshStatus: status(
                outcome: .skipped,
                diagnosticReason: .authorizationRequired
            )
        )
        XCTAssertEqual(firstLaunch.state, .authorizationRequired)
        XCTAssertEqual(missingAuthorization.state, .authorizationRequired)
        XCTAssertNotEqual(firstLaunch.transitionIdentity, missingAuthorization.transitionIdentity)
    }

    func testSharedSnapshotObservationMapsToOneDataAvailabilityContract() {
        let stale = TinyBuddySharedSnapshotObservation(
            phase: .snapshotRead,
            reason: .staleData,
            recovery: .stopped,
            attemptCount: 1
        )
        let recovered = TinyBuddySharedSnapshotObservation(
            phase: .snapshotRead,
            reason: .snapshotCorrupt,
            recovery: .rebuilt,
            attemptCount: 2
        )
        let denied = TinyBuddySharedSnapshotObservation(
            phase: .snapshotRead,
            reason: .sandboxReadDenied,
            recovery: .stopped,
            attemptCount: 1
        )

        XCTAssertEqual(
            TinyBuddyDisplayDataAvailability(observation: nil, hasSnapshot: true),
            .available
        )
        XCTAssertEqual(
            TinyBuddyDisplayDataAvailability(observation: nil, hasSnapshot: false),
            .loading
        )
        XCTAssertEqual(
            TinyBuddyDisplayDataAvailability(observation: stale, hasSnapshot: true),
            .stale
        )
        XCTAssertEqual(
            TinyBuddyDisplayDataAvailability(observation: recovered, hasSnapshot: true),
            .available
        )
        XCTAssertEqual(
            TinyBuddyDisplayDataAvailability(observation: denied, hasSnapshot: false),
            .failed(.sandboxReadDenied)
        )
    }

    func testFailureStaleAndAuthorizationPresentationContentAndActions() {
        let cases: [(TinyBuddyDisplayPresentation, TinyBuddyDisplayState, String, String, TinyBuddyDisplayAccentRole, TinyBuddyDisplayAction?, String?)] = [
            (
                presentation(onboardingCompleted: false),
                .authorizationRequired,
                "从选择仓库目录开始",
                "folder.badge.plus",
                .warning,
                .chooseDirectories,
                "选择仓库目录"
            ),
            (
                presentation(refreshStatus: status(outcome: .failed, diagnosticReason: .authorizationInvalid)),
                .authorizationInvalid,
                "仓库目录授权已失效",
                "lock.trianglebadge.exclamationmark",
                .warning,
                .reauthorize,
                "重新授权"
            ),
            (
                presentation(dataAvailability: .failed(.sandboxReadDenied)),
                .readFailed,
                "数据读取失败",
                "exclamationmark.triangle",
                .error,
                .rescan,
                "重试读取"
            ),
            (
                presentation(dataAvailability: .stale),
                .stale,
                "数据已过期",
                "clock.badge.exclamationmark",
                .warning,
                .rescan,
                "刷新数据"
            )
        ]

        for (value, state, title, image, accent, action, actionTitle) in cases {
            XCTAssertEqual(value.state, state)
            XCTAssertEqual(value.title, title)
            XCTAssertEqual(value.statusTitle, title)
            XCTAssertEqual(value.systemImage, image)
            XCTAssertEqual(value.accentRole, accent)
            XCTAssertEqual(value.action, action)
            XCTAssertEqual(value.actionTitle, actionTitle)
        }
    }

    func testActivityAndPartialPresentationContentUsesExpectedRolesAndActions() {
        let partialAuthorization = presentation(
            activity: activity(focus: 1, completion: 1),
            refreshStatus: status(outcome: .partial, diagnosticReason: .partialAuthorizationRecovery)
        )
        XCTAssertEqual(partialAuthorization.title, "部分仓库目录授权已失效")
        XCTAssertEqual(partialAuthorization.systemImage, "lock.trianglebadge.exclamationmark")
        XCTAssertEqual(partialAuthorization.accentRole, .warning)
        XCTAssertEqual(partialAuthorization.action, .reauthorize)
        XCTAssertEqual(partialAuthorization.actionTitle, "重新授权")

        let completed = presentation(activity: activity(focus: 1, completion: 1))
        XCTAssertEqual(completed.title, "今日完成")
        XCTAssertEqual(completed.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(completed.accentRole, .success)
        XCTAssertNil(completed.action)
        XCTAssertNil(completed.actionTitle)
    }

    func testMetricProjectAndDataDateFormattingIsDeterministic() {
        let longProject = "abcdefghijklmnopqrstuvwxy"
        let value = presentation(
            activity: activity(focus: 12_345, completion: 6_789, project: longProject),
            refreshStatus: status(outcome: .succeeded, repositoryCount: 1),
            locale: Locale(identifier: "zh_CN"),
            timeZone: shanghaiTimeZone
        )

        XCTAssertEqual(value.focusCountText, "12,345")
        XCTAssertEqual(value.completionCountText, "6,789")
        XCTAssertEqual(value.recentProjectName, "abcdefghijkl…opqrstuvwxy")
        XCTAssertEqual(value.statusDisplayTitle, "今日完成 · abcdefghijkl…opqrstuvwxy")
        XCTAssertEqual(value.dataDateText, "数据日期 07-18")
    }

    func testLayoutStrategyCoversAllSizesTextScalesAndSystemPreferences() {
        let value = presentation(
            activity: activity(focus: 1, completion: 1, project: "TinyBuddy"),
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )

        for size in TinyBuddyDisplayLayoutSize.allCases {
            for textScale in TinyBuddyDisplayTextScale.allCases {
                for increasedContrast in [false, true] {
                    for reduceMotion in [false, true] {
                        for lowPower in [false, true] {
                            let environment = TinyBuddyDisplayEnvironment(
                                size: size,
                                textScale: textScale,
                                increasedContrast: increasedContrast,
                                reduceMotion: reduceMotion,
                                lowPower: lowPower
                            )
                            let layout = TinyBuddyDisplayLayout(
                                presentation: value,
                                environment: environment
                            )
                            let isAccessibility = textScale == .accessibility

                            let isHUD = size == .standard
                            XCTAssertEqual(layout.showsBrandLabel, isHUD || !isAccessibility)
                            XCTAssertEqual(layout.showsExpression, !isAccessibility)
                            XCTAssertEqual(layout.showsMetrics, isHUD)
                            XCTAssertEqual(layout.showsProject, isHUD && !isAccessibility)
                            XCTAssertTrue(layout.showsMessage)
                            XCTAssertEqual(layout.showsDataDate, isHUD && !isAccessibility)
                            XCTAssertEqual(
                                layout.stacksMetricsVertically,
                                isAccessibility && isHUD
                            )
                            XCTAssertEqual(layout.usesEnhancedContrast, increasedContrast)
                            XCTAssertEqual(layout.allowsMotion, !reduceMotion && !lowPower)
                            XCTAssertEqual(layout.titleLineLimit, 2)
                            XCTAssertEqual(layout.messageLineLimit, expectedMessageLineLimit(size: size, accessibility: isAccessibility))
                        }
                    }
                }
            }
        }
    }

    func testWidgetLayoutPrioritizesStatusWithoutOverflowAtAccessibilitySizes() {
        let activityValue = presentation(
            activity: activity(focus: 2, completion: 3, project: "TinyBuddy")
        )
        let partialValue = presentation(
            activity: activity(focus: 2, completion: 3, project: "TinyBuddy"),
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )
        let staleValue = presentation(
            activity: activity(focus: 2, completion: 3, project: "Future"),
            dataAvailability: .stale
        )

        XCTAssertFalse(staleValue.showsActivityMetrics)

        for size in [TinyBuddyDisplayLayoutSize.compact, .expanded] {
            let activityStandard = TinyBuddyDisplayLayout(
                presentation: activityValue,
                environment: TinyBuddyDisplayEnvironment(size: size)
            )
            XCTAssertTrue(activityStandard.showsMetrics)
            XCTAssertFalse(activityStandard.showsMessage)
            XCTAssertEqual(activityStandard.showsProject, size == .expanded)
            XCTAssertEqual(activityStandard.showsDataDate, size == .expanded)
            XCTAssertEqual(activityStandard.titleLineLimit, size == .compact ? 2 : 1)

            let partialStandard = TinyBuddyDisplayLayout(
                presentation: partialValue,
                environment: TinyBuddyDisplayEnvironment(size: size)
            )
            XCTAssertFalse(partialStandard.showsMetrics)
            XCTAssertTrue(partialStandard.showsMessage)
            XCTAssertFalse(partialStandard.showsProject)
            XCTAssertFalse(partialStandard.showsDataDate)
            XCTAssertEqual(partialStandard.titleLineLimit, 2)

            let staleStandard = TinyBuddyDisplayLayout(
                presentation: staleValue,
                environment: TinyBuddyDisplayEnvironment(size: size)
            )
            XCTAssertFalse(staleStandard.showsMetrics)
            XCTAssertTrue(staleStandard.showsMessage)
            XCTAssertFalse(staleStandard.showsProject)
            XCTAssertFalse(staleStandard.showsDataDate)

            for value in [activityValue, partialValue, staleValue] {
                let accessibility = TinyBuddyDisplayLayout(
                    presentation: value,
                    environment: TinyBuddyDisplayEnvironment(
                        size: size,
                        textScale: .accessibility
                    )
                )
                XCTAssertFalse(accessibility.showsBrandLabel)
                XCTAssertFalse(accessibility.showsExpression)
                XCTAssertFalse(accessibility.showsMetrics)
                XCTAssertFalse(accessibility.showsProject)
                XCTAssertFalse(accessibility.showsDataDate)
                XCTAssertEqual(accessibility.titleLineLimit, 2)
                XCTAssertEqual(accessibility.messageLineLimit, 1)
            }
        }
    }

    private func presentation(
        activity: GitTodayActivitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: nil,
            commitCount: nil
        ),
        snapshotStatus: PetStatus = .idle,
        refreshStatus: GitActivityRefreshStatus? = nil,
        dataAvailability: TinyBuddyDisplayDataAvailability = .available,
        isRefreshing: Bool = false,
        onboardingCompleted: Bool = true,
        locale: Locale = Locale(identifier: "zh_CN"),
        timeZone: TimeZone? = nil
    ) -> TinyBuddyDisplayPresentation {
        TinyBuddyDisplayPresentation(
            snapshot: TinyBuddySnapshot(
                status: snapshotStatus,
                stats: DailyStats(dayIdentifier: "2026-07-18", focusCount: 0, completionCount: 0)
            ),
            activitySnapshot: activity,
            refreshStatus: refreshStatus,
            dataAvailability: dataAvailability,
            isRefreshing: isRefreshing,
            onboardingCompleted: onboardingCompleted,
            locale: locale,
            timeZone: timeZone ?? shanghaiTimeZone
        )
    }

    private func activity(focus: Int?, completion: Int?, project: String? = nil) -> GitTodayActivitySnapshot {
        GitTodayActivitySnapshot(
            focusBlockCount: focus,
            commitCount: completion,
            recentProjectName: project
        )
    }

    private func status(
        outcome: GitActivityRefreshOutcome,
        diagnosticReason: GitActivityRefreshDiagnosticReason? = nil,
        authorizedRootCount: Int? = nil,
        repositoryCount: Int? = nil,
        refreshedAt: Date? = nil
    ) -> GitActivityRefreshStatus {
        GitActivityRefreshStatus(
            refreshedAt: refreshedAt ?? fixedDate,
            trigger: .launch,
            outcome: outcome,
            diagnostic: diagnosticReason.map {
                GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: diagnosticStage(for: $0),
                    reason: $0
                )
            },
            metrics: GitActivityRefreshMetrics(
                authorizedRootCount: authorizedRootCount,
                repositoryCount: repositoryCount
            )
        )
    }

    private func diagnosticStage(
        for reason: GitActivityRefreshDiagnosticReason
    ) -> GitActivityRefreshDiagnosticStage {
        switch reason {
        case .authorizationRequired, .authorizationInvalid, .partialAuthorizationRecovery:
            return .authorizationResolution
        case .refreshedActivityUnavailable:
            return .activitySnapshotLoad
        case .combinedSnapshotCommitFailed:
            return .combinedSnapshotCommit
        case .scriptMissing:
            return .scriptLookup
        case .scriptExecutionFailed, .partialRecovery:
            return .scriptExecution
        }
    }

    private func expectedMessageLineLimit(
        size: TinyBuddyDisplayLayoutSize,
        accessibility: Bool
    ) -> Int {
        switch size {
        case .compact:
            return accessibility ? 1 : 2
        case .standard:
            return accessibility ? 5 : 3
        case .expanded:
            return accessibility ? 1 : 3
        }
    }
}
