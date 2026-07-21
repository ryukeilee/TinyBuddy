import Foundation

/// A project a focus session can be attributed to.
/// `key` is the canonical identity (e.g. Git common-dir path or foreground app bundle id);
/// `displayName` is a human-readable, redacted-safe label.
public struct FocusProjectContext: Equatable, Hashable, Codable, Sendable {
    public let key: String
    public let displayName: String

    public init(key: String, displayName: String) {
        self.key = key
        self.displayName = displayName
    }
}

public enum FocusSessionStatus: String, Codable, Equatable, Sendable {
    case active
    case paused
    case ended
}

/// How a focus session was initiated. Manual sessions take priority over
/// automatic detection; during a manual session the engine must not create
/// parallel records, switch projects, or end sessions from automatic triggers.
public enum FocusMode: String, Codable, Equatable, Sendable {
    case automatic
    case manual
}

/// The live state of manual focus control, published to all UI surfaces.
public enum ManualFocusControlState: Equatable, Sendable {
    /// No manual focus session; auto-detection can freely start sessions.
    case idle
    /// A manual session is active and counting time.
    case focusing(project: FocusProjectContext, startedAt: Date, activeDuration: TimeInterval)
    /// A manual session is paused; time is not accumulating.
    case paused(project: FocusProjectContext, startedAt: Date, pausedAt: Date, activeDuration: TimeInterval)
}

extension ManualFocusControlState {
    public var project: FocusProjectContext? {
        switch self {
        case .idle: return nil
        case .focusing(let p, _, _): return p
        case .paused(let p, _, _, _): return p
        }
    }

    public var isManualSessionActive: Bool {
        if case .focusing = self { return true }
        return false
    }

    public var isManualSessionPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

/// Stable, privacy-safe authority classes for a recorded decision. The enum
/// deliberately carries no captured input, path, repository URL, or commit
/// text. Later cases have higher authority when a session is reviewed.
public enum FocusSessionDecisionSource: String, Codable, Equatable, Sendable {
    case automatic
    case userConfirmed
    case manualCorrection
}

/// The lifecycle fact that changed. Project values are intentionally omitted:
/// the session's current presentation-safe project label is the only project
/// detail retained by this trail.
public enum FocusSessionDecisionKind: String, Codable, Equatable, Sendable {
    case started
    case paused
    case resumed
    case ended
    case projectChanged
    case confirmed
    case corrected
    case split
    case merged
    case undo
}

/// Minimal reason vocabulary used by the history UI. These values describe
/// why a transition happened without retaining the underlying sensitive data.
public enum FocusSessionDecisionReason: String, Codable, Equatable, Sendable {
    case userActivity
    case gitActivity
    case idle
    case lockScreen
    case systemSleep
    case projectSwitch
    case dayBoundary
    case appTermination
    case crashRecovery
    case manualConfirmation
    case manualCorrection
    case manualSplit
    case manualMerge
    case undo
}

public struct FocusSessionDecisionEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    public let kind: FocusSessionDecisionKind
    public let reason: FocusSessionDecisionReason
    public let source: FocusSessionDecisionSource

    public init(
        id: UUID = UUID(),
        at: Date,
        kind: FocusSessionDecisionKind,
        reason: FocusSessionDecisionReason,
        source: FocusSessionDecisionSource
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.reason = reason
        self.source = source
    }
}

/// A single contiguous focus effort attributed to one project within one local day.
/// Time that must not count (idle, lock/sleep, brief interruptions) is tracked separately
/// and excluded from `activeDuration`, so durations are never duplicated, negative, or
/// backfilled across offline gaps.
public struct FocusSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var project: FocusProjectContext
    public var dayIdentifier: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: FocusSessionStatus
    public var lastUserActivityAt: Date
    public var lastStateChangeAt: Date

    /// Completed (already closed) paused intervals, excluded from duration.
    public var pausedTotal: TimeInterval
    /// An open pause that is currently excluding time, or `nil` when running.
    public var currentPauseStartedAt: Date?
    /// A user-confirmed record is immutable to automatic attribution. Automatic
    /// activity may start a later session, but must never rewrite this one.
    public var isManuallyConfirmed: Bool
    /// Monotonic revision of the last user-confirmed edit. Optional preserves
    /// compatibility with pre-review session journals.
    public var manualRevision: Int64?
    /// `nil` means the row predates source tracking. It must remain explicitly
    /// historical rather than being reconstructed from present-day state.
    public var decisionEvents: [FocusSessionDecisionEvent]?
    /// How this session was initiated. Manual sessions cannot be mutated by
    /// automatic detection and must use the explicit manual-control API.
    /// Defaults to `.automatic` for legacy records.
    public var mode: FocusMode

    private enum CodingKeys: String, CodingKey {
        case id, project, dayIdentifier, startedAt, endedAt, status
        case lastUserActivityAt, lastStateChangeAt, pausedTotal, currentPauseStartedAt
        case isManuallyConfirmed, manualRevision, decisionEvents, mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        project = try container.decode(FocusProjectContext.self, forKey: .project)
        dayIdentifier = try container.decode(String.self, forKey: .dayIdentifier)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        status = try container.decode(FocusSessionStatus.self, forKey: .status)
        lastUserActivityAt = try container.decode(Date.self, forKey: .lastUserActivityAt)
        lastStateChangeAt = try container.decode(Date.self, forKey: .lastStateChangeAt)
        pausedTotal = try container.decode(TimeInterval.self, forKey: .pausedTotal)
        currentPauseStartedAt = try container.decodeIfPresent(Date.self, forKey: .currentPauseStartedAt)
        isManuallyConfirmed = try container.decode(Bool.self, forKey: .isManuallyConfirmed)
        manualRevision = try container.decodeIfPresent(Int64.self, forKey: .manualRevision)
        decisionEvents = try container.decodeIfPresent([FocusSessionDecisionEvent].self, forKey: .decisionEvents)
        mode = try container.decodeIfPresent(FocusMode.self, forKey: .mode) ?? .automatic
    }

    public init(
        id: UUID = UUID(),
        project: FocusProjectContext,
        dayIdentifier: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: FocusSessionStatus,
        lastUserActivityAt: Date,
        lastStateChangeAt: Date,
        pausedTotal: TimeInterval = 0,
        currentPauseStartedAt: Date? = nil,
        isManuallyConfirmed: Bool = false,
        manualRevision: Int64? = nil,
        decisionEvents: [FocusSessionDecisionEvent]? = nil,
        mode: FocusMode = .automatic
    ) {
        self.id = id
        self.project = project
        self.dayIdentifier = dayIdentifier
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.lastUserActivityAt = lastUserActivityAt
        self.lastStateChangeAt = lastStateChangeAt
        self.pausedTotal = pausedTotal
        self.currentPauseStartedAt = currentPauseStartedAt
        self.isManuallyConfirmed = isManuallyConfirmed
        self.manualRevision = manualRevision
        self.decisionEvents = decisionEvents
        self.mode = mode
    }

    /// Time during which this session is NOT counting toward focus:
    /// all fully-closed pauses plus any currently-open pause (clamped to `now`/end).
    public func excludedTime(now: Date) -> TimeInterval {
        let end = endedAt ?? now
        var excluded = pausedTotal
        if let pauseStart = currentPauseStartedAt {
            let openEnd = max(pauseStart, min(now, end))
            excluded += openEnd.timeIntervalSince(pauseStart)
        }
        return excluded
    }

    /// The focus duration that actually counts, with idle/lock/interrupt gaps removed.
    /// Always non-negative; never includes time after the session ended or before it started.
    public func activeDuration(now: Date) -> TimeInterval {
        let end = endedAt ?? now
        guard end > startedAt else { return 0 }
        let gross = end.timeIntervalSince(startedAt)
        let excluded = min(excludedTime(now: now), gross)
        return max(0, gross - excluded)
    }

    public var isOpen: Bool {
        status != .ended && endedAt == nil
    }

    /// Highest durable authority represented by the source trail. Legacy rows
    /// return `nil`, which presentation renders as an unexplained historical
    /// record rather than inventing a cause.
    public var decisionAuthority: FocusSessionDecisionSource? {
        guard let decisionEvents else { return nil }
        if decisionEvents.contains(where: { $0.source == .manualCorrection }) {
            return .manualCorrection
        }
        if decisionEvents.contains(where: { $0.source == .userConfirmed }) {
            return .userConfirmed
        }
        return decisionEvents.isEmpty ? nil : .automatic
    }
}
