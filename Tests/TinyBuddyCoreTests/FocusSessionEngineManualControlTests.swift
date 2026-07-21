import Foundation
import XCTest
@testable import TinyBuddyCore

/// Manual focus control tests. Reuses FakeClock and MemoryStore from
/// FocusSessionEngineTests.swift in the same module.

private let projectA = FocusProjectContext(key: "proj.a", displayName: "Project A")
private let projectB = FocusProjectContext(key: "proj.b", displayName: "Project B")

final class FocusSessionEngineManualControlTests: XCTestCase {

    func makeEngine(_ clock: FakeClock, _ store: MemoryStore) -> FocusSessionEngine {
        FocusSessionEngine(
            clock: clock, persisting: store,
            dayIdentifier: { _ in "2001-01-24" }
        )
    }

    // MARK: - Basic start/stop

    func test_manual_start_when_idle_creates_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        let result = engine.startManualFocus(project: projectA, at: clock.now)
        XCTAssertEqual(result, .saved)

        let state = engine.manualControlState
        guard case .focusing(let project, _, let duration) = state else {
            return XCTFail("Expected focusing, got \(state)")
        }
        XCTAssertEqual(project, projectA)
        XCTAssertEqual(duration, 0)

        let all = engine.allSessions
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].mode, .manual)
        XCTAssertEqual(all[0].project, projectA)
        XCTAssertEqual(all[0].status, .active)
    }

    func test_manual_start_with_same_project_when_active_is_noop() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)

        let result = engine.startManualFocus(project: projectA, at: clock.now)
        XCTAssertEqual(result, .noChange)
        XCTAssertEqual(engine.allSessions.count, 1)
    }

    func test_manual_start_with_different_project_ends_old_and_starts_new() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)

        let result = engine.startManualFocus(project: projectB, at: clock.now)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.allSessions.count, 2)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
        XCTAssertEqual(engine.allSessions[1].status, .active)
        XCTAssertEqual(engine.allSessions[1].project, projectB)
    }

    // MARK: - Pause / Resume

    func test_manual_pause_when_active_then_resume() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)

        let pauseResult = engine.pauseManualFocus(at: clock.now)
        XCTAssertEqual(pauseResult, .saved)
        guard case .paused = engine.manualControlState else {
            return XCTFail("Expected paused state")
        }

        clock.advance(by: 5)
        let resumeResult = engine.resumeManualFocus(at: clock.now)
        XCTAssertEqual(resumeResult, .saved)
        guard case .focusing = engine.manualControlState else {
            return XCTFail("Expected focusing after resume")
        }
    }

    func test_manual_pause_when_idle_is_noop() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        let result = engine.pauseManualFocus(at: clock.now)
        XCTAssertEqual(result, .noChange)
    }

    func test_manual_pause_when_already_paused_is_noop() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        _ = engine.pauseManualFocus(at: clock.now)
        let result = engine.pauseManualFocus(at: clock.now)
        XCTAssertEqual(result, .noChange)
    }

    func test_manual_resume_when_not_paused_is_noop() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        let result = engine.resumeManualFocus(at: clock.now)
        XCTAssertEqual(result, .noChange)
    }

    // MARK: - Duration accounting

    func test_paused_time_is_excluded_from_active_duration() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)
        _ = engine.pauseManualFocus(at: clock.now)

        // Paused for 5 seconds
        clock.advance(by: 5)
        guard case .paused(_, _, _, let durDuringPause) = engine.manualControlState else {
            return XCTFail("Expected paused")
        }
        // Duration should be ~10 seconds (not 15).
        XCTAssertEqual(Int(durDuringPause), 10)

        _ = engine.resumeManualFocus(at: clock.now)
        clock.advance(by: 5)

        guard case .focusing(_, _, let finalDur) = engine.manualControlState else {
            return XCTFail("Expected focusing after resume")
        }
        // Duration should be ~15 seconds.
        XCTAssertEqual(Int(finalDur), 15)
    }

    func test_ended_manual_session_has_correct_paused_total() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)
        _ = engine.pauseManualFocus(at: clock.now)
        clock.advance(by: 10)
        _ = engine.resumeManualFocus(at: clock.now)
        clock.advance(by: 10)
        _ = engine.endManualFocus(at: clock.now)

        let session = engine.allSessions[0]
        // 30 gross - 10 paused = 20 active
        XCTAssertEqual(session.activeDuration(now: clock.now), 20, accuracy: 0.01)
        XCTAssertEqual(session.pausedTotal, 10, accuracy: 0.01)
    }

    // MARK: - Auto blocking

    func test_auto_activity_during_manual_does_not_switch_project() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)

        let result = engine.userActivity(in: projectB, at: clock.now, reason: .gitActivity)
        // Timestamps update but project does NOT change — this is .saved, not .noChange.
        XCTAssertEqual(result, .saved)

        guard case .focusing(let p, _, _) = engine.manualControlState else {
            return XCTFail("Expected focusing")
        }
        XCTAssertEqual(p, projectA)
    }

    func test_auto_foreground_change_during_manual_is_blocked() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)

        let result = engine.foregroundProjectChanged(to: projectB, at: clock.now)
        XCTAssertEqual(result, .noChange)

        guard case .focusing(let p, _, _) = engine.manualControlState else {
            return XCTFail("Expected focusing")
        }
        XCTAssertEqual(p, projectA)
    }

    func test_auto_idle_during_manual_does_not_pause() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)

        let result = engine.idleDetected(at: clock.now)
        XCTAssertEqual(result, .noChange)

        guard case .focusing = engine.manualControlState else {
            return XCTFail("Expected focusing, not paused by auto idle")
        }
    }

    // MARK: - Manual overrides auto

    func test_manual_start_ends_active_auto_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.userActivity(in: projectA, at: clock.now, reason: .userActivity)
        clock.advance(by: 10)

        let result = engine.startManualFocus(project: projectB, at: clock.now)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.allSessions.count, 2)
        XCTAssertEqual(engine.allSessions[0].mode, .automatic)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
        XCTAssertEqual(engine.allSessions[1].mode, .manual)
        XCTAssertEqual(engine.allSessions[1].status, .active)
    }

    // MARK: - After manual end, auto starts fresh

    func test_after_manual_end_auto_can_start_new_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)
        _ = engine.endManualFocus(at: clock.now)

        // Now auto should be able to start a new session.
        clock.advance(by: 10)
        let result = engine.userActivity(in: projectB, at: clock.now, reason: .userActivity)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.allSessions.count, 2)
        // The auto session should start now (1020), not backfilled to manual end (1010).
        XCTAssertEqual(engine.allSessions[1].project, projectB)
        XCTAssertEqual(engine.allSessions[1].startedAt, clock.now)
    }

    // MARK: - Lock screen behavior for manual

    func test_lock_screen_pauses_manual_session_instead_of_ending() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)

        let result = engine.lockScreen(at: clock.now)
        XCTAssertEqual(result, .saved)

        guard case .paused = engine.manualControlState else {
            return XCTFail("Manual session should be paused on lock, not ended")
        }
        XCTAssertTrue(engine.allSessions[0].isOpen)
        XCTAssertEqual(engine.allSessions[0].mode, .manual)
    }

    func test_lock_screen_ends_auto_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.userActivity(in: projectA, at: clock.now, reason: .userActivity)
        clock.advance(by: 10)

        let result = engine.lockScreen(at: clock.now)
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
    }

    // MARK: - Idempotent command tokens

    func test_duplicate_command_token_is_noop() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        let token = UUID()
        let first = engine.startManualFocus(project: projectA, at: clock.now, commandToken: token)
        XCTAssertEqual(first, .saved)

        clock.advance(by: 10)
        let second = engine.startManualFocus(project: projectA, at: clock.now, commandToken: token)
        XCTAssertEqual(second, .noChange)
        XCTAssertEqual(engine.allSessions.count, 1)
    }

    func test_different_command_tokens_are_not_deduplicated() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        let first = engine.startManualFocus(project: projectA, at: clock.now, commandToken: UUID())
        XCTAssertEqual(first, .saved)

        let second = engine.startManualFocus(project: projectA, at: clock.now, commandToken: UUID())
        XCTAssertEqual(second, .noChange)
    }

    // MARK: - Persistence failure

    func test_persistence_failure_rolls_back_to_last_valid_state() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        XCTAssertEqual(engine.allSessions.count, 1)

        store.shouldFail = true
        clock.advance(by: 10)

        let result = engine.pauseManualFocus(at: clock.now)
        XCTAssertEqual(result, .persistenceFailed)

        guard case .focusing = engine.manualControlState else {
            return XCTFail("State should not have changed after persistence failure")
        }
    }

    // MARK: - Crash recovery

    func test_crash_recovery_ends_open_manual_session_without_backfill() {
        let store = MemoryStore()
        let priorSession = FocusSession(
            id: UUID(),
            project: projectA,
            dayIdentifier: "2001-01-24",
            startedAt: Date(timeIntervalSinceReferenceDate: 900),
            status: .active,
            lastUserActivityAt: Date(timeIntervalSinceReferenceDate: 950),
            lastStateChangeAt: Date(timeIntervalSinceReferenceDate: 950),
            mode: .manual
        )
        store.stored = [priorSession]

        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let engine = makeEngine(clock, store)

        let sessions = engine.allSessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].status, .ended)
        XCTAssertEqual(sessions[0].endedAt, Date(timeIntervalSinceReferenceDate: 950))
        // No backfill: active duration should be <= 50 (from 900 to 950).
        XCTAssertLessThanOrEqual(sessions[0].activeDuration(now: clock.now), 50)
    }

    // MARK: - Day boundary during manual

    func test_day_boundary_ends_open_manual_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 100)

        let result = engine.timeChanged(at: clock.now, dayIdentifier: "2001-01-25")
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(engine.manualControlState, .idle)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
    }

    // MARK: - Reject invalid projects

    func test_manual_start_with_empty_project_key_is_rejected() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        let badProject = FocusProjectContext(key: "", displayName: "Empty")
        let result = engine.startManualFocus(project: badProject, at: clock.now)
        XCTAssertEqual(result, .rejectedInvalid)
    }

    func test_manual_start_with_empty_display_name_is_rejected() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        let badProject = FocusProjectContext(key: "key", displayName: "")
        let result = engine.startManualFocus(project: badProject, at: clock.now)
        XCTAssertEqual(result, .rejectedInvalid)
    }

    // MARK: - Auto resume during manual pause

    func test_auto_activity_resumes_paused_manual_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)
        _ = engine.pauseManualFocus(at: clock.now)

        // Auto user activity resumes the paused manual session.
        clock.advance(by: 10)
        let result = engine.userActivity(in: projectB, at: clock.now, reason: .userActivity)
        XCTAssertEqual(result, .saved)

        guard case .focusing(let p, _, _) = engine.manualControlState else {
            return XCTFail("Expected focusing after auto resume")
        }
        // Project should remain projectA.
        XCTAssertEqual(p, projectA)
    }

    // MARK: - State queries

    func test_manual_control_state_returns_idle_when_no_manual_session() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)
        XCTAssertEqual(engine.manualControlState, .idle)
    }

    func test_manual_control_state_returns_idle_after_end() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        _ = engine.endManualFocus(at: clock.now)
        XCTAssertEqual(engine.manualControlState, .idle)
    }

    func test_manual_project_is_preserved_through_pause_resume() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)
        _ = engine.pauseManualFocus(at: clock.now)
        clock.advance(by: 10)
        _ = engine.resumeManualFocus(at: clock.now)

        guard case .focusing(let p, _, _) = engine.manualControlState else {
            return XCTFail("Expected focusing")
        }
        XCTAssertEqual(p, projectA)
    }

    func test_only_one_open_manual_session_at_a_time() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)
        _ = engine.startManualFocus(project: projectB, at: clock.now)

        let open = engine.allSessions.filter(\.isOpen)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].mode, .manual)
    }

    // MARK: - End manual focus edge cases

    func test_end_manual_focus_when_idle_is_noop() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        let result = engine.endManualFocus(at: clock.now)
        XCTAssertEqual(result, .noChange)
    }

    func test_crash_recovery_preserves_manual_mode_in_ended_session() {
        let store = MemoryStore()
        let priorSession = FocusSession(
            id: UUID(),
            project: projectA,
            dayIdentifier: "2001-01-24",
            startedAt: Date(timeIntervalSinceReferenceDate: 900),
            endedAt: Date(timeIntervalSinceReferenceDate: 950),
            status: .ended,
            lastUserActivityAt: Date(timeIntervalSinceReferenceDate: 950),
            lastStateChangeAt: Date(timeIntervalSinceReferenceDate: 950),
            mode: .manual
        )
        store.stored = [priorSession]

        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let engine = makeEngine(clock, store)

        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].mode, .manual)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
    }

    func test_after_manual_end_auto_detection_starts_fresh_without_backfill() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)
        _ = engine.endManualFocus(at: clock.now)

        clock.advance(by: 20)
        _ = engine.userActivity(in: projectB, at: clock.now, reason: .userActivity)

        XCTAssertEqual(engine.allSessions.count, 2)

        let autoSession = engine.allSessions[1]
        XCTAssertEqual(autoSession.startedAt, clock.now)
        XCTAssertEqual(autoSession.mode, .automatic)
    }

    // MARK: - Resume / end edge cases

    func test_resume_manual_focus_when_idle_is_noop() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        let result = engine.resumeManualFocus(at: clock.now)
        XCTAssertEqual(result, .noChange)
    }

    func test_end_manual_focus_twice_is_idempotent() {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let store = MemoryStore()
        let engine = makeEngine(clock, store)

        _ = engine.startManualFocus(project: projectA, at: clock.now)
        clock.advance(by: 10)

        let firstEnd = engine.endManualFocus(at: clock.now)
        XCTAssertEqual(firstEnd, .saved)

        let secondEnd = engine.endManualFocus(at: clock.now)
        XCTAssertEqual(secondEnd, .noChange)

        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
    }
}
