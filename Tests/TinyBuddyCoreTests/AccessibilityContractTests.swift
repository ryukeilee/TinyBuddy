import XCTest
@testable import TinyBuddyCore

// MARK: - Accessibility Contract Tests

/// Verifies that every display state, status, and interactive element
/// provides VoiceOver-friendly labels that are descriptive and non-empty.
///
/// These tests document the accessibility contract: changing a title,
/// message, image, or label requires updating corresponding
/// accessibility strings. A failure here means VoiceOver users
/// would encounter missing or misleading descriptions.
final class AccessibilityContractTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 0)
    private let shanghaiTimeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    private let chineseLocale = Locale(identifier: "zh_CN")

    // MARK: - Display State Accessibility

    func testEveryDisplayStateHasDescriptiveTitleAndMessage() {
        let cases: [(String, TinyBuddyDisplayPresentation, String, String)] = [
            (
                "loading",
                presentation(dataAvailability: .loading),
                "数据加载中", "正在读取"
            ),
            (
                "authorizationRequired",
                presentation(dataAvailability: .failed(.appGroupUnavailable), onboardingCompleted: false),
                "从选择仓库目录开始", "TinyBuddy 只读取你授权"
            ),
            (
                "authorizationInvalid",
                presentation(refreshStatus: status(outcome: .failed, diagnosticReason: .authorizationInvalid)),
                "仓库目录授权已失效", "目录可能已移动"
            ),
            (
                "readFailed",
                presentation(dataAvailability: .failed(.sandboxReadDenied)),
                "数据读取失败", "当前继续保留"
            ),
            (
                "stale",
                presentation(dataAvailability: .stale),
                "数据已过期", "当前快照不属于今天"
            ),
            (
                "noRepositories",
                presentation(refreshStatus: status(outcome: .succeeded, authorizedRootCount: 1, repositoryCount: 0)),
                "未发现 Git 仓库", "已授权目录中"
            ),
            (
                "partial",
                presentation(
                    activity: activity(focus: 2, completion: 3),
                    refreshStatus: status(outcome: .partial, repositoryCount: 1)
                ),
                "数据部分可用", "可用仓库已更新"
            ),
            (
                "noActivity",
                presentation(
                    activity: activity(focus: 0, completion: 0),
                    refreshStatus: status(outcome: .succeeded, repositoryCount: 1)
                ),
                "今日无活动", "仓库读取正常"
            ),
            (
                "idle",
                presentation(snapshotStatus: .idle),
                "待机", "TinyBuddy 已准备好"
            ),
            (
                "focusing",
                presentation(activity: activity(focus: 1, completion: 0)),
                "专注中", "保持当前专注"
            ),
            (
                "completedToday",
                presentation(activity: activity(focus: 1, completion: 1)),
                "今日完成", "今天已经有完成记录"
            ),
        ]

        for (name, value, expectedTitlePrefix, expectedMessagePrefix) in cases {
            // VoiceOver reads `title` and `message` as the primary descriptor.
            // Both must be non-empty and substantive.
            XCTAssertFalse(
                value.title.isEmpty,
                "\(name): title must not be empty"
            )
            XCTAssertFalse(
                value.message.isEmpty,
                "\(name): message must not be empty"
            )

            // The title should be descriptive enough for a VoiceOver user to
            // understand the current state without additional context.
            XCTAssertTrue(
                value.title.hasPrefix(expectedTitlePrefix),
                "\(name): expected title to start with '\(expectedTitlePrefix)' but got '\(value.title)'"
            )
            XCTAssertTrue(
                value.message.hasPrefix(expectedMessagePrefix),
                "\(name): expected message to start with '\(expectedMessagePrefix)' but got '\(value.message)'"
            )

            // The statusTitle must match the presentation's core title.
            XCTAssertEqual(
                value.statusTitle, value.title,
                "\(name): statusTitle must match title"
            )

            // Every state must have a non-empty systemImage for VoiceOver to
            // describe.
            XCTAssertFalse(
                value.systemImage.isEmpty,
                "\(name): systemImage must not be empty"
            )
        }
    }

    // MARK: - Expression Accessibility

    func testEveryStateHasNonEmptyExpression() {
        let values: [TinyBuddyDisplayPresentation] = [
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
            presentation(
                activity: activity(focus: 0, completion: 0),
                refreshStatus: status(outcome: .succeeded, repositoryCount: 1)
            ),
            presentation(snapshotStatus: .idle),
            presentation(activity: activity(focus: 1, completion: 0)),
            presentation(activity: activity(focus: 1, completion: 1)),
        ]

        for value in values {
            XCTAssertFalse(
                value.expression.isEmpty,
                "\(value.state.rawValue): expression must not be empty"
            )
        }
    }

    // MARK: - Accent Role Non-Color Semantics

    func testAccentRoleIsMeaningfulForEveryDisplayState() {
        let values: [TinyBuddyDisplayPresentation] = [
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
            presentation(
                activity: activity(focus: 0, completion: 0),
                refreshStatus: status(outcome: .succeeded, repositoryCount: 1)
            ),
            presentation(snapshotStatus: .idle),
            presentation(activity: activity(focus: 1, completion: 0)),
            presentation(activity: activity(focus: 1, completion: 1)),
        ]

        let validRoles: [TinyBuddyDisplayAccentRole] = [
            .neutral, .focus, .success, .warning, .error, .loading
        ]

        for value in values {
            XCTAssertTrue(
                validRoles.contains(value.accentRole),
                "\(value.state.rawValue): accentRole \(value.accentRole) must be valid"
            )

            // The accent role must be meaningful — at minimum it changes between
            // major state categories (loading, authorization, activity).
            switch value.state {
            case .loading:
                XCTAssertEqual(value.accentRole, .loading)
            case .authorizationRequired, .authorizationInvalid, .stale, .noRepositories, .partial:
                XCTAssertEqual(value.accentRole, .warning)
            case .readFailed:
                XCTAssertEqual(value.accentRole, .error)
            case .noActivity, .idle:
                XCTAssertEqual(value.accentRole, .neutral)
            case .focusing:
                XCTAssertEqual(value.accentRole, .focus)
            case .completedToday:
                XCTAssertEqual(value.accentRole, .success)
            }
        }
    }

    // MARK: - PetStatus Accessibility

    func testPetStatusAccessibilityLabels() {
        let testCases: [(PetStatus, expectedTitle: String, expectedShortMood: String)] = [
            (.idle, "待机", "准备好了"),
            (.focusing, "专注中", "保持专注"),
            (.completedOnce, "完成一次", "做得不错"),
        ]

        for (status, expectedTitle, expectedShortMood) in testCases {
            XCTAssertEqual(
                status.title, expectedTitle,
                "\(status.rawValue): title should match"
            )
            XCTAssertEqual(
                status.shortMood, expectedShortMood,
                "\(status.rawValue): shortMood should match"
            )
        }
    }

    // MARK: - Layout Accessibility Degradation

    func testAccessibilityTextScaleDegradesLayoutAsExpected() {
        let activityWithData = activity(focus: 2, completion: 5, project: "TinyBuddy")
        let value = presentation(
            activity: activityWithData,
            refreshStatus: status(outcome: .succeeded, authorizedRootCount: 1, repositoryCount: 2)
        )

        // Accessibility text scale layout for compact widget
        let accessibilityLayout = TinyBuddyDisplayLayout(
            presentation: value,
            environment: TinyBuddyDisplayEnvironment(
                size: .compact,
                textScale: .accessibility,
                increasedContrast: false,
                reduceMotion: false,
                lowPower: false
            )
        )

        // Accessibility text scale should hide decorative elements
        XCTAssertFalse(
            accessibilityLayout.showsExpression,
            "Expression should be hidden in accessibility text scale"
        )
        XCTAssertFalse(
            accessibilityLayout.showsBrandLabel,
            "Brand label should be hidden in accessibility text scale"
        )
        XCTAssertFalse(
            accessibilityLayout.showsProject,
            "Project name should be hidden in accessibility text scale"
        )
        XCTAssertFalse(
            accessibilityLayout.showsDataDate,
            "Data date should be hidden in accessibility text scale"
        )

        // Standard text scale layout (control)
        let standardLayout = TinyBuddyDisplayLayout(
            presentation: value,
            environment: TinyBuddyDisplayEnvironment(
                size: .compact,
                textScale: .standard,
                increasedContrast: false,
                reduceMotion: false,
                lowPower: false
            )
        )

        // Standard compact should show expression and brand label
        XCTAssertTrue(standardLayout.showsExpression)
        XCTAssertTrue(standardLayout.showsBrandLabel)
    }

    func testReduceMotionDisablesAnimations() {
        let value = presentation()
        let reduceMotionLayout = TinyBuddyDisplayLayout(
            presentation: value,
            environment: TinyBuddyDisplayEnvironment(
                size: .standard,
                textScale: .standard,
                increasedContrast: false,
                reduceMotion: true,
                lowPower: false
            )
        )

        XCTAssertFalse(reduceMotionLayout.allowsMotion)

        let normalLayout = TinyBuddyDisplayLayout(
            presentation: value,
            environment: TinyBuddyDisplayEnvironment(
                size: .standard,
                textScale: .standard,
                increasedContrast: false,
                reduceMotion: false,
                lowPower: false
            )
        )

        XCTAssertTrue(normalLayout.allowsMotion)
    }

    func testIncreasedContrastPropagatesToLayout() {
        let value = presentation()
        let highContrastLayout = TinyBuddyDisplayLayout(
            presentation: value,
            environment: TinyBuddyDisplayEnvironment(
                size: .standard,
                textScale: .standard,
                increasedContrast: true,
                reduceMotion: false,
                lowPower: false
            )
        )

        XCTAssertTrue(highContrastLayout.usesEnhancedContrast)
    }

    // MARK: - Helpers

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
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 0, completionCount: 0)
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

    private func activity(
        focus: Int?,
        completion: Int?,
        project: String? = nil
    ) -> GitTodayActivitySnapshot {
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
}
