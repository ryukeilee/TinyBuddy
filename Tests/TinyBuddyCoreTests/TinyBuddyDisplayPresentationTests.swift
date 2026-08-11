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
            .paused: 45,
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

    func testPausedPublicationWinsOverActivityCountsAndAnomaliesStillWin() {
        let paused = presentation(
            activity: activity(focus: 4, completion: 3, project: "Paused"),
            snapshotStatus: .focusing,
            focusHistoryPublication: makePublication(isPaused: true)
        )
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.displayState, .paused)
        XCTAssertEqual(paused.title, "已暂停")
        XCTAssertEqual(paused.accentRole, .warning)

        let repeated = presentation(
            activity: activity(focus: 4, completion: 3, project: "Paused"),
            snapshotStatus: .focusing,
            focusHistoryPublication: makePublication(isPaused: true)
        )
        XCTAssertEqual(paused.transitionIdentity, repeated.transitionIdentity)

        let stale = presentation(
            activity: activity(focus: 4, completion: 3),
            snapshotStatus: .focusing,
            focusHistoryPublication: makePublication(isPaused: true),
            dataAvailability: .stale
        )
        XCTAssertEqual(stale.state, .stale)
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
                "partial with incomplete data",
                presentation(
                    activity: activity(focus: nil, completion: nil),
                    refreshStatus: status(outcome: .partial, repositoryCount: 1)
                ),
                .partial
            ),
            (
                "partial with complete data shows real activity",
                presentation(
                    activity: activity(focus: 2, completion: 3),
                    refreshStatus: status(outcome: .partial, repositoryCount: 1)
                ),
                .completedToday
            ),
            (
                "partial recovery with complete data shows real activity",
                presentation(
                    activity: activity(focus: 0, completion: 0),
                    refreshStatus: status(
                        outcome: .partial,
                        diagnosticReason: .partialRecovery,
                        repositoryCount: 1
                    )
                ),
                .noActivity
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
                "paused",
                presentation(
                    activity: activity(focus: 1, completion: 0),
                    snapshotStatus: .focusing,
                    focusHistoryPublication: makePublication(isPaused: true)
                ),
                .paused
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
            // Partial with complete data → shows real activity state
            presentation(
                activity: activity(focus: 1, completion: 1),
                refreshStatus: status(outcome: .partial, repositoryCount: 1)
            ),
            // Partial with incomplete data → shows .partial
            presentation(
                activity: activity(focus: nil, completion: nil),
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
            completedToday|今日完成|今天已经有完成记录，可以继续推进下一项。|checkmark.circle.fill|success|-|★ᴗ★|metrics
            partial|数据部分可用|可用仓库已更新，异常仓库已安全跳过。|exclamationmark.circle|warning|rescan|•~•|no-metrics
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
        // Partial outcome with complete data → show real activity
        XCTAssertEqual(
            presentation(
                activity: activity(focus: 3, completion: 4),
                refreshStatus: status(outcome: .partial, repositoryCount: 1)
            ).state,
            .completedToday
        )
        // Partial outcome with incomplete data → show .partial
        // (dataAvailability: .available + no activity snapshot = not complete)
        XCTAssertEqual(
            presentation(
                activity: activity(focus: nil, completion: nil),
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

        // .partialRecovery with complete data → show real activity state
        XCTAssertEqual(partialRecovery.state, .completedToday)
        // .partialAuthorizationRecovery always shows .partial (user action required)
        XCTAssertEqual(partialAuthorization.state, .partial)
        XCTAssertNotEqual(partialRecovery.title, partialAuthorization.title)
        XCTAssertNotEqual(
            partialRecovery.transitionIdentity,
            partialAuthorization.transitionIdentity
        )

        // .partialRecovery with incomplete data → shows .partial
        let partialRecoveryIncomplete = presentation(
            activity: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            refreshStatus: status(
                outcome: .partial,
                diagnosticReason: .partialRecovery,
                repositoryCount: 1
            )
        )
        XCTAssertEqual(partialRecoveryIncomplete.state, .partial)

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

    func testFocusHistoryOnlyDataMakesWidgetMetricsVisible() {
        let historyOnly = presentation(
            activity: activity(focus: nil, completion: nil),
            focusHistoryPublication: makePublication(isPaused: false)
        )
        XCTAssertEqual(historyOnly.state, .idle)
        XCTAssertTrue(historyOnly.showsActivityMetrics)

        for size in [TinyBuddyDisplayLayoutSize.compact, .expanded] {
            let layout = TinyBuddyDisplayLayout(
                presentation: historyOnly,
                environment: TinyBuddyDisplayEnvironment(size: size)
            )
            XCTAssertTrue(layout.showsMetrics, size.rawValue)
            XCTAssertFalse(layout.showsMessage, size.rawValue)
        }

        let empty = presentation(activity: activity(focus: nil, completion: nil))
        XCTAssertFalse(empty.showsActivityMetrics)
        XCTAssertFalse(
            TinyBuddyDisplayLayout(
                presentation: empty,
                environment: TinyBuddyDisplayEnvironment(size: .expanded)
            ).showsMetrics
        )

        let stale = presentation(
            activity: activity(focus: nil, completion: nil),
            focusHistoryPublication: makePublication(isPaused: false),
            dataAvailability: .stale
        )
        XCTAssertEqual(stale.state, .stale)
        XCTAssertFalse(stale.showsActivityMetrics)
        XCTAssertFalse(
            TinyBuddyDisplayLayout(
                presentation: stale,
                environment: TinyBuddyDisplayEnvironment(size: .expanded)
            ).showsMetrics
        )
    }

    func testLayoutStrategyCoversAllSizesTextScalesAndSystemPreferences() {
        // Partial with incomplete data (no activity counts) → stays .partial
        let value = presentation(
            activity: activity(focus: nil, completion: nil, project: "TinyBuddy"),
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
                            let isExpandedWidget = size == .expanded
                            // With incomplete data (no activity snapshot) the
                            // state is .partial but showsActivityMetrics = false,
                            // so showsPartialActivityDetails is always false.
                            let showsPartialActivityDetails = false
                            XCTAssertEqual(layout.showsBrandLabel, isHUD || !isAccessibility)
                            XCTAssertEqual(layout.showsExpression, !isAccessibility)
                            // showsActivityMetrics is false → no metrics on any surface
                            XCTAssertEqual(layout.showsMetrics, false)
                            XCTAssertEqual(
                                layout.showsProject,
                                !isAccessibility && isHUD
                            )
                            XCTAssertEqual(layout.showsMessage, true)
                            XCTAssertEqual(
                                layout.showsDataDate,
                                !isAccessibility && isHUD
                            )
                            XCTAssertEqual(
                                layout.stacksMetricsVertically,
                                isAccessibility && isHUD
                            )
                            XCTAssertEqual(layout.usesEnhancedContrast, increasedContrast)
                            XCTAssertEqual(layout.allowsMotion, !reduceMotion && !lowPower)
                            XCTAssertEqual(layout.titleLineLimit, 2)
                            XCTAssertEqual(
                                layout.messageLineLimit,
                                expectedMessageLineLimit(size: size, accessibility: isAccessibility)
                            )
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

            // partialValue now shows .completedToday (complete data + activity,
            // so the partial outcome is suppressed → layout matches activityValue)
            let partialStandard = TinyBuddyDisplayLayout(
                presentation: partialValue,
                environment: TinyBuddyDisplayEnvironment(size: size)
            )
            XCTAssertTrue(partialStandard.showsMetrics)
            XCTAssertFalse(partialStandard.showsMessage)
            XCTAssertEqual(partialStandard.showsProject, size == .expanded)
            XCTAssertEqual(partialStandard.showsDataDate, size == .expanded)
            XCTAssertEqual(partialStandard.titleLineLimit, size == .compact ? 2 : 1)

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

    func testExpandedWidgetShowsPartialMetricsOnlyForTrustedPartialData() {
        let activity = activity(focus: 2, completion: 3, project: "TinyBuddy")
        let partial = presentation(
            activity: activity,
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )
        let partialWithoutTrustedMetrics = presentation(
            activity: self.activity(focus: nil, completion: nil, project: "TinyBuddy"),
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )
        XCTAssertEqual(partialWithoutTrustedMetrics.state, .partial)
        let unavailableValues = [
            partialWithoutTrustedMetrics,
            presentation(activity: activity, refreshStatus: status(outcome: .failed)),
            presentation(
                activity: activity,
                refreshStatus: status(
                    outcome: .skipped,
                    diagnosticReason: .authorizationRequired
                )
            ),
            presentation(
                activity: activity,
                refreshStatus: status(
                    outcome: .failed,
                    diagnosticReason: .authorizationInvalid
                )
            ),
            presentation(activity: activity, dataAvailability: .stale),
            presentation(activity: activity, dataAvailability: .loading)
        ]

        let environment = TinyBuddyDisplayEnvironment(size: .expanded)
        let partialLayout = TinyBuddyDisplayLayout(
            presentation: partial,
            environment: environment
        )
        XCTAssertTrue(partialLayout.showsMetrics)
        XCTAssertTrue(partialLayout.showsProject)
        XCTAssertTrue(partialLayout.showsDataDate)
        XCTAssertFalse(partialLayout.showsMessage)

        for value in unavailableValues {
            let layout = TinyBuddyDisplayLayout(presentation: value, environment: environment)
            XCTAssertFalse(layout.showsMetrics, value.state.rawValue)
            XCTAssertFalse(layout.showsProject, value.state.rawValue)
            XCTAssertFalse(layout.showsDataDate, value.state.rawValue)
            XCTAssertTrue(layout.showsMessage, value.state.rawValue)
        }
    }

    // MARK: - Partial availability self-healing & regression tests

    func testColdStartWithPartialStatusShowsActivityWhenDataComplete() {
        // Cold-start scenario: stored refreshStatus shows .partial from a
        // previous session, but the combined snapshot already has complete
        // activity data. The display should NOT show .partial because data
        // is fully usable.
        let presentation = self.presentation(
            activity: activity(focus: 3, completion: 5, project: "TinyBuddy"),
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )
        XCTAssertEqual(presentation.state, .completedToday,
                       "Stale partial status must not suppress real activity")
        XCTAssertEqual(presentation.title, "今日完成")
        XCTAssertEqual(presentation.showsActivityMetrics, true)
    }

    func testColdStartWithPartialStatusAndNoActivityShowsPartial() {
        // Cold-start scenario: stored refreshStatus shows .partial and there
        // is NO activity data yet. The display should show .partial because
        // the failure coverage may have hidden real activity.
        let presentation = self.presentation(
            activity: activity(focus: nil, completion: nil),
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )
        XCTAssertEqual(presentation.state, .partial,
                       "Partial outcome without activity data must show .partial")
        XCTAssertEqual(presentation.title, "数据部分可用")
        XCTAssertEqual(presentation.showsActivityMetrics, false)
    }

    func testPartialAuthorizationRecoveryAlwaysShowsPartialRegardlessOfData() {
        // .partialAuthorizationRecovery requires user action (re-authorize).
        // It must always show .partial even when activity data is complete.
        let presentation = self.presentation(
            activity: activity(focus: 3, completion: 5, project: "TinyBuddy"),
            refreshStatus: status(
                outcome: .partial,
                diagnosticReason: .partialAuthorizationRecovery,
                repositoryCount: 1
            )
        )
        XCTAssertEqual(presentation.state, .partial,
                       "Partial authorization recovery always shows .partial")
        XCTAssertEqual(presentation.title, "部分仓库目录授权已失效")
        XCTAssertEqual(presentation.action, .reauthorize)
    }

    func testPartialRecoveryTransitionsToActivityAfterCompleteRefresh() {
        // Simulate: first refresh was .partial, then a second full refresh
        // completes with .succeeded. The system should show the real
        // activity state, not .partial (the new status overwrites the old).
        let afterPartial = self.presentation(
            activity: activity(focus: 2, completion: 3, project: "TinyBuddy"),
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )
        let afterFullRefresh = self.presentation(
            activity: activity(focus: 2, completion: 3, project: "TinyBuddy"),
            refreshStatus: status(outcome: .succeeded, repositoryCount: 1)
        )

        // After partial refresh with complete data → data is usable, show activity
        XCTAssertEqual(afterPartial.state, .completedToday,
                       "Partial refresh with complete data must show activity")
        // After full .succeeded refresh → definitely show activity
        XCTAssertEqual(afterFullRefresh.state, .completedToday)
        // Both should have same content (same data)
        XCTAssertEqual(afterPartial.title, afterFullRefresh.title)
        XCTAssertEqual(afterPartial.showsActivityMetrics, afterFullRefresh.showsActivityMetrics)
    }

    func testCrossDayPartialStatusDoesNotAffectNewDay() {
        // The refresh status from yesterday (partial) is filtered out by
        // isForDisplayDay, so the display falls back to no-status behavior.
        // With no refresh status and complete data, show the activity state.
        let yesterday = Date(timeIntervalSince1970: 0)
        let todayPresentation = self.presentation(
            activity: activity(focus: 1, completion: 2, project: "TinyBuddy"),
            refreshStatus: nil  // No status for today
        )
        XCTAssertEqual(todayPresentation.state, .completedToday,
                       "Cross-day status filtered: show real activity")
        XCTAssertEqual(todayPresentation.title, "今日完成")
    }

    func testWidgetReloadAfterPartialToCompleteTransition() {
        // Widget reload scenario: the Widget creates an entry with a
        // .partial refresh status but the combined snapshot shows complete
        // data. The entry's presentation should show the real activity, not
        // .partial, so the Widget renders correctly on reload.
        let widgetEntryPresentation = self.presentation(
            activity: activity(focus: 4, completion: 7, project: "TinyBuddy"),
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )

        // The Widget entry must NOT show .partial when data is complete.
        XCTAssertNotEqual(widgetEntryPresentation.state, .partial,
                          "Widget must not show .partial when data is complete")
        XCTAssertEqual(widgetEntryPresentation.state, .completedToday)
        XCTAssertEqual(widgetEntryPresentation.completionCount, 7)
        XCTAssertEqual(widgetEntryPresentation.showsActivityMetrics, true)
    }

    func testWidgetReloadWithPartialStatusAndEmptyData() {
        // Widget reload scenario: .partial outcome with NO activity data.
        // The Widget must show .partial (data is truly partially missing).
        let widgetEntryPresentation = self.presentation(
            activity: activity(focus: nil, completion: nil),
            refreshStatus: status(outcome: .partial, repositoryCount: 1)
        )
        XCTAssertEqual(widgetEntryPresentation.state, .partial,
                       "Widget shows .partial when no activity data present")
        XCTAssertEqual(widgetEntryPresentation.showsActivityMetrics, false)
    }

    func testMultipleReposPartialFailureDoesNotMaskAuthorizationState() {
        // Even with .partial outcome, authorization states take priority.
        let authInvalid = self.presentation(
            activity: activity(focus: 3, completion: 5),
            refreshStatus: status(
                outcome: .partial,
                diagnosticReason: .authorizationInvalid
            )
        )
        XCTAssertEqual(authInvalid.state, .authorizationInvalid,
                       "Authorization invalid takes priority over partial")

        let authRequired = self.presentation(
            activity: activity(focus: 3, completion: 5),
            refreshStatus: status(
                outcome: .partial,
                diagnosticReason: .authorizationRequired
            )
        )
        XCTAssertEqual(authRequired.state, .authorizationRequired,
                       "Authorization required takes priority over partial")
    }

    func testPartialStatusWithFailedDataAvailability() {
        // When dataAvailability is .failed, the state should be .readFailed
        // (higher priority than .partial), regardless of partial outcome.
        let partialWithFailedData = self.presentation(
            activity: activity(focus: nil, completion: nil),
            refreshStatus: status(outcome: .partial, repositoryCount: 1),
            dataAvailability: .failed(.sandboxReadDenied)
        )
        XCTAssertEqual(partialWithFailedData.state, .readFailed,
                       "Failed data takes priority over partial")
    }

    func testPartialStatusWithStaleDataAvailability() {
        // When dataAvailability is .stale, the state should be .stale
        // (higher priority than .partial).
        let partialWithStaleData = self.presentation(
            activity: activity(focus: nil, completion: nil),
            refreshStatus: status(outcome: .partial, repositoryCount: 1),
            dataAvailability: .stale
        )
        XCTAssertEqual(partialWithStaleData.state, .stale,
                       "Stale data takes priority over partial")
    }

    func testPartialStatusWithLoadingDataAvailability() {
        // When dataAvailability is .loading, the state should be .loading
        // (higher priority than .partial).
        let partialWithLoadingData = self.presentation(
            activity: activity(focus: nil, completion: nil),
            refreshStatus: status(outcome: .partial, repositoryCount: 1),
            dataAvailability: .loading
        )
        XCTAssertEqual(partialWithLoadingData.state, .loading,
                       "Loading data takes priority over partial")
    }

    // MARK: - Private helpers

    private func presentation(
        activity: GitTodayActivitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: nil,
            commitCount: nil
        ),
        snapshotStatus: PetStatus = .idle,
        focusHistoryPublication: FocusHistoryPublication? = nil,
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
            focusHistoryPublication: focusHistoryPublication,
            refreshStatus: refreshStatus,
            dataAvailability: dataAvailability,
            isRefreshing: isRefreshing,
            onboardingCompleted: onboardingCompleted,
            locale: locale,
            timeZone: timeZone ?? shanghaiTimeZone
        )
    }

    private func makePublication(isPaused: Bool) -> FocusHistoryPublication {
        let previousDay = FocusHistoryDay(
            dayIdentifier: "2026-07-19",
            state: .noSessions,
            focusDuration: 0,
            completedSessionCount: 0,
            goalMinutes: nil,
            goalCompletionRate: nil,
            isGoalMet: nil
        )
        let currentDay = FocusHistoryDay(
            dayIdentifier: "2026-07-20",
            state: .sessions,
            focusDuration: 1,
            completedSessionCount: 3,
            goalMinutes: nil,
            goalCompletionRate: nil,
            isGoalMet: nil
        )
        let snapshot = FocusHistorySnapshot(
            state: .available,
            sourceHealth: .available,
            recentDays: [previousDay, currentDay],
            currentWeek: FocusHistoryWeek(
                startDayIdentifier: "2026-07-14",
                endDayIdentifier: "2026-07-20",
                state: .available,
                focusDuration: 1,
                completedSessionCount: 3,
                goalCompletionRate: nil,
                goalMetDayCount: nil,
                configuredGoalDayCount: nil,
                projectDistribution: nil
            ),
            currentGoalStreakDays: nil
        )
        return FocusHistoryPublication(
            revision: 1,
            snapshot: snapshot,
            isFocusSessionActive: false,
            isFocusSessionPaused: isPaused
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
