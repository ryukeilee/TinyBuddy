import Foundation

public struct TinyBuddyWidgetPresentation: Equatable, Sendable {
    public enum StatusTitleSource: Equatable, Sendable {
        case snapshot
        case gitTodayActivity
    }

    public enum DisplayState: Equatable, Sendable {
        case idle
        case focusing
        case completed
        case active
    }

    public let expression: String
    public let statusTitle: String
    public let statusDisplayTitle: String
    public let focusCount: Int
    public let completionCount: Int
    public let displayState: DisplayState

    public init(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot
    ) {
        self.init(
            snapshot: snapshot,
            focusCountOverride: activitySnapshot.focusBlockCount ?? 0,
            completionCountOverride: activitySnapshot.commitCount ?? 0,
            recentProjectName: activitySnapshot.recentProjectName,
            statusTitleSource: .gitTodayActivity
        )
    }

    public init(
        snapshot: TinyBuddySnapshot,
        focusCountOverride: Int? = nil,
        completionCountOverride: Int? = nil,
        recentProjectName: String? = nil,
        statusTitleSource: StatusTitleSource = .snapshot
    ) {
        let focusCount = focusCountOverride ?? snapshot.stats.focusCount
        let completionCount = completionCountOverride ?? snapshot.stats.completionCount
        let displayState = Self.displayState(
            from: snapshot,
            focusCount: focusCount,
            completionCount: completionCount,
            source: statusTitleSource
        )
        let statusTitle = Self.statusTitle(
            from: snapshot,
            focusCount: focusCount,
            completionCount: completionCount,
            source: statusTitleSource
        )

        self.expression = Self.expression(for: displayState)
        self.statusTitle = statusTitle
        self.statusDisplayTitle = Self.statusDisplayTitle(
            statusTitle: statusTitle,
            recentProjectName: recentProjectName
        )
        self.focusCount = focusCount
        self.completionCount = completionCount
        self.displayState = displayState
    }

    private static func expression(for displayState: DisplayState) -> String {
        switch displayState {
        case .idle:
            return "•ᴗ•"
        case .focusing:
            return "–_–"
        case .completed, .active:
            return "★ᴗ★"
        }
    }

    private static func displayState(
        from snapshot: TinyBuddySnapshot,
        focusCount: Int,
        completionCount: Int,
        source: StatusTitleSource
    ) -> DisplayState {
        switch source {
        case .snapshot:
            switch snapshot.status {
            case .idle:
                return .idle
            case .focusing:
                return .focusing
            case .completedOnce:
                return .completed
            }
        case .gitTodayActivity:
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
    }

    private static func statusTitle(
        from snapshot: TinyBuddySnapshot,
        focusCount: Int,
        completionCount: Int,
        source: StatusTitleSource
    ) -> String {
        switch source {
        case .snapshot:
            return snapshot.status.title
        case .gitTodayActivity:
            switch (focusCount > 0, completionCount > 0) {
            case (false, false):
                return "待机"
            case (true, false):
                return "专注中"
            case (false, true):
                return "已完成"
            case (true, true):
                return "活跃"
            }
        }
    }

    private static func statusDisplayTitle(
        statusTitle: String,
        recentProjectName: String?
    ) -> String {
        guard let recentProjectName = recentProjectName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !recentProjectName.isEmpty
        else {
            return statusTitle
        }

        return "\(statusTitle) · \(recentProjectName)"
    }
}
