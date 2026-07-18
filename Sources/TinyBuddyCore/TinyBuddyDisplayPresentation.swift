import Foundation

public enum TinyBuddyDisplaySharedState {
    public static let onboardingStateKey = "tinybuddy.onboarding.state.v1"

    public static func onboardingCompleted(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> Bool? {
        userDefaults.synchronize()
        switch userDefaults.string(forKey: onboardingStateKey) {
        case "completed":
            return true
        case "pending":
            return false
        default:
            return nil
        }
    }

    public static func saveOnboardingCompleted(
        _ isCompleted: Bool,
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) {
        userDefaults.set(
            isCompleted ? "completed" : "pending",
            forKey: onboardingStateKey
        )
        userDefaults.synchronize()
    }
}

public enum TinyBuddyDisplayState: String, CaseIterable, Equatable, Sendable {
    case loading
    case authorizationRequired
    case authorizationInvalid
    case readFailed
    case stale
    case noRepositories
    case partial
    case noActivity
    case idle
    case focusing
    case completedToday

    /// Higher-priority states must win when more than one condition is true.
    /// This ordering is part of the cross-surface display contract.
    public var priority: Int {
        switch self {
        case .authorizationInvalid:
            return 110
        case .authorizationRequired:
            return 100
        case .readFailed:
            return 90
        case .stale:
            return 80
        case .loading:
            return 70
        case .noRepositories:
            return 60
        case .partial:
            return 50
        case .noActivity:
            return 40
        case .completedToday:
            return 30
        case .focusing:
            return 20
        case .idle:
            return 10
        }
    }

    public var isActivityState: Bool {
        switch self {
        case .idle, .focusing, .completedToday, .noActivity, .partial:
            return true
        case .loading, .authorizationRequired, .authorizationInvalid,
                .readFailed, .stale, .noRepositories:
            return false
        }
    }
}

public enum TinyBuddyDisplayDataAvailability: Equatable, Sendable {
    case available
    case loading
    case stale
    case failed(TinyBuddySharedSnapshotReason?)

    public init(
        observation: TinyBuddySharedSnapshotObservation?,
        hasSnapshot: Bool
    ) {
        guard let observation else {
            self = hasSnapshot ? .available : .loading
            return
        }
        if observation.recovery == .rereadSucceeded || observation.recovery == .rebuilt {
            self = .available
        } else if observation.reason == .staleData {
            self = .stale
        } else {
            self = .failed(observation.reason)
        }
    }
}

public enum TinyBuddyDisplayAccentRole: String, Equatable, Sendable {
    case neutral
    case focus
    case success
    case warning
    case error
    case loading
}

public enum TinyBuddyDisplayAction: String, Equatable, Sendable {
    case chooseDirectories
    case reauthorize
    case addDirectory
    case rescan
}

public struct TinyBuddyDisplayPresentation: Equatable, Sendable {
    /// Compatibility shape for callers that only need the historical mood.
    public enum DisplayState: Equatable, Sendable {
        case idle
        case focusing
        case completed
        case active
    }

    public enum StatusTitleSource: Equatable, Sendable {
        case snapshot
        case gitTodayActivity
    }

    public static let projectNameCharacterLimit = 24

    public let state: TinyBuddyDisplayState
    public let title: String
    public let message: String
    public let systemImage: String
    public let accentRole: TinyBuddyDisplayAccentRole
    public let action: TinyBuddyDisplayAction?
    public let actionTitle: String?
    public let expression: String
    public let statusTitle: String
    public let statusDisplayTitle: String
    public let focusCount: Int
    public let completionCount: Int
    public let focusCountText: String
    public let completionCountText: String
    public let recentProjectName: String?
    public let dataDateText: String?
    public let showsActivityMetrics: Bool
    public let isRefreshing: Bool
    public let displayState: DisplayState

    /// Drives only semantic cross-fades. Refresh timestamps and repeated
    /// publications deliberately do not change this identity.
    public var transitionIdentity: String {
        [
            state.rawValue,
            displayState.identity,
            title,
            systemImage,
            accentRole.rawValue,
            action?.rawValue ?? "none"
        ].joined(separator: "|")
    }

    public init(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot,
        refreshStatus: GitActivityRefreshStatus? = nil,
        dataAvailability: TinyBuddyDisplayDataAvailability = .available,
        isRefreshing: Bool = false,
        onboardingCompleted: Bool = true,
        locale: Locale = Locale(identifier: "zh_CN"),
        timeZone: TimeZone = .current
    ) {
        let focusCount = max(0, activitySnapshot.focusBlockCount ?? 0)
        let completionCount = max(0, activitySnapshot.commitCount ?? 0)
        let hasActivitySnapshot = activitySnapshot.focusBlockCount != nil
            || activitySnapshot.commitCount != nil
        let state = Self.resolveState(
            snapshot: snapshot,
            focusCount: focusCount,
            completionCount: completionCount,
            hasActivitySnapshot: hasActivitySnapshot,
            refreshStatus: refreshStatus,
            dataAvailability: dataAvailability,
            isRefreshing: isRefreshing,
            onboardingCompleted: onboardingCompleted
        )
        let content = Self.content(
            for: state,
            refreshStatus: refreshStatus,
            onboardingCompleted: onboardingCompleted
        )
        let displayState = Self.displayState(
            snapshot: snapshot,
            focusCount: focusCount,
            completionCount: completionCount,
            hasActivitySnapshot: hasActivitySnapshot
        )
        let recentProjectName = Self.normalizedProjectName(
            activitySnapshot.recentProjectName
        )

        self.state = state
        self.title = content.title
        self.message = content.message
        self.systemImage = content.systemImage
        self.accentRole = content.accentRole
        self.action = content.action
        self.actionTitle = content.actionTitle
        self.expression = Self.expression(for: state, displayState: displayState)
        self.statusTitle = content.title
        self.statusDisplayTitle = Self.statusDisplayTitle(
            statusTitle: content.title,
            recentProjectName: recentProjectName
        )
        self.focusCount = focusCount
        self.completionCount = completionCount
        self.focusCountText = Self.metricText(focusCount, locale: locale)
        self.completionCountText = Self.metricText(completionCount, locale: locale)
        self.recentProjectName = recentProjectName
        self.dataDateText = Self.dataDateText(snapshot.stats.dayIdentifier)
        self.showsActivityMetrics = hasActivitySnapshot
            && state != .stale
            && state != .loading
            && state != .authorizationRequired
            && state != .authorizationInvalid
            && state != .noRepositories
        self.isRefreshing = isRefreshing
        self.displayState = displayState
    }

    /// Compatibility initializer. New App, HUD and Widget code should use the
    /// full initializer above so data quality and refresh state stay unified.
    public init(
        snapshot: TinyBuddySnapshot,
        focusCountOverride: Int? = nil,
        completionCountOverride: Int? = nil,
        recentProjectName: String? = nil,
        statusTitleSource: StatusTitleSource = .snapshot
    ) {
        let activitySnapshot: GitTodayActivitySnapshot
        switch statusTitleSource {
        case .snapshot:
            activitySnapshot = GitTodayActivitySnapshot(
                focusBlockCount: focusCountOverride ?? snapshot.stats.focusCount,
                commitCount: completionCountOverride ?? snapshot.stats.completionCount,
                recentProjectName: recentProjectName
            )
        case .gitTodayActivity:
            activitySnapshot = GitTodayActivitySnapshot(
                focusBlockCount: focusCountOverride ?? 0,
                commitCount: completionCountOverride ?? 0,
                recentProjectName: recentProjectName
            )
        }

        self.init(snapshot: snapshot, activitySnapshot: activitySnapshot)
    }

    private static func resolveState(
        snapshot: TinyBuddySnapshot,
        focusCount: Int,
        completionCount: Int,
        hasActivitySnapshot: Bool,
        refreshStatus: GitActivityRefreshStatus?,
        dataAvailability: TinyBuddyDisplayDataAvailability,
        isRefreshing: Bool,
        onboardingCompleted: Bool
    ) -> TinyBuddyDisplayState {
        switch refreshStatus?.diagnostic?.reason {
        case .authorizationInvalid:
            return .authorizationInvalid
        case .authorizationRequired:
            return .authorizationRequired
        default:
            break
        }

        if onboardingCompleted == false {
            return .authorizationRequired
        }

        switch dataAvailability {
        case .failed:
            return .readFailed
        case .stale, .loading, .available:
            break
        }

        if refreshStatus?.outcome == .failed {
            return .readFailed
        }

        switch dataAvailability {
        case .stale:
            return .stale
        case .loading:
            return .loading
        case .available, .failed:
            break
        }

        // A refresh never replaces already-usable content with a transient
        // loading state. Loading is reserved for the initial unavailable phase.
        if isRefreshing, hasActivitySnapshot == false {
            return .loading
        }

        if refreshStatus?.metrics?.authorizedRootCount ?? 0 > 0,
           refreshStatus?.metrics?.repositoryCount == 0 {
            return .noRepositories
        }

        if refreshStatus?.outcome == .partial
            || refreshStatus?.diagnostic?.reason == .partialAuthorizationRecovery
            || refreshStatus?.diagnostic?.reason == .partialRecovery {
            return .partial
        }

        if hasActivitySnapshot,
           focusCount == 0,
           completionCount == 0 {
            return .noActivity
        }

        if hasActivitySnapshot {
            if completionCount > 0 {
                return .completedToday
            }
            if focusCount > 0 {
                return .focusing
            }
        }

        switch snapshot.status {
        case .idle:
            return .idle
        case .focusing:
            return .focusing
        case .completedOnce:
            return .completedToday
        }
    }

    private static func displayState(
        snapshot: TinyBuddySnapshot,
        focusCount: Int,
        completionCount: Int,
        hasActivitySnapshot: Bool
    ) -> DisplayState {
        guard hasActivitySnapshot else {
            switch snapshot.status {
            case .idle:
                return .idle
            case .focusing:
                return .focusing
            case .completedOnce:
                return .completed
            }
        }

        switch (focusCount > 0, completionCount > 0) {
        case (false, false):
            return .idle
        case (true, false):
            return .focusing
        case (false, true):
            return .completed
        case (true, true):
            return .active
        }
    }

    private static func content(
        for state: TinyBuddyDisplayState,
        refreshStatus: GitActivityRefreshStatus?,
        onboardingCompleted: Bool
    ) -> (
        title: String,
        message: String,
        systemImage: String,
        accentRole: TinyBuddyDisplayAccentRole,
        action: TinyBuddyDisplayAction?,
        actionTitle: String?
    ) {
        switch state {
        case .loading:
            return (
                "数据加载中",
                "正在读取已授权仓库，完成后会自动同步所有入口。",
                "arrow.triangle.2.circlepath",
                .loading,
                nil,
                nil
            )
        case .authorizationRequired:
            return (
                onboardingCompleted ? "需要仓库目录授权" : "从选择仓库目录开始",
                onboardingCompleted
                    ? "选择可读取的开发目录后即可恢复 Git 活动。"
                    : "TinyBuddy 只读取你授权目录中的 Git 元数据。",
                onboardingCompleted ? "folder.badge.questionmark" : "folder.badge.plus",
                .warning,
                .chooseDirectories,
                "选择仓库目录"
            )
        case .authorizationInvalid:
            return (
                "仓库目录授权已失效",
                "目录可能已移动、移除或被撤销；重新授权后即可恢复。",
                "lock.trianglebadge.exclamationmark",
                .warning,
                .reauthorize,
                "重新授权"
            )
        case .readFailed:
            return (
                "数据读取失败",
                "当前继续保留上次可信结果；可重试读取。",
                "exclamationmark.triangle",
                .error,
                .rescan,
                "重试读取"
            )
        case .stale:
            return (
                "数据已过期",
                "当前快照不属于今天，刷新完成前不会当作今日数据展示。",
                "clock.badge.exclamationmark",
                .warning,
                .rescan,
                "刷新数据"
            )
        case .noRepositories:
            return (
                "未发现 Git 仓库",
                "已授权目录中没有可识别的 Git 仓库。",
                "folder.badge.minus",
                .warning,
                .addDirectory,
                "添加 Git 目录"
            )
        case .partial:
            let needsAuthorization = refreshStatus?.diagnostic?.reason
                == .partialAuthorizationRecovery
            return (
                needsAuthorization ? "部分仓库目录授权已失效" : "数据部分可用",
                needsAuthorization
                    ? "可用仓库已更新；重新授权后会补充其余数据。"
                    : "可用仓库已更新，异常仓库已安全跳过。",
                needsAuthorization
                    ? "lock.trianglebadge.exclamationmark"
                    : "exclamationmark.circle",
                .warning,
                needsAuthorization ? .reauthorize : .rescan,
                needsAuthorization ? "重新授权" : "重新扫描"
            )
        case .noActivity:
            return (
                "今日无活动",
                "仓库读取正常，今天还没有提交、合并或专注记录。",
                "moon.zzz",
                .neutral,
                .rescan,
                "重新扫描"
            )
        case .idle:
            return (
                "待机",
                "TinyBuddy 已准备好，随时可以进入今天的节奏。",
                "circle.dotted",
                .neutral,
                nil,
                nil
            )
        case .focusing:
            return (
                "专注中",
                "保持当前专注，今天的投入会持续累积。",
                "scope",
                .focus,
                nil,
                nil
            )
        case .completedToday:
            return (
                "今日完成",
                "今天已经有完成记录，可以继续推进下一项。",
                "checkmark.circle.fill",
                .success,
                nil,
                nil
            )
        }
    }

    private static func expression(
        for state: TinyBuddyDisplayState,
        displayState: DisplayState
    ) -> String {
        switch state {
        case .loading:
            return "…"
        case .authorizationRequired, .authorizationInvalid:
            return "•?•"
        case .readFailed:
            return "×_×"
        case .stale:
            return "•_•"
        case .noRepositories, .noActivity, .idle:
            return "•ᴗ•"
        case .partial:
            return "•~•"
        case .focusing:
            return "–_–"
        case .completedToday:
            return "★ᴗ★"
        }
    }

    private static func normalizedProjectName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }

        let characters = Array(trimmed)
        guard characters.count > projectNameCharacterLimit else {
            return trimmed
        }

        let visibleCount = projectNameCharacterLimit - 1
        let prefixCount = (visibleCount + 1) / 2
        let suffixCount = visibleCount - prefixCount
        return String(characters.prefix(prefixCount))
            + "…"
            + String(characters.suffix(suffixCount))
    }

    private static func statusDisplayTitle(
        statusTitle: String,
        recentProjectName: String?
    ) -> String {
        guard let recentProjectName else {
            return statusTitle
        }
        return "\(statusTitle) · \(recentProjectName)"
    }

    private static func metricText(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func dataDateText(_ dayIdentifier: String) -> String? {
        let normalized = dayIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4,
              fields[1].count == 2,
              fields[2].count == 2,
              let year = Int(fields[0]),
              let month = Int(fields[1]),
              let day = Int(fields[2]) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else {
            return nil
        }
        return "数据日期 \(fields[1])-\(fields[2])"
    }
}

private extension TinyBuddyDisplayPresentation.DisplayState {
    var identity: String {
        switch self {
        case .idle:
            return "idle"
        case .focusing:
            return "focusing"
        case .completed:
            return "completed"
        case .active:
            return "active"
        }
    }
}

public enum TinyBuddyDisplayLayoutSize: String, CaseIterable, Equatable, Sendable {
    case compact
    case standard
    case expanded
}

public enum TinyBuddyDisplayTextScale: String, CaseIterable, Equatable, Sendable {
    case standard
    case accessibility
}

public struct TinyBuddyDisplayEnvironment: Equatable, Sendable {
    public let size: TinyBuddyDisplayLayoutSize
    public let textScale: TinyBuddyDisplayTextScale
    public let increasedContrast: Bool
    public let reduceMotion: Bool
    public let lowPower: Bool

    public init(
        size: TinyBuddyDisplayLayoutSize,
        textScale: TinyBuddyDisplayTextScale = .standard,
        increasedContrast: Bool = false,
        reduceMotion: Bool = false,
        lowPower: Bool = false
    ) {
        self.size = size
        self.textScale = textScale
        self.increasedContrast = increasedContrast
        self.reduceMotion = reduceMotion
        self.lowPower = lowPower
    }
}

public struct TinyBuddyDisplayLayout: Equatable, Sendable {
    public let showsBrandLabel: Bool
    public let showsExpression: Bool
    public let showsMetrics: Bool
    public let showsProject: Bool
    public let showsMessage: Bool
    public let showsDataDate: Bool
    public let stacksMetricsVertically: Bool
    public let usesEnhancedContrast: Bool
    public let allowsMotion: Bool
    public let titleLineLimit: Int
    public let messageLineLimit: Int

    public init(
        presentation: TinyBuddyDisplayPresentation,
        environment: TinyBuddyDisplayEnvironment
    ) {
        let accessibilityText = environment.textScale == .accessibility

        let isHUD = environment.size == .standard
        let isCompactWidget = environment.size == .compact
        let isExpandedWidget = environment.size == .expanded
        let prioritizesActivity = Self.prioritizesActivityContent(
            presentation.state
        )
        let showsPartialActivityDetails = isExpandedWidget
            && accessibilityText == false
            && presentation.state == .partial
            && presentation.showsActivityMetrics

        showsBrandLabel = isHUD || accessibilityText == false
        showsExpression = accessibilityText == false
        showsMetrics = isHUD
            ? presentation.showsActivityMetrics
            : accessibilityText == false
                && (prioritizesActivity || showsPartialActivityDetails)
                && presentation.showsActivityMetrics
        showsProject = accessibilityText == false
            && presentation.recentProjectName != nil
            && (isHUD || (isExpandedWidget && (prioritizesActivity || showsPartialActivityDetails)))
        showsMessage = isHUD || (prioritizesActivity == false && showsPartialActivityDetails == false)
        showsDataDate = accessibilityText == false
            && (isHUD || (isExpandedWidget && (prioritizesActivity || showsPartialActivityDetails)))
        stacksMetricsVertically = isHUD && accessibilityText
        usesEnhancedContrast = environment.increasedContrast
        allowsMotion = environment.reduceMotion == false && environment.lowPower == false
        titleLineLimit = accessibilityText || isCompactWidget
            || (prioritizesActivity == false && showsPartialActivityDetails == false)
            ? 2
            : 1
        switch environment.size {
        case .compact:
            messageLineLimit = accessibilityText ? 1 : 2
        case .standard:
            messageLineLimit = accessibilityText ? 5 : 3
        case .expanded:
            messageLineLimit = accessibilityText || showsPartialActivityDetails ? 1 : 3
        }
    }

    private static func prioritizesActivityContent(
        _ state: TinyBuddyDisplayState
    ) -> Bool {
        switch state {
        case .idle, .focusing, .completedToday, .noActivity:
            return true
        case .loading, .authorizationRequired, .authorizationInvalid,
             .readFailed, .stale, .noRepositories, .partial:
            return false
        }
    }
}
