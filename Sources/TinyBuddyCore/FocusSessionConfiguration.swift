import Foundation

/// Tunable thresholds for focus-session determination. Defaults target a macOS
/// desktop coding session; they can be shrunk for tests.
public struct FocusSessionConfiguration: Equatable, Sendable {
    /// Continuous user-idle time that auto-pauses the running session.
    public var idleThreshold: TimeInterval
    /// If the user returns to the original project within this window, the away
    /// interval is treated as a brief interruption (excluded) instead of a new session.
    public var briefInterruptionThreshold: TimeInterval
    /// Absence longer than this ends the session (used for long idle / lock / sleep).
    public var longAbsenceThreshold: TimeInterval
    /// Optional hard cap on a single session span (safety only). `nil` disables it.
    public var maxSessionSpan: TimeInterval?
    /// Tolerance for same-day comparisons / minor clock jitter.
    public var dayBoundaryTolerance: TimeInterval
    /// Automatic-session confirmation window: activity events for one project
    /// accumulate only within this span. A longer gap (or a switch to another
    /// project) resets the accumulation, so a fast A→B→A round trip never
    /// accumulates across projects into a session.
    public var confirmationWindow: TimeInterval
    /// Cumulative active time within `confirmationWindow` that must accumulate
    /// before an automatic session may start. Values ≤ 0 confirm on the first
    /// activity event (legacy immediate-start behavior).
    public var confirmationMinimumActiveDuration: TimeInterval

    public init(
        idleThreshold: TimeInterval = 120,
        briefInterruptionThreshold: TimeInterval = 60,
        longAbsenceThreshold: TimeInterval = 600,
        maxSessionSpan: TimeInterval? = nil,
        dayBoundaryTolerance: TimeInterval = 1,
        confirmationWindow: TimeInterval = 1800,
        confirmationMinimumActiveDuration: TimeInterval = 120
    ) {
        self.idleThreshold = idleThreshold
        self.briefInterruptionThreshold = briefInterruptionThreshold
        self.longAbsenceThreshold = longAbsenceThreshold
        self.maxSessionSpan = maxSessionSpan
        self.dayBoundaryTolerance = dayBoundaryTolerance
        self.confirmationWindow = confirmationWindow
        self.confirmationMinimumActiveDuration = confirmationMinimumActiveDuration
    }
}
