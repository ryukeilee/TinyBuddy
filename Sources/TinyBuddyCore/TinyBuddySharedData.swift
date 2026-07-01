import Foundation

public enum TinyBuddySharedData {
    public static let appGroupIdentifier = "group.com.ryukeili.TinyBuddy"

    public static func makeUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}

public struct TinyBuddySnapshot: Equatable, Sendable {
    public let status: PetStatus
    public let stats: DailyStats

    public init(status: PetStatus, stats: DailyStats) {
        self.status = status
        self.stats = stats
    }
}

