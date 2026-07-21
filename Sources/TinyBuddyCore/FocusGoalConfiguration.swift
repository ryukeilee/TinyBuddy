import Foundation

// MARK: - Goal Configuration

/// User-configurable focus goal and break reminder preferences.
/// Stored independently from `TinyBuddyAppConfig` to avoid coupling
/// to the app-level config versioning scheme.
public struct FocusGoalConfiguration: Codable, Equatable, Sendable {
    /// Daily focus target in minutes (default: 240 = 4 hours).
    public var dailyFocusGoalMinutes: Int
    /// Continuous focus time in minutes before a break reminder fires (default: 50).
    public var continuousFocusThresholdMinutes: Int
    /// Suggested break duration in minutes (default: 10).
    public var breakDurationMinutes: Int
    /// Whether break reminders are enabled.
    public var isBreakReminderEnabled: Bool
    /// Whether daily-goal-completion feedback is enabled.
    public var isGoalCompletionEnabled: Bool
    /// Optional quiet-mode start hour (0–23). When set, reminders are suppressed.
    public var quietModeStartHour: Int?
    /// Optional quiet-mode end hour (0–23).
    public var quietModeEndHour: Int?

    /// Conservative defaults for existing users — never surprise on first launch.
    public static let `default` = FocusGoalConfiguration(
        dailyFocusGoalMinutes: 240,
        continuousFocusThresholdMinutes: 50,
        breakDurationMinutes: 10,
        isBreakReminderEnabled: true,
        isGoalCompletionEnabled: true,
        quietModeStartHour: 22,
        quietModeEndHour: 8
    )

    public init(
        dailyFocusGoalMinutes: Int = 240,
        continuousFocusThresholdMinutes: Int = 50,
        breakDurationMinutes: Int = 10,
        isBreakReminderEnabled: Bool = true,
        isGoalCompletionEnabled: Bool = true,
        quietModeStartHour: Int? = 22,
        quietModeEndHour: Int? = 8
    ) {
        self.dailyFocusGoalMinutes = max(1, dailyFocusGoalMinutes)
        self.continuousFocusThresholdMinutes = max(1, continuousFocusThresholdMinutes)
        self.breakDurationMinutes = max(1, breakDurationMinutes)
        self.isBreakReminderEnabled = isBreakReminderEnabled
        self.isGoalCompletionEnabled = isGoalCompletionEnabled
        self.quietModeStartHour = quietModeStartHour
        self.quietModeEndHour = quietModeEndHour
    }
}

// MARK: - Reminder State (persisted)

/// Per-day reminder delivery state. Prevents duplicate notifications across
/// app restarts, multiple wake-up paths, and cross-day persistence.
public struct FocusReminderState: Codable, Equatable, Sendable {
    /// The day this state applies to.
    public var dayIdentifier: String
    /// IDs of focus sessions for which a break reminder was already sent.
    public var triggeredBreakReminderSessionIDs: [UUID]
    /// Whether the daily goal completion notification was already sent.
    public var goalCompletedNotified: Bool
    /// Last time a reminder was delivered (for cooling interval checks).
    public var lastReminderDeliveryDate: Date?

    public init(
        dayIdentifier: String,
        triggeredBreakReminderSessionIDs: [UUID] = [],
        goalCompletedNotified: Bool = false,
        lastReminderDeliveryDate: Date? = nil
    ) {
        self.dayIdentifier = dayIdentifier
        self.triggeredBreakReminderSessionIDs = triggeredBreakReminderSessionIDs
        self.goalCompletedNotified = goalCompletedNotified
        self.lastReminderDeliveryDate = lastReminderDeliveryDate
    }

    /// Returns a new state reset for the given day. Does NOT mutate self.
    public func reset(for newDay: String) -> FocusReminderState {
        FocusReminderState(dayIdentifier: newDay)
    }
}

// MARK: - Preferences Store

/// Persists `FocusGoalConfiguration` and `FocusReminderState` via the shared
/// App Group container so all processes (App, Widget) read the same values.
public final class FocusGoalPreferencesStore {
    private let defaults: UserDefaults

    private enum Key {
        static let configuration = "tinybuddy.focusGoal.configuration.v1"
        static let reminderState = "tinybuddy.focusGoal.reminderState.v1"
        static let dayIdentifier = "tinybuddy.focusGoal.dayIdentifier.v1"
    }

    public init(userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()) {
        self.defaults = userDefaults
    }

    // MARK: Configuration

    public func loadConfiguration() -> FocusGoalConfiguration {
        guard let data = defaults.data(forKey: Key.configuration),
              let config = try? JSONDecoder().decode(FocusGoalConfiguration.self, from: data) else {
            return .default
        }
        return config
    }

    @discardableResult
    public func saveConfiguration(_ config: FocusGoalConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }
        defaults.set(data, forKey: Key.configuration)
        defaults.synchronize()
        return true
    }

    // MARK: Reminder State

    public func loadReminderState(for day: String) -> FocusReminderState? {
        guard let dayIdentifier = defaults.string(forKey: Key.dayIdentifier),
              dayIdentifier == day,
              let data = defaults.data(forKey: Key.reminderState),
              let state = try? JSONDecoder().decode(FocusReminderState.self, from: data) else {
            return nil
        }
        return state
    }

    public func saveReminderState(_ state: FocusReminderState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Key.reminderState)
        defaults.set(state.dayIdentifier, forKey: Key.dayIdentifier)
        defaults.synchronize()
    }

    /// Resets reminder state if the day changed. Returns the valid state for today.
    public func validateReminderState(for day: String) -> FocusReminderState {
        if let existing = loadReminderState(for: day) {
            return existing
        }
        // Day changed or first launch — reset.
        let fresh = FocusReminderState(dayIdentifier: day)
        saveReminderState(fresh)
        return fresh
    }
}

// MARK: - Reminder Action

/// The action a reminder engine evaluation produces.
public enum FocusReminderAction: Equatable, Sendable {
    /// No reminder should be delivered.
    case none
    /// A break is suggested because the user has been continuously focused.
    case breakReminder(continuousDuration: TimeInterval)
    /// The daily focus goal was reached.
    case goalCompleted(focusDuration: TimeInterval, goalMinutes: Int)
}

public struct FocusReminderEvaluation: Equatable, Sendable {
    public let action: FocusReminderAction
    public let updatedState: FocusReminderState

    public init(action: FocusReminderAction, updatedState: FocusReminderState) {
        self.action = action
        self.updatedState = updatedState
    }
}

// MARK: - Reminder Engine

/// Pure, deterministic reminder evaluator. Takes current sessions, config,
/// persisted state, and time; returns the action and the new state to persist.
/// The engine never sends notifications — it only decides what should happen.
public enum FocusReminderEngine {
    /// Minimum interval between any two reminders (seconds).
    public static let minimumCoolingInterval: TimeInterval = 300 // 5 minutes
    /// Maximum number of break reminders per day.
    public static let maxBreakRemindersPerDay = 6

    /// Evaluates whether a reminder should be delivered.
    /// - Parameters:
    ///   - allSessions: All sessions known to the engine (for the current day).
    ///   - config: Current goal configuration.
    ///   - state: Current persisted reminder state.
    ///   - now: Current date.
    ///   - dayIdentifier: Current local day identifier.
    ///   - isInQuietHours: Whether the system is in a period where reminders should be suppressed.
    ///   - isSystemDND: Whether the system focus mode / DND is active.
    /// - Returns: The evaluation result.
    public static func evaluate(
        allSessions: [FocusSession],
        config: FocusGoalConfiguration,
        state: FocusReminderState,
        now: Date,
        dayIdentifier: String,
        isInQuietHours: Bool = false,
        isSystemDND: Bool = false
    ) -> FocusReminderEvaluation {
        // Day boundary check — reset state if day changed.
        var currentState = state
        if currentState.dayIdentifier != dayIdentifier {
            currentState = currentState.reset(for: dayIdentifier)
        }

        // Skip all reminders during quiet hours or system DND.
        if isInQuietHours || isSystemDND {
            return FocusReminderEvaluation(action: .none, updatedState: currentState)
        }

        // Cooling: too soon since last reminder?
        if let lastDelivery = currentState.lastReminderDeliveryDate,
           now.timeIntervalSince(lastDelivery) < minimumCoolingInterval {
            return FocusReminderEvaluation(action: .none, updatedState: currentState)
        }

        // === Goal Completion Check ===
        if config.isGoalCompletionEnabled, !currentState.goalCompletedNotified {
            let totalFocusDuration = allSessions
                .filter { $0.dayIdentifier == dayIdentifier }
                .reduce(0) { $0 + $1.activeDuration(now: now) }
            let goalSeconds = TimeInterval(config.dailyFocusGoalMinutes * 60)
            if totalFocusDuration >= goalSeconds, goalSeconds > 0 {
                var newState = currentState
                newState.goalCompletedNotified = true
                newState.lastReminderDeliveryDate = now
                return FocusReminderEvaluation(
                    action: .goalCompleted(focusDuration: totalFocusDuration, goalMinutes: config.dailyFocusGoalMinutes),
                    updatedState: newState
                )
            }
        }

        // === Break Reminder Check ===
        if config.isBreakReminderEnabled {
            // Find the current active session(s). Only one can be open.
            guard let activeSession = allSessions.first(where: \.isOpen) else {
                return FocusReminderEvaluation(action: .none, updatedState: currentState)
            }

            // Only trigger break reminder for active sessions that haven't been
            // reminded yet.
            guard !currentState.triggeredBreakReminderSessionIDs.contains(activeSession.id) else {
                return FocusReminderEvaluation(action: .none, updatedState: currentState)
            }

            // Per-day cap.
            guard currentState.triggeredBreakReminderSessionIDs.count < maxBreakRemindersPerDay else {
                return FocusReminderEvaluation(action: .none, updatedState: currentState)
            }

            let continuousDuration = activeSession.activeDuration(now: now)
            let threshold = TimeInterval(config.continuousFocusThresholdMinutes * 60)

            if continuousDuration >= threshold {
                var newState = currentState
                newState.triggeredBreakReminderSessionIDs.append(activeSession.id)
                newState.lastReminderDeliveryDate = now
                return FocusReminderEvaluation(
                    action: .breakReminder(continuousDuration: continuousDuration),
                    updatedState: newState
                )
            }
        }

        return FocusReminderEvaluation(action: .none, updatedState: currentState)
    }
}

// MARK: - Goal Progress

/// Lightweight value type for display across App, HUD, and Widget surfaces.
public struct FocusGoalProgress: Equatable, Sendable {
    /// Total focus duration today (seconds).
    public let focusDuration: TimeInterval
    /// Daily goal in seconds.
    public let goalSeconds: TimeInterval
    /// Whether the goal has been reached.
    public let isCompleted: Bool
    /// Continuous focus threshold (minutes) for break reminder.
    public let continuousFocusThresholdMinutes: Int
    /// Suggested break duration (minutes).
    public let breakDurationMinutes: Int
    /// Whether break reminders are enabled.
    public let isBreakReminderEnabled: Bool
    /// Whether goal completion notification is enabled.
    public let isGoalCompletionEnabled: Bool

    /// Progress fraction (0.0–1.0+). May exceed 1.0 when over-achieving.
    public var progress: Double {
        guard goalSeconds > 0 else { return 0 }
        return focusDuration / goalSeconds
    }

    /// Formatted progress string, e.g. "120/240 分钟".
    public var formattedProgress: String {
        let current = Int(focusDuration / 60)
        let goal = Int(goalSeconds / 60)
        return "\(current)/\(goal) 分钟"
    }

    /// Remaining minutes to goal (negative if exceeded).
    public var remainingMinutes: Int {
        Int((goalSeconds - focusDuration) / 60)
    }

    public init(
        focusDuration: TimeInterval,
        goalSeconds: TimeInterval,
        isCompleted: Bool,
        continuousFocusThresholdMinutes: Int,
        breakDurationMinutes: Int,
        isBreakReminderEnabled: Bool,
        isGoalCompletionEnabled: Bool
    ) {
        self.focusDuration = focusDuration
        self.goalSeconds = goalSeconds
        self.isCompleted = isCompleted
        self.continuousFocusThresholdMinutes = continuousFocusThresholdMinutes
        self.breakDurationMinutes = breakDurationMinutes
        self.isBreakReminderEnabled = isBreakReminderEnabled
        self.isGoalCompletionEnabled = isGoalCompletionEnabled
    }
}
