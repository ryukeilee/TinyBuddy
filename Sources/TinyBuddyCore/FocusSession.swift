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
        manualRevision: Int64? = nil
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
}
