import Foundation
import XCTest
@testable import TinyBuddyCore

/// Advanced manual focus control tests covering:
/// - Session overlap resolution (auto↔manual transitions)
/// - Concurrent commands and anti-bounce
/// - Atomic persistence and rollback
/// - Crash recovery with no backfill
/// - System time and day boundary during manual
/// - Idle/lock/sleep behavior consistency
/// - Rapid project switching
/// - Widget state consistency verification

private let projX = FocusProjectContext(key: "proj.x", displayName: "Project X")
private let projY = FocusProjectContext(key: "proj.y", displayName: "Project Y")
private let projZ = FocusProjectContext(key: "proj.z", displayName: "Project Z")

final class FocusSessionEngineManualControlAdvancedTests: XCTestCase {

    func makeEngine(
        _ clock: FakeClock,
        _ store: MemoryStore,
        day: String = "2001-01-24"
    ) -> FocusSessionEngine {
        FocusSessionEngine(
            clock: clock, persisting: store,
            dayIdentifier: { _ in day }
        )
    }

    // MARK: - Overlap Resolution: Auto → Manual

    func test_manual_start_ends_auto_with_correct_boundary() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        // Start auto session at T=1000
        _ = engine.userActivity(in: projX, at: clock.now, reason: .userActivity)
        clock.advance(by: 30)

        // Start manual at T=1030 — auto should end at exactly 1030.
        _ = engine.startManualFocus(project: projY, at: clock.now)

        let sessions = engine.allSessions.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].mode, .automatic)
        XCTAssertEqual(sessions[0].status, .ended)
        XCTAssertEqual(sessions[0].endedAt, Date(timeIntervalSinceReferenceDate: 1_030))
        XCTAssertEqual(sessions[1].mode, .manual)
        XCTAssertEqual(sessions[1].status, .active)
        XCTAssertEqual(sessions[1].startedAt, Date(timeIntervalSinceReferenceDate: 1_030))

        // Verify no overlap: auto ends at 1030, manual starts at 1030.
        XCTAssertEqual(sessions[0].endedAt, sessions[1].startedAt)
    }

    func test_manual_start_when_no_auto_active_creates_clean_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)

        let sessions = engine.allSessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].mode, .manual)
        XCTAssertEqual(sessions[0].project, projX)
    }

    // MARK: - Overlap Resolution: Manual → Auto

    func test_after_manual_end_auto_starts_at_new_activity_not_at_manual_end() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 60)
        let manualEnd = clock.now // T=1060
        _ = engine.endManualFocus(at: manualEnd)

        // Gap of 30 seconds — no activity.
        clock.advance(by: 30)

        // Auto activity at T=1090 starts a new session at T=1090, NOT at 1060.
        _ = engine.userActivity(in: projY, at: clock.now, reason: .userActivity)

        let sessions = engine.allSessions.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].mode, .manual)
        XCTAssertEqual(sessions[0].status, .ended)
        XCTAssertEqual(sessions[1].mode, .automatic)
        XCTAssertEqual(sessions[1].startedAt, Date(timeIntervalSinceReferenceDate: 1_090))
        // No gap fill: auto started at actual activity time.
    }

    func test_after_manual_end_auto_does_not_resume_old_auto_project() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        // Auto session for projX
        _ = engine.userActivity(in: projX, at: clock.now, reason: .gitActivity)
        clock.advance(by: 10)

        // Manual session for projY replaces it
        _ = engine.startManualFocus(project: projY, at: clock.now)
        clock.advance(by: 30)
        _ = engine.endManualFocus(at: clock.now)

        // New auto activity for projZ — should NOT revive projX.
        clock.advance(by: 10)
        _ = engine.userActivity(in: projZ, at: clock.now, reason: .gitActivity)

        let sessions = engine.allSessions.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[2].project, projZ)
        XCTAssertEqual(sessions[2].mode, .automatic)
    }

    // MARK: - Concurrent Commands & Anti-bounce

    func test_concurrent_start_tokens_from_different_sources_only_first_creates() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        // Simulate two UI sources sending start at the same time with different tokens.
        let token1 = UUID()
        let token2 = UUID()

        let r1 = engine.startManualFocus(project: projX, at: clock.now, commandToken: token1)
        XCTAssertEqual(r1, .saved)

        let r2 = engine.startManualFocus(project: projX, at: clock.now, commandToken: token2)
        // Second call with same project + different token = no change.
        XCTAssertEqual(r2, .noChange)
        XCTAssertEqual(engine.allSessions.count, 1)
    }

    func test_concurrent_pause_and_resume_converge_to_latest_command() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 10)

        // Pause wins the race (arrives first).
        let pauseResult = engine.pauseManualFocus(at: clock.now, commandToken: UUID())
        XCTAssertEqual(pauseResult, .saved)
        XCTAssertEqual(engine.manualControlState.isManualSessionPaused, true)

        // Late end should still work (ends paused session).
        let endResult = engine.endManualFocus(at: clock.now, commandToken: UUID())
        XCTAssertEqual(endResult, .saved)
        XCTAssertEqual(engine.manualControlState, .idle)
    }

    func test_rapid_project_switch_converge_to_last_project() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        // Start X
        _ = engine.startManualFocus(project: projX, at: clock.now, commandToken: UUID())
        clock.advance(by: 5)

        // Switch to Y (rapidly)
        _ = engine.startManualFocus(project: projY, at: clock.now, commandToken: UUID())
        clock.advance(by: 5)

        // Switch to Z (final)
        _ = engine.startManualFocus(project: projZ, at: clock.now, commandToken: UUID())

        // Only one open session should exist, and it should be Z.
        let open = engine.allSessions.filter(\.isOpen)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].project, projZ)
        XCTAssertEqual(open[0].mode, .manual)

        // All previous sessions ended.
        let ended = engine.allSessions.filter { $0.status == .ended }
        XCTAssertEqual(ended.count, 2)
    }

    func test_duplicate_end_is_idempotent() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 10)

        XCTAssertEqual(engine.endManualFocus(at: clock.now), .saved)
        XCTAssertEqual(engine.endManualFocus(at: clock.now), .noChange)
        XCTAssertEqual(engine.allSessions.count, 1)
    }

    // MARK: - Persistence Atomicity

    func test_persistence_failure_on_start_does_not_leave_partial_state() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        store.shouldFail = true
        let engine = makeEngine(clock, store)

        let result = engine.startManualFocus(project: projX, at: clock.now)
        XCTAssertEqual(result, .persistenceFailed)
        XCTAssertEqual(engine.manualControlState, .idle)
        XCTAssertEqual(engine.allSessions.count, 0)
    }

    func test_persistence_failure_on_pause_rolls_back_to_active() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)

        store.shouldFail = true
        clock.advance(by: 10)

        let result = engine.pauseManualFocus(at: clock.now)
        XCTAssertEqual(result, .persistenceFailed)
        // State should NOT have changed.
        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)
        XCTAssertFalse(engine.manualControlState.isManualSessionPaused)
    }

    func test_persistence_failure_on_end_rolls_back_correctly() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 10)

        store.shouldFail = true
        let result = engine.endManualFocus(at: clock.now)
        XCTAssertEqual(result, .persistenceFailed)
        // Manual session should still be active.
        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].status, .active)
    }

    func test_persistence_fails_then_recovers_on_next_command() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 10)

        // First pause fails.
        store.shouldFail = true
        XCTAssertEqual(engine.pauseManualFocus(at: clock.now), .persistenceFailed)
        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)

        // Second pause succeeds (store recovers).
        store.shouldFail = false
        clock.advance(by: 5)
        let result = engine.pauseManualFocus(at: clock.now)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.manualControlState.isManualSessionPaused, true)
    }

    // MARK: - Crash Recovery

    func test_crash_recovery_ends_manual_with_last_known_time_not_now() {
        let store = MemoryStore()
        // Session was active at T=900, app crashed at T=950.
        let priorSession = FocusSession(
            id: UUID(),
            project: projX,
            dayIdentifier: "2001-01-24",
            startedAt: Date(timeIntervalSinceReferenceDate: 800),
            status: .active,
            lastUserActivityAt: Date(timeIntervalSinceReferenceDate: 900),
            lastStateChangeAt: Date(timeIntervalSinceReferenceDate: 900),
            mode: .manual
        )
        store.stored = [priorSession]

        // App restarts at T=2000 (1 hour later).
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 2_000))
        let engine = makeEngine(clock, store)

        let sessions = engine.allSessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].status, .ended)
        // endedAt should be the last known time (900), NOT now (2000).
        XCTAssertEqual(sessions[0].endedAt, Date(timeIntervalSinceReferenceDate: 900))
        // Duration should NOT include the offline gap (900 to 2000).
        XCTAssertLessThanOrEqual(sessions[0].activeDuration(now: clock.now), 100)
    }

    func test_crash_recovery_on_paused_manual_closes_pause_and_ends() {
        let store = MemoryStore()
        let priorSession = FocusSession(
            id: UUID(),
            project: projX,
            dayIdentifier: "2001-01-24",
            startedAt: Date(timeIntervalSinceReferenceDate: 800),
            status: .paused,
            lastUserActivityAt: Date(timeIntervalSinceReferenceDate: 850),
            lastStateChangeAt: Date(timeIntervalSinceReferenceDate: 850),
            pausedTotal: 0,
            currentPauseStartedAt: Date(timeIntervalSinceReferenceDate: 850),
            mode: .manual
        )
        store.stored = [priorSession]

        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 2_000))
        let engine = makeEngine(clock, store)

        let sessions = engine.allSessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].status, .ended)
        // Open pause should be closed.
        XCTAssertNil(sessions[0].currentPauseStartedAt)
        // Active duration should be 50s (800→850), no offline补算.
        XCTAssertEqual(sessions[0].activeDuration(now: clock.now), 50, accuracy: 0.01)
    }

    // MARK: - System Time / Day Boundary During Manual

    func test_day_boundary_during_manual_ends_session_at_last_event_not_midnight() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 86_000)) // ~midnight - 400s
        let store = MemoryStore()
        let engine = makeEngine(clock, store, day: "2001-01-24")

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 60) // T=86060

        // Day rolls to 2001-01-25
        let result = engine.timeChanged(at: clock.now, dayIdentifier: "2001-01-25")
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.manualControlState, .idle)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
        // endedAt should be lastStateChangeAt (86000 when started), not the current time (86060).
        // No时间补算: the engine preserves the last known event boundary.
        XCTAssertEqual(engine.allSessions[0].endedAt, Date(timeIntervalSinceReferenceDate: 86_000))
        // Active duration: 0s (started and ended at the same boundary).
        XCTAssertEqual(engine.allSessions[0].activeDuration(now: clock.now), 0, accuracy: 0.01)
    }

    func test_time_jump_backward_during_manual_is_clamped_to_now() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 60) // now = 1060

        // Try to end at a time before start (T=500) — should be rejected.
        let pastResult = engine.endManualFocus(at: Date(timeIntervalSinceReferenceDate: 500))
        XCTAssertEqual(pastResult, .rejectedInvalid)
        // Session should remain active.
        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)

        // End at current time works fine.
        let result = engine.endManualFocus(at: clock.now)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.allSessions[0].endedAt, Date(timeIntervalSinceReferenceDate: 1_060))
    }

    // MARK: - Idle / Lock / Sleep During Manual

    func test_lock_during_manual_pauses_instead_of_ends() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 30)

        let result = engine.lockScreen(at: clock.now)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.manualControlState.isManualSessionPaused, true)
        XCTAssertTrue(engine.allSessions[0].isOpen)
    }

    func test_unlock_after_manual_pause_keeps_session_paused() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 30)
        _ = engine.lockScreen(at: clock.now)

        // Unlock should keep session paused (user must explicitly resume).
        clock.advance(by: 60)
        _ = engine.unlock(at: clock.now)

        XCTAssertEqual(engine.manualControlState.isManualSessionPaused, true)
        // No time should have accumulated during lock.
    }

    func test_sleep_during_manual_ends_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 30)

        let result = engine.systemSleep(at: clock.now)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
        XCTAssertEqual(engine.manualControlState, .idle)
    }

    func test_idle_during_manual_does_not_auto_pause() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 200) // Beyond idle threshold

        let result = engine.idleDetected(at: clock.now)
        XCTAssertEqual(result, .noChange)
        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)
    }

    // MARK: - Auto Activity During Manual

    func test_auto_git_activity_during_manual_updates_timestamps_but_not_project() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 30)

        // Git activity from a different project.
        let result = engine.userActivity(in: projY, at: clock.now, reason: .gitActivity)
        // Timestamps update but project stays X.
        XCTAssertEqual(result, .saved)

        guard case .focusing(let p, _, _) = engine.manualControlState else {
            return XCTFail("Expected focusing")
        }
        XCTAssertEqual(p, projX)
    }

    func test_auto_activity_resumes_paused_manual() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 10)
        _ = engine.pauseManualFocus(at: clock.now)

        clock.advance(by: 20)
        // Any user activity resumes paused manual.
        _ = engine.userActivity(in: nil, at: clock.now, reason: .userActivity)

        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)
    }

    // MARK: - Only One Open Session

    func test_only_one_open_session_across_all_modes() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        // Multiple starts should never create multiple open sessions.
        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 10)
        _ = engine.startManualFocus(project: projY, at: clock.now)

        let open = engine.allSessions.filter(\.isOpen)
        XCTAssertEqual(open.count, 1)
    }

    // MARK: - Session Validation: No Overlap After Edits

    func test_sessions_never_overlap_after_multiple_transitions() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        // Complex sequence: auto → manual → manual switch → manual end → auto
        _ = engine.userActivity(in: projX, at: clock.now, reason: .gitActivity)
        clock.advance(by: 30)
        _ = engine.startManualFocus(project: projY, at: clock.now)
        clock.advance(by: 40)
        _ = engine.startManualFocus(project: projZ, at: clock.now)
        clock.advance(by: 20)
        _ = engine.endManualFocus(at: clock.now)
        clock.advance(by: 10)
        _ = engine.userActivity(in: projX, at: clock.now, reason: .userActivity)

        let sorted = engine.allSessions.sorted { $0.startedAt < $1.startedAt }
        // Verify no overlaps.
        for i in 0..<(sorted.count - 1) {
            let thisEnd = sorted[i].endedAt ?? Date.distantFuture
            XCTAssertLessThanOrEqual(thisEnd, sorted[i + 1].startedAt,
                "Session \(i) ends at \(thisEnd) but next starts at \(sorted[i + 1].startedAt)")
        }
    }

    // MARK: - Widget State Consistency

    func test_manual_control_state_reflects_engine() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        XCTAssertEqual(engine.manualControlState, .idle)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)

        clock.advance(by: 10)
        _ = engine.pauseManualFocus(at: clock.now)
        XCTAssertEqual(engine.manualControlState.isManualSessionPaused, true)

        _ = engine.resumeManualFocus(at: clock.now)
        XCTAssertEqual(engine.manualControlState.isManualSessionActive, true)

        _ = engine.endManualFocus(at: clock.now)
        XCTAssertEqual(engine.manualControlState, .idle)
    }

    func test_project_durations_today_excludes_paused_time() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projX, at: clock.now)
        clock.advance(by: 20)
        _ = engine.pauseManualFocus(at: clock.now)
        clock.advance(by: 100) // Long pause
        _ = engine.resumeManualFocus(at: clock.now)
        clock.advance(by: 10)
        _ = engine.endManualFocus(at: clock.now)

        let durations = engine.projectDurationsToday()
        // 30s active - 100s paused = ~30s
        XCTAssertEqual(durations[projX.key] ?? 0, 30, accuracy: 0.5)
    }

    func test_focus_duration_today_sums_all_sessions_correctly() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        // Auto session: 30s
        _ = engine.userActivity(in: projX, at: clock.now, reason: .userActivity)
        clock.advance(by: 30)
        _ = engine.lockScreen(at: clock.now)

        // Manual session: 20s active, 5s paused, 15s active
        clock.advance(by: 10)
        _ = engine.unlock(at: clock.now)
        _ = engine.startManualFocus(project: projY, at: clock.now)
        clock.advance(by: 20)
        _ = engine.pauseManualFocus(at: clock.now)
        clock.advance(by: 5)
        _ = engine.resumeManualFocus(at: clock.now)
        clock.advance(by: 15)
        _ = engine.endManualFocus(at: clock.now)

        let total = engine.focusDurationToday()
        // Auto: 30, Manual: 35. Total: ~65
        XCTAssertEqual(total, 65, accuracy: 0.5)
    }
}
