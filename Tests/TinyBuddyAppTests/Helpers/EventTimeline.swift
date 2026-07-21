import Foundation
import TinyBuddyCore

// MARK: - Event Timeline

/// Records a chronological timeline of key state transitions during
/// deterministic end-to-end tests. Supports fault injection debugging
/// by providing exact ordering of events, state snapshots, and
/// unresolved tasks at failure.
public final class EventTimeline: @unchecked Sendable {

    // MARK: Types

    /// A single recorded event with virtual time, category, and payload.
    public struct Event: Equatable, Sendable, CustomStringConvertible {
        public let timestamp: TimeInterval
        public let category: Category
        public let detail: String
        public let stateSnapshot: StateSnapshot?

        public var description: String {
            var parts = [String(format: "[T+%.3fs] %@", timestamp, category.rawValue)]
            if !detail.isEmpty {
                parts.append(detail)
            }
            if let snapshot = stateSnapshot {
                parts.append(snapshot.summary)
            }
            return parts.joined(separator: " | ")
        }
    }

    /// Event categories covering the complete refresh lifecycle.
    public enum Category: String, Equatable, Sendable {
        case lifecycleStarted = "LIFECYCLE_START"
        case lifecycleStopped = "LIFECYCLE_STOP"
        case refreshStarted = "REFRESH_START"
        case refreshCompleted = "REFRESH_COMPLETE"
        case scriptStarted = "SCRIPT_START"
        case scriptCompleted = "SCRIPT_COMPLETE"
        case scriptCancelled = "SCRIPT_CANCELLED"
        case scriptTimeout = "SCRIPT_TIMEOUT"
        case snapshotRead = "SNAPSHOT_READ"
        case snapshotWritten = "SNAPSHOT_WRITTEN"
        case snapshotWriteFailed = "SNAPSHOT_WRITE_FAILED"
        case widgetReloaded = "WIDGET_RELOADED"
        case statusChanged = "STATUS_CHANGED"
        case permissionChanged = "PERMISSION_CHANGED"
        case permissionRevoked = "PERMISSION_REVOKED"
        case repositoryChange = "REPOSITORY_CHANGE"
        case monitorStarted = "MONITOR_STARTED"
        case monitorStopped = "MONITOR_STOPPED"
        case dayBoundary = "DAY_BOUNDARY"
        case sleepWake = "SLEEP_WAKE"
        case powerStateChanged = "POWER_STATE_CHANGED"
        case faultInjected = "FAULT_INJECTED"
        case recoveryAttempt = "RECOVERY_ATTEMPT"
        case taskCancelled = "TASK_CANCELLED"
        case staleResultDiscarded = "STALE_RESULT_DISCARDED"
        case raceDetected = "RACE_DETECTED"
        case assertionFailed = "ASSERTION_FAILED"
        case error = "ERROR"
    }

    /// A point-in-time snapshot of key state.
    public struct StateSnapshot: Equatable, Sendable {
        public let dayIdentifier: String?
        public let refreshOutcome: String?
        public let focusBlockCount: Int?
        public let commitCount: Int?
        public let recentProjectName: String?
        public let isRefreshing: Bool
        public let scriptRunCount: Int
        public let widgetReloadCount: Int
        public let pendingTaskCount: Int

        public var summary: String {
            var parts: [String] = []
            parts.append("day=\(dayIdentifier ?? "nil")")
            parts.append("outcome=\(refreshOutcome ?? "nil")")
            parts.append("focus=\(focusBlockCount.map(String.init) ?? "nil")")
            parts.append("commits=\(commitCount.map(String.init) ?? "nil")")
            parts.append("refreshing=\(isRefreshing)")
            parts.append("scriptRuns=\(scriptRunCount)")
            parts.append("widgetReloads=\(widgetReloadCount)")
            parts.append("pending=\(pendingTaskCount)")
            return "{\(parts.joined(separator: ", "))}"
        }
    }

    // MARK: State

    private var events: [Event] = []
    private let lock = NSLock()
    private var startTime: TimeInterval = 0
    private var isRecording = false

    // MARK: Public API

    /// All recorded events in chronological order.
    public var allEvents: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// The number of recorded events.
    public var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    /// Events filtered by category.
    public func events(matching category: Category) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.category == category }
    }

    /// Events filtered by multiple categories.
    public func events(matching categories: Set<Category>) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { categories.contains($0.category) }
    }

    /// Start recording with the given reference time.
    public func startRecording(at referenceTime: TimeInterval = 0) {
        lock.lock()
        startTime = referenceTime
        events.removeAll()
        isRecording = true
        lock.unlock()
    }

    /// Stop recording.
    public func stopRecording() {
        lock.lock()
        isRecording = false
        lock.unlock()
    }

    /// Record an event at the current virtual time.
    public func record(
        at timestamp: TimeInterval,
        category: Category,
        detail: String = "",
        snapshot: StateSnapshot? = nil
    ) {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
        events.append(Event(
            timestamp: timestamp - startTime,
            category: category,
            detail: detail,
            stateSnapshot: snapshot
        ))
        lock.unlock()
    }

    /// Convenience: capture current state and record.
    public func capture(
        at timestamp: TimeInterval,
        category: Category,
        detail: String = "",
        dayIdentifier: String? = nil,
        refreshOutcome: String? = nil,
        focusBlockCount: Int? = nil,
        commitCount: Int? = nil,
        recentProjectName: String? = nil,
        isRefreshing: Bool = false,
        scriptRunCount: Int = 0,
        widgetReloadCount: Int = 0,
        pendingTaskCount: Int = 0
    ) {
        let snapshot = StateSnapshot(
            dayIdentifier: dayIdentifier,
            refreshOutcome: refreshOutcome,
            focusBlockCount: focusBlockCount,
            commitCount: commitCount,
            recentProjectName: recentProjectName,
            isRefreshing: isRefreshing,
            scriptRunCount: scriptRunCount,
            widgetReloadCount: widgetReloadCount,
            pendingTaskCount: pendingTaskCount
        )
        record(at: timestamp, category: category, detail: detail, snapshot: snapshot)
    }

    // MARK: Analysis

    /// Returns a chronological text representation of the timeline.
    public func timelineDescription() -> String {
        lock.lock()
        let events = self.events
        lock.unlock()

        guard !events.isEmpty else { return "(empty timeline)" }

        var lines: [String] = []
        lines.append("=== Event Timeline (\(events.count) events) ===")
        for event in events {
            lines.append(event.description)
        }
        lines.append("=== End Timeline ===")
        return lines.joined(separator: "\n")
    }

    /// Returns events that occurred between two timestamps.
    public func events(between start: TimeInterval, and end: TimeInterval) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.timestamp >= start && $0.timestamp <= end }
    }

    /// Verifies that events occurred in the expected category order.
    /// Returns the first mismatch or nil if the order is correct.
    public func verifyOrder(_ expectedCategories: [Category]) -> String? {
        lock.lock()
        let events = self.events
        lock.unlock()

        let actualCategories = events.map(\.category)
        var expectedIndex = 0
        for actual in actualCategories {
            if expectedIndex < expectedCategories.count,
               actual == expectedCategories[expectedIndex] {
                expectedIndex += 1
            }
        }
        if expectedIndex < expectedCategories.count {
            let missing = expectedCategories[expectedIndex...]
                .map(\.rawValue)
                .joined(separator: ", ")
            return "Missing expected events: \(missing)"
        }
        return nil
    }
}
