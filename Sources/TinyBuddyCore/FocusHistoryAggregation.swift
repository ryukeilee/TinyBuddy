import Foundation

/// Availability of the authoritative session archive supplied to history.
/// A partial archive must name the days for which an empty result is trusted.
public enum FocusHistorySourceHealth: String, Codable, Equatable, Sendable {
    case available
    case partial
    case unavailable
}

/// Describes which day identifiers may safely be rendered as zero when the
/// archive is not complete. `available` trusts every requested day;
/// `partial` trusts only `trustedDayIdentifiers`; `unavailable` trusts none.
public struct FocusHistorySource: Codable, Equatable, Sendable {
    public let health: FocusHistorySourceHealth
    public let trustedDayIdentifiers: Set<String>

    public init(
        health: FocusHistorySourceHealth,
        trustedDayIdentifiers: Set<String> = []
    ) {
        self.health = health
        self.trustedDayIdentifiers = trustedDayIdentifiers
    }

    public func isDayTrusted(_ dayIdentifier: String) -> Bool {
        switch health {
        case .available:
            return true
        case .partial:
            return trustedDayIdentifiers.contains(dayIdentifier)
        case .unavailable:
            return false
        }
    }
}

/// Input that defines a history presentation without creating another source
/// of truth. Day identifiers are persisted local-day labels (`yyyy-MM-dd`).
public struct FocusHistoryQuery: Equatable, Sendable {
    public let referenceDayIdentifier: String
    /// Historical daily targets in minutes. A missing or non-positive value
    /// means that goal completion for that day is not configured.
    public let dailyGoalMinutes: [String: Int]
    public let source: FocusHistorySource
    /// A project is historical when its canonical key is absent from this set.
    /// `nil` means the caller has no authoritative project registry, which is
    /// distinct from an explicitly empty registry. Keys never leave the
    /// aggregation API in presentation models.
    public let activeProjectKeys: Set<String>?
    /// Applied when no day-specific target is available. TinyBuddy currently
    /// stores one daily target preference, while retaining a path to a future
    /// per-day goal archive without rewriting session-derived history.
    public let defaultDailyGoalMinutes: Int?

    public init(
        referenceDayIdentifier: String,
        dailyGoalMinutes: [String: Int] = [:],
        source: FocusHistorySource,
        activeProjectKeys: Set<String>? = nil,
        defaultDailyGoalMinutes: Int? = nil
    ) {
        self.referenceDayIdentifier = referenceDayIdentifier
        self.dailyGoalMinutes = dailyGoalMinutes
        self.source = source
        self.activeProjectKeys = activeProjectKeys
        self.defaultDailyGoalMinutes = defaultDailyGoalMinutes.flatMap { $0 > 0 ? $0 : nil }
    }
}

public enum FocusHistoryAggregationError: Error, Equatable, Sendable {
    case invalidDayIdentifier(String)
}

public enum FocusHistoryState: String, Codable, Equatable, Sendable {
    case noHistory
    case available
    case partial
    case unknown
}

public enum FocusHistoryDayState: String, Codable, Equatable, Sendable {
    case sessions
    case noSessions
    case unknown
}

public enum FocusHistoryWeekState: String, Codable, Equatable, Sendable {
    case available
    case partial
    case unknown
}

public struct FocusHistoryDay: Codable, Equatable, Sendable {
    public let dayIdentifier: String
    public let state: FocusHistoryDayState
    /// `nil` means the archive cannot establish this value; zero means a
    /// trusted day with no ended sessions.
    public let focusDuration: TimeInterval?
    public let completedSessionCount: Int?
    public let goalMinutes: Int?
    /// Clamped to 0...1. `nil` means an unknown day or no configured goal.
    public let goalCompletionRate: Double?
    public let isGoalMet: Bool?
    /// Stable authority references behind the aggregate. `nil` means the day
    /// is unknown; an empty array is a trusted zero-session day.
    public let contributingSessionIDs: [UUID]?

    public init(
        dayIdentifier: String,
        state: FocusHistoryDayState,
        focusDuration: TimeInterval?,
        completedSessionCount: Int?,
        goalMinutes: Int?,
        goalCompletionRate: Double?,
        isGoalMet: Bool?,
        contributingSessionIDs: [UUID]? = nil
    ) {
        self.dayIdentifier = dayIdentifier
        self.state = state
        self.focusDuration = focusDuration
        self.completedSessionCount = completedSessionCount
        self.goalMinutes = goalMinutes
        self.goalCompletionRate = goalCompletionRate
        self.isGoalMet = isGoalMet
        self.contributingSessionIDs = contributingSessionIDs
    }
}

    /// Presentation-safe project aggregate. The canonical project key remains
    /// internal; deleted projects are intentionally retained as historical.
public struct FocusHistoryProject: Codable, Equatable, Sendable {
    public let displayName: String
    /// `true` means the authoritative project registry no longer contains the
    /// project; `false` means it does; `nil` means no such registry was
    /// available, so presentation must not claim an active status.
    public let isHistoricalArchive: Bool?
    public let focusDuration: TimeInterval
    public let completedSessionCount: Int
    public let focusShare: Double
    public let contributingSessionIDs: [UUID]?

    public init(
        displayName: String,
        isHistoricalArchive: Bool?,
        focusDuration: TimeInterval,
        completedSessionCount: Int,
        focusShare: Double,
        contributingSessionIDs: [UUID]? = nil
    ) {
        self.displayName = displayName
        self.isHistoricalArchive = isHistoricalArchive
        self.focusDuration = focusDuration
        self.completedSessionCount = completedSessionCount
        self.focusShare = focusShare
        self.contributingSessionIDs = contributingSessionIDs
    }
}

public struct FocusHistoryWeek: Codable, Equatable, Sendable {
    public let startDayIdentifier: String
    public let endDayIdentifier: String
    public let state: FocusHistoryWeekState
    /// All values are `nil` when any included day is unknown.
    public let focusDuration: TimeInterval?
    public let completedSessionCount: Int?
    public let goalCompletionRate: Double?
    public let goalMetDayCount: Int?
    public let configuredGoalDayCount: Int?
    public let projectDistribution: [FocusHistoryProject]?
}

public struct FocusHistorySnapshot: Codable, Equatable, Sendable {
    public let state: FocusHistoryState
    public let sourceHealth: FocusHistorySourceHealth
    public let recentDays: [FocusHistoryDay]
    public let currentWeek: FocusHistoryWeek
    /// The exact current streak ending on `referenceDayIdentifier`, or `nil`
    /// when a required historical day or goal configuration is unknown.
    public let currentGoalStreakDays: Int?
}

/// The revision-bound publication used by shared snapshots. It is derived
/// from the atomic session archive revision, never from an entry-local counter.
public struct FocusHistoryPublication: Codable, Equatable, Sendable {
    public let revision: Int64
    public let snapshot: FocusHistorySnapshot

    public init(revision: Int64, snapshot: FocusHistorySnapshot) {
        self.revision = max(0, revision)
        self.snapshot = snapshot
    }
}

/// One authoritative-session delta. A replace, merge, split, delete, and
/// reassignment are all expressed by removing `previous` and adding `current`.
public struct FocusHistorySessionChange: Equatable, Sendable {
    public let previous: FocusSession?
    public let current: FocusSession?

    public init(previous: FocusSession?, current: FocusSession?) {
        self.previous = previous
        self.current = current
    }
}

public struct FocusHistoryIncrementalUpdate: Equatable, Sendable {
    public let affectedDayIdentifiers: Set<String>

    public init(affectedDayIdentifiers: Set<String>) {
        self.affectedDayIdentifiers = affectedDayIdentifiers
    }
}

/// In-memory, session-derived history cache. It has no persistence and never
/// reads time zones: persisted `FocusSession.dayIdentifier` is the immutable
/// attribution rule for historical records.
public struct FocusHistoryAggregationCache: Sendable {
    private struct Contribution: Sendable {
        let dayIdentifier: String
        let projectKey: String
        let displayName: String
        let endedAt: Date
        let duration: TimeInterval
    }

    private struct ProjectAccumulator: Sendable {
        var focusDuration: TimeInterval = 0
        var completedSessionCount: Int = 0
        var displayCandidates: [UUID: DisplayCandidate] = [:]
    }

    private struct DisplayCandidate: Sendable {
        let displayName: String
        let endedAt: Date
    }

    private struct DayAccumulator: Sendable {
        var focusDuration: TimeInterval = 0
        var completedSessionCount: Int = 0
        var projects: [String: ProjectAccumulator] = [:]
        var sessionIDs = Set<UUID>()
    }

    private var contributions: [UUID: Contribution] = [:]
    private var days: [String: DayAccumulator] = [:]
    private let projectResolver: @Sendable (FocusProjectContext) -> FocusProjectContext

    /// Initial construction scans the supplied archive once. Subsequent
    /// `apply` calls only remove/add the supplied changed records.
    public init(
        sessions: [FocusSession] = [],
        projectResolver: @escaping @Sendable (FocusProjectContext) -> FocusProjectContext = { $0 }
    ) {
        self.projectResolver = projectResolver
        for session in sessions {
            replaceContribution(for: session.id, with: contribution(from: session))
        }
    }

    /// Applies multiple session edits as one cache update without rescanning
    /// unchanged records. The returned days are the invalidation boundary for
    /// consumers that cache rendered trends.
    @discardableResult
    public mutating func apply(_ changes: [FocusHistorySessionChange]) -> FocusHistoryIncrementalUpdate {
        var affectedDays = Set<String>()
        for change in changes {
            if let previous = change.previous,
               let removed = contributions[previous.id] {
                affectedDays.insert(removed.dayIdentifier)
                replaceContribution(for: previous.id, with: nil)
            }
            if let current = change.current,
               let contribution = contribution(from: current) {
                affectedDays.insert(contribution.dayIdentifier)
                replaceContribution(for: current.id, with: contribution)
            }
        }
        return FocusHistoryIncrementalUpdate(affectedDayIdentifiers: affectedDays)
    }

    @discardableResult
    public mutating func replace(
        previous: FocusSession?,
        current: FocusSession?
    ) -> FocusHistoryIncrementalUpdate {
        apply([FocusHistorySessionChange(previous: previous, current: current)])
    }

    public func snapshot(for query: FocusHistoryQuery) throws -> FocusHistorySnapshot {
        let referenceDate = try Self.date(for: query.referenceDayIdentifier)
        let recentIdentifiers = Self.dayIdentifiers(endingAt: referenceDate, count: 7)
        let weekIdentifiers = Self.isoWeekDayIdentifiers(through: referenceDate)
        let recentDays = recentIdentifiers.map { makeDay($0, query: query) }
        let weekDays = weekIdentifiers.map { makeDay($0, query: query) }
        let week = makeWeek(weekDays, query: query)

        let state: FocusHistoryState
        switch query.source.health {
        case .unavailable:
            state = .unknown
        case .partial:
            state = .partial
        case .available:
            state = contributions.isEmpty ? .noHistory : .available
        }

        return FocusHistorySnapshot(
            state: state,
            sourceHealth: query.source.health,
            recentDays: recentDays,
            currentWeek: week,
            currentGoalStreakDays: currentGoalStreak(endingAt: referenceDate, query: query)
        )
    }

    private func contribution(from session: FocusSession) -> Contribution? {
        guard session.status == .ended, let endedAt = session.endedAt else { return nil }
        // A manual reassignment is the highest authority. Registry discovery
        // may continue to reconcile automatic aliases, but it must not silently
        // redirect a project explicitly chosen by the user.
        let project = session.decisionAuthority == .manualCorrection
            ? session.project
            : projectResolver(session.project)
        return Contribution(
            dayIdentifier: session.dayIdentifier,
            projectKey: project.key,
            displayName: project.displayName,
            endedAt: endedAt,
            duration: session.activeDuration(now: endedAt)
        )
    }

    private mutating func replaceContribution(for id: UUID, with newContribution: Contribution?) {
        if let oldContribution = contributions.removeValue(forKey: id) {
            remove(oldContribution, id: id)
        }
        guard let newContribution else { return }
        contributions[id] = newContribution
        add(newContribution, id: id)
    }

    private mutating func add(_ contribution: Contribution, id: UUID) {
        var day = days[contribution.dayIdentifier] ?? DayAccumulator()
        day.focusDuration += contribution.duration
        day.completedSessionCount += 1
        day.sessionIDs.insert(id)
        var project = day.projects[contribution.projectKey] ?? ProjectAccumulator()
        project.focusDuration += contribution.duration
        project.completedSessionCount += 1
        project.displayCandidates[id] = DisplayCandidate(
            displayName: contribution.displayName,
            endedAt: contribution.endedAt
        )
        day.projects[contribution.projectKey] = project
        days[contribution.dayIdentifier] = day
    }

    private mutating func remove(_ contribution: Contribution, id: UUID) {
        guard var day = days[contribution.dayIdentifier],
              var project = day.projects[contribution.projectKey] else { return }
        day.focusDuration = max(0, day.focusDuration - contribution.duration)
        day.completedSessionCount = max(0, day.completedSessionCount - 1)
        day.sessionIDs.remove(id)
        project.focusDuration = max(0, project.focusDuration - contribution.duration)
        project.completedSessionCount = max(0, project.completedSessionCount - 1)
        project.displayCandidates.removeValue(forKey: id)
        if project.completedSessionCount == 0 {
            day.projects.removeValue(forKey: contribution.projectKey)
        } else {
            day.projects[contribution.projectKey] = project
        }
        if day.completedSessionCount == 0 {
            days.removeValue(forKey: contribution.dayIdentifier)
        } else {
            days[contribution.dayIdentifier] = day
        }
    }

    private func makeDay(_ identifier: String, query: FocusHistoryQuery) -> FocusHistoryDay {
        guard query.source.isDayTrusted(identifier) else {
            return FocusHistoryDay(
                dayIdentifier: identifier,
                state: .unknown,
                focusDuration: nil,
                completedSessionCount: nil,
                goalMinutes: nil,
                goalCompletionRate: nil,
                isGoalMet: nil,
                contributingSessionIDs: nil
            )
        }

        let accumulator = days[identifier]
        let duration = accumulator?.focusDuration ?? 0
        let count = accumulator?.completedSessionCount ?? 0
        let goal = query.dailyGoalMinutes[identifier].flatMap { $0 > 0 ? $0 : nil }
            ?? query.defaultDailyGoalMinutes
        let rate = goal.map { min(1, duration / TimeInterval($0 * 60)) }
        return FocusHistoryDay(
            dayIdentifier: identifier,
            state: accumulator == nil ? .noSessions : .sessions,
            focusDuration: duration,
            completedSessionCount: count,
            goalMinutes: goal,
            goalCompletionRate: rate,
            isGoalMet: rate.map { $0 >= 1 },
            contributingSessionIDs: accumulator?.sessionIDs.sorted {
                $0.uuidString < $1.uuidString
            } ?? []
        )
    }

    private func makeWeek(_ days: [FocusHistoryDay], query: FocusHistoryQuery) -> FocusHistoryWeek {
        precondition(!days.isEmpty)
        let allDaysTrusted = !days.contains { $0.state == .unknown }
        let state: FocusHistoryWeekState
        if query.source.health == .unavailable {
            state = .unknown
        } else if !allDaysTrusted || query.source.health == .partial {
            state = .partial
        } else {
            state = .available
        }

        guard allDaysTrusted else {
            return FocusHistoryWeek(
                startDayIdentifier: days[0].dayIdentifier,
                endDayIdentifier: days[days.count - 1].dayIdentifier,
                state: state,
                focusDuration: nil,
                completedSessionCount: nil,
                goalCompletionRate: nil,
                goalMetDayCount: nil,
                configuredGoalDayCount: nil,
                projectDistribution: nil
            )
        }

        let duration = days.reduce(0) { $0 + ($1.focusDuration ?? 0) }
        let count = days.reduce(0) { $0 + ($1.completedSessionCount ?? 0) }
        let configuredGoals = days.compactMap(\.goalMinutes)
        let totalGoalSeconds = configuredGoals.reduce(0) { $0 + $1 * 60 }
        let goalRate = totalGoalSeconds > 0 ? min(1, duration / TimeInterval(totalGoalSeconds)) : nil
        let metDays = days.compactMap(\.isGoalMet).filter { $0 }.count
        let distribution = projectDistribution(for: days.map(\.dayIdentifier), totalDuration: duration, activeKeys: query.activeProjectKeys)
        return FocusHistoryWeek(
            startDayIdentifier: days[0].dayIdentifier,
            endDayIdentifier: days[days.count - 1].dayIdentifier,
            state: state,
            focusDuration: duration,
            completedSessionCount: count,
            goalCompletionRate: goalRate,
            goalMetDayCount: configuredGoals.isEmpty ? nil : metDays,
            configuredGoalDayCount: configuredGoals.isEmpty ? nil : configuredGoals.count,
            projectDistribution: distribution
        )
    }

    private func projectDistribution(
        for identifiers: [String],
        totalDuration: TimeInterval,
        activeKeys: Set<String>?
    ) -> [FocusHistoryProject] {
        var buckets: [String: ProjectAccumulator] = [:]
        for identifier in identifiers {
            guard let day = days[identifier] else { continue }
            for (key, project) in day.projects {
                var bucket = buckets[key] ?? ProjectAccumulator()
                bucket.focusDuration += project.focusDuration
                bucket.completedSessionCount += project.completedSessionCount
                bucket.displayCandidates.merge(project.displayCandidates) { _, newest in newest }
                buckets[key] = bucket
            }
        }

        return buckets.compactMap { key, bucket in
            guard let displayName = preferredDisplayName(in: bucket) else { return nil }
            return FocusHistoryProject(
                displayName: displayName,
                isHistoricalArchive: activeKeys.map { !$0.contains(key) },
                focusDuration: bucket.focusDuration,
                completedSessionCount: bucket.completedSessionCount,
                focusShare: totalDuration > 0 ? bucket.focusDuration / totalDuration : 0,
                contributingSessionIDs: bucket.displayCandidates.keys.sorted {
                    $0.uuidString < $1.uuidString
                }
            )
        }
        .sorted {
            if $0.focusDuration != $1.focusDuration { return $0.focusDuration > $1.focusDuration }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.completedSessionCount > $1.completedSessionCount
        }
    }

    private func preferredDisplayName(in project: ProjectAccumulator) -> String? {
        project.displayCandidates.max { lhs, rhs in
            if lhs.value.endedAt != rhs.value.endedAt { return lhs.value.endedAt < rhs.value.endedAt }
            return lhs.key.uuidString < rhs.key.uuidString
        }?.value.displayName
    }

    private func currentGoalStreak(endingAt referenceDate: Date, query: FocusHistoryQuery) -> Int? {
        var streak = 0
        var cursor = referenceDate
        while true {
            let day = makeDay(Self.dayIdentifier(for: cursor), query: query)
            guard let isGoalMet = day.isGoalMet else { return nil }
            guard isGoalMet else { return streak }
            streak += 1
            guard let previous = Self.calendar.date(byAdding: .day, value: -1, to: cursor) else { return nil }
            cursor = previous
        }
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(for identifier: String) throws -> Date {
        let components = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]), let month = Int(components[1]), let day = Int(components[2]),
              components[0].count == 4, components[1].count == 2, components[2].count == 2,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              dayIdentifier(for: date) == identifier else {
            throw FocusHistoryAggregationError.invalidDayIdentifier(identifier)
        }
        return date
    }

    private static func dayIdentifier(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func dayIdentifiers(endingAt date: Date, count: Int) -> [String] {
        (0 ..< count).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: date).map(dayIdentifier(for:))
        }
    }

    private static func isoWeekDayIdentifiers(through referenceDate: Date) -> [String] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else { return [dayIdentifier(for: referenceDate)] }
        var identifiers: [String] = []
        var cursor = interval.start
        while cursor <= referenceDate {
            identifiers.append(dayIdentifier(for: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return identifiers
    }
}
