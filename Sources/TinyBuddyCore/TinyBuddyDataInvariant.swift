import Foundation

// MARK: - Data Domain

/// One logical data domain that invariants apply to.
public enum TinyBuddyDataDomain: String, Codable, Equatable, Sendable {
    case focusSession
    case projectIdentity
    case configSnapshot
    case historyAggregation
    case sharedSnapshot
    case dailyStats

    public var identifier: String { rawValue }
}

// MARK: - Severity

public enum TinyBuddyDataInvariantSeverity: String, Codable, Equatable, Sendable, Comparable {
    /// Non-critical: a recoverable inconsistency (e.g. stale aux copy, minor drift)
    case warning
    /// Serious: derived stats inconsistent, reference stale — requires repair
    case error
    /// Fatal: schema mismatch, unrecoverable corruption — data cannot be used
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ s: Self) -> Int {
        switch s {
        case .warning: return 0
        case .error: return 1
        case .critical: return 2
        }
    }

    public var identifier: String { rawValue }
}

// MARK: - Violation Kind

/// Specific violation kind within a data domain. Each case encodes exactly what
/// invariant was violated so repair logic can match precisely without string parsing.
public enum TinyBuddyDataInvariantKind {
    // MARK: Focus Session violations
    case duplicateSessionID(UUID)
    case sessionTimeOverlap(sessionIDs: [UUID])
    case negativeDuration(sessionID: UUID, duration: TimeInterval)
    case futureStartedAt(sessionID: UUID, date: Date)
    case missingEndedAt(sessionID: UUID)
    case statusEndedWithoutEndedAt(sessionID: UUID)
    case statusActiveWithEndedAt(sessionID: UUID)
    case invalidDayIdentifier(sessionID: UUID, identifier: String)
    case emptyProjectKey(sessionID: UUID)
    case sessionEmptyProjectDisplayName(sessionID: UUID)
    case pausedTotalExceedsGross(sessionID: UUID, pausedTotal: TimeInterval, gross: TimeInterval)
    case currentPauseNotNilForActive(sessionID: UUID)
    case currentPauseNotNilForEnded(sessionID: UUID)
    case decisionEventDuplicateID(sessionID: UUID, eventID: UUID)
    case manualRevisionNegative(sessionID: UUID, revision: Int64)
    case lastUserActivityBeforeStart(sessionID: UUID)
    case lastStateChangeBeforeStart(sessionID: UUID)

    // MARK: Project identity violations
    case duplicateProjectID(TinyBuddyProjectID)
    case projectEmptyProjectDisplayName(projectID: TinyBuddyProjectID)
    case staleProjectReference(projectKey: String)
    case projectRegistryRedirectCycle
    case projectRegistryRedirectToSelf
    case projectRedirectSourceNotInRegistry(source: TinyBuddyProjectID)
    case projectRedirectTargetNotInRegistry(target: TinyBuddyProjectID)

    // MARK: Config snapshot violations
    case configVersionRegression(previous: Int64, current: Int64)
    case configPayloadDecodeFailed
    case configVersionMarkerMismatch

    // MARK: History aggregation violations
    case focusCountMismatch(dayIdentifier: String, expected: Int, actual: Int)
    case contributionSessionIDCountMismatch(dayIdentifier: String)
    case goalConsistencyViolation(dayIdentifier: String)
    case weekFocusDurationMismatch(weekStart: String)

    // MARK: Shared snapshot violations
    case snapshotRevisionRegression(previous: Int64, current: Int64)
    case snapshotDayIdentifierMismatch(expected: String, actual: String)
    case snapshotFocusSessionDayMismatch(snapshotDay: String, focusDay: String)
    case snapshotHistoryDayMismatch(snapshotDay: String, historyDay: String)
    case snapshotFieldMissing(field: String)
    case snapshotSchemaVersionMismatch

    // MARK: DailyStats violations
    case focusCountNegative(dayIdentifier: String, count: Int)
    case completionCountNegative(dayIdentifier: String, count: Int)
    case dayIdentifierRollback(previous: String, current: String)

    // MARK: Generic
    case unknown(String)
}

// MARK: - Codable conformance (manual, due to associated values)

extension TinyBuddyDataInvariantKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum TypeID: String, Codable {
        case duplicateSessionID, sessionTimeOverlap, negativeDuration, futureStartedAt
        case missingEndedAt, statusEndedWithoutEndedAt, statusActiveWithEndedAt
        case invalidDayIdentifier, emptyProjectKey, sessionEmptyProjectDisplayName
        case pausedTotalExceedsGross, currentPauseNotNilForActive, currentPauseNotNilForEnded
        case decisionEventDuplicateID, manualRevisionNegative
        case lastUserActivityBeforeStart, lastStateChangeBeforeStart
        case duplicateProjectID, projectEmptyProjectDisplayName, staleProjectReference
        case projectRegistryRedirectCycle, projectRegistryRedirectToSelf
        case projectRedirectSourceNotInRegistry, projectRedirectTargetNotInRegistry
        case configVersionRegression, configPayloadDecodeFailed, configVersionMarkerMismatch
        case focusCountMismatch, contributionSessionIDCountMismatch, goalConsistencyViolation
        case weekFocusDurationMismatch
        case snapshotRevisionRegression, snapshotDayIdentifierMismatch
        case snapshotFocusSessionDayMismatch, snapshotHistoryDayMismatch
        case snapshotFieldMissing, snapshotSchemaVersionMismatch
        case focusCountNegative, completionCountNegative, dayIdentifierRollback
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeID.self, forKey: .type)
        switch type {
        case .duplicateSessionID:
            self = .duplicateSessionID(try container.decode(UUID.self, forKey: .payload))
        case .sessionTimeOverlap:
            self = .sessionTimeOverlap(sessionIDs: try container.decode([UUID].self, forKey: .payload))
        case .negativeDuration:
            let p = try container.decode(NegativeDurationPayload.self, forKey: .payload)
            self = .negativeDuration(sessionID: p.sessionID, duration: p.duration)
        case .futureStartedAt:
            let p = try container.decode(FutureDatePayload.self, forKey: .payload)
            self = .futureStartedAt(sessionID: p.id, date: p.date)
        case .missingEndedAt:
            self = .missingEndedAt(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .statusEndedWithoutEndedAt:
            self = .statusEndedWithoutEndedAt(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .statusActiveWithEndedAt:
            self = .statusActiveWithEndedAt(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .invalidDayIdentifier:
            let p = try container.decode(InvalidDayPayload.self, forKey: .payload)
            self = .invalidDayIdentifier(sessionID: p.id, identifier: p.identifier)
        case .emptyProjectKey:
            self = .emptyProjectKey(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .sessionEmptyProjectDisplayName:
            self = .sessionEmptyProjectDisplayName(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .pausedTotalExceedsGross:
            let p = try container.decode(PausedExcessPayload.self, forKey: .payload)
            self = .pausedTotalExceedsGross(sessionID: p.sessionID, pausedTotal: p.pausedTotal, gross: p.gross)
        case .currentPauseNotNilForActive:
            self = .currentPauseNotNilForActive(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .currentPauseNotNilForEnded:
            self = .currentPauseNotNilForEnded(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .decisionEventDuplicateID:
            let p = try container.decode(EventDuplicatePayload.self, forKey: .payload)
            self = .decisionEventDuplicateID(sessionID: p.sessionID, eventID: p.eventID)
        case .manualRevisionNegative:
            let p = try container.decode(RevisionNegativePayload.self, forKey: .payload)
            self = .manualRevisionNegative(sessionID: p.sessionID, revision: p.revision)
        case .lastUserActivityBeforeStart:
            self = .lastUserActivityBeforeStart(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .lastStateChangeBeforeStart:
            self = .lastStateChangeBeforeStart(sessionID: try container.decode(UUID.self, forKey: .payload))
        case .duplicateProjectID:
            self = .duplicateProjectID(try container.decode(TinyBuddyProjectID.self, forKey: .payload))
        case .projectEmptyProjectDisplayName:
            self = .projectEmptyProjectDisplayName(projectID: try container.decode(TinyBuddyProjectID.self, forKey: .payload))
        case .staleProjectReference:
            self = .staleProjectReference(projectKey: try container.decode(String.self, forKey: .payload))
        case .projectRegistryRedirectCycle:
            self = .projectRegistryRedirectCycle
        case .projectRegistryRedirectToSelf:
            self = .projectRegistryRedirectToSelf
        case .projectRedirectSourceNotInRegistry:
            self = .projectRedirectSourceNotInRegistry(source: try container.decode(TinyBuddyProjectID.self, forKey: .payload))
        case .projectRedirectTargetNotInRegistry:
            self = .projectRedirectTargetNotInRegistry(target: try container.decode(TinyBuddyProjectID.self, forKey: .payload))
        case .configVersionRegression:
            let p = try container.decode(VersionRegressionPayload.self, forKey: .payload)
            self = .configVersionRegression(previous: p.previous, current: p.current)
        case .configPayloadDecodeFailed:
            self = .configPayloadDecodeFailed
        case .configVersionMarkerMismatch:
            self = .configVersionMarkerMismatch
        case .focusCountMismatch:
            let p = try container.decode(CountMismatchPayload.self, forKey: .payload)
            self = .focusCountMismatch(dayIdentifier: p.dayIdentifier, expected: p.expected, actual: p.actual)
        case .contributionSessionIDCountMismatch:
            self = .contributionSessionIDCountMismatch(dayIdentifier: try container.decode(String.self, forKey: .payload))
        case .goalConsistencyViolation:
            self = .goalConsistencyViolation(dayIdentifier: try container.decode(String.self, forKey: .payload))
        case .weekFocusDurationMismatch:
            self = .weekFocusDurationMismatch(weekStart: try container.decode(String.self, forKey: .payload))
        case .snapshotRevisionRegression:
            let p = try container.decode(VersionRegressionPayload.self, forKey: .payload)
            self = .snapshotRevisionRegression(previous: p.previous, current: p.current)
        case .snapshotDayIdentifierMismatch:
            let p = try container.decode(DayMismatchPayload.self, forKey: .payload)
            self = .snapshotDayIdentifierMismatch(expected: p.expected, actual: p.actual)
        case .snapshotFocusSessionDayMismatch:
            let p = try container.decode(DayMismatchPayload.self, forKey: .payload)
            self = .snapshotFocusSessionDayMismatch(snapshotDay: p.expected, focusDay: p.actual)
        case .snapshotHistoryDayMismatch:
            let p = try container.decode(DayMismatchPayload.self, forKey: .payload)
            self = .snapshotHistoryDayMismatch(snapshotDay: p.expected, historyDay: p.actual)
        case .snapshotFieldMissing:
            self = .snapshotFieldMissing(field: try container.decode(String.self, forKey: .payload))
        case .snapshotSchemaVersionMismatch:
            self = .snapshotSchemaVersionMismatch
        case .focusCountNegative:
            let p = try container.decode(NegativeCountPayload.self, forKey: .payload)
            self = .focusCountNegative(dayIdentifier: p.dayIdentifier, count: p.count)
        case .completionCountNegative:
            let p = try container.decode(NegativeCountPayload.self, forKey: .payload)
            self = .completionCountNegative(dayIdentifier: p.dayIdentifier, count: p.count)
        case .dayIdentifierRollback:
            let p = try container.decode(DayRollbackPayload.self, forKey: .payload)
            self = .dayIdentifierRollback(previous: p.previous, current: p.current)
        case .unknown:
            self = .unknown(try container.decode(String.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .duplicateSessionID(let id):
            try container.encode(TypeID.duplicateSessionID, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .sessionTimeOverlap(let ids):
            try container.encode(TypeID.sessionTimeOverlap, forKey: .type)
            try container.encode(ids, forKey: .payload)
        case .negativeDuration(let sessionID, let duration):
            try container.encode(TypeID.negativeDuration, forKey: .type)
            try container.encode(NegativeDurationPayload(sessionID: sessionID, duration: duration), forKey: .payload)
        case .futureStartedAt(let id, let date):
            try container.encode(TypeID.futureStartedAt, forKey: .type)
            try container.encode(FutureDatePayload(id: id, date: date), forKey: .payload)
        case .missingEndedAt(let id):
            try container.encode(TypeID.missingEndedAt, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .statusEndedWithoutEndedAt(let id):
            try container.encode(TypeID.statusEndedWithoutEndedAt, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .statusActiveWithEndedAt(let id):
            try container.encode(TypeID.statusActiveWithEndedAt, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .invalidDayIdentifier(let id, let identifier):
            try container.encode(TypeID.invalidDayIdentifier, forKey: .type)
            try container.encode(InvalidDayPayload(id: id, identifier: identifier), forKey: .payload)
        case .emptyProjectKey(let id):
            try container.encode(TypeID.emptyProjectKey, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .sessionEmptyProjectDisplayName(let sessionID):
            try container.encode(TypeID.sessionEmptyProjectDisplayName, forKey: .type)
            try container.encode(sessionID, forKey: .payload)
        case .pausedTotalExceedsGross(let sessionID, let pausedTotal, let gross):
            try container.encode(TypeID.pausedTotalExceedsGross, forKey: .type)
            try container.encode(PausedExcessPayload(sessionID: sessionID, pausedTotal: pausedTotal, gross: gross), forKey: .payload)
        case .currentPauseNotNilForActive(let id):
            try container.encode(TypeID.currentPauseNotNilForActive, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .currentPauseNotNilForEnded(let id):
            try container.encode(TypeID.currentPauseNotNilForEnded, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .decisionEventDuplicateID(let sessionID, let eventID):
            try container.encode(TypeID.decisionEventDuplicateID, forKey: .type)
            try container.encode(EventDuplicatePayload(sessionID: sessionID, eventID: eventID), forKey: .payload)
        case .manualRevisionNegative(let sessionID, let revision):
            try container.encode(TypeID.manualRevisionNegative, forKey: .type)
            try container.encode(RevisionNegativePayload(sessionID: sessionID, revision: revision), forKey: .payload)
        case .lastUserActivityBeforeStart(let id):
            try container.encode(TypeID.lastUserActivityBeforeStart, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .lastStateChangeBeforeStart(let id):
            try container.encode(TypeID.lastStateChangeBeforeStart, forKey: .type)
            try container.encode(id, forKey: .payload)
        case .duplicateProjectID(let pid):
            try container.encode(TypeID.duplicateProjectID, forKey: .type)
            try container.encode(pid, forKey: .payload)
        case .projectEmptyProjectDisplayName(let projectID):
            try container.encode(TypeID.projectEmptyProjectDisplayName, forKey: .type)
            try container.encode(projectID, forKey: .payload)
        case .staleProjectReference(let key):
            try container.encode(TypeID.staleProjectReference, forKey: .type)
            try container.encode(key, forKey: .payload)
        case .projectRegistryRedirectCycle:
            try container.encode(TypeID.projectRegistryRedirectCycle, forKey: .type)
        case .projectRegistryRedirectToSelf:
            try container.encode(TypeID.projectRegistryRedirectToSelf, forKey: .type)
        case .projectRedirectSourceNotInRegistry(let source):
            try container.encode(TypeID.projectRedirectSourceNotInRegistry, forKey: .type)
            try container.encode(source, forKey: .payload)
        case .projectRedirectTargetNotInRegistry(let target):
            try container.encode(TypeID.projectRedirectTargetNotInRegistry, forKey: .type)
            try container.encode(target, forKey: .payload)
        case .configVersionRegression(let previous, let current):
            try container.encode(TypeID.configVersionRegression, forKey: .type)
            try container.encode(VersionRegressionPayload(previous: previous, current: current), forKey: .payload)
        case .configPayloadDecodeFailed:
            try container.encode(TypeID.configPayloadDecodeFailed, forKey: .type)
        case .configVersionMarkerMismatch:
            try container.encode(TypeID.configVersionMarkerMismatch, forKey: .type)
        case .focusCountMismatch(let dayIdentifier, let expected, let actual):
            try container.encode(TypeID.focusCountMismatch, forKey: .type)
            try container.encode(CountMismatchPayload(dayIdentifier: dayIdentifier, expected: expected, actual: actual), forKey: .payload)
        case .contributionSessionIDCountMismatch(let dayIdentifier):
            try container.encode(TypeID.contributionSessionIDCountMismatch, forKey: .type)
            try container.encode(dayIdentifier, forKey: .payload)
        case .goalConsistencyViolation(let dayIdentifier):
            try container.encode(TypeID.goalConsistencyViolation, forKey: .type)
            try container.encode(dayIdentifier, forKey: .payload)
        case .weekFocusDurationMismatch(let weekStart):
            try container.encode(TypeID.weekFocusDurationMismatch, forKey: .type)
            try container.encode(weekStart, forKey: .payload)
        case .snapshotRevisionRegression(let previous, let current):
            try container.encode(TypeID.snapshotRevisionRegression, forKey: .type)
            try container.encode(VersionRegressionPayload(previous: previous, current: current), forKey: .payload)
        case .snapshotDayIdentifierMismatch(let expected, let actual):
            try container.encode(TypeID.snapshotDayIdentifierMismatch, forKey: .type)
            try container.encode(DayMismatchPayload(expected: expected, actual: actual), forKey: .payload)
        case .snapshotFocusSessionDayMismatch(let snapshotDay, let focusDay):
            try container.encode(TypeID.snapshotFocusSessionDayMismatch, forKey: .type)
            try container.encode(DayMismatchPayload(expected: snapshotDay, actual: focusDay), forKey: .payload)
        case .snapshotHistoryDayMismatch(let snapshotDay, let historyDay):
            try container.encode(TypeID.snapshotHistoryDayMismatch, forKey: .type)
            try container.encode(DayMismatchPayload(expected: snapshotDay, actual: historyDay), forKey: .payload)
        case .snapshotFieldMissing(let field):
            try container.encode(TypeID.snapshotFieldMissing, forKey: .type)
            try container.encode(field, forKey: .payload)
        case .snapshotSchemaVersionMismatch:
            try container.encode(TypeID.snapshotSchemaVersionMismatch, forKey: .type)
        case .focusCountNegative(let dayIdentifier, let count):
            try container.encode(TypeID.focusCountNegative, forKey: .type)
            try container.encode(NegativeCountPayload(dayIdentifier: dayIdentifier, count: count), forKey: .payload)
        case .completionCountNegative(let dayIdentifier, let count):
            try container.encode(TypeID.completionCountNegative, forKey: .type)
            try container.encode(NegativeCountPayload(dayIdentifier: dayIdentifier, count: count), forKey: .payload)
        case .dayIdentifierRollback(let previous, let current):
            try container.encode(TypeID.dayIdentifierRollback, forKey: .type)
            try container.encode(DayRollbackPayload(previous: previous, current: current), forKey: .payload)
        case .unknown(let desc):
            try container.encode(TypeID.unknown, forKey: .type)
            try container.encode(desc, forKey: .payload)
        }
    }
}

// MARK: - Codable Payload Types (private)

private struct NegativeDurationPayload: Codable {
    let sessionID: UUID
    let duration: TimeInterval
}

private struct FutureDatePayload: Codable {
    let id: UUID
    let date: Date
}

private struct InvalidDayPayload: Codable {
    let id: UUID
    let identifier: String
}

private struct PausedExcessPayload: Codable {
    let sessionID: UUID
    let pausedTotal: TimeInterval
    let gross: TimeInterval
}

private struct EventDuplicatePayload: Codable {
    let sessionID: UUID
    let eventID: UUID
}

private struct RevisionNegativePayload: Codable {
    let sessionID: UUID
    let revision: Int64
}

private struct VersionRegressionPayload: Codable {
    let previous: Int64
    let current: Int64
}

private struct CountMismatchPayload: Codable {
    let dayIdentifier: String
    let expected: Int
    let actual: Int
}

private struct DayMismatchPayload: Codable {
    let expected: String
    let actual: String
}

private struct NegativeCountPayload: Codable {
    let dayIdentifier: String
    let count: Int
}

private struct DayRollbackPayload: Codable {
    let previous: String
    let current: String
}

// MARK: - Hashable

extension TinyBuddyDataInvariantKind: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .duplicateSessionID(let id): hasher.combine("a"); hasher.combine(id)
        case .sessionTimeOverlap(let ids): hasher.combine("b"); hasher.combine(ids)
        case .negativeDuration(let id, _): hasher.combine("c"); hasher.combine(id)
        case .futureStartedAt(let id, _): hasher.combine("d"); hasher.combine(id)
        case .missingEndedAt(let id): hasher.combine("e"); hasher.combine(id)
        case .statusEndedWithoutEndedAt(let id): hasher.combine("f"); hasher.combine(id)
        case .statusActiveWithEndedAt(let id): hasher.combine("g"); hasher.combine(id)
        case .invalidDayIdentifier(let id, _): hasher.combine("h"); hasher.combine(id)
        case .emptyProjectKey(let id): hasher.combine("i"); hasher.combine(id)
        case .sessionEmptyProjectDisplayName(let id): hasher.combine("j"); hasher.combine(id)
        case .pausedTotalExceedsGross(let id, _, _): hasher.combine("k"); hasher.combine(id)
        case .currentPauseNotNilForActive(let id): hasher.combine("l"); hasher.combine(id)
        case .currentPauseNotNilForEnded(let id): hasher.combine("m"); hasher.combine(id)
        case .decisionEventDuplicateID(let sid, _): hasher.combine("n"); hasher.combine(sid)
        case .manualRevisionNegative(let sid, _): hasher.combine("o"); hasher.combine(sid)
        case .lastUserActivityBeforeStart(let id): hasher.combine("p"); hasher.combine(id)
        case .lastStateChangeBeforeStart(let id): hasher.combine("q"); hasher.combine(id)
        case .duplicateProjectID(let pid): hasher.combine("r"); hasher.combine(pid)
        case .projectEmptyProjectDisplayName(let pid): hasher.combine("s"); hasher.combine(pid)
        case .staleProjectReference(let key): hasher.combine("t"); hasher.combine(key)
        case .projectRegistryRedirectCycle: hasher.combine("u")
        case .projectRegistryRedirectToSelf: hasher.combine("v")
        case .projectRedirectSourceNotInRegistry(let s): hasher.combine("w"); hasher.combine(s)
        case .projectRedirectTargetNotInRegistry(let t): hasher.combine("x"); hasher.combine(t)
        case .configVersionRegression(let p, _): hasher.combine("y"); hasher.combine(p)
        case .configPayloadDecodeFailed: hasher.combine("z")
        case .configVersionMarkerMismatch: hasher.combine("aa")
        case .focusCountMismatch(let d, _, _): hasher.combine("ab"); hasher.combine(d)
        case .contributionSessionIDCountMismatch(let d): hasher.combine("ac"); hasher.combine(d)
        case .goalConsistencyViolation(let d): hasher.combine("ad"); hasher.combine(d)
        case .weekFocusDurationMismatch(let s): hasher.combine("ae"); hasher.combine(s)
        case .snapshotRevisionRegression(let p, _): hasher.combine("af"); hasher.combine(p)
        case .snapshotDayIdentifierMismatch(let e, _): hasher.combine("ag"); hasher.combine(e)
        case .snapshotFocusSessionDayMismatch(let sd, _): hasher.combine("ah"); hasher.combine(sd)
        case .snapshotHistoryDayMismatch(let sd, _): hasher.combine("ai"); hasher.combine(sd)
        case .snapshotFieldMissing(let f): hasher.combine("aj"); hasher.combine(f)
        case .snapshotSchemaVersionMismatch: hasher.combine("ak")
        case .focusCountNegative(let d, _): hasher.combine("al"); hasher.combine(d)
        case .completionCountNegative(let d, _): hasher.combine("am"); hasher.combine(d)
        case .dayIdentifierRollback(let p, _): hasher.combine("an"); hasher.combine(p)
        case .unknown(let desc): hasher.combine("ao"); hasher.combine(desc)
        }
    }
}

// MARK: - Equatable (manual, due to associated values with floating-point)

extension TinyBuddyDataInvariantKind: Equatable {
    public static func == (lhs: TinyBuddyDataInvariantKind, rhs: TinyBuddyDataInvariantKind) -> Bool {
        switch (lhs, rhs) {
        case (.duplicateSessionID(let a), .duplicateSessionID(let b)): return a == b
        case (.sessionTimeOverlap(let a), .sessionTimeOverlap(let b)): return a == b
        case (.negativeDuration(let a1, let a2), .negativeDuration(let b1, let b2)): return a1 == b1 && abs(a2 - b2) < 0.001
        case (.futureStartedAt(let a1, let a2), .futureStartedAt(let b1, let b2)): return a1 == b1 && abs(a2.timeIntervalSince(b2)) < 0.001
        case (.missingEndedAt(let a), .missingEndedAt(let b)): return a == b
        case (.statusEndedWithoutEndedAt(let a), .statusEndedWithoutEndedAt(let b)): return a == b
        case (.statusActiveWithEndedAt(let a), .statusActiveWithEndedAt(let b)): return a == b
        case (.invalidDayIdentifier(let a1, let a2), .invalidDayIdentifier(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.emptyProjectKey(let a), .emptyProjectKey(let b)): return a == b
        case (.sessionEmptyProjectDisplayName(let a), .sessionEmptyProjectDisplayName(let b)): return a == b
        case (.pausedTotalExceedsGross(let a1, let a2, let a3), .pausedTotalExceedsGross(let b1, let b2, let b3)): return a1 == b1 && abs(a2 - b2) < 0.001 && abs(a3 - b3) < 0.001
        case (.currentPauseNotNilForActive(let a), .currentPauseNotNilForActive(let b)): return a == b
        case (.currentPauseNotNilForEnded(let a), .currentPauseNotNilForEnded(let b)): return a == b
        case (.decisionEventDuplicateID(let a1, let a2), .decisionEventDuplicateID(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.manualRevisionNegative(let a1, let a2), .manualRevisionNegative(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.lastUserActivityBeforeStart(let a), .lastUserActivityBeforeStart(let b)): return a == b
        case (.lastStateChangeBeforeStart(let a), .lastStateChangeBeforeStart(let b)): return a == b
        case (.duplicateProjectID(let a), .duplicateProjectID(let b)): return a == b
        case (.projectEmptyProjectDisplayName(let a), .projectEmptyProjectDisplayName(let b)): return a == b
        case (.staleProjectReference(let a), .staleProjectReference(let b)): return a == b
        case (.projectRegistryRedirectCycle, .projectRegistryRedirectCycle): return true
        case (.projectRegistryRedirectToSelf, .projectRegistryRedirectToSelf): return true
        case (.projectRedirectSourceNotInRegistry(let a), .projectRedirectSourceNotInRegistry(let b)): return a == b
        case (.projectRedirectTargetNotInRegistry(let a), .projectRedirectTargetNotInRegistry(let b)): return a == b
        case (.configVersionRegression(let a1, let a2), .configVersionRegression(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.configPayloadDecodeFailed, .configPayloadDecodeFailed): return true
        case (.configVersionMarkerMismatch, .configVersionMarkerMismatch): return true
        case (.focusCountMismatch(let a1, let a2, let a3), .focusCountMismatch(let b1, let b2, let b3)): return a1 == b1 && a2 == b2 && a3 == b3
        case (.contributionSessionIDCountMismatch(let a), .contributionSessionIDCountMismatch(let b)): return a == b
        case (.goalConsistencyViolation(let a), .goalConsistencyViolation(let b)): return a == b
        case (.weekFocusDurationMismatch(let a), .weekFocusDurationMismatch(let b)): return a == b
        case (.snapshotRevisionRegression(let a1, let a2), .snapshotRevisionRegression(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.snapshotDayIdentifierMismatch(let a1, let a2), .snapshotDayIdentifierMismatch(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.snapshotFocusSessionDayMismatch(let a1, let a2), .snapshotFocusSessionDayMismatch(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.snapshotHistoryDayMismatch(let a1, let a2), .snapshotHistoryDayMismatch(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.snapshotFieldMissing(let a), .snapshotFieldMissing(let b)): return a == b
        case (.snapshotSchemaVersionMismatch, .snapshotSchemaVersionMismatch): return true
        case (.focusCountNegative(let a1, let a2), .focusCountNegative(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.completionCountNegative(let a1, let a2), .completionCountNegative(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.dayIdentifierRollback(let a1, let a2), .dayIdentifierRollback(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.unknown(let a), .unknown(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Sendable

extension TinyBuddyDataInvariantKind: Sendable {}

// MARK: - Repair Action

/// Action taken (or needed) to address a violation.
public enum TinyBuddyDataRepairAction: String, Codable, Equatable, Sendable {
    /// Violation requires no repair (informational / warning only)
    case none
    /// The affected record was removed from the active set and placed in quarantine
    case isolated
    /// Derived statistics were regenerated from authoritative source data
    case regenerated
    /// The record was repaired in-place (e.g. truncated, clamped, filled)
    case repaired
    /// Original corrupt data was preserved for diagnostics; no automatic repair possible
    case preserved
    /// An existing repair was skipped because it was already applied (idempotent)
    case skippedAlreadyApplied

    public var identifier: String { rawValue }
}

// MARK: - Violation

/// One detected invariant violation with enough context for targeted repair.
public struct TinyBuddyDataInvariantViolation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let domain: TinyBuddyDataDomain
    public let kind: TinyBuddyDataInvariantKind
    public let severity: TinyBuddyDataInvariantSeverity
    public let description: String
    /// Affected record IDs (session UUIDs, project IDs, etc.)
    public let affectedIdentifiers: [String]
    /// Stable redacted diagnostic key for aggregation (no user data)
    public let diagnosticKey: String
    /// Timestamp of detection
    public let detectedAt: Date
    /// Candidate repair action determined at detection time
    public let suggestedRepair: TinyBuddyDataRepairAction

    public init(
        id: UUID = UUID(),
        domain: TinyBuddyDataDomain,
        kind: TinyBuddyDataInvariantKind,
        severity: TinyBuddyDataInvariantSeverity,
        description: String,
        affectedIdentifiers: [String] = [],
        detectedAt: Date = Date(),
        suggestedRepair: TinyBuddyDataRepairAction = .none
    ) {
        self.id = id
        self.domain = domain
        self.kind = kind
        self.severity = severity
        self.description = description
        self.affectedIdentifiers = affectedIdentifiers
        self.diagnosticKey = "invariant.\(domain.identifier).\(kind.diagnosticSuffix)"
        self.detectedAt = detectedAt
        self.suggestedRepair = suggestedRepair
    }
}

// MARK: - Repair Result

/// Outcome of a repair attempt for one violation.
public struct TinyBuddyDataRepairResult: Codable, Equatable, Sendable {
    public let violationID: UUID
    public let action: TinyBuddyDataRepairAction
    /// Whether the repaired data was verified after repair
    public let verifiedAfterRepair: Bool
    /// Diagnostics string (redacted) — stable key for aggregation
    public let diagnosticKey: String
    /// One or more quarantine entry IDs if records were isolated
    public let quarantineEntryIDs: [UUID]
    /// Human-readable summary of what was done
    public let summary: String

    public init(
        violationID: UUID,
        action: TinyBuddyDataRepairAction,
        verifiedAfterRepair: Bool = false,
        diagnosticKey: String,
        quarantineEntryIDs: [UUID] = [],
        summary: String
    ) {
        self.violationID = violationID
        self.action = action
        self.verifiedAfterRepair = verifiedAfterRepair
        self.diagnosticKey = diagnosticKey
        self.quarantineEntryIDs = quarantineEntryIDs
        self.summary = summary
    }
}

// MARK: - Repair Session

/// A single repair session — tracks all violations detected and all repairs performed.
/// Idempotent: the session's `id` is stable so repeated repair with the same input
/// produces identical results.
public struct TinyBuddyDataRepairSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let violations: [TinyBuddyDataInvariantViolation]
    public let results: [TinyBuddyDataRepairResult]
    /// Whether the entire session completed without interruption
    public let didComplete: Bool
    /// Input checkpoint hash — changes when input data changes
    public let inputHash: String
    /// Whether any actual repair was performed (vs. no violations found)
    public let didPerformRepair: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        violations: [TinyBuddyDataInvariantViolation] = [],
        results: [TinyBuddyDataRepairResult] = [],
        didComplete: Bool = false,
        inputHash: String = "",
        didPerformRepair: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.violations = violations
        self.results = results
        self.didComplete = didComplete
        self.inputHash = inputHash
        self.didPerformRepair = didPerformRepair
    }
}

// MARK: - Quarantine Entry

/// A corrupted record that could not be safely auto-repaired. It is removed from
/// the active data set and stored here with its original content and diagnostics.
public struct TinyBuddyCorruptedRecordEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let domain: TinyBuddyDataDomain
    /// The violation kind that caused quarantine
    public let violationKind: TinyBuddyDataInvariantKind
    /// Original raw data, redacted for safe diagnostics
    public let redactedOriginalData: String
    /// Stable diagnostic key (no user data)
    public let diagnosticKey: String
    public let isolatedAt: Date

    public init(
        id: UUID = UUID(),
        domain: TinyBuddyDataDomain,
        violationKind: TinyBuddyDataInvariantKind,
        redactedOriginalData: String,
        diagnosticKey: String,
        isolatedAt: Date = Date()
    ) {
        self.id = id
        self.domain = domain
        self.violationKind = violationKind
        self.redactedOriginalData = redactedOriginalData
        self.diagnosticKey = diagnosticKey
        self.isolatedAt = isolatedAt
    }
}

// MARK: - Diagnostic Suffix

extension TinyBuddyDataInvariantKind {
    /// Stable diagnostic suffix for aggregation. Never contains user data.
    var diagnosticSuffix: String {
        switch self {
        case .duplicateSessionID: return "duplicate_session_id"
        case .sessionTimeOverlap: return "session_time_overlap"
        case .negativeDuration: return "negative_duration"
        case .futureStartedAt: return "future_started_at"
        case .missingEndedAt: return "missing_ended_at"
        case .statusEndedWithoutEndedAt: return "status_ended_no_ended_at"
        case .statusActiveWithEndedAt: return "status_active_with_ended_at"
        case .invalidDayIdentifier: return "invalid_day_identifier"
        case .emptyProjectKey: return "empty_project_key"
        case .sessionEmptyProjectDisplayName: return "session_empty_project_display_name"
        case .pausedTotalExceedsGross: return "paused_total_exceeds_gross"
        case .currentPauseNotNilForActive: return "current_pause_active"
        case .currentPauseNotNilForEnded: return "current_pause_ended"
        case .decisionEventDuplicateID: return "decision_event_duplicate"
        case .manualRevisionNegative: return "manual_revision_negative"
        case .lastUserActivityBeforeStart: return "last_activity_before_start"
        case .lastStateChangeBeforeStart: return "last_state_change_before_start"
        case .duplicateProjectID: return "duplicate_project_id"
        case .projectEmptyProjectDisplayName: return "project_empty_display_name"
        case .staleProjectReference: return "stale_project_reference"
        case .projectRegistryRedirectCycle: return "registry_redirect_cycle"
        case .projectRegistryRedirectToSelf: return "registry_redirect_to_self"
        case .projectRedirectSourceNotInRegistry: return "redirect_source_not_in_registry"
        case .projectRedirectTargetNotInRegistry: return "redirect_target_not_in_registry"
        case .configVersionRegression: return "config_version_regression"
        case .configPayloadDecodeFailed: return "config_payload_decode_failed"
        case .configVersionMarkerMismatch: return "config_version_marker_mismatch"
        case .focusCountMismatch: return "focus_count_mismatch"
        case .contributionSessionIDCountMismatch: return "contribution_id_count_mismatch"
        case .goalConsistencyViolation: return "goal_consistency_violation"
        case .weekFocusDurationMismatch: return "week_focus_duration_mismatch"
        case .snapshotRevisionRegression: return "snapshot_revision_regression"
        case .snapshotDayIdentifierMismatch: return "snapshot_day_mismatch"
        case .snapshotFocusSessionDayMismatch: return "snapshot_focus_session_day_mismatch"
        case .snapshotHistoryDayMismatch: return "snapshot_history_day_mismatch"
        case .snapshotFieldMissing: return "snapshot_field_missing"
        case .snapshotSchemaVersionMismatch: return "snapshot_schema_version_mismatch"
        case .focusCountNegative: return "focus_count_negative"
        case .completionCountNegative: return "completion_count_negative"
        case .dayIdentifierRollback: return "day_identifier_rollback"
        case .unknown: return "unknown"
        }
    }
}
