import Foundation

public struct TinyBuddyWidgetPresentation: Equatable, Sendable {
    public let expression: String
    public let statusTitle: String
    public let focusCount: Int
    public let completionCount: Int

    public init(snapshot: TinyBuddySnapshot) {
        self.expression = Self.expression(for: snapshot.status)
        self.statusTitle = snapshot.status.title
        self.focusCount = snapshot.stats.focusCount
        self.completionCount = snapshot.stats.completionCount
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
}

