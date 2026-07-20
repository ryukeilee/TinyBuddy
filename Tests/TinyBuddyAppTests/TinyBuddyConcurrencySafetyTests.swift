import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

// MARK: - TinyBuddyDebugLogManager Concurrency Safety (non-MainActor, Sendable type)

final class TinyBuddyDebugLogManagerConcurrencyTests: XCTestCase {
    /// Verifies that concurrent enable/write/disable cycles do not crash
    /// or produce unexpected state. The manager uses NSLock for synchronization
    /// and is marked @unchecked Sendable.
    func testConcurrentEnableWriteDisableIsSafe() {
        let manager = TinyBuddyDebugLogManager.shared
        let group = DispatchGroup()
        let iterationCount = 50

        for _ in 0..<iterationCount {
            group.enter()
            DispatchQueue.global().async {
                let expiration = Date().addingTimeInterval(3600)
                manager.enable(expiration: expiration)
                manager.write("concurrent test message")
                manager.disable()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success,
                       "concurrent enable/write/disable should complete without timeout")
        XCTAssertFalse(manager.isActive,
                       "manager should be inactive after all concurrent disables")
    }

    /// Verifies that concurrent reads of `isActive` do not crash.
    func testConcurrentIsActiveReadIsSafe() {
        let manager = TinyBuddyDebugLogManager.shared
        let group = DispatchGroup()
        let iterationCount = 100

        manager.enable(expiration: Date().addingTimeInterval(3600))

        for _ in 0..<iterationCount {
            group.enter()
            DispatchQueue.global().async {
                _ = manager.isActive
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        manager.disable()
    }

    /// Verifies that the Configuration type is Sendable by sending it across
    /// a Task boundary at runtime.
    func testConfigurationIsSendable() {
        let config = TinyBuddyDebugLogManager.Configuration()
        let configSent = expectation(description: "configuration sent across actor boundary")

        Task {
            let captured = config
            let (maxAge, totalBytes) = (captured.maxLogAge, captured.maxTotalBytes)
            XCTAssertGreaterThan(maxAge, 0)
            XCTAssertGreaterThan(totalBytes, 0)
            configSent.fulfill()
        }

        wait(for: [configSent], timeout: 1)
    }
}

/// Thread-safe collector for values accumulated across concurrent DispatchQueue
/// blocks. Uses NSLock internally and is explicitly Sendable.
private final class LockedSummaryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TinyBuddyHiddenSnapshotDiagnosticSummary?] = []

    func append(_ value: TinyBuddyHiddenSnapshotDiagnosticSummary?) {
        lock.withLock { _values.append(value) }
    }

    var values: [TinyBuddyHiddenSnapshotDiagnosticSummary?] {
        lock.withLock { _values }
    }
}

// MARK: - TinyBuddySharedSnapshotDiagnosticRecorder Concurrency Safety (non-MainActor, @unchecked Sendable)

final class TinyBuddySharedSnapshotDiagnosticRecorderConcurrencyTests: XCTestCase {
    /// Verifies that the shared diagnostic recorder handles concurrent
    /// `record` and `latestSummary` accesses without crashing.
    func testConcurrentRecordAndReadIsSafe() {
        let recorder = TinyBuddySharedSnapshotDiagnosticRecorder()
        let group = DispatchGroup()
        let iterationCount = 100

        // Thread-safe collector to avoid capturing a mutable local var.
        let collector = LockedSummaryCollector()

        for i in 0..<iterationCount {
            group.enter()
            DispatchQueue.global().async {
                let observation = TinyBuddySharedSnapshotObservation(
                    phase: .snapshotWrite,
                    reason: .appGroupUnavailable,
                    recovery: .stopped,
                    attemptCount: i
                )
                recorder.record(observation)
                group.leave()
            }

            group.enter()
            DispatchQueue.global().async {
                let summary = recorder.latestSummary
                collector.append(summary)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let latestAttemptCounts = collector.values.compactMap { $0?.attemptCount }
        XCTAssertFalse(latestAttemptCounts.isEmpty,
                       "at least one concurrent read should succeed")
    }
}

// MARK: - TinyBuddyPowerStateMonitor Lifecycle Safety (@MainActor)

@MainActor
final class TinyBuddyPowerStateMonitorConcurrencyTests: XCTestCase {
    /// Verifies that starting and stopping the power state monitor does not
    /// crash and properly cleans up notification observers.
    /// Note: `start()` synchronously fires `publishCurrentState(force: true)`
    /// so the event handler is called exactly once during start.
    func testStartStopDoesNotCrash() {
        var eventCallCount = 0
        let eventCalled = expectation(description: "event handler called on start")

        let monitor = TinyBuddyPowerStateMonitor(
            notificationCenter: NotificationCenter(),
            stateProvider: {
                TinyBuddyPowerState(isOnBatteryPower: false, isLowPowerModeEnabled: false)
            },
            scheduler: { $0() },
            eventHandler: { _ in
                eventCallCount += 1
                if eventCallCount == 1 {
                    eventCalled.fulfill()
                }
            }
        )

        // Start twice should be idempotent (no crash). First start fires
        // publishCurrentState(force: true).
        monitor.start()
        XCTAssertEqual(monitor.observerCount, 1,
                       "observer should be registered after start")
        monitor.start()

        // Stop twice should be idempotent (no crash).
        monitor.stop()
        XCTAssertEqual(monitor.observerCount, 0,
                       "observer should be removed after stop")
        monitor.stop()

        // Restart should fire the event handler again.
        monitor.start()
        XCTAssertEqual(monitor.observerCount, 1,
                       "observer should be re-registered on restart")
        monitor.stop()
        XCTAssertEqual(monitor.observerCount, 0,
                       "observer should be removed after second stop")

        waitForExpectations(timeout: 0.5)
    }
}

// MARK: - TimeEnvironmentChangeMonitor Lifecycle Safety (@MainActor)

@MainActor
final class TimeEnvironmentChangeMonitorConcurrencyTests: XCTestCase {
    /// Verifies that the generic time environment monitor starts and stops
    /// without crashing and properly cleans up observers.
    func testStartStopIsIdempotent() {
        let monitor = TimeEnvironmentChangeMonitor<String>(
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter(),
            capture: { "test" },
            scheduler: { $0() },
            eventHandler: { _ in }
        )

        // Start twice.
        monitor.start()
        monitor.start()

        // Stop twice.
        monitor.stop()
        monitor.stop()

        XCTAssertEqual(monitor.observerCount, 0,
                       "all observers should be removed after stop")
    }
}

// MARK: - HUDVisibilityMonitor Lifecycle Safety (@MainActor)

@MainActor
final class HUDVisibilityMonitorConcurrencyTests: XCTestCase {
    /// Verifies that starting and stopping the HUD visibility monitor is safe
    /// and properly cleans up all observers.
    func testStartStopCleansUpObservers() {
        let monitor = HUDVisibilityMonitor(
            notificationCenter: NotificationCenter(),
            visibilityProvider: { true },
            scheduler: { $0() },
            eventHandler: { _ in }
        )

        monitor.start()
        XCTAssertGreaterThan(monitor.observerCount, 0,
                             "observers should be registered after start")

        monitor.stop()
        XCTAssertEqual(monitor.observerCount, 0,
                       "all observers should be removed after stop")
    }
}
