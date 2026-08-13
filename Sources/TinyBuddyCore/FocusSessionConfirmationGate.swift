import Foundation

/// Pure, deterministic confirmation gate for automatic focus session start.
///
/// The gate turns the activity event stream (project, timestamp) into a
/// confirmed / unconfirmed / reset decision without any I/O:
/// - Activity events for one project accumulate active time only within
///   `confirmationWindow`. A gap longer than the window, or an event for a
///   different project, discards the accumulation and starts fresh — a fast
///   A→B→A round trip never accumulates across projects into a session.
/// - `minimumActiveDuration` is the cumulative active time that must
///   accumulate before the gate confirms. Values ≤ 0 confirm on the first
///   event (legacy immediate-start behavior).
/// - The gate is in-memory only: a crash loses nothing but unconfirmed
///   candidates and can never leave a session remnant behind.
///
/// Automated background reports never reach the gate: the coordinator drops
/// `automated` Git activity before it enters the engine, so background
/// refreshes cannot create, revive, or switch sessions.
public struct FocusSessionConfirmationGate: Equatable, Sendable {
    /// The project currently accumulating activity, if any.
    public private(set) var trackedProjectKey: String?
    /// Timestamp of the first event of the current accumulation run.
    public private(set) var firstActivityAt: Date?
    /// Timestamp of the most recent event of the current accumulation run.
    public private(set) var lastActivityAt: Date?
    /// Cumulative active time accumulated for the tracked project within the
    /// window. Time between two events counts only while the run is live.
    public private(set) var accumulatedActiveTime: TimeInterval = 0

    public init() {}

    public var isTracking: Bool {
        trackedProjectKey != nil
    }

    /// Records one activity event for `project` at `date` and returns whether
    /// the reliable condition is now satisfied (confirmed).
    ///
    /// Deterministic: same event sequence always produces the same decision.
    public mutating func recordActivity(
        project: FocusProjectContext,
        at date: Date,
        window: TimeInterval,
        minimumActiveDuration: TimeInterval
    ) -> Bool {
        // A switch to a different project resets the accumulation: the old
        // candidate's progress must never carry over.
        guard trackedProjectKey == project.key else {
            startTracking(project, at: date)
            return isConfirmed(minimumActiveDuration: minimumActiveDuration)
        }
        guard let first = firstActivityAt,
              let last = lastActivityAt,
              date > first,
              date.timeIntervalSince(first) <= window else {
            // Window expired (or out-of-order event): restart the run.
            startTracking(project, at: date)
            return isConfirmed(minimumActiveDuration: minimumActiveDuration)
        }
        let gap = date > last ? date.timeIntervalSince(last) : 0
        accumulatedActiveTime += gap
        if date > last {
            lastActivityAt = date
        }
        return isConfirmed(minimumActiveDuration: minimumActiveDuration)
    }

    /// Discards all accumulation. Called when a session starts, ends, or a
    /// lifecycle boundary (lock, sleep, day change, manual takeover) resets
    /// automatic detection, so re-entry must re-satisfy the reliable condition.
    public mutating func reset() {
        trackedProjectKey = nil
        firstActivityAt = nil
        lastActivityAt = nil
        accumulatedActiveTime = 0
    }

    // MARK: - Private

    private mutating func startTracking(_ project: FocusProjectContext, at date: Date) {
        trackedProjectKey = project.key
        firstActivityAt = date
        lastActivityAt = date
        accumulatedActiveTime = 0
    }

    private func isConfirmed(minimumActiveDuration: TimeInterval) -> Bool {
        accumulatedActiveTime >= minimumActiveDuration
    }
}
