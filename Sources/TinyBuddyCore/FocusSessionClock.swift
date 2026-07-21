import Foundation

/// Injected source of truth for time, making the engine fully deterministic in tests.
public protocol FocusClock: Sendable {
    var now: Date { get }
    var monotonic: TimeInterval { get }
}

/// Uses the system wall clock and uptime.  Safe for production use.
public struct SystemFocusClock: FocusClock {
    public init() {}
    public var now: Date { Date() }
    public var monotonic: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
