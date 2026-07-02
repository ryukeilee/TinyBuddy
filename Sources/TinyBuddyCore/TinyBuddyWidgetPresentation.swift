import Foundation

public struct TinyBuddyWidgetPresentation: Equatable, Sendable {
    public enum StatusTitleSource: Equatable, Sendable {
        case snapshot
        case gitTodayActivity
    }

    public let expression: String
    public let statusTitle: String
    public let focusCount: Int
    public let completionCount: Int

    public init(
        snapshot: TinyBuddySnapshot,
        focusCountOverride: Int? = nil,
        completionCountOverride: Int? = nil,
        statusTitleSource: StatusTitleSource = .snapshot
    ) {
        let focusCount = focusCountOverride ?? snapshot.stats.focusCount
        let completionCount = completionCountOverride ?? snapshot.stats.completionCount

        self.expression = Self.expression(for: snapshot.status)
        self.statusTitle = Self.statusTitle(
            from: snapshot,
            focusCount: focusCount,
            completionCount: completionCount,
            source: statusTitleSource
        )
        self.focusCount = focusCount
        self.completionCount = completionCount
    }

    private static func expression(for status: PetStatus) -> String {
        switch status {
        case .idle:
            return "•ᴗ•"
        case .focusing:
            return "–_–"
        case .completedOnce:
            return "★ᴗ★"
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
}
