import AppKit
import Foundation
import OSLog
import TinyBuddyCore
@preconcurrency import UserNotifications

/// The deliverability of TinyBuddy's focus notifications, derived from the
/// system's current `UNNotificationSettings`. This is the single source of
/// truth for both the settings UI and the delivery pipeline so the two can
/// never disagree about whether a notification will actually be presented.
enum NotificationPermissionState: Equatable, Sendable {
    /// The user has not yet been asked for permission.
    case notDetermined
    /// Permission granted and system alerts/banners are enabled — a focus
    /// alert created now would actually be presented.
    case authorized
    /// Permission granted but the user has turned off alerts/banners for
    /// TinyBuddy in System Settings. The system still accepts requests but
    /// never presents them, so the app must treat this as not deliverable.
    case alertsDisabled
    /// The user denied permission, or later disabled the master switch.
    case denied
    /// An unexpected authorization status (provisional, ephemeral, …).
    case unknown
}

/// A snapshot of the notification settings that matter for deliverability,
/// decoupled from the concrete `UNNotificationSettings` object so tests can
/// fabricate any state without touching the real notification system.
struct FocusNotificationSettingsSnapshot: Equatable, Sendable {
    let authorizationStatus: UNAuthorizationStatus
    let alertSetting: UNNotificationSetting
}

/// Abstraction over the pieces of `UNUserNotificationCenter` the focus
/// notification pipeline uses, so the manager is unit-testable.
@MainActor
protocol FocusNotificationCenter {
    func notificationSettingsSnapshot() async -> FocusNotificationSettingsSnapshot
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: FocusNotificationCenter {
    func notificationSettingsSnapshot() async -> FocusNotificationSettingsSnapshot {
        let settings = await notificationSettings()
        return FocusNotificationSettingsSnapshot(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting
        )
    }
}

/// The delivery/cleanup surface the focus goal coordinator depends on. Split
/// from the concrete manager so the coordinator's gate-on-deliverable logic
/// can be unit-tested with a fake.
@MainActor
protocol FocusNotificationDelivering {
    func canDeliver() async -> Bool
    @discardableResult
    func deliverBreakReminder(continuousDuration: TimeInterval) async -> Bool
    @discardableResult
    func deliverGoalCompleted(focusDuration: TimeInterval, goalMinutes: Int) async -> Bool
    func removePendingFocusNotifications()
    func removeDeliveredBreakReminder()
    func removeDeliveredGoalCompletion()
}

/// Manages macOS notification delivery for focus goal and break reminders.
/// All public methods are `@MainActor`-safe and designed for use from the
/// app's main actor context.
@MainActor
final class FocusNotificationManager: FocusNotificationDelivering {
    private let notificationCenter: FocusNotificationCenter
    private let logger: Logger

    private enum Identifier {
        static let breakReminder = "tinybuddy.focus.breakReminder"
        static let goalCompleted = "tinybuddy.focus.goalCompleted"
    }

    init(
        notificationCenter: FocusNotificationCenter = UNUserNotificationCenter.current(),
        logger: Logger = Logger(subsystem: "local.tinybuddy", category: "FocusNotification")
    ) {
        self.notificationCenter = notificationCenter
        self.logger = logger
    }

    // MARK: - Authorization

    /// The current permission state, read live from the system so the UI and
    /// the delivery pipeline always reflect reality.
    func permissionState() async -> NotificationPermissionState {
        let snapshot = await notificationCenter.notificationSettingsSnapshot()
        switch snapshot.authorizationStatus {
        case .authorized:
            return snapshot.alertSetting == .enabled ? .authorized : .alertsDisabled
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        default:
            return .unknown
        }
    }

    /// Whether a focus alert created right now would actually be presented.
    func canDeliver() async -> Bool {
        await permissionState() == .authorized
    }

    /// Requests notification permission. Returns the resulting state re-read
    /// from the system so the caller's UI matches what the user actually chose.
    @discardableResult
    func requestAuthorization() async -> NotificationPermissionState {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            if granted {
                logger.notice("Notification authorization granted")
            } else {
                logger.notice("Notification authorization denied")
            }
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription)")
        }
        return await permissionState()
    }

    /// Opens System Settings to the Notifications pane for this app.
    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
    }

    // MARK: - Deliver

    /// Delivers a break reminder notification. No‑op and returns false if the
    /// notification cannot actually be presented.
    @discardableResult
    func deliverBreakReminder(continuousDuration: TimeInterval) async -> Bool {
        guard await canDeliver() else {
            logger.notice("Break reminder suppressed — notifications not deliverable")
            return false
        }
        let minutes = Int(continuousDuration / 60)
        let content = UNMutableNotificationContent()
        content.title = "专注休息提醒"
        content.body = "你已经连续专注 \(minutes) 分钟，建议短暂休息一下。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Identifier.breakReminder,
            content: content,
            trigger: nil // Deliver immediately.
        )
        do {
            try await notificationCenter.add(request)
            logger.notice("Break reminder delivered: \(minutes) minutes continuous")
            return true
        } catch {
            logger.error("Failed to deliver break reminder: \(error.localizedDescription)")
            return false
        }
    }

    /// Delivers a daily goal completion notification. No‑op and returns false
    /// if the notification cannot actually be presented.
    @discardableResult
    func deliverGoalCompleted(focusDuration: TimeInterval, goalMinutes: Int) async -> Bool {
        guard await canDeliver() else {
            logger.notice("Goal completion suppressed — notifications not deliverable")
            return false
        }
        let totalMinutes = Int(focusDuration / 60)
        let content = UNMutableNotificationContent()
        content.title = "今日专注目标达成！"
        content.body = "已完成 \(goalMinutes) 分钟专注目标，实际专注 \(totalMinutes) 分钟，干得不错！"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Identifier.goalCompleted,
            content: content,
            trigger: nil
        )
        do {
            try await notificationCenter.add(request)
            logger.notice("Goal completion delivered: \(totalMinutes) minutes")
            return true
        } catch {
            logger.error("Failed to deliver goal completion: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cleanup

    /// Removes pending (scheduled) focus requests. Called whenever delivery is
    /// impossible so invalid requests are cleared promptly instead of lingering.
    func removePendingFocusNotifications() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [
            Identifier.breakReminder,
            Identifier.goalCompleted
        ])
    }

    /// Removes any delivered break reminder. Called when the feature is
    /// disabled so Notification Center no longer shows an alert the user
    /// opted out of.
    func removeDeliveredBreakReminder() {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [Identifier.breakReminder])
    }

    /// Removes any delivered goal completion. Called when the feature is
    /// disabled so Notification Center no longer shows an alert the user
    /// opted out of.
    func removeDeliveredGoalCompletion() {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [Identifier.goalCompleted])
    }

    /// Removes all focus-related pending and delivered notifications.
    func removeAllPending() {
        removePendingFocusNotifications()
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [
            Identifier.breakReminder,
            Identifier.goalCompleted
        ])
    }
}
