import Foundation
import XCTest
import UserNotifications
@testable import TinyBuddy
@testable import TinyBuddyCore

/// Verifies the notification permission/delivery pipeline: the manager maps
/// system settings to a deliverability state, delivery is skipped when a
/// notification cannot be presented, cleanup routes the right identifiers,
/// and the coordinator only gates a reminder as delivered when it can actually
/// be delivered — so reminders suppressed while permission is missing stay
/// eligible and are recalculated after permission returns.
@MainActor
final class FocusNotificationDeliveryTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000 + 7200)
    private let dayID = "2026-08-06"
    private let project = FocusProjectContext(key: "repo/a", displayName: "Project A")

    // MARK: - FocusNotificationManager: permission state

    func testPermissionStateMapsSystemSettings() async {
        let enabled = await makeManager(status: .authorized, alert: .enabled).permissionState()
        XCTAssertEqual(enabled, .authorized)

        let alertsOff = await makeManager(status: .authorized, alert: .disabled).permissionState()
        XCTAssertEqual(alertsOff, .alertsDisabled)

        let denied = await makeManager(status: .denied, alert: .enabled).permissionState()
        XCTAssertEqual(denied, .denied)

        let notDetermined = await makeManager(status: .notDetermined, alert: .enabled).permissionState()
        XCTAssertEqual(notDetermined, .notDetermined)
    }

    func testCanDeliverRequiresAuthorizedAndAlertsEnabled() async {
        let alertsOff = await makeManager(status: .authorized, alert: .disabled).canDeliver()
        XCTAssertFalse(alertsOff)

        let enabled = await makeManager(status: .authorized, alert: .enabled).canDeliver()
        XCTAssertTrue(enabled)

        let denied = await makeManager(status: .denied, alert: .enabled).canDeliver()
        XCTAssertFalse(denied)

        let notDetermined = await makeManager(status: .notDetermined, alert: .enabled).canDeliver()
        XCTAssertFalse(notDetermined)
    }

    // MARK: - FocusNotificationManager: delivery guard

    func testDeliverBreakReminderNoOpWhenNotDeliverable() async {
        let fake = FakeNotificationCenter()
        fake.authorizationStatus = .denied
        let manager = FocusNotificationManager(notificationCenter: fake)

        let delivered = await manager.deliverBreakReminder(continuousDuration: 3600)

        XCTAssertFalse(delivered)
        XCTAssertTrue(fake.addedRequests.isEmpty)
    }

    func testDeliverBreakReminderNoOpWhenAlertsDisabled() async {
        let fake = FakeNotificationCenter()
        fake.authorizationStatus = .authorized
        fake.alertSetting = .disabled
        let manager = FocusNotificationManager(notificationCenter: fake)

        let delivered = await manager.deliverBreakReminder(continuousDuration: 3600)

        XCTAssertFalse(delivered)
        XCTAssertTrue(fake.addedRequests.isEmpty)
    }

    func testDeliverBreakReminderAddsRequestWhenDeliverable() async {
        let fake = FakeNotificationCenter()
        fake.authorizationStatus = .authorized
        fake.alertSetting = .enabled
        let manager = FocusNotificationManager(notificationCenter: fake)

        let delivered = await manager.deliverBreakReminder(continuousDuration: 3600)

        XCTAssertTrue(delivered)
        XCTAssertEqual(fake.addedRequests.map(\.identifier), ["tinybuddy.focus.breakReminder"])
    }

    func testDeliverGoalCompletedAddsRequestWhenDeliverable() async {
        let fake = FakeNotificationCenter()
        fake.authorizationStatus = .authorized
        fake.alertSetting = .enabled
        let manager = FocusNotificationManager(notificationCenter: fake)

        let delivered = await manager.deliverGoalCompleted(focusDuration: 7200, goalMinutes: 240)

        XCTAssertTrue(delivered)
        XCTAssertEqual(fake.addedRequests.map(\.identifier), ["tinybuddy.focus.goalCompleted"])
    }

    func testRequestAuthorizationReadsBackDefinitiveState() async {
        let fake = FakeNotificationCenter()
        fake.granted = true
        fake.authorizationStatus = .authorized
        fake.alertSetting = .disabled
        let manager = FocusNotificationManager(notificationCenter: fake)

        let state = await manager.requestAuthorization()

        // The granted Bool alone would claim "authorized"; the read-back must
        // reflect that system alerts are actually disabled.
        XCTAssertEqual(state, .alertsDisabled)
        XCTAssertEqual(fake.requestedOptions, [.alert, .sound])
    }

    // MARK: - FocusNotificationManager: cleanup routing

    func testRemoveAllPendingCleansPendingAndDelivered() {
        let fake = FakeNotificationCenter()
        let manager = FocusNotificationManager(notificationCenter: fake)

        manager.removeAllPending()

        XCTAssertEqual(
            fake.removedPending,
            [["tinybuddy.focus.breakReminder", "tinybuddy.focus.goalCompleted"]]
        )
        XCTAssertEqual(
            fake.removedDelivered,
            [["tinybuddy.focus.breakReminder", "tinybuddy.focus.goalCompleted"]]
        )
    }

    func testRemoveDeliveredRoutsPerFeature() {
        let fake = FakeNotificationCenter()
        let manager = FocusNotificationManager(notificationCenter: fake)

        manager.removeDeliveredBreakReminder()
        manager.removeDeliveredGoalCompletion()

        XCTAssertEqual(fake.removedDelivered, [["tinybuddy.focus.breakReminder"], ["tinybuddy.focus.goalCompleted"]])
        XCTAssertTrue(fake.removedPending.isEmpty)
    }

    func testRemovePendingFocusNotificationsRoutsIdentifiers() {
        let fake = FakeNotificationCenter()
        let manager = FocusNotificationManager(notificationCenter: fake)

        manager.removePendingFocusNotifications()

        XCTAssertEqual(
            fake.removedPending,
            [["tinybuddy.focus.breakReminder", "tinybuddy.focus.goalCompleted"]]
        )
        XCTAssertTrue(fake.removedDelivered.isEmpty)
    }

    // MARK: - FocusGoalCoordinator: gating on deliverability

    func testCoordinatorDoesNotGateOrDeliverWhenNotDeliverable() async {
        let deliverer = FakeNotificationDeliverer()
        deliverer.canDeliverResult = false
        let (store, defaults, suite) = makeStore()

        defer { defaults.removePersistentDomain(forName: suite) }
        store.saveConfiguration(
            FocusGoalConfiguration(quietModeStartHour: nil, quietModeEndHour: nil)
        )
        let coordinator = FocusGoalCoordinator(preferencesStore: store, notificationManager: deliverer)

        let sessionID = UUID()
        let session = makeActiveSession(id: sessionID, activeSeconds: 4000)
        let result = await coordinator.evaluateReminders(
            sessions: [session],
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertEqual(result, .none)
        XCTAssertTrue(deliverer.deliveredBreakReminders.isEmpty)
        XCTAssertTrue(deliverer.deliveredGoalCompletions.isEmpty)
        // Pending requests are cleaned while delivery is impossible.
        XCTAssertGreaterThanOrEqual(deliverer.pendingRemovedCount, 1)
        // The gate must NOT be closed, so the reminder can fire after recovery.
        let state = store.loadReminderState(for: dayID)
        XCTAssertFalse(state?.triggeredBreakReminderSessionIDs.contains(sessionID) ?? true)
    }

    func testCoordinatorGatesAndDeliversWhenDeliverable() async {
        let deliverer = FakeNotificationDeliverer()
        deliverer.canDeliverResult = true
        let (store, defaults, suite) = makeStore()

        defer { defaults.removePersistentDomain(forName: suite) }
        store.saveConfiguration(
            FocusGoalConfiguration(quietModeStartHour: nil, quietModeEndHour: nil)
        )
        let coordinator = FocusGoalCoordinator(preferencesStore: store, notificationManager: deliverer)

        let sessionID = UUID()
        let session = makeActiveSession(id: sessionID, activeSeconds: 4000)
        let result = await coordinator.evaluateReminders(
            sessions: [session],
            now: now,
            dayIdentifier: dayID
        )

        guard case .breakReminder = result else {
            XCTFail("Expected breakReminder, got \(result)")
            return
        }
        XCTAssertEqual(deliverer.deliveredBreakReminders, [4000])
        let state = store.loadReminderState(for: dayID)
        XCTAssertTrue(state?.triggeredBreakReminderSessionIDs.contains(sessionID) ?? false)
    }

    func testCoordinatorRecalculatesGoalAfterPermissionRecovery() async {
        let deliverer = FakeNotificationDeliverer()
        deliverer.canDeliverResult = false
        let (store, defaults, suite) = makeStore()

        defer { defaults.removePersistentDomain(forName: suite) }
        store.saveConfiguration(
            FocusGoalConfiguration(
                dailyFocusGoalMinutes: 30,
                quietModeStartHour: nil,
                quietModeEndHour: nil
            )
        )
        let coordinator = FocusGoalCoordinator(preferencesStore: store, notificationManager: deliverer)

        // Goal met while not deliverable — suppressed, not gated.
        let session = makeEndedSession(durationSeconds: 40 * 60)
        let suppressed = await coordinator.evaluateReminders(
            sessions: [session],
            now: now,
            dayIdentifier: dayID
        )
        XCTAssertEqual(suppressed, .none)
        XCTAssertFalse(store.loadReminderState(for: dayID)?.goalCompletedNotified ?? true)

        // Permission returns — the still-valid goal completion is recalculated.
        deliverer.canDeliverResult = true
        let recovered = await coordinator.evaluateReminders(
            sessions: [session],
            now: now,
            dayIdentifier: dayID
        )
        guard case .goalCompleted = recovered else {
            XCTFail("Expected goalCompleted after permission recovery, got \(recovered)")
            return
        }
        XCTAssertTrue(store.loadReminderState(for: dayID)?.goalCompletedNotified ?? false)
        XCTAssertEqual(deliverer.deliveredGoalCompletions.count, 1)
    }

    func testCoordinatorCleansDeliveredAlertsForDisabledFeatures() async {
        let deliverer = FakeNotificationDeliverer()
        deliverer.canDeliverResult = true
        let (store, defaults, suite) = makeStore()

        defer { defaults.removePersistentDomain(forName: suite) }
        store.saveConfiguration(
            FocusGoalConfiguration(
                isBreakReminderEnabled: false,
                isGoalCompletionEnabled: false,
                quietModeStartHour: nil,
                quietModeEndHour: nil
            )
        )
        let coordinator = FocusGoalCoordinator(preferencesStore: store, notificationManager: deliverer)

        _ = await coordinator.evaluateReminders(
            sessions: [makeEndedSession(durationSeconds: 10 * 60)],
            now: now,
            dayIdentifier: dayID
        )

        XCTAssertGreaterThanOrEqual(deliverer.deliveredBreakRemovedCount, 1)
        XCTAssertGreaterThanOrEqual(deliverer.deliveredGoalRemovedCount, 1)
    }

    // MARK: - Helpers

    private func makeManager(
        status: UNAuthorizationStatus,
        alert: UNNotificationSetting
    ) -> FocusNotificationManager {
        let fake = FakeNotificationCenter()
        fake.authorizationStatus = status
        fake.alertSetting = alert
        return FocusNotificationManager(notificationCenter: fake)
    }

    private func makeStore() -> (FocusGoalPreferencesStore, UserDefaults, String) {
        let suite = "FocusNotificationDeliveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (FocusGoalPreferencesStore(userDefaults: defaults), defaults, suite)
    }

    private func makeActiveSession(id: UUID, activeSeconds: TimeInterval) -> FocusSession {
        FocusSession(
            id: id,
            project: project,
            dayIdentifier: dayID,
            startedAt: now.addingTimeInterval(-activeSeconds),
            status: .active,
            lastUserActivityAt: now,
            lastStateChangeAt: now
        )
    }

    private func makeEndedSession(durationSeconds: TimeInterval) -> FocusSession {
        let end = now
        let start = now.addingTimeInterval(-durationSeconds)
        return FocusSession(
            project: project,
            dayIdentifier: dayID,
            startedAt: start,
            endedAt: end,
            status: .ended,
            lastUserActivityAt: end,
            lastStateChangeAt: end
        )
    }
}

// MARK: - Fakes

@MainActor
private final class FakeNotificationCenter: FocusNotificationCenter {
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var alertSetting: UNNotificationSetting = .enabled
    var granted: Bool = false
    var requestedOptions: UNAuthorizationOptions?
    var addedRequests: [UNNotificationRequest] = []
    var removedPending: [[String]] = []
    var removedDelivered: [[String]] = []

    func notificationSettingsSnapshot() async -> FocusNotificationSettingsSnapshot {
        FocusNotificationSettingsSnapshot(
            authorizationStatus: authorizationStatus,
            alertSetting: alertSetting
        )
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions = options
        return granted
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(identifiers)
    }
}

@MainActor
private final class FakeNotificationDeliverer: FocusNotificationDelivering {
    var canDeliverResult: Bool = true
    var deliveredBreakReminders: [TimeInterval] = []
    var deliveredGoalCompletions: [(focusDuration: TimeInterval, goalMinutes: Int)] = []
    var pendingRemovedCount = 0
    var deliveredBreakRemovedCount = 0
    var deliveredGoalRemovedCount = 0

    func canDeliver() async -> Bool { canDeliverResult }

    func deliverBreakReminder(continuousDuration: TimeInterval) async -> Bool {
        deliveredBreakReminders.append(continuousDuration)
        return true
    }

    func deliverGoalCompleted(focusDuration: TimeInterval, goalMinutes: Int) async -> Bool {
        deliveredGoalCompletions.append((focusDuration, goalMinutes))
        return true
    }

    func removePendingFocusNotifications() { pendingRemovedCount += 1 }
    func removeDeliveredBreakReminder() { deliveredBreakRemovedCount += 1 }
    func removeDeliveredGoalCompletion() { deliveredGoalRemovedCount += 1 }
}
