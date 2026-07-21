import XCTest
@testable import TinyBuddyCore

// MARK: - Fakes

final class FakeClock: FocusClock, @unchecked Sendable {
    var now: Date { _now }
    private var _now: Date
    let monotonic: TimeInterval

    init(_ date: Date) {
        _now = date
        monotonic = date.timeIntervalSinceReferenceDate
    }

    func advance(by seconds: TimeInterval) {
        _now = _now.addingTimeInterval(seconds)
    }

    func set(to date: Date) {
        _now = date
    }
}

final class MemoryStore: FocusSessionPersisting, @unchecked Sendable {
    var stored: [FocusSession]?
    var shouldFail = false
    var saveCount = 0
    var loadCount = 0

    func load() -> [FocusSession]? {
        loadCount += 1
        return stored
    }

    @discardableResult
    func save(_ sessions: [FocusSession]) -> Bool {
        saveCount += 1
        guard !shouldFail else { return false }
        stored = sessions
        return true
    }

    func reset() {
        stored = nil
        shouldFail = false
        saveCount = 0
        loadCount = 0
    }
}

final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var snapshots: [FocusSessionDerivedSnapshot] = []

    func append(_ snapshot: FocusSessionDerivedSnapshot) {
        lock.lock(); defer { lock.unlock() }
        snapshots.append(snapshot)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return snapshots.count
    }
}

// MARK: - Helpers

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000) // arbitrary reference
private let projectA = FocusProjectContext(key: "repo/a", displayName: "Project A")
private let projectB = FocusProjectContext(key: "repo/b", displayName: "Project B")
private let projectC = FocusProjectContext(key: "repo/c", displayName: "Project C")

private func dayIdentifier(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func makeEngine(
    clock: FakeClock,
    store: MemoryStore,
    config: FocusSessionConfiguration = FocusSessionConfiguration()
) -> FocusSessionEngine {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return FocusSessionEngine(
        clock: clock,
        persisting: store,
        config: config,
        dayIdentifier: { dayIdentifier(for: $0) },
        nextDayBoundary: { date in
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        }
    )
}

// MARK: - Tests

final class FocusSessionEngineTests: XCTestCase {
    var clock: FakeClock!
    var store: MemoryStore!

    override func setUp() {
        super.setUp()
        clock = FakeClock(t0)
        store = MemoryStore()
    }

    override func tearDown() {
        clock = nil
        store = nil
        super.tearDown()
    }
}

// MARK: - Basic lifecycle

extension FocusSessionEngineTests {
    func test_start_on_user_activity_creates_session() {
        let engine = makeEngine(clock: clock, store: store)
        let out = engine.userActivity(in: projectA, at: t0)
        XCTAssertEqual(out, .saved)

        XCTAssertEqual(engine.allSessions.count, 1)
        let s = engine.allSessions[0]
        XCTAssertEqual(s.project, projectA)
        XCTAssertEqual(s.status, .active)
        XCTAssertTrue(s.isOpen)
        XCTAssertEqual(s.lastUserActivityAt, t0)
        XCTAssertEqual(s.activeDuration(now: t0), 0) // no wall time passed
    }

    func test_user_activity_same_project_refreshes() {
        let engine = makeEngine(clock: clock, store: store)
        XCTAssertEqual(engine.userActivity(in: projectA, at: t0), .saved)

        clock.advance(by: 30)
        let out = engine.userActivity(in: projectA, at: clock.now)
        XCTAssertEqual(out, .saved)

        XCTAssertEqual(engine.allSessions.count, 1) // no duplicate session
        let s = engine.allSessions[0]
        XCTAssertTrue(s.isOpen)
        XCTAssertEqual(s.lastUserActivityAt, clock.now)
        // Duration should include the 30s (no idle pause)
        XCTAssertEqual(s.activeDuration(now: clock.now), 30, accuracy: 0.001)
    }

    func test_user_activity_nil_reuses_open_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 10)
        let out = engine.userActivity(in: nil, at: clock.now)
        XCTAssertEqual(out, .saved)
        XCTAssertEqual(engine.allSessions[0].lastUserActivityAt, clock.now)
    }

    func test_user_activity_nil_with_no_open_session_is_noop() {
        let engine = makeEngine(clock: clock, store: store)
        let out = engine.userActivity(in: nil, at: t0)
        XCTAssertEqual(out, .noChange)
        XCTAssertTrue(engine.allSessions.isEmpty)
    }
}

// MARK: - Idle

extension FocusSessionEngineTests {
    func test_idle_pauses_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        let out = engine.idleDetected(at: clock.now)
        XCTAssertEqual(out, .saved)

        let s = engine.allSessions[0]
        XCTAssertEqual(s.status, .paused)
        XCTAssertNotNil(s.currentPauseStartedAt)

        clock.advance(by: 60)
        // Duration counted only up to idle start (30s), not the 60s idle
        XCTAssertEqual(s.activeDuration(now: clock.now), 30, accuracy: 0.001)
    }

    func test_user_activity_resumes_idle_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        engine.idleDetected(at: clock.now)

        clock.advance(by: 60)
        engine.userActivity(in: projectA, at: clock.now)

        let s = engine.allSessions[0]
        XCTAssertEqual(s.status, .active)
        XCTAssertNil(s.currentPauseStartedAt)

        // gross = 90, excluded = 60 (idle), active = 30
        XCTAssertEqual(s.activeDuration(now: clock.now), 30, accuracy: 0.001)
    }

    func test_multiple_idle_pauses_accumulate() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 10)
        engine.idleDetected(at: clock.now)   // pause 1
        clock.advance(by: 20)
        engine.userActivity(in: projectA, at: clock.now) // resume
        clock.advance(by: 15)
        engine.idleDetected(at: clock.now)   // pause 2
        clock.advance(by: 25)
        // gross = 70, excluded = 20+25 = 45, active = 25
        XCTAssertEqual(engine.focusDurationToday(now: clock.now), 25, accuracy: 0.001)
    }

    func test_idle_when_already_paused_is_noop() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 10)
        engine.idleDetected(at: clock.now)
        let out = engine.idleDetected(at: clock.now) // already paused
        XCTAssertEqual(out, .noChange)
    }
}

// MARK: - Lock / Sleep / Terminate

extension FocusSessionEngineTests {
    func test_lock_ends_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        engine.lockScreen(at: clock.now)

        let s = engine.allSessions[0]
        XCTAssertEqual(s.status, .ended)
        XCTAssertNotNil(s.endedAt)
        XCTAssertEqual(s.endedAt, clock.now)
        // active = 30s (no idle)
        XCTAssertEqual(s.activeDuration(now: clock.now), 30, accuracy: 0.001)
    }

    func test_lock_with_prior_idle_ends_and_excludes_idle() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)  // t0
        clock.advance(by: 10)
        engine.idleDetected(at: clock.now) // t0+10 pause
        clock.advance(by: 20)
        engine.lockScreen(at: clock.now) // t0+30
        // gross = 30, excluded = 20 (idle t0+10..t0+30), active = 10
        let s = engine.allSessions[0]
        XCTAssertEqual(s.activeDuration(now: clock.now), 10, accuracy: 0.001)
    }

    func test_unlock_does_not_resume_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        engine.lockScreen(at: clock.now)
        engine.unlock(at: clock.now)
        XCTAssertNil(engine.currentProject)
    }

    func test_activity_after_unlock_starts_fresh_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        engine.lockScreen(at: clock.now)
        engine.unlock(at: clock.now)
        clock.advance(by: 60)
        engine.userActivity(in: projectA, at: clock.now)

        XCTAssertEqual(engine.allSessions.count, 2) // ended session + new one
        let second = engine.allSessions[1]
        XCTAssertTrue(second.isOpen)
        // No backfill from idle/lock time
        XCTAssertEqual(second.activeDuration(now: clock.now), 0, accuracy: 0.001)
    }

    func test_sleep_ends_session_and_wake_does_not_resume() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 15)
        engine.systemSleep(at: clock.now)
        clock.advance(by: 200)
        engine.systemWake(at: clock.now)

        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertFalse(engine.allSessions[0].isOpen)
        XCTAssertEqual(engine.allSessions[0].activeDuration(now: clock.now), 15, accuracy: 0.001)

        // Activity after wake creates new session
        engine.userActivity(in: projectA, at: clock.now)
        XCTAssertEqual(engine.allSessions.count, 2)
    }

    func test_terminate_ends_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 40)
        engine.appWillTerminate(at: clock.now)

        let s = engine.allSessions[0]
        XCTAssertEqual(s.status, .ended)
        XCTAssertEqual(s.endedAt, clock.now)
        XCTAssertEqual(s.activeDuration(now: clock.now), 40, accuracy: 0.001)
    }
}

// MARK: - Crash recovery

extension FocusSessionEngineTests {
    func test_crash_recovery_no_backfill() {
        // Session: user was active up to t0+30, then crash.
        // The last known state change was at the activity event (t0+30).
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        // User activity at t0+30 updates the last‑known timestamp.
        engine.userActivity(in: projectA, at: clock.now)

        // "Crash" — store has session open with lastStateChangeAt = t0+30.
        // Engine deallocated.
        clock.advance(by: 300) // offline gap — must NOT be included.
        let engine2 = makeEngine(clock: clock, store: store)

        let s = engine2.allSessions.first { $0.project == projectA }
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.status, .ended)
        // Ended at lastStateChangeAt (=t0+30), NOT at restart time (t0+330).
        XCTAssertEqual(s!.endedAt, t0.addingTimeInterval(30))
        // Duration capped at 30s, offline 300s excluded.
        XCTAssertEqual(s!.activeDuration(now: clock.now), 30, accuracy: 0.001)
    }

    func test_crash_recovery_with_idle_pause() {
        // Session: active 10s, idle pause at t0+10, crash at t0+30.
        // lastStateChangeAt = t0+30 (the idle event).
        clock.set(to: t0)
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 10)
        engine.idleDetected(at: clock.now) // pause at t0+10 → lastStateChangeAt = t0+10

        clock.advance(by: 20) // idle time, no events → lastStateChangeAt still t0+10

        // Reload after long offline gap.
        clock.advance(by: 500)
        let engine2 = makeEngine(clock: clock, store: store)
        let s = engine2.allSessions[0]

        XCTAssertEqual(s.status, .ended)
        // Ended at lastStateChangeAt (= t0+10), the last known event.
        XCTAssertEqual(s.endedAt, t0.addingTimeInterval(10))
        // Active: gross = 10, excluded = 0 (pause started at t0+10, but endedAt=t0+10
        // so the pause interval t0+10..t0+10 is 0), active = 10.
        XCTAssertEqual(s.activeDuration(now: clock.now), 10, accuracy: 0.001)
    }
}

// MARK: - Project switch

extension FocusSessionEngineTests {
    func test_switch_project_via_foreground_then_activity() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)                // start A at t0
        clock.advance(by: 20)
        engine.foregroundProjectChanged(to: projectB, at: clock.now) // pending A→B at t0+20
        clock.advance(by: 10)
        engine.userActivity(in: projectB, at: clock.now)          // confirm B at t0+30

        XCTAssertEqual(engine.allSessions.count, 2)
        let a = engine.allSessions[0]
        let b = engine.allSessions[1]

        XCTAssertEqual(a.project, projectA)
        XCTAssertEqual(a.status, .ended)
        XCTAssertEqual(a.endedAt, t0.addingTimeInterval(20))
        XCTAssertEqual(a.activeDuration(now: clock.now), 20, accuracy: 0.001)

        XCTAssertEqual(b.project, projectB)
        XCTAssertTrue(b.isOpen)
        XCTAssertEqual(b.startedAt, t0.addingTimeInterval(20))
        // B has been running for 10s
        XCTAssertEqual(b.activeDuration(now: clock.now), 10, accuracy: 0.001)
    }

    func test_brief_interruption_merge() {
        let config = FocusSessionConfiguration(briefInterruptionThreshold: 60,
                                               longAbsenceThreshold: 600)
        let engine = makeEngine(clock: clock, store: store, config: config)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 10)
        engine.foregroundProjectChanged(to: projectB, at: clock.now) // away at t0+10
        clock.advance(by: 20) // brief away (within 60s window)
        engine.userActivity(in: projectA, at: clock.now) // back to A

        // Still one session: A was paused during away, resumed now.
        XCTAssertEqual(engine.allSessions.count, 1)
        let s = engine.allSessions[0]
        XCTAssertTrue(s.isOpen)
        // gross = t0+30 - t0 = 30, excluded = 20 (away), active = 10
        XCTAssertEqual(s.activeDuration(now: clock.now), 10, accuracy: 0.001)
    }

    func test_long_idle_then_lock_ends_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 5)
        engine.idleDetected(at: clock.now) // pause at t0+5
        clock.advance(by: 200) // long idle
        engine.lockScreen(at: clock.now) // end at t0+205
        let s = engine.allSessions[0]
        // active = 5 (before idle), excluded = 200 (idle), active total = 5
        XCTAssertEqual(s.activeDuration(now: clock.now), 5, accuracy: 0.001)
    }

    func test_activity_in_third_project_within_brief_window() {
        let config = FocusSessionConfiguration(briefInterruptionThreshold: 60)
        let engine = makeEngine(clock: clock, store: store, config: config)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 10)
        engine.foregroundProjectChanged(to: projectB, at: clock.now) // pending A→B
        clock.advance(by: 20) // within brief
        engine.userActivity(in: projectC, at: clock.now)
        // Re-pending → commit A→C: A ended at away (t0+10), C started at away (t0+10)
        XCTAssertEqual(engine.allSessions.count, 2)
        let a = engine.allSessions[0]
        let c = engine.allSessions[1]
        XCTAssertEqual(a.project, projectA)
        XCTAssertEqual(a.status, .ended)
        XCTAssertEqual(a.endedAt, t0.addingTimeInterval(10))
        XCTAssertEqual(c.project, projectC)
        XCTAssertTrue(c.isOpen)
        // A active = up to t0+10 = 10s
        XCTAssertEqual(a.activeDuration(now: clock.now), 10, accuracy: 0.001)
        // C active = t0+10 to t0+30 = 20s
        XCTAssertEqual(c.activeDuration(now: clock.now), 20, accuracy: 0.001)
    }

    func test_activity_in_third_project_outside_brief_window() {
        let config = FocusSessionConfiguration(briefInterruptionThreshold: 30)
        let engine = makeEngine(clock: clock, store: store, config: config)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 5)
        engine.foregroundProjectChanged(to: projectB, at: clock.now) // pending at t0+5
        clock.advance(by: 50) // > brief threshold (30s)
        engine.userActivity(in: projectC, at: clock.now)
        // Long absence: end A at away (t0+5), start C at away (t0+5)
        XCTAssertEqual(engine.allSessions.count, 2)
        let a = engine.allSessions[0]
        let c = engine.allSessions[1]
        XCTAssertEqual(a.status, .ended)
        XCTAssertEqual(a.endedAt, t0.addingTimeInterval(5))
        XCTAssertEqual(a.activeDuration(now: clock.now), 5, accuracy: 0.001)
        XCTAssertEqual(c.project, projectC)
        XCTAssertEqual(c.activeDuration(now: clock.now), 50, accuracy: 0.001)
    }
}

// MARK: - Time change / cross‑day

extension FocusSessionEngineTests {
    func test_time_change_same_day_noop() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        let day = dayIdentifier(for: t0)
        let out = engine.timeChanged(at: clock.now, dayIdentifier: day)
        XCTAssertEqual(out, .noChange)
        XCTAssertTrue(engine.allSessions[0].isOpen)
    }

    func test_time_change_new_day_ends_open_session() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        let today = dayIdentifier(for: t0)
        let tomorrow = dayIdentifier(for: t0.addingTimeInterval(86400 * 2))
        let out = engine.timeChanged(at: clock.now, dayIdentifier: tomorrow)
        XCTAssertEqual(out, .saved)
        let s = engine.allSessions[0]
        XCTAssertEqual(s.status, .ended)
        // currentDay is now tomorrow
        XCTAssertEqual(engine.currentDayIdentifier, tomorrow)
        // Yesterday's session still in allSessions
        XCTAssertTrue(engine.sessionsForDay(today).contains { $0.project == projectA })
    }

    func test_activity_in_new_day_creates_separate_session() {
        let engine = makeEngine(clock: clock, store: store)
        let today = dayIdentifier(for: t0)
        let tomorrow = dayIdentifier(for: t0.addingTimeInterval(86400 * 2))

        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 86400 * 2)
        engine.timeChanged(at: clock.now, dayIdentifier: tomorrow)

        clock.advance(by: 60)
        engine.userActivity(in: projectA, at: clock.now)

        XCTAssertEqual(engine.sessionsForDay(today).count, 1)
        let tomSessions = engine.sessionsForDay(tomorrow)
        XCTAssertEqual(tomSessions.count, 1)
        XCTAssertTrue(tomSessions[0].isOpen)
    }
}

// MARK: - Time rollback

extension FocusSessionEngineTests {
    func test_future_date_clamped_to_now() {
        let engine = makeEngine(clock: clock, store: store)
        clock.set(to: t0)
        let future = t0.addingTimeInterval(100)
        engine.userActivity(in: projectA, at: future) // 100s future → clamped to t0
        let s = engine.allSessions[0]
        XCTAssertEqual(s.startedAt, t0)
        XCTAssertEqual(s.activeDuration(now: clock.now), 0)
    }

    func test_past_date_not_clamped() {
        let engine = makeEngine(clock: clock, store: store)
        clock.set(to: t0)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        let past = t0.addingTimeInterval(10) // < clock.now but valid
        engine.userActivity(in: projectA, at: past)
        let s = engine.allSessions[0]
        XCTAssertEqual(s.lastUserActivityAt, past) // past < now, not clamped
    }
}

// MARK: - Background git filtering (coordinator)

extension FocusSessionEngineTests {
    @MainActor
    func test_coordinator_filters_automated_git() {
        let engine = makeEngine(clock: clock, store: store)
        let coordinator = FocusSessionCoordinator(
            engine: engine,
            policy: FocusAttributionPolicy(gitAttributionWindow: nil),
            clock: clock
        )

        // Foreground is a code editor
        coordinator.reportForegroundApp(bundleID: "com.apple.dt.Xcode",
                                        displayName: "Xcode",
                                        isCodeEditor: true)
        // Automated git must NOT start a session
        coordinator.reportGitActivity(repoKey: "repo/a", displayName: "A", automated: true)
        XCTAssertNil(coordinator.currentFocusProject())

        // Non‑automated git starts session
        coordinator.reportGitActivity(repoKey: "repo/a", displayName: "A", automated: false)
        XCTAssertNotNil(coordinator.currentFocusProject())
        XCTAssertEqual(coordinator.currentFocusProject()?.key, "repo/a")
    }
}

// MARK: - Aggregates

extension FocusSessionEngineTests {
    func test_focus_duration_today_with_multiple_sessions() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 30)
        engine.lockScreen(at: clock.now)

        clock.advance(by: 60)
        engine.unlock(at: clock.now)
        clock.advance(by: 10)
        engine.userActivity(in: projectB, at: clock.now)
        clock.advance(by: 20)
        // total = 30 (A) + 20 (B) = 50
        XCTAssertEqual(engine.focusDurationToday(now: clock.now), 50, accuracy: 0.001)
    }

    func test_project_durations_today() {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 40)
        engine.lockScreen(at: clock.now)
        clock.advance(by: 10)
        engine.unlock(at: clock.now)
        engine.userActivity(in: projectB, at: clock.now)
        clock.advance(by: 15)

        let durations = engine.projectDurationsToday(now: clock.now)
        XCTAssertEqual(durations["repo/a"] ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(durations["repo/b"] ?? 0, 15, accuracy: 0.001)
    }

    func test_project_durations_zero_for_inactive_day() {
        let engine = makeEngine(clock: clock, store: store)
        XCTAssertTrue(engine.projectDurationsToday(now: clock.now).isEmpty)
    }
}

// MARK: - Validation / Atomicity

extension FocusSessionEngineTests {
    func test_persistence_failure_retains_previous_saved_state() {
        let engine = makeEngine(clock: clock, store: store)
        let out1 = engine.userActivity(in: projectA, at: t0)
        XCTAssertEqual(out1, .saved)

        clock.advance(by: 10)
        store.shouldFail = true
        let out2 = engine.userActivity(in: projectA, at: clock.now)
        XCTAssertEqual(out2, .persistenceFailed)

        let sessions = engine.allSessions
        XCTAssertEqual(sessions.count, 1)
        // lastUserActivityAt should be from the last SUCCESSFUL save (= t0)
        XCTAssertEqual(sessions[0].lastUserActivityAt, t0)
    }

    func test_no_overlap_invariant() {
        let engine = makeEngine(clock: clock, store: store)

        func checkNoOverlap() {
            let sorted = engine.allSessions.sorted { $0.startedAt < $1.startedAt }
            for i in 0 ..< sorted.count where i + 1 < sorted.count {
                let thisEnd = sorted[i].endedAt ?? Date.distantFuture
                if sorted[i + 1].startedAt < thisEnd {
                    XCTFail("Overlap detected: session \(sorted[i].id) ends \(thisEnd) but next starts \(sorted[i + 1].startedAt)")
                }
            }
        }

        // Rapid sequence of project switches + lock/unlock
        engine.userActivity(in: projectA, at: t0)
        clock.advance(by: 10)
        engine.foregroundProjectChanged(to: projectB, at: clock.now)
        clock.advance(by: 20)
        engine.userActivity(in: projectB, at: clock.now)
        clock.advance(by: 30)
        engine.foregroundProjectChanged(to: projectC, at: clock.now)
        clock.advance(by: 10)
        engine.userActivity(in: projectC, at: clock.now)
        clock.advance(by: 40)
        engine.lockScreen(at: clock.now)
        clock.advance(by: 100)
        engine.unlock(at: clock.now)
        clock.advance(by: 5)
        engine.userActivity(in: projectA, at: clock.now)

        checkNoOverlap()
    }
}

// MARK: - Single open session invariant

extension FocusSessionEngineTests {
    func test_single_open_session_always_upheld() {
        let engine = makeEngine(clock: clock, store: store)

        func assertSingleOpen(file: StaticString = #file, line: UInt = #line) {
            let openCount = engine.allSessions.filter(\.isOpen).count
            XCTAssertLessThanOrEqual(openCount, 1, file: file, line: line)
        }

        engine.userActivity(in: projectA, at: t0);                   assertSingleOpen()
        clock.advance(by: 10)
        engine.idleDetected(at: clock.now);                          assertSingleOpen()
        clock.advance(by: 20)
        engine.userActivity(in: projectA, at: clock.now);            assertSingleOpen()
        clock.advance(by: 10)
        engine.foregroundProjectChanged(to: projectB, at: clock.now); assertSingleOpen()
        clock.advance(by: 5)
        engine.userActivity(in: projectB, at: clock.now);            assertSingleOpen()
        clock.advance(by: 15)
        engine.userActivity(in: projectA, at: clock.now);            assertSingleOpen()
        clock.advance(by: 10)
        engine.userActivity(in: nil, at: clock.now);                 assertSingleOpen()
        clock.advance(by: 5)
        engine.lockScreen(at: clock.now);                            assertSingleOpen()
    }
}

// MARK: - User corrections / transactional edits

extension FocusSessionEngineTests {
    private func endedSession(_ project: FocusProjectContext, start: Date, duration: TimeInterval) -> UUID {
        let engine = makeEngine(clock: clock, store: store)
        engine.userActivity(in: project, at: start)
        clock.set(to: start.addingTimeInterval(duration))
        engine.lockScreen(at: clock.now)
        return engine.allSessions[0].id
    }

    func test_edit_is_stable_by_identifier_and_automatic_activity_does_not_overwrite_confirmation() {
        let id = endedSession(projectA, start: t0, duration: 30)
        let engine = makeEngine(clock: clock, store: store)

        let result = engine.editSession(id: id, project: projectB)
        guard case .saved(_, let snapshot) = result else { return XCTFail("Expected saved edit") }
        XCTAssertEqual(snapshot.projectDurations[projectB.displayName], 30)
        XCTAssertEqual(engine.allSessions.first(where: { $0.id == id })?.project, projectB)
        XCTAssertTrue(engine.allSessions.first(where: { $0.id == id })?.isManuallyConfirmed == true)

        clock.advance(by: 10)
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions.first(where: { $0.id == id })?.project, projectB)
        XCTAssertEqual(engine.allSessions.count, 2)
    }

    func test_confirmed_correction_survives_restart_and_automatic_activity_only_appends() {
        let id = endedSession(projectA, start: t0, duration: 30)
        let firstEngine = makeEngine(clock: clock, store: store)
        guard case .saved = firstEngine.editSession(id: id, project: projectB) else {
            return XCTFail("Expected correction to persist")
        }

        clock.advance(by: 20)
        let restartedEngine = makeEngine(clock: clock, store: store)
        XCTAssertEqual(restartedEngine.allSessions.first(where: { $0.id == id })?.project, projectB)
        XCTAssertTrue(restartedEngine.allSessions.first(where: { $0.id == id })?.isManuallyConfirmed == true)

        XCTAssertEqual(restartedEngine.userActivity(in: projectC, at: clock.now), .saved)
        XCTAssertEqual(restartedEngine.allSessions.first(where: { $0.id == id })?.project, projectB)
        XCTAssertEqual(restartedEngine.allSessions.count, 2)
    }

    func test_confirmed_revision_persists_across_restart_and_advances_on_next_edit() {
        let id = endedSession(projectA, start: t0, duration: 30)
        let firstEngine = makeEngine(clock: clock, store: store)
        guard case .saved(_, let firstSnapshot) = firstEngine.editSession(id: id, project: projectB) else {
            return XCTFail("Expected first correction")
        }
        let restartedEngine = makeEngine(clock: clock, store: store)
        XCTAssertEqual(restartedEngine.derivedSnapshot().revision, firstSnapshot.revision)

        guard case .saved(_, let secondSnapshot) = restartedEngine.editSession(id: id, project: projectC) else {
            return XCTFail("Expected second correction")
        }
        XCTAssertGreaterThan(secondSnapshot.revision, firstSnapshot.revision)
    }

    func test_correction_reassigns_session_when_original_project_no_longer_exists() {
        // A recorded session stores only a stable project value; correction must
        // not require the former workspace to remain available on disk.
        let removedProject = FocusProjectContext(key: "former/project", displayName: "Former project")
        let id = endedSession(removedProject, start: t0, duration: 30)
        let engine = makeEngine(clock: clock, store: store)

        guard case .saved(_, let snapshot) = engine.editSession(id: id, project: projectB) else {
            return XCTFail("Expected correction after project removal")
        }
        XCTAssertEqual(engine.allSessions.first(where: { $0.id == id })?.project, projectB)
        XCTAssertEqual(snapshot.projectDurations, [projectB.displayName: 30])
    }

    func test_edit_rejects_future_negative_and_overlapping_ranges_without_mutating() {
        let id = endedSession(projectA, start: t0, duration: 30)
        let engine = makeEngine(clock: clock, store: store)
        let original = engine.allSessions

        XCTAssertEqual(engine.editSession(id: id, endedAt: t0.addingTimeInterval(32)), .rejected(.futureTime))
        XCTAssertEqual(engine.editSession(id: id, startedAt: t0.addingTimeInterval(30), endedAt: t0.addingTimeInterval(20)), .rejected(.invalidTimeRange))
        XCTAssertEqual(engine.allSessions, original)
    }

    func test_edit_rejects_span_exceeding_configured_safety_cap() {
        let id = endedSession(projectA, start: t0, duration: 20)
        clock.set(to: t0.addingTimeInterval(40))
        let constrained = makeEngine(
            clock: clock,
            store: store,
            config: FocusSessionConfiguration(maxSessionSpan: 30)
        )
        XCTAssertEqual(
            constrained.editSession(id: id, endedAt: t0.addingTimeInterval(40)),
            .rejected(.invalidTimeRange)
        )
    }

    func test_split_merge_delete_and_undo_restore_complete_previous_record() {
        let id = endedSession(projectA, start: t0, duration: 60)
        let engine = makeEngine(clock: clock, store: store)
        let original = engine.allSessions

        let split = engine.splitSession(id: id, at: t0.addingTimeInterval(20))
        guard case .saved = split else { return XCTFail("Expected split") }
        XCTAssertEqual(engine.allSessions.count, 2)
        XCTAssertEqual(engine.allSessions.first(where: { $0.id == id })?.activeDuration(now: clock.now), 20)

        let merge = engine.mergeSessions(ids: engine.allSessions.map(\.id))
        guard case .saved = merge else { return XCTFail("Expected merge") }
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].activeDuration(now: clock.now), 60)

        guard case .saved = engine.deleteSession(id: id) else { return XCTFail("Expected delete") }
        XCTAssertTrue(engine.allSessions.isEmpty)
        guard case .saved = engine.undoLastEdit() else { return XCTFail("Expected undo") }
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].id, id)
        XCTAssertNotEqual(engine.allSessions, original) // merge created a confirmed version; undo restores pre-delete exactly.
    }

    func test_merge_rejects_project_without_display_name() {
        let id = endedSession(projectA, start: t0, duration: 20)
        let engine = makeEngine(clock: clock, store: store)
        guard case .saved = engine.splitSession(id: id, at: t0.addingTimeInterval(10)) else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(
            engine.mergeSessions(
                ids: engine.allSessions.map(\.id),
                project: FocusProjectContext(key: "repo/new", displayName: " ")
            ),
            .rejected(.invalidProject)
        )
    }

    func test_edit_persistence_failure_keeps_disk_and_memory_state_and_does_not_create_undo() {
        let id = endedSession(projectA, start: t0, duration: 30)
        let engine = makeEngine(clock: clock, store: store)
        let original = engine.allSessions
        store.shouldFail = true

        XCTAssertEqual(engine.editSession(id: id, project: projectB), .rejected(.persistenceFailed))
        XCTAssertEqual(engine.allSessions, original)
        XCTAssertEqual(store.stored, original)
        XCTAssertEqual(engine.undoLastEdit(), .rejected(.nothingToUndo))
    }

    func test_committed_snapshot_handler_runs_only_after_successful_journal_write() {
        let id = endedSession(projectA, start: t0, duration: 30)
        let engine = makeEngine(clock: clock, store: store)
        let recorder = SnapshotRecorder()
        engine.committedSnapshotHandler = { recorder.append($0) }

        store.shouldFail = true
        XCTAssertEqual(engine.editSession(id: id, project: projectB), .rejected(.persistenceFailed))
        XCTAssertEqual(recorder.count, 0)

        store.shouldFail = false
        guard case .saved = engine.editSession(id: id, project: projectB) else { return XCTFail("Expected saved edit") }
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.snapshots[0].projectDurations[projectB.displayName], 30)
    }

    func test_automatic_activity_does_not_replace_existing_shared_focus_presentation() {
        let engine = makeEngine(clock: clock, store: store)
        let recorder = SnapshotRecorder()
        engine.committedSnapshotHandler = { recorder.append($0) }

        XCTAssertEqual(engine.userActivity(in: projectA, at: t0), .saved)
        clock.advance(by: 10)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)
        XCTAssertEqual(recorder.count, 0)
    }

    func test_rapid_successive_edits_are_serialized_and_latest_commit_wins() {
        let id = endedSession(projectA, start: t0, duration: 30)
        let engine = makeEngine(clock: clock, store: store)
        guard case .saved = engine.editSession(id: id, project: projectB) else { return XCTFail("Expected first edit") }
        guard case .saved = engine.editSession(id: id, project: projectC) else { return XCTFail("Expected second edit") }
        XCTAssertEqual(engine.allSessions.first(where: { $0.id == id })?.project, projectC)
        XCTAssertEqual(engine.derivedSnapshot().projectDurations[projectC.displayName], 30)
        // Undo restores the complete record before the latest edit, not a
        // partial merge of fields from the two corrections.
        guard case .saved = engine.undoLastEdit() else { return XCTFail("Expected undo") }
        XCTAssertEqual(engine.allSessions.first(where: { $0.id == id })?.project, projectB)
    }

    func test_automatic_activity_and_manual_correction_concurrent_write_preserves_confirmed_session() {
        let id = endedSession(projectA, start: t0, duration: 30)
        let engine = makeEngine(clock: clock, store: store)
        let automaticStart = t0.addingTimeInterval(30)
        clock.set(to: automaticStart)

        DispatchQueue.concurrentPerform(iterations: 24) { index in
            if index == 0 {
                guard case .saved = engine.editSession(id: id, project: projectB) else {
                    XCTFail("Manual correction must save")
                    return
                }
            } else {
                _ = engine.userActivity(in: projectC, at: automaticStart)
            }
        }

        let sessions = engine.allSessions
        XCTAssertEqual(sessions.first(where: { $0.id == id })?.project, projectB)
        XCTAssertTrue(sessions.first(where: { $0.id == id })?.isManuallyConfirmed == true)
        XCTAssertEqual(sessions.filter { $0.project == projectC }.count, 1)
        let sorted = sessions.sorted { $0.startedAt < $1.startedAt }
        XCTAssertTrue(zip(sorted, sorted.dropFirst()).allSatisfy { ($0.endedAt ?? .distantFuture) <= $1.startedAt })
    }

    func test_edit_cross_day_creates_adjacent_day_local_sessions_without_overlap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 23, minute: 50))!
        clock.set(to: start)
        let id = endedSession(projectA, start: start, duration: 60)
        clock.set(to: start.addingTimeInterval(1_200))
        let engine = makeEngine(clock: clock, store: store)

        guard case .saved = engine.editSession(id: id, endedAt: start.addingTimeInterval(1_200)) else { return XCTFail("Expected cross-day edit") }
        let sessions = engine.allSessions.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(sessions.count, 2)
        guard sessions.count == 2 else { return }
        XCTAssertEqual(sessions[0].endedAt, sessions[1].startedAt)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.activeDuration(now: clock.now) }, 1_200, accuracy: 0.001)
    }
}
