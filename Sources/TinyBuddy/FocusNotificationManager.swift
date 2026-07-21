import AppKit
import Foundation
import OSLog
import TinyBuddyCore
@preconcurrency import UserNotifications

/// Manages macOS notification delivery for focus goal and break reminders.
/// All public methods are `@MainActor`-safe and designed for use from the
/// app's main actor context.
@MainActor
final class FocusNotificationManager {
    private let notificationCenter: UNUserNotificationCenter
    private let logger: Logger

    private enum Identifier {
        static let breakReminder = "tinybuddy.focus.breakReminder"
        static let goalCompleted = "tinybuddy.focus.goalCompleted"
    }

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        logger: Logger = Logger(subsystem: "local.tinybuddy", category: "FocusNotification")
    ) {
        self.notificationCenter = notificationCenter
        self.logger = logger
    }

    // MARK: - Authorization

    /// Whether notification permission has been granted.
    func isAuthorized() async -> Bool {
        let center = notificationCenter
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    /// Requests notification permission. Returns true if granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            if granted {
                logger.notice("Notification authorization granted")
            } else {
                logger.notice("Notification authorization denied")
            }
            return granted
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Opens System Settings to the Notifications pane for this app.
    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
    }

    // MARK: - Deliver

    /// Delivers a break reminder notification. No‑op if not authorized.
    func deliverBreakReminder(continuousDuration: TimeInterval) async {
        guard await isAuthorized() else {
            logger.notice("Break reminder suppressed — notification not authorized")
            return
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
        } catch {
            logger.error("Failed to deliver break reminder: \(error.localizedDescription)")
        }
    }

    /// Delivers a daily goal completion notification. No‑op if not authorized.
    func deliverGoalCompleted(focusDuration: TimeInterval, goalMinutes: Int) async {
        guard await isAuthorized() else {
            logger.notice("Goal completion suppressed — notification not authorized")
            return
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
        } catch {
            logger.error("Failed to deliver goal completion: \(error.localizedDescription)")
        }
    }

    /// Removes all pending focus-related notification requests.
    func removeAllPending() {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [
            Identifier.breakReminder,
            Identifier.goalCompleted
        ])
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [
            Identifier.breakReminder,
            Identifier.goalCompleted
        ])
    }
}
