import AppKit
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

    /// Cached evaluation to avoid redundant work.
    private var lastEvaluatedState: FocusReminderState?

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
        lastEvaluatedState = evaluation.updatedState

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

    /// Resets in-memory cached evaluation state (e.g., after a config change).
    func resetEvaluationCache() {
        lastEvaluatedState = nil
    }

    /// Checks user preference quiet hours.
    private func checkQuietHours(config: FocusGoalConfiguration, now: Date) -> Bool {
        guard let startHour = config.quietModeStartHour,
              let endHour = config.quietModeEndHour else {
            return false
        }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        if startHour <= endHour {
            // e.g., 22:00 – 08:00 (same-day end means through next morning)
            return hour >= startHour || hour < endHour
        } else {
            // endHour is smaller, meaning it wraps to next day
            return hour >= startHour || hour < endHour
        }
    }

    /// Checks system-level DND / focus mode status.
    private func isSystemDND() -> Bool {
        // On macOS 14+, we can check the focus mode via
        // NSWorkspace.shared.isActive or DistributedNotificationCenter.
        // As a conservative fallback, check if the screen is asleep or
        // the session is not active.
        if NSWorkspace.shared.frontmostApplication == nil {
            return true
        }
        // Simple heuristic: treat as DND if the app is not active.
        return !NSApp.isActive
    }
}


