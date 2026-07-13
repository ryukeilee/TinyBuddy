import Foundation

public enum GitActivityRefreshOutcome: String, Equatable, Sendable {
    case succeeded
    case partial
    case skipped
    case failed
}

public enum GitActivityRefreshDiagnosticSource: String, Equatable, Sendable {
    case gitActivityRefresh
}

public enum GitActivityRefreshDiagnosticStage: String, Equatable, Sendable {
    case scriptLookup
    case authorizationResolution
    case scriptExecution
    case activitySnapshotLoad
    case combinedSnapshotCommit
}

public enum GitActivityRefreshDiagnosticReason: String, Equatable, Sendable {
    case scriptMissing
    case authorizationRequired
    case authorizationInvalid
    case scriptExecutionFailed
    case refreshedActivityUnavailable
    case partialRecovery
    case combinedSnapshotCommitFailed
}

public struct GitActivityRefreshDiagnostic: Equatable, Sendable {
    public let source: GitActivityRefreshDiagnosticSource
    public let stage: GitActivityRefreshDiagnosticStage
    public let reason: GitActivityRefreshDiagnosticReason

    public init(
        source: GitActivityRefreshDiagnosticSource,
        stage: GitActivityRefreshDiagnosticStage,
        reason: GitActivityRefreshDiagnosticReason
    ) {
        self.source = source
        self.stage = stage
        self.reason = reason
    }

    public var stableIdentifier: String {
        "\(source.rawValue).\(stage.rawValue).\(reason.rawValue)"
    }

    public static func legacyDiagnostic(for reason: String?) -> GitActivityRefreshDiagnostic? {
        guard let normalizedReason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              normalizedReason.isEmpty == false else {
            return nil
        }

        if normalizedReason.contains("gitactivityrefresh.scriptlookup.scriptmissing")
            || normalizedReason.contains("missing git refresh script") {
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .scriptLookup,
                reason: .scriptMissing
            )
        }

        if normalizedReason.contains("gitactivityrefresh.authorizationresolution.authorizationrequired")
            || normalizedReason.contains("no authorized git scan roots") {
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .authorizationResolution,
                reason: .authorizationRequired
            )
        }

        if normalizedReason.contains("gitactivityrefresh.authorizationresolution.authorizationinvalid")
            || normalizedReason.contains("saved git scan root authorizations are no longer valid") {
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .authorizationResolution,
                reason: .authorizationInvalid
            )
        }

        if normalizedReason.contains("gitactivityrefresh.activitysnapshotload.refreshedactivityunavailable")
            || normalizedReason.contains("refreshed git activity data is unavailable") {
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .activitySnapshotLoad,
                reason: .refreshedActivityUnavailable
            )
        }

        if normalizedReason.contains("gitactivityrefresh.combinedsnapshotcommit.combinedsnapshotcommitfailed")
            || normalizedReason.contains("combined snapshot commit failed") {
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .combinedSnapshotCommit,
                reason: .combinedSnapshotCommitFailed
            )
        }

        if normalizedReason.contains("gitactivityrefresh.scriptexecution.partialrecovery")
            || normalizedReason.contains("partial git refresh") {
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .scriptExecution,
                reason: .partialRecovery
            )
        }

        if normalizedReason.contains("gitactivityrefresh.scriptexecution.scriptexecutionfailed")
            || normalizedReason.contains("refresh script exited with status")
            || normalizedReason.contains("git temporarily unavailable") {
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .scriptExecution,
                reason: .scriptExecutionFailed
            )
        }

        return nil
    }
}

public struct GitActivityRefreshMetrics: Equatable, Sendable {
    public let durationMilliseconds: Int?
    public let authorizedRootCount: Int?
    public let repositoryCount: Int?
    public let cacheHitCount: Int?
    public let reflogUnchangedSkipCount: Int?
    public let recomputedRepositoryCount: Int?
    public let invalidRepositoryCount: Int?
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
        invalidRepositoryCount: Int? = nil,
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
        self.invalidRepositoryCount = invalidRepositoryCount
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
    public let diagnostic: GitActivityRefreshDiagnostic?
    public let metrics: GitActivityRefreshMetrics?

    public init(
        refreshedAt: Date,
        trigger: GitTodayActivityRefreshTrigger,
        outcome: GitActivityRefreshOutcome,
        reason: String? = nil,
        diagnostic: GitActivityRefreshDiagnostic? = nil,
        metrics: GitActivityRefreshMetrics? = nil
    ) {
        let normalizedReason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let resolvedDiagnostic = diagnostic ?? GitActivityRefreshDiagnostic.legacyDiagnostic(for: normalizedReason)
        self.refreshedAt = refreshedAt
        self.trigger = trigger
        self.outcome = outcome
        self.reason = resolvedDiagnostic?.stableIdentifier ?? normalizedReason
        self.diagnostic = resolvedDiagnostic
        self.metrics = metrics
    }
}

public final class GitActivityRefreshStatusStore {
    public enum Key {
        public static let refreshedAt = "tinybuddy.gitRefreshStatus.refreshedAt"
        public static let trigger = "tinybuddy.gitRefreshStatus.trigger"
        public static let outcome = "tinybuddy.gitRefreshStatus.outcome"
        public static let reason = "tinybuddy.gitRefreshStatus.reason"
        public static let diagnosticSource = "tinybuddy.gitRefreshStatus.diagnostic.source"
        public static let diagnosticStage = "tinybuddy.gitRefreshStatus.diagnostic.stage"
        public static let diagnosticReason = "tinybuddy.gitRefreshStatus.diagnostic.reason"
        public static let durationMilliseconds = "tinybuddy.gitRefreshStatus.metrics.durationMilliseconds"
        public static let authorizedRootCount = "tinybuddy.gitRefreshStatus.metrics.authorizedRootCount"
        public static let repositoryCount = "tinybuddy.gitRefreshStatus.metrics.repositoryCount"
        public static let cacheHitCount = "tinybuddy.gitRefreshStatus.metrics.cacheHitCount"
        public static let reflogUnchangedSkipCount = "tinybuddy.gitRefreshStatus.metrics.reflogUnchangedSkipCount"
        public static let recomputedRepositoryCount = "tinybuddy.gitRefreshStatus.metrics.recomputedRepositoryCount"
        public static let invalidRepositoryCount = "tinybuddy.gitRefreshStatus.metrics.invalidRepositoryCount"
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

        let legacyReason = userDefaults.string(forKey: Key.reason)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let (reason, diagnostic, didMigrateReason) = loadReasonAndDiagnostic(legacyReason: legacyReason)
        let (metrics, didMigrateMetrics) = loadMetrics(fallbackDiagnostic: diagnostic)

        let status = GitActivityRefreshStatus(
            refreshedAt: refreshedAt,
            trigger: trigger,
            outcome: outcome,
            reason: reason,
            diagnostic: diagnostic,
            metrics: metrics
        )

        if didMigrateReason || didMigrateMetrics {
            save(status)
        }

        return status
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

        saveDiagnostic(status.diagnostic)
        saveMetrics(status.metrics)
    }

    private func loadMetrics(
        fallbackDiagnostic: GitActivityRefreshDiagnostic?
    ) -> (metrics: GitActivityRefreshMetrics?, didMigrate: Bool) {
        let durationMilliseconds = integer(forKey: Key.durationMilliseconds)
        let authorizedRootCount = integer(forKey: Key.authorizedRootCount)
        let repositoryCount = integer(forKey: Key.repositoryCount)
        let cacheHitCount = integer(forKey: Key.cacheHitCount)
        let reflogUnchangedSkipCount = integer(forKey: Key.reflogUnchangedSkipCount)
        let recomputedRepositoryCount = integer(forKey: Key.recomputedRepositoryCount)
        let invalidRepositoryCount = integer(forKey: Key.invalidRepositoryCount)
        let sharedDataWritten = bool(forKey: Key.sharedDataWritten)
        let widgetReloaded = bool(forKey: Key.widgetReloaded)
        let legacyReason = userDefaults.string(forKey: Key.metricsReason)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let reason = GitActivityRefreshDiagnostic.legacyDiagnostic(for: legacyReason)?.stableIdentifier
            ?? (legacyReason != nil ? fallbackDiagnostic?.stableIdentifier : nil)

        guard
            durationMilliseconds != nil ||
            authorizedRootCount != nil ||
            repositoryCount != nil ||
            cacheHitCount != nil ||
            reflogUnchangedSkipCount != nil ||
            recomputedRepositoryCount != nil ||
            invalidRepositoryCount != nil ||
            sharedDataWritten != nil ||
            widgetReloaded != nil ||
            reason != nil
        else {
            return (nil, legacyReason != nil)
        }

        return (
            GitActivityRefreshMetrics(
                durationMilliseconds: durationMilliseconds,
                authorizedRootCount: authorizedRootCount,
                repositoryCount: repositoryCount,
                cacheHitCount: cacheHitCount,
                reflogUnchangedSkipCount: reflogUnchangedSkipCount,
                recomputedRepositoryCount: recomputedRepositoryCount,
                invalidRepositoryCount: invalidRepositoryCount,
                sharedDataWritten: sharedDataWritten,
                widgetReloaded: widgetReloaded,
                reason: reason
            ),
            legacyReason != reason
        )
    }

    private func loadReasonAndDiagnostic(
        legacyReason: String?
    ) -> (reason: String?, diagnostic: GitActivityRefreshDiagnostic?, didMigrate: Bool) {
        if let diagnostic = loadStoredDiagnostic() {
            let reason = diagnostic.stableIdentifier
            return (reason, diagnostic, legacyReason != reason)
        }

        if let diagnostic = GitActivityRefreshDiagnostic.legacyDiagnostic(for: legacyReason) {
            return (diagnostic.stableIdentifier, diagnostic, true)
        }

        return (nil, nil, legacyReason != nil)
    }

    private func loadStoredDiagnostic() -> GitActivityRefreshDiagnostic? {
        if let sourceRawValue = userDefaults.string(forKey: Key.diagnosticSource),
           let stageRawValue = userDefaults.string(forKey: Key.diagnosticStage),
           let reasonRawValue = userDefaults.string(forKey: Key.diagnosticReason),
           let source = GitActivityRefreshDiagnosticSource(rawValue: sourceRawValue),
           let stage = GitActivityRefreshDiagnosticStage(rawValue: stageRawValue),
           let reason = GitActivityRefreshDiagnosticReason(rawValue: reasonRawValue) {
            return GitActivityRefreshDiagnostic(
                source: source,
                stage: stage,
                reason: reason
            )
        }

        return nil
    }

    private func saveDiagnostic(_ diagnostic: GitActivityRefreshDiagnostic?) {
        if let diagnostic {
            userDefaults.set(diagnostic.source.rawValue, forKey: Key.diagnosticSource)
            userDefaults.set(diagnostic.stage.rawValue, forKey: Key.diagnosticStage)
            userDefaults.set(diagnostic.reason.rawValue, forKey: Key.diagnosticReason)
            return
        }

        userDefaults.removeObject(forKey: Key.diagnosticSource)
        userDefaults.removeObject(forKey: Key.diagnosticStage)
        userDefaults.removeObject(forKey: Key.diagnosticReason)
    }

    private func saveMetrics(_ metrics: GitActivityRefreshMetrics?) {
        writeInteger(metrics?.durationMilliseconds, forKey: Key.durationMilliseconds)
        writeInteger(metrics?.authorizedRootCount, forKey: Key.authorizedRootCount)
        writeInteger(metrics?.repositoryCount, forKey: Key.repositoryCount)
        writeInteger(metrics?.cacheHitCount, forKey: Key.cacheHitCount)
        writeInteger(metrics?.reflogUnchangedSkipCount, forKey: Key.reflogUnchangedSkipCount)
        writeInteger(metrics?.recomputedRepositoryCount, forKey: Key.recomputedRepositoryCount)
        writeInteger(metrics?.invalidRepositoryCount, forKey: Key.invalidRepositoryCount)
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
