import Foundation
import OSLog
import TinyBuddyCore

/// Coordinates the focus goal configuration, reminder evaluation, and
/// notification delivery. Owned by `AppDelegate` and wired into the
/// focus session lifecycle.
@MainActor
final class FocusGoalCoordinator {
    private let preferencesStore: FocusGoalPreferencesStore
    private let notificationManager: FocusNotificationDelivering
    private let logger: Logger

    init(
        preferencesStore: FocusGoalPreferencesStore = FocusGoalPreferencesStore(),
        notificationManager: FocusNotificationDelivering? = nil,
        logger: Logger = Logger(subsystem: "local.tinybuddy", category: "FocusGoal")
    ) {
        self.preferencesStore = preferencesStore
        self.notificationManager = notificationManager ?? (FocusNotificationManager() as FocusNotificationDelivering)
        self.logger = logger
    }

    /// Current configuration.
    var configuration: FocusGoalConfiguration {
        preferencesStore.loadConfiguration()
    }

    /// Updates and persists the configuration. Returns whether the write
    /// succeeded so callers can surface a failure instead of discarding edits.
    @discardableResult
    func saveConfiguration(_ config: FocusGoalConfiguration) -> Bool {
        let saved = preferencesStore.saveConfiguration(config)
        if saved {
            logger.notice("Focus goal configuration saved")
        } else {
            logger.error("Focus goal configuration could not be persisted")
        }
        return saved
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
    ) async -> FocusReminderAction {
        let config = configuration
        let state = preferencesStore.validateReminderState(for: dayIdentifier)
        let isInQuietHours = checkQuietHours(config: config, now: now)
        let canDeliver = await notificationManager.canDeliver()

        // Reconcile the system notification queue with deliverability and the
        // currently enabled features. A request that can never be presented,
        // or a delivered alert for a feature the user has turned off, is
        // removed promptly instead of lingering in Notification Center.
        if !canDeliver {
            notificationManager.removePendingFocusNotifications()
        }
        if !config.isBreakReminderEnabled {
            notificationManager.removeDeliveredBreakReminder()
        }
        if !config.isGoalCompletionEnabled {
            notificationManager.removeDeliveredGoalCompletion()
        }

        // The engine only gates a reminder as delivered when it can actually
        // be presented. When permission is missing, the gate is left open so
        // the still-valid reminder is re-evaluated after permission returns.
        // System Focus modes are enforced by macOS at delivery time and the
        // app must not infer DND from its own foreground state: TinyBuddy is
        // normally inactive while the user is doing the focused work.
        let evaluation = FocusReminderEngine.evaluate(
            allSessions: sessions,
            config: config,
            state: state,
            now: now,
            dayIdentifier: dayIdentifier,
            isInQuietHours: isInQuietHours,
            isSystemDND: false,
            canDeliverNotifications: canDeliver
        )

        // Persist updated state regardless of action.
        preferencesStore.saveReminderState(evaluation.updatedState)

        // Deliver based on action. `canDeliver` was already true for any
        // non-`.none` action, and the deliver methods re-check as a guard.
        switch evaluation.action {
        case .none:
            break
        case .breakReminder(let duration):
            _ = await notificationManager.deliverBreakReminder(continuousDuration: duration)
        case .goalCompleted(let duration, let minutes):
            _ = await notificationManager.deliverGoalCompleted(focusDuration: duration, goalMinutes: minutes)
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
}


