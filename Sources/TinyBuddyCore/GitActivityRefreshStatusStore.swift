import Foundation

public enum GitActivityRefreshOutcome: String, Equatable, Sendable {
    case succeeded
    case skipped
    case failed
}

public struct GitActivityRefreshStatus: Equatable, Sendable {
    public let refreshedAt: Date
    public let trigger: GitTodayActivityRefreshTrigger
    public let outcome: GitActivityRefreshOutcome
    public let reason: String?

    public init(
        refreshedAt: Date,
        trigger: GitTodayActivityRefreshTrigger,
        outcome: GitActivityRefreshOutcome,
        reason: String? = nil
    ) {
        self.refreshedAt = refreshedAt
        self.trigger = trigger
        self.outcome = outcome
        self.reason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
}

public final class GitActivityRefreshStatusStore {
    public enum Key {
        public static let refreshedAt = "tinybuddy.gitRefreshStatus.refreshedAt"
        public static let trigger = "tinybuddy.gitRefreshStatus.trigger"
        public static let outcome = "tinybuddy.gitRefreshStatus.outcome"
        public static let reason = "tinybuddy.gitRefreshStatus.reason"
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()) {
        self.userDefaults = userDefaults
    }

    public func load() -> GitActivityRefreshStatus? {
        userDefaults.synchronize()

        guard
            let refreshedAt = userDefaults.object(forKey: Key.refreshedAt) as? Date,
            let triggerRawValue = userDefaults.string(forKey: Key.trigger),
            let trigger = GitTodayActivityRefreshTrigger(rawValue: triggerRawValue),
            let outcomeRawValue = userDefaults.string(forKey: Key.outcome),
            let outcome = GitActivityRefreshOutcome(rawValue: outcomeRawValue)
        else {
            return nil
        }

        let reason = userDefaults.string(forKey: Key.reason)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        return GitActivityRefreshStatus(
            refreshedAt: refreshedAt,
            trigger: trigger,
            outcome: outcome,
            reason: reason
        )
    }

    public func save(_ status: GitActivityRefreshStatus) {
        userDefaults.set(status.refreshedAt, forKey: Key.refreshedAt)
        userDefaults.set(status.trigger.rawValue, forKey: Key.trigger)
        userDefaults.set(status.outcome.rawValue, forKey: Key.outcome)

        if let reason = status.reason {
            userDefaults.set(reason, forKey: Key.reason)
        } else {
            userDefaults.removeObject(forKey: Key.reason)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
