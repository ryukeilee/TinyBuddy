import Foundation
import XCTest
@testable import TinyBuddyCore

private final class SustainedFocusClock: FocusClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) {
        self.instant = instant
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return instant
    }

    var monotonic: TimeInterval {
        now.timeIntervalSinceReferenceDate
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        instant = instant.addingTimeInterval(seconds)
    }
}

private final class SustainedFocusSessionStore: FocusSessionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [FocusSession]?
    private(set) var saveCount = 0

    func load() -> [FocusSession]? {
        lock.lock(); defer { lock.unlock() }
        return sessions
    }

    func save(_ sessions: [FocusSession]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        saveCount += 1
        self.sessions = sessions
        return true
    }
}

/// Counts combined-snapshot `writeValue` calls, each of which invokes `UserDefaults.set`.
/// This measures key writes, not lower-level disk flushes or fsync operations.
private final class SharedSnapshotWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var writes = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func write(_ value: Any, forKey key: String) -> Bool {
        defaults.set(value, forKey: key)
        lock.lock(); defer { lock.unlock() }
        writes += 1
        return defaults.object(forKey: key) != nil
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
}

private final class SustainedFocusMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private let combinedStore: TinyBuddyCombinedSnapshotStore
    private let fallbackSnapshot: TinyBuddySnapshot
    private var sameProjectApplyPasses = 0
    private var livePublicationRequests = 0
    private var sharedSnapshotWriteRequests = 0
    private var persistedSnapshots = 0

    init(combinedStore: TinyBuddyCombinedSnapshotStore, fallbackSnapshot: TinyBuddySnapshot) {
        self.combinedStore = combinedStore
        self.fallbackSnapshot = fallbackSnapshot
    }

    func recordApplyPass() {
        lock.lock(); defer { lock.unlock() }
        sameProjectApplyPasses += 1
    }

    func publish(_ publication: FocusHistoryPublication, isLive: Bool) {
        lock.lock()
        sharedSnapshotWriteRequests += 1
        if isLive { livePublicationRequests += 1 }
        lock.unlock()

        let result = combinedStore.updateFocusHistorySlice(
            publication,
            fallbackSnapshot: fallbackSnapshot
        )
        if result.didPersist {
            lock.lock(); defer { lock.unlock() }
            persistedSnapshots += 1
        }
    }

    func resetInterval() {
        lock.lock(); defer { lock.unlock() }
        sameProjectApplyPasses = 0
        livePublicationRequests = 0
        sharedSnapshotWriteRequests = 0
        persistedSnapshots = 0
    }

    func values() -> (applyPasses: Int, liveRequests: Int, writeRequests: Int, persisted: Int) {
        lock.lock(); defer { lock.unlock() }
        return (sameProjectApplyPasses, livePublicationRequests, sharedSnapshotWriteRequests, persistedSnapshots)
    }
}

final class SustainedFocusPersistenceBenchmarkTests: XCTestCase {
    @MainActor
    func testTwoHourStableFocusHasReproducibleBeforeAndAfterCounters() throws {
        let baselineMode = ProcessInfo.processInfo.environment["TINYBUDDY_FOCUS_BENCHMARK_MODE"] == "baseline"
        let day = "2025-06-03"
        let start = ISO8601DateFormatter().date(from: "2025-06-03T09:00:00Z")!
        let clock = SustainedFocusClock(start)
        let sessionStore = SustainedFocusSessionStore()
        let defaultsName = "TinyBuddySustainedFocusBenchmark-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let preferenceKeySetCalls = SharedSnapshotWriteCounter(defaults: defaults)
        let combinedStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false,
            writeValue: { value, key in preferenceKeySetCalls.write(value, forKey: key) },
            synchronizeWrites: { true }
        )
        let fallback = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: day, focusCount: 0, completionCount: 0)
        )
        let measurement = SustainedFocusMeasurement(
            combinedStore: combinedStore,
            fallbackSnapshot: fallback
        )
        let project = FocusProjectContext(key: "com.example.editor", displayName: "Editor")
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: sessionStore,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { _ in day }
        )
        engine.committedHistorySnapshotHandler = { publication in
            measurement.publish(publication, isLive: false)
        }
        engine.liveMinuteRepublishHandler = { publication in
            measurement.publish(publication, isLive: true)
        }
#if DEBUG
        engine.sustainedActivityApplyObserver = { measurement.recordApplyPass() }
#endif
        let coordinator = FocusSessionCoordinator(engine: engine, clock: clock)
        coordinator.reportForegroundApp(
            bundleID: project.key,
            displayName: project.displayName,
            isCodeEditor: false,
            at: start
        )
        coordinator.reportUserInput(at: start)
        XCTAssertTrue(engine.isFocusSessionActive)
        XCTAssertEqual(preferenceKeySetCalls.count > 0, true, "The semantic session start must persist immediately")
        let startSnapshotKeySetCalls = preferenceKeySetCalls.count
        let startSessionJournalWrites = sessionStore.saveCount

        // Mirror the old bridge's initial whole-minute seed, then measure only
        // its stable two-hour polling interval. This path was removed from the
        // production bridge; retaining it here makes the pre-change comparator
        // explicit and reproducible without wall-clock sleeps or app installs.
        var lastPublishedMinute: Int? = nil
        if baselineMode {
            let minute = max(0, Int(engine.focusDurationToday() / 60))
            if minute != lastPublishedMinute {
                lastPublishedMinute = minute
                engine.republishFocusHistory(shouldReloadWidget: false)
            }
        }
        measurement.resetInterval()
        let keySetCallsBeforeInterval = preferenceKeySetCalls.count

        var pollEvents = 0
        var reminderEvaluationOpportunities = 0
        for _ in 0 ..< 480 {
            clock.advance(by: 15)
            pollEvents += 1
            coordinator.reportSustainedActivity(at: clock.now)
            reminderEvaluationOpportunities += 1

            if baselineMode {
                let minute = max(0, Int(engine.focusDurationToday() / 60))
                if minute != lastPublishedMinute {
                    lastPublishedMinute = minute
                    engine.republishFocusHistory(shouldReloadWidget: false)
                }
            }
        }

        let values = measurement.values()
        let intervalPreferenceKeySetCalls = preferenceKeySetCalls.count - keySetCallsBeforeInterval
        let expectedNoOpApplyPasses = baselineMode ? 480 : 0
        let expectedMinuteWrites = baselineMode ? 120 : 0
        XCTAssertEqual(pollEvents, 480)
        XCTAssertEqual(reminderEvaluationOpportunities, 480)
        XCTAssertEqual(values.applyPasses, expectedNoOpApplyPasses)
        XCTAssertEqual(values.liveRequests, expectedMinuteWrites)
        XCTAssertEqual(values.writeRequests, expectedMinuteWrites)
        XCTAssertEqual(values.persisted, expectedMinuteWrites)
        if baselineMode {
            XCTAssertGreaterThan(intervalPreferenceKeySetCalls, 0)
        } else {
            XCTAssertEqual(intervalPreferenceKeySetCalls, 0)
        }
        XCTAssertEqual(startSessionJournalWrites, 1)
        XCTAssertGreaterThan(startSnapshotKeySetCalls, 0)

        print(
            "SUSTAINED_FOCUS_METRICS mode=\(baselineMode ? "baseline-0689e1e" : "optimized-\(gitRevisionHint())") " +
            "simulated_seconds=7200 poll_events=\(pollEvents) " +
            "reminder_evaluation_opportunities=\(reminderEvaluationOpportunities) " +
            "same_project_apply_validation_passes=\(values.applyPasses) " +
            "live_publication_requests=\(values.liveRequests) shared_snapshot_write_requests=\(values.writeRequests) " +
            "store_persistence_commits=\(values.persisted) " +
            "combined_snapshot_preference_key_set_calls=\(intervalPreferenceKeySetCalls) " +
            "session_start_journal_writes=\(startSessionJournalWrites) " +
            "start_snapshot_preference_key_set_calls=\(startSnapshotKeySetCalls)"
        )
    }

    private func gitRevisionHint() -> String {
        ProcessInfo.processInfo.environment["TINYBUDDY_FOCUS_BENCHMARK_REVISION"] ?? "current"
    }
}
