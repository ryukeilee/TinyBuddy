import Foundation

public struct DailyStats: Equatable, Sendable {
    public let dayIdentifier: String
    public var focusCount: Int
    public var completionCount: Int

    public init(dayIdentifier: String, focusCount: Int, completionCount: Int) {
        self.dayIdentifier = dayIdentifier
        self.focusCount = focusCount
        self.completionCount = completionCount
    }
}
