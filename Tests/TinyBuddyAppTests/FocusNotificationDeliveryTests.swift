import Foundation
import XCTest
import UserNotifications
import AppKit
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

    func testMidnightRolloverSealsBeforeReminderEvaluationAndSerializesPermissionWait() async {
        let oldDate = makeDate(year: 2026, month: 8, day: 6, hour: 20)
        let rolloverDate = makeDate(year: 2026, month: 8, day: 7, hour: 1)
        let time = MutableRolloverTime(now: oldDate, timeZone: utc)
        let clock = MutableRolloverClock(oldDate)
        let sessionStore = RolloverSessionStore()
        let engine = makeRolloverEngine(clock: clock, store: sessionStore, time: time)

        let preferences = makeStore()
        defer { preferences.1.removePersistentDomain(forName: preferences.2) }
        preferences.0.saveConfiguration(
            FocusGoalConfiguration(quietModeStartHour: nil, quietModeEndHour: nil)
        )
        let deliverer = SuspendedNotificationDeliverer()
        let goalCoordinator = FocusGoalCoordinator(
            preferencesStore: preferences.0,
            notificationManager: deliverer
        )
        let oldPermissionCheck = expectation(description: "outgoing-day permission check")
        let newPermissionCheck = expectation(description: "new-day permission check")
        let repeatedNewDayCheck = expectation(description: "follow-up new-day permission check")
        deliverer.onCanDeliver = { call in
            if call == 1 { oldPermissionCheck.fulfill() }
            if call == 2 { newPermissionCheck.fulfill() }
            if call == 3 { repeatedNewDayCheck.fulfill() }
        }

        let coordinator = FocusSessionCoordinator(engine: engine, clock: clock)
        let workspaceCenter = NotificationCenter()
        let notificationCenter = NotificationCenter()
        let bridge = FocusSessionAppBridge(
            coordinator: coordinator,
            engine: engine,
            idleThreshold: 0,
            workspaceNotificationCenter: workspaceCenter,
            notificationCenter: notificationCenter,
            timeContextProvider: { time.capture() }
        )
        var inputs: [FocusReminderEvaluationInput] = []
        bridge.start()
        XCTAssertEqual(
            engine.userActivity(
                in: FocusProjectContext(key: "repo/rollover", displayName: "Rollover"),
                at: oldDate
            ),
            .saved
        )
        bridge.reminderEvaluationHandler = { input in
            inputs.append(input)
            goalCoordinator.enqueueReminderEvaluation(input)
        }
        defer { bridge.stop() }

        clock.set(rolloverDate)
        time.set(now: rolloverDate, timeZone: utc)
        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        await fulfillment(of: [oldPermissionCheck], timeout: 2)
        XCTAssertEqual(engine.currentDayIdentifier, "2026-08-07")
        XCTAssertEqual(engine.allSessions.first?.status, .ended)
        XCTAssertEqual(engine.allSessions.first?.endedAt, oldDate)
        XCTAssertGreaterThanOrEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].dayIdentifier, "2026-08-06")
        XCTAssertEqual(inputs[0].now, rolloverDate)
        XCTAssertEqual(inputs[0].sessions.first?.status, .ended)
        XCTAssertEqual(inputs[0].sessions.first?.activeDuration(now: inputs[0].now) ?? -1, 0)
        XCTAssertEqual(inputs[1].dayIdentifier, "2026-08-07")
        XCTAssertEqual(
            deliverer.canDeliverCallCount,
            1,
            "The new-day request must wait behind the outgoing-day request"
        )
        XCTAssertNil(preferences.0.loadReminderState(for: "2026-08-07"))

        deliverer.resolveFirstPermissionCheck(true)
        await fulfillment(of: [newPermissionCheck], timeout: 2)
        XCTAssertTrue(deliverer.deliveredBreakReminders.isEmpty)
        XCTAssertTrue(deliverer.deliveredGoalCompletions.isEmpty)
        XCTAssertEqual(preferences.0.loadReminderState(for: "2026-08-07")?.dayIdentifier, "2026-08-07")
        deliverer.resolveFirstPermissionCheck(true)
        await fulfillment(of: [repeatedNewDayCheck], timeout: 2)
        deliverer.resolveFirstPermissionCheck(true)
    }

    func testRolloverPreservesGoalReachedAtLastRecordedEvent() async throws {
        let start = makeDate(year: 2026, month: 8, day: 6, hour: 19)
        let lastEvent = makeDate(year: 2026, month: 8, day: 6, hour: 23, minute: 30)
        let rolloverDate = makeDate(year: 2026, month: 8, day: 7, hour: 0, minute: 10)
        let time = MutableRolloverTime(now: start, timeZone: utc)
        let clock = MutableRolloverClock(start)
        let engine = makeRolloverEngine(clock: clock, store: RolloverSessionStore(), time: time)

        let preferences = makeStore()
        defer { preferences.1.removePersistentDomain(forName: preferences.2) }
        preferences.0.saveConfiguration(
            FocusGoalConfiguration(quietModeStartHour: nil, quietModeEndHour: nil)
        )
        let deliverer = FakeNotificationDeliverer()
        let goalCoordinator = FocusGoalCoordinator(
            preferencesStore: preferences.0,
            notificationManager: deliverer
        )
        let coordinator = FocusSessionCoordinator(engine: engine, clock: clock)
        let notificationCenter = NotificationCenter()
        let bridge = FocusSessionAppBridge(
            coordinator: coordinator,
            engine: engine,
            idleThreshold: 0,
            workspaceNotificationCenter: NotificationCenter(),
            notificationCenter: notificationCenter,
            timeContextProvider: { time.capture() }
        )
        var evaluationTasks: [Task<FocusReminderAction, Never>] = []
        bridge.start()
        XCTAssertEqual(
            engine.userActivity(
                in: FocusProjectContext(key: "repo/goal", displayName: "Goal"),
                at: start
            ),
            .saved
        )
        clock.set(lastEvent)
        time.set(now: lastEvent, timeZone: utc)
        XCTAssertEqual(
            engine.userActivity(
                in: FocusProjectContext(key: "repo/goal", displayName: "Goal"),
                at: lastEvent
            ),
            .saved
        )
        bridge.reminderEvaluationHandler = { input in
            evaluationTasks.append(goalCoordinator.enqueueReminderEvaluation(input))
        }
        defer { bridge.stop() }

        clock.set(rolloverDate)
        time.set(now: rolloverDate, timeZone: utc)
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)

        let outgoingTask = try XCTUnwrap(evaluationTasks.first)
        let outgoingAction = await outgoingTask.value
        guard case .goalCompleted(let duration, let minutes) = outgoingAction else {
            XCTFail("Expected the final outgoing-day session to keep its valid goal reminder, got \(outgoingAction)")
            return
        }
        XCTAssertEqual(duration, 4.5 * 60 * 60)
        XCTAssertEqual(minutes, FocusGoalConfiguration.default.dailyFocusGoalMinutes)
        for task in evaluationTasks.dropFirst() {
            _ = await task.value
        }
        XCTAssertEqual(deliverer.deliveredGoalCompletions.count, 1)
        XCTAssertEqual(deliverer.deliveredGoalCompletions.first?.focusDuration, 4.5 * 60 * 60)
    }

    func testTimeZoneJumpUsesSealedOutgoingDayAndCapturedEvaluationTime() {
        let jumpDate = makeDate(year: 2026, month: 8, day: 7, hour: 0, minute: 30)
        let oldZone = TimeZone(secondsFromGMT: 3_600)!
        let newZone = TimeZone(secondsFromGMT: -3_600)!
        let time = MutableRolloverTime(now: jumpDate, timeZone: oldZone)
        let clock = MutableRolloverClock(jumpDate)
        let engine = makeRolloverEngine(clock: clock, store: RolloverSessionStore(), time: time)

        let coordinator = FocusSessionCoordinator(engine: engine, clock: clock)
        let notificationCenter = NotificationCenter()
        let bridge = FocusSessionAppBridge(
            coordinator: coordinator,
            engine: engine,
            idleThreshold: 0,
            workspaceNotificationCenter: NotificationCenter(),
            notificationCenter: notificationCenter,
            timeContextProvider: { time.capture() }
        )
        var inputs: [FocusReminderEvaluationInput] = []
        bridge.start()
        XCTAssertEqual(
            engine.userActivity(
                in: FocusProjectContext(key: "repo/time-zone", displayName: "Time Zone"),
                at: jumpDate
            ),
            .saved
        )
        bridge.reminderEvaluationHandler = { inputs.append($0) }
        defer { bridge.stop() }

        time.set(now: jumpDate, timeZone: newZone)
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)

        XCTAssertEqual(engine.currentDayIdentifier, "2026-08-06")
        XCTAssertEqual(engine.allSessions.first?.status, .ended)
        XCTAssertEqual(inputs.first?.dayIdentifier, "2026-08-07")
        XCTAssertEqual(inputs.first?.now, jumpDate)
        XCTAssertEqual(inputs.first?.sessions.first?.endedAt, jumpDate)
        XCTAssertEqual(inputs.dropFirst().first?.dayIdentifier, "2026-08-06")
    }

    func testFailedRolloverPersistenceDoesNotPublishOutgoingDayReminderInput() {
        let oldDate = makeDate(year: 2026, month: 8, day: 6, hour: 23)
        let newDate = makeDate(year: 2026, month: 8, day: 7, hour: 1)
        let time = MutableRolloverTime(now: oldDate, timeZone: utc)
        let clock = MutableRolloverClock(oldDate)
        let store = RolloverSessionStore()
        let engine = makeRolloverEngine(clock: clock, store: store, time: time)

        let coordinator = FocusSessionCoordinator(engine: engine, clock: clock)
        let notificationCenter = NotificationCenter()
        let bridge = FocusSessionAppBridge(
            coordinator: coordinator,
            engine: engine,
            idleThreshold: 0,
            workspaceNotificationCenter: NotificationCenter(),
            notificationCenter: notificationCenter,
            timeContextProvider: { time.capture() }
        )
        var inputs: [FocusReminderEvaluationInput] = []
        bridge.start()
        XCTAssertEqual(
            engine.userActivity(
                in: FocusProjectContext(key: "repo/failure", displayName: "Failure"),
                at: oldDate
            ),
            .saved
        )
        bridge.reminderEvaluationHandler = { inputs.append($0) }
        defer { bridge.stop() }

        store.shouldFailWrites = true
        clock.set(newDate)
        time.set(now: newDate, timeZone: utc)
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)

        XCTAssertFalse(inputs.contains { $0.dayIdentifier == "2026-08-06" })
        XCTAssertTrue(inputs.contains { $0.dayIdentifier == "2026-08-07" })
        XCTAssertEqual(engine.allSessions.first?.status, .active)
    }

    // MARK: - Helpers

    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeRolloverEngine(
        clock: MutableRolloverClock,
        store: RolloverSessionStore,
        time: MutableRolloverTime
    ) -> FocusSessionEngine {
        FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { date in time.capture()?.dayIdentifier(for: date) ?? "" }
        )
    }

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

@MainActor
private final class SuspendedNotificationDeliverer: FocusNotificationDelivering {
    private var permissionContinuations: [CheckedContinuation<Bool, Never>] = []
    var canDeliverCallCount = 0
    var onCanDeliver: ((Int) -> Void)?
    var deliveredBreakReminders: [TimeInterval] = []
    var deliveredGoalCompletions: [(focusDuration: TimeInterval, goalMinutes: Int)] = []

    func canDeliver() async -> Bool {
        await withCheckedContinuation { continuation in
            canDeliverCallCount += 1
            permissionContinuations.append(continuation)
            onCanDeliver?(canDeliverCallCount)
        }
    }

    func deliverBreakReminder(continuousDuration: TimeInterval) async -> Bool {
        deliveredBreakReminders.append(continuousDuration)
        return true
    }

    func deliverGoalCompleted(focusDuration: TimeInterval, goalMinutes: Int) async -> Bool {
        deliveredGoalCompletions.append((focusDuration, goalMinutes))
        return true
    }

    func removePendingFocusNotifications() {}
    func removeDeliveredBreakReminder() {}
    func removeDeliveredGoalCompletion() {}

    func resolveFirstPermissionCheck(_ result: Bool) {
        guard !permissionContinuations.isEmpty else { return }
        permissionContinuations.removeFirst().resume(returning: result)
    }
}

private final class MutableRolloverClock: FocusClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    var monotonic: TimeInterval { now.timeIntervalSinceReferenceDate }

    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}

private final class MutableRolloverTime: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var timeZone: TimeZone

    init(now: Date, timeZone: TimeZone) {
        self.date = now
        self.timeZone = timeZone
    }

    func set(now: Date, timeZone: TimeZone) {
        lock.lock()
        self.date = now
        self.timeZone = timeZone
        lock.unlock()
    }

    func capture() -> TinyBuddyTimeContext? {
        lock.lock()
        let date = self.date
        let timeZone = self.timeZone
        lock.unlock()
        return TinyBuddyTimeContext(
            now: date,
            timeZone: timeZone,
            locale: Locale(identifier: "en_US_POSIX"),
            sourceCalendar: Calendar(identifier: .gregorian)
        )
    }
}

private final class RolloverSessionStore: FocusSessionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [FocusSession] = []
    var shouldFailWrites = false

    func load() -> [FocusSession]? {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    func save(_ sessions: [FocusSession]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !shouldFailWrites else { return false }
        self.sessions = sessions
        return true
    }
}
