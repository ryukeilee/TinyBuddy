import Foundation
import XCTest
@testable import TinyBuddyCore

// MARK: - Helpers

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

private let projectA = FocusProjectContext(key: "repo/a", displayName: "Project A")

private let dayID = "2026-07-21"

/// An active session that started `activeSeconds` before `now`,
/// giving exactly `activeSeconds` of continuous focus.
private func activeSession(activeSeconds: TimeInterval, now: Date, id: UUID = UUID()) -> FocusSession {
    FocusSession(
        id: id,
        project: projectA,
        dayIdentifier: dayID,
        startedAt: now.addingTimeInterval(-activeSeconds),
        status: .active,
        lastUserActivityAt: now,
        lastStateChangeAt: now
    )
}

/// An ended session that ran for `durationSeconds`.
private func endedSession(durationSeconds: TimeInterval) -> FocusSession {
    let end = t0.addingTimeInterval(7200)
    let start = end.addingTimeInterval(-durationSeconds)
    return FocusSession(
        project: projectA,
        dayIdentifier: dayID,
        startedAt: start,
        endedAt: end,
        status: .ended,
        lastUserActivityAt: end,
        lastStateChangeAt: end
    )
}

final class FocusReminderEngineTests: XCTestCase {
    /// Fixed "now" for all tests.
    private let now = t0.addingTimeInterval(7200)

    private let defaultConfig = FocusGoalConfiguration()

    // MARK: - No-op cases

    func test_no_active_session_returns_none() {
        let sessions: [FocusSession] = [endedSession(durationSeconds: 3000)]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.updatedState, state)
    }

    func test_cooling_interval_suppresses_reminder() {
        let sessionID = UUID()
        let sessions = [activeSession(activeSeconds: 4000, now: now, id: sessionID)]
        var state = FocusReminderState(dayIdentifier: dayID)
        state.lastReminderDeliveryDate = now.addingTimeInterval(-120) // 2 min ago (< 5 min cooling)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
    }

    func test_quiet_hours_suppresses_reminder() {
        let sessions = [activeSession(activeSeconds: 4000, now: now)]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID,
            isInQuietHours: true
        )

        XCTAssertEqual(result.action, .none)
    }

    func test_system_dnd_suppresses_reminder() {
        let sessions = [activeSession(activeSeconds: 4000, now: now)]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID,
            isSystemDND: true
        )

        XCTAssertEqual(result.action, .none)
    }

    func test_disabled_break_reminder_returns_none() {
        var config = defaultConfig
        config.isBreakReminderEnabled = false
        let sessions = [activeSession(activeSeconds: 4000, now: now)]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: config,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
    }

    func test_disabled_goal_completion_returns_none_when_not_goal() {
        var config = defaultConfig
        config.isGoalCompletionEnabled = false
        let thresholdSeconds = TimeInterval(defaultConfig.dailyFocusGoalMinutes * 60 + 100)
        let sessions = [endedSession(durationSeconds: thresholdSeconds)]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: config,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
    }

    // MARK: - Break Reminder

    func test_break_reminder_fires_when_threshold_exceeded() {
        let sessionID = UUID()
        let thresholdSeconds = TimeInterval(defaultConfig.continuousFocusThresholdMinutes * 60)
        let sessions = [activeSession(activeSeconds: thresholdSeconds + 10, now: now, id: sessionID)]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        guard case .breakReminder(let duration) = result.action else {
            XCTFail("Expected breakReminder, got \(result.action)")
            return
        }
        XCTAssertGreaterThanOrEqual(duration, thresholdSeconds)
        XCTAssertTrue(result.updatedState.triggeredBreakReminderSessionIDs.contains(sessionID))
        XCTAssertNotNil(result.updatedState.lastReminderDeliveryDate)
    }

    func test_break_reminder_not_fired_below_threshold() {
        let thresholdSeconds = TimeInterval(defaultConfig.continuousFocusThresholdMinutes * 60)
        // Active for 1 minute only — well below the 50-minute threshold.
        let sessions = [activeSession(activeSeconds: 60, now: now)]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
    }

    func test_break_reminder_dedup_same_session() {
        let sessionID = UUID()
        let sessions = [activeSession(activeSeconds: 4000, now: now, id: sessionID)]
        var state = FocusReminderState(dayIdentifier: dayID)
        state.triggeredBreakReminderSessionIDs = [sessionID] // Already reminded

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
    }

    func test_break_reminder_different_session_allows_new() {
        let sessionID1 = UUID()
        let sessionID2 = UUID()
        let sessions = [activeSession(activeSeconds: 4000, now: now, id: sessionID2)]
        var state = FocusReminderState(dayIdentifier: dayID)
        state.triggeredBreakReminderSessionIDs = [sessionID1] // Different session already reminded

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        guard case .breakReminder = result.action else {
            XCTFail("Expected breakReminder for new session")
            return
        }
    }

    func test_break_reminder_daily_cap() {
        let sessions = [activeSession(activeSeconds: 4000, now: now)]
        var state = FocusReminderState(dayIdentifier: dayID)
        // Fill up to cap
        state.triggeredBreakReminderSessionIDs = (0..<FocusReminderEngine.maxBreakRemindersPerDay).map { _ in UUID() }

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
    }

    // MARK: - Goal Completion

    func test_goal_completion_fires_when_goal_reached() {
        let exceededMinutes = defaultConfig.dailyFocusGoalMinutes + 10
        let sessions = [endedSession(durationSeconds: TimeInterval(exceededMinutes * 60))]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        guard case .goalCompleted(let duration, let minutes) = result.action else {
            XCTFail("Expected goalCompleted, got \(result.action)")
            return
        }
        XCTAssertGreaterThanOrEqual(duration, TimeInterval(defaultConfig.dailyFocusGoalMinutes * 60))
        XCTAssertEqual(minutes, defaultConfig.dailyFocusGoalMinutes)
        XCTAssertTrue(result.updatedState.goalCompletedNotified)
    }

    func test_goal_completion_not_fired_below_goal() {
        let minutes = defaultConfig.dailyFocusGoalMinutes - 5
        let sessions = [endedSession(durationSeconds: TimeInterval(minutes * 60))]
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
    }

    func test_goal_completion_dedup() {
        let exceededMinutes = defaultConfig.dailyFocusGoalMinutes + 10
        let sessions = [endedSession(durationSeconds: TimeInterval(exceededMinutes * 60))]
        var state = FocusReminderState(dayIdentifier: dayID)
        state.goalCompletedNotified = true

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result.action, .none)
    }

    // MARK: - Day boundary

    func test_day_boundary_resets_state() {
        let oldDayID = "2026-07-20"
        let sessionID = UUID()
        // Use a short active session so the new-day check doesn't fire a break reminder.
        let sessions = [activeSession(activeSeconds: 60, now: now, id: sessionID)]
        var state = FocusReminderState(dayIdentifier: oldDayID)
        state.goalCompletedNotified = true
        state.triggeredBreakReminderSessionIDs = [sessionID]

        let result = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: defaultConfig,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        // State should be reset for new day
        XCTAssertEqual(result.updatedState.dayIdentifier, dayID)
        XCTAssertFalse(result.updatedState.goalCompletedNotified)
        XCTAssertTrue(result.updatedState.triggeredBreakReminderSessionIDs.isEmpty)
    }

    // MARK: - Multi-session goal computation

    func test_goal_progress_aggregates_multiple_sessions() {
        var config = defaultConfig
        config.dailyFocusGoalMinutes = 30 // Make it easy
        let s1 = endedSession(durationSeconds: 1200) // 20 min
        let s2 = endedSession(durationSeconds: 1200) // 20 min = 40 min total
        let state = FocusReminderState(dayIdentifier: dayID)

        let result = FocusReminderEngine.evaluate(
            allSessions: [s1, s2],
            config: config,
            state: state,
            now: now,
            dayIdentifier: dayID
        )

        guard case .goalCompleted = result.action else {
            XCTFail("Expected goalCompleted for 40 min against 30 min goal")
            return
        }
    }

    // MARK: - FocusGoalProgress

    func test_goal_progress_computation() {
        let progress = FocusGoalProgress(
            focusDuration: 7200, // 2 hours
            goalSeconds: 14400,  // 4 hours
            isCompleted: false,
            continuousFocusThresholdMinutes: 50,
            breakDurationMinutes: 10,
            isBreakReminderEnabled: true,
            isGoalCompletionEnabled: true
        )

        XCTAssertEqual(progress.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(progress.remainingMinutes, 120)
        XCTAssertEqual(progress.formattedProgress, "120/240 分钟")
        XCTAssertFalse(progress.isCompleted)
    }

    func test_goal_progress_overachievement() {
        let progress = FocusGoalProgress(
            focusDuration: 18000, // 5 hours
            goalSeconds: 14400,   // 4 hours
            isCompleted: true,
            continuousFocusThresholdMinutes: 50,
            breakDurationMinutes: 10,
            isBreakReminderEnabled: true,
            isGoalCompletionEnabled: true
        )

        XCTAssertGreaterThan(progress.progress, 1.0)
        XCTAssertTrue(progress.isCompleted)
        XCTAssertEqual(progress.remainingMinutes, -60)
    }

    func test_goal_progress_zero_goal() {
        let progress = FocusGoalProgress(
            focusDuration: 100,
            goalSeconds: 0,
            isCompleted: false,
            continuousFocusThresholdMinutes: 50,
            breakDurationMinutes: 10,
            isBreakReminderEnabled: true,
            isGoalCompletionEnabled: true
        )

        XCTAssertEqual(progress.progress, 0)
        XCTAssertFalse(progress.isCompleted)
    }
}
