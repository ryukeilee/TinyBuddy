import AppKit
import XCTest
@testable import TinyBuddy

@MainActor
final class TimeEnvironmentChangeMonitorTests: XCTestCase {
    func testStartAndStopAreIdempotent() {
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let scheduler = Scheduler()
        let recorder = EventRecorder()
        let monitor = makeMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            scheduler: scheduler,
            capture: { "context" },
            recorder: recorder
        )

        monitor.start()
        monitor.start()
        XCTAssertEqual(monitor.observerCount, 5)

        monitor.stop()
        monitor.stop()
        XCTAssertEqual(monitor.observerCount, 0)
    }

    func testEnvironmentNotificationBurstEmitsOnlyTheLastCapturedContext() {
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let scheduler = Scheduler()
        var currentContext = "before-burst"
        let recorder = EventRecorder()
        let monitor = makeMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            scheduler: scheduler,
            capture: { currentContext },
            recorder: recorder
        )
        monitor.start()

        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        currentContext = "last-in-burst"
        notificationCenter.post(name: .NSSystemTimeZoneDidChange, object: nil)
        notificationCenter.post(name: .NSCalendarDayChanged, object: nil)
        notificationCenter.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        XCTAssertEqual(scheduler.actionCount, 1)

        scheduler.runNext()

        XCTAssertEqual(recorder.events.count, 1)
        assertEnvironmentChanged(recorder.events[0], equals: "last-in-burst")
    }

    func testWillSleepIsImmediateAndNotCoalescedWithEnvironmentChanges() {
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let scheduler = Scheduler()
        let recorder = EventRecorder()
        let monitor = makeMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            scheduler: scheduler,
            capture: { "context" },
            recorder: recorder
        )
        monitor.start()

        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        XCTAssertEqual(recorder.events.count, 1)
        guard case .willSleep = recorder.events[0] else {
            return XCTFail("willSleep must be delivered immediately")
        }

        scheduler.runNext()
        XCTAssertEqual(recorder.events.count, 2)
        assertEnvironmentChanged(recorder.events[1], equals: "context")
    }

    func testStopDropsScheduledEnvironmentEmissionAndFutureNotifications() {
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let scheduler = Scheduler()
        let recorder = EventRecorder()
        let monitor = makeMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            scheduler: scheduler,
            capture: { "context" },
            recorder: recorder
        )
        monitor.start()
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        monitor.stop()

        scheduler.runNext()
        notificationCenter.post(name: .NSSystemTimeZoneDidChange, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertEqual(monitor.observerCount, 0)
    }

    func testRestartDoesNotDeliverEmissionQueuedByPreviousLifecycle() {
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let scheduler = Scheduler()
        var currentContext = "old"
        let recorder = EventRecorder()
        let monitor = makeMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            scheduler: scheduler,
            capture: { currentContext },
            recorder: recorder
        )

        monitor.start()
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        monitor.stop()
        currentContext = "new"
        monitor.start()

        scheduler.runNext()
        XCTAssertTrue(recorder.events.isEmpty)

        notificationCenter.post(name: .NSSystemTimeZoneDidChange, object: nil)
        scheduler.runNext()
        XCTAssertEqual(recorder.events.count, 1)
        assertEnvironmentChanged(recorder.events[0], equals: "new")
    }

    func testDeinitRemovesObserversAndDoesNotRetainMonitor() {
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let scheduler = Scheduler()
        let recorder = EventRecorder()
        weak var weakMonitor: TimeEnvironmentChangeMonitor<String>?

        do {
            let monitor = makeMonitor(
                notificationCenter: notificationCenter,
                workspaceNotificationCenter: workspaceNotificationCenter,
                scheduler: scheduler,
                capture: { "context" },
                recorder: recorder
            )
            monitor.start()
            weakMonitor = monitor
        }

        XCTAssertNil(weakMonitor)
        notificationCenter.post(name: .NSSystemClockDidChange, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(scheduler.actionCount, 0)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    private func makeMonitor(
        notificationCenter: NotificationCenter,
        workspaceNotificationCenter: NotificationCenter,
        scheduler: Scheduler,
        capture: @escaping () -> String?,
        recorder: EventRecorder
    ) -> TimeEnvironmentChangeMonitor<String> {
        TimeEnvironmentChangeMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            capture: capture,
            scheduler: scheduler.schedule,
            eventHandler: { event in
                recorder.events.append(event)
            }
        )
    }

    private func assertEnvironmentChanged(
        _ event: TimeEnvironmentChangeMonitor<String>.Event,
        equals expectedContext: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .environmentChanged(context) = event else {
            return XCTFail("expected environmentChanged", file: file, line: line)
        }
        XCTAssertEqual(context, expectedContext, file: file, line: line)
    }
}

@MainActor
private final class Scheduler {
    private var actions: [@MainActor () -> Void] = []

    var actionCount: Int {
        actions.count
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        actions.append(action)
    }

    func runNext() {
        guard !actions.isEmpty else {
            return
        }

        actions.removeFirst()()
    }
}

@MainActor
private final class EventRecorder {
    var events: [TimeEnvironmentChangeMonitor<String>.Event] = []
}
