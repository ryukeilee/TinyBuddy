import Foundation

public enum GitActivityRefreshOutcome: String, Equatable, Sendable {
    case succeeded
    case skipped
    case failed
}

public struct GitActivityRefreshMetrics: Equatable, Sendable {
    public let durationMilliseconds: Int?
    public let authorizedRootCount: Int?
    public let repositoryCount: Int?
    public let cacheHitCount: Int?
    public let reflogUnchangedSkipCount: Int?
    public let recomputedRepositoryCount: Int?
    public let sharedDataWritten: Bool?
    public let widgetReloaded: Bool?
    public let reason: String?

    public init(
        durationMilliseconds: Int? = nil,
        authorizedRootCount: Int? = nil,
        repositoryCount: Int? = nil,
        cacheHitCount: Int? = nil,
        reflogUnchangedSkipCount: Int? = nil,
        recomputedRepositoryCount: Int? = nil,
        sharedDataWritten: Bool? = nil,
        widgetReloaded: Bool? = nil,
        reason: String? = nil
    ) {
        self.durationMilliseconds = durationMilliseconds
        self.authorizedRootCount = authorizedRootCount
        self.repositoryCount = repositoryCount
        self.cacheHitCount = cacheHitCount
        self.reflogUnchangedSkipCount = reflogUnchangedSkipCount
        self.recomputedRepositoryCount = recomputedRepositoryCount
        self.sharedDataWritten = sharedDataWritten
        self.widgetReloaded = widgetReloaded
        self.reason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
}

public struct GitActivityRefreshStatus: Equatable, Sendable {
    public let refreshedAt: Date
    public let trigger: GitTodayActivityRefreshTrigger
    public let outcome: GitActivityRefreshOutcome
    public let reason: String?
    public let metrics: GitActivityRefreshMetrics?

    public init(
        refreshedAt: Date,
        trigger: GitTodayActivityRefreshTrigger,
        outcome: GitActivityRefreshOutcome,
        reason: String? = nil,
        metrics: GitActivityRefreshMetrics? = nil
    ) {
        self.refreshedAt = refreshedAt
        self.trigger = trigger
        self.outcome = outcome
        self.reason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        self.metrics = metrics
    }
}

public final class GitActivityRefreshStatusStore {
    public enum Key {
        public static let refreshedAt = "tinybuddy.gitRefreshStatus.refreshedAt"
        public static let trigger = "tinybuddy.gitRefreshStatus.trigger"
        public static let outcome = "tinybuddy.gitRefreshStatus.outcome"
        public static let reason = "tinybuddy.gitRefreshStatus.reason"
        public static let durationMilliseconds = "tinybuddy.gitRefreshStatus.metrics.durationMilliseconds"
        public static let authorizedRootCount = "tinybuddy.gitRefreshStatus.metrics.authorizedRootCount"
        public static let repositoryCount = "tinybuddy.gitRefreshStatus.metrics.repositoryCount"
        public static let cacheHitCount = "tinybuddy.gitRefreshStatus.metrics.cacheHitCount"
        public static let reflogUnchangedSkipCount = "tinybuddy.gitRefreshStatus.metrics.reflogUnchangedSkipCount"
        public static let recomputedRepositoryCount = "tinybuddy.gitRefreshStatus.metrics.recomputedRepositoryCount"
        public static let sharedDataWritten = "tinybuddy.gitRefreshStatus.metrics.sharedDataWritten"
        public static let widgetReloaded = "tinybuddy.gitRefreshStatus.metrics.widgetReloaded"
        public static let metricsReason = "tinybuddy.gitRefreshStatus.metrics.reason"
    }

    private let userDefaults: UserDefaults
    private let calendar: Calendar
    private let dateProvider: () -> Date

    public init(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.calendar = calendar
        self.dateProvider = dateProvider
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

        guard calendar.isDate(refreshedAt, inSameDayAs: dateProvider()) else {
            return nil
        }

        let reason = userDefaults.string(forKey: Key.reason)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let metrics = loadMetrics()

        return GitActivityRefreshStatus(
            refreshedAt: refreshedAt,
            trigger: trigger,
            outcome: outcome,
            reason: reason,
            metrics: metrics
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

        saveMetrics(status.metrics)
    }

    private func loadMetrics() -> GitActivityRefreshMetrics? {
        let durationMilliseconds = integer(forKey: Key.durationMilliseconds)
        let authorizedRootCount = integer(forKey: Key.authorizedRootCount)
        let repositoryCount = integer(forKey: Key.repositoryCount)
        let cacheHitCount = integer(forKey: Key.cacheHitCount)
        let reflogUnchangedSkipCount = integer(forKey: Key.reflogUnchangedSkipCount)
        let recomputedRepositoryCount = integer(forKey: Key.recomputedRepositoryCount)
        let sharedDataWritten = bool(forKey: Key.sharedDataWritten)
        let widgetReloaded = bool(forKey: Key.widgetReloaded)
        let reason = userDefaults.string(forKey: Key.metricsReason)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        guard
            durationMilliseconds != nil ||
            authorizedRootCount != nil ||
            repositoryCount != nil ||
            cacheHitCount != nil ||
            reflogUnchangedSkipCount != nil ||
            recomputedRepositoryCount != nil ||
            sharedDataWritten != nil ||
            widgetReloaded != nil ||
            reason != nil
        else {
            return nil
        }

        return GitActivityRefreshMetrics(
            durationMilliseconds: durationMilliseconds,
            authorizedRootCount: authorizedRootCount,
            repositoryCount: repositoryCount,
            cacheHitCount: cacheHitCount,
            reflogUnchangedSkipCount: reflogUnchangedSkipCount,
            recomputedRepositoryCount: recomputedRepositoryCount,
            sharedDataWritten: sharedDataWritten,
            widgetReloaded: widgetReloaded,
            reason: reason
        )
    }

    private func saveMetrics(_ metrics: GitActivityRefreshMetrics?) {
        writeInteger(metrics?.durationMilliseconds, forKey: Key.durationMilliseconds)
        writeInteger(metrics?.authorizedRootCount, forKey: Key.authorizedRootCount)
        writeInteger(metrics?.repositoryCount, forKey: Key.repositoryCount)
        writeInteger(metrics?.cacheHitCount, forKey: Key.cacheHitCount)
        writeInteger(metrics?.reflogUnchangedSkipCount, forKey: Key.reflogUnchangedSkipCount)
        writeInteger(metrics?.recomputedRepositoryCount, forKey: Key.recomputedRepositoryCount)
        writeBool(metrics?.sharedDataWritten, forKey: Key.sharedDataWritten)
        writeBool(metrics?.widgetReloaded, forKey: Key.widgetReloaded)

        if let reason = metrics?.reason {
            userDefaults.set(reason, forKey: Key.metricsReason)
        } else {
            userDefaults.removeObject(forKey: Key.metricsReason)
        }
    }

    private func integer(forKey key: String) -> Int? {
        guard userDefaults.object(forKey: key) != nil else {
            return nil
        }

        return userDefaults.integer(forKey: key)
    }

    private func bool(forKey key: String) -> Bool? {
        guard userDefaults.object(forKey: key) != nil else {
            return nil
        }

        return userDefaults.bool(forKey: key)
    }

    private func writeInteger(_ value: Int?, forKey key: String) {
        if let value {
            userDefaults.set(value, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    private func writeBool(_ value: Bool?, forKey key: String) {
        if let value {
            userDefaults.set(value, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
