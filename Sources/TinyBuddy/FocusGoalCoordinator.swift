import Foundation
import OSLog
import TinyBuddyCore

/// Coordinates the focus goal configuration, reminder evaluation, and
/// notification delivery. Owned by `AppDelegate` and wired into the
/// focus session lifecycle.
@MainActor
final class FocusGoalCoordinator {
    private let preferencesStore: FocusGoalPreferencesStore
    private let notificationManager: FocusNotificationManager
    private let logger: Logger

    init(
        preferencesStore: FocusGoalPreferencesStore = FocusGoalPreferencesStore(),
        notificationManager: FocusNotificationManager? = nil,
        logger: Logger = Logger(subsystem: "local.tinybuddy", category: "FocusGoal")
    ) {
        self.preferencesStore = preferencesStore
        self.notificationManager = notificationManager ?? FocusNotificationManager()
        self.logger = logger
    }

    /// Current configuration.
    var configuration: FocusGoalConfiguration {
        preferencesStore.loadConfiguration()
    }

    /// Updates and persists the configuration.
    func saveConfiguration(_ config: FocusGoalConfiguration) {
        preferencesStore.saveConfiguration(config)
        logger.notice("Focus goal configuration saved")
    }

    /// Returns goal progress info for display.
    func goalProgress(sessions: [FocusSession], now: Date, dayIdentifier: String) -> FocusGoalProgress {
        let config = configuration
        let totalDuration = sessions
            .filter { $0.dayIdentifier == dayIdentifier }
            .reduce(0) { $0 + $1.activeDuration(now: now) }
        let goalSeconds = TimeInterval(config.dailyFocusGoalMinutes * 60)
        return FocusGoalProgress(
            focusDuration: totalDuration,
            goalSeconds: goalSeconds,
            isCompleted: goalSeconds > 0 && totalDuration >= goalSeconds,
            continuousFocusThresholdMinutes: config.continuousFocusThresholdMinutes,
            breakDurationMinutes: config.breakDurationMinutes,
            isBreakReminderEnabled: config.isBreakReminderEnabled,
            isGoalCompletionEnabled: config.isGoalCompletionEnabled
        )
    }

    /// Evaluates reminders based on current sessions and state.
    /// Call this whenever the focus session state changes.
    /// Returns what action was taken, so callers can react.
    @discardableResult
    func evaluateReminders(
        sessions: [FocusSession],
        now: Date,
        dayIdentifier: String
    ) -> FocusReminderAction {
        let config = configuration
        let state = preferencesStore.validateReminderState(for: dayIdentifier)
        let isInQuietHours = checkQuietHours(config: config, now: now)
        let isDND = isSystemDND()

        let evaluation = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: config,
            state: state,
            now: now,
            dayIdentifier: dayIdentifier,
            isInQuietHours: isInQuietHours,
            isSystemDND: isDND
        )

        // Persist updated state regardless of action.
        preferencesStore.saveReminderState(evaluation.updatedState)

        // Deliver based on action.
        switch evaluation.action {
        case .none:
            break
        case .breakReminder(let duration):
            Task {
                await notificationManager.deliverBreakReminder(continuousDuration: duration)
            }
        case .goalCompleted(let duration, let minutes):
            Task {
                await notificationManager.deliverGoalCompleted(focusDuration: duration, goalMinutes: minutes)
            }
        }

        return evaluation.action
    }

    /// Kept as a compatibility no-op for settings callers. Reminder state is
    /// persisted and evaluated from the current session snapshot, so an
    /// in-memory cache cannot become stale after configuration changes.
    func resetEvaluationCache() {}

    /// Checks user preference quiet hours.
    private func checkQuietHours(config: FocusGoalConfiguration, now: Date) -> Bool {
        guard let startHour = config.quietModeStartHour,
              let endHour = config.quietModeEndHour else {
            return false
        }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        if startHour < endHour {
            // Same-day interval, e.g. 08:00–22:00.
            return hour >= startHour && hour < endHour
        } else if startHour > endHour {
            // Overnight interval, e.g. 22:00–08:00.
            return hour >= startHour || hour < endHour
        } else {
            // Equal endpoints represent a full-day quiet interval.
            return true
        }
    }

    /// Focus modes are enforced by macOS at notification delivery time. The
    /// app must not infer DND from its own foreground state: TinyBuddy is
    /// normally inactive while the user is doing the focused work.
    private func isSystemDND() -> Bool {
        false
    }
}


