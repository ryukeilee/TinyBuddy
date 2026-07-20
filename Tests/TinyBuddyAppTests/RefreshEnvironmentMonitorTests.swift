import AppKit
import XCTest
@testable import TinyBuddy

@MainActor
final class RefreshEnvironmentMonitorTests: XCTestCase {
    func testPowerNotificationBurstPublishesOnlyOneSemanticStateChange() {
        let notificationCenter = NotificationCenter()
        let scheduler = RefreshEnvironmentScheduler()
        var currentState = TinyBuddyPowerState(
            isOnBatteryPower: false,
            isLowPowerModeEnabled: false
        )
        var publishedStates: [TinyBuddyPowerState] = []
        let monitor = TinyBuddyPowerStateMonitor(
            notificationCenter: notificationCenter,
            stateProvider: { currentState },
            scheduler: scheduler.schedule,
            eventHandler: { publishedStates.append($0) }
        )

        monitor.start()
        XCTAssertEqual(monitor.observerCount, 1)
        XCTAssertEqual(publishedStates, [currentState])

        currentState = TinyBuddyPowerState(
            isOnBatteryPower: true,
            isLowPowerModeEnabled: true
        )
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertEqual(scheduler.actionCount, 1)

        scheduler.runNext()
        XCTAssertEqual(publishedStates, [
            TinyBuddyPowerState(isOnBatteryPower: false, isLowPowerModeEnabled: false),
            currentState
        ])

        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        scheduler.runNext()
        XCTAssertEqual(publishedStates.count, 2)
    }

    func testPowerMonitorStopDropsScheduledEmissionAndReleasesObserver() {
        let notificationCenter = NotificationCenter()
        let scheduler = RefreshEnvironmentScheduler()
        var state = TinyBuddyPowerState(
            isOnBatteryPower: false,
            isLowPowerModeEnabled: false
        )
        var eventCount = 0
        let monitor = TinyBuddyPowerStateMonitor(
            notificationCenter: notificationCenter,
            stateProvider: { state },
            scheduler: scheduler.schedule,
            eventHandler: { _ in eventCount += 1 }
        )

        monitor.start()
        state = TinyBuddyPowerState(isOnBatteryPower: true, isLowPowerModeEnabled: false)
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        monitor.stop()
        scheduler.runNext()
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(monitor.observerCount, 0)
    }

    func testHUDVisibilitySignalsCoalesceAndIgnoreUnchangedVisibility() {
        let notificationCenter = NotificationCenter()
        let scheduler = RefreshEnvironmentScheduler()
        var isVisible = false
        var publishedVisibility: [Bool] = []
        let monitor = HUDVisibilityMonitor(
            notificationCenter: notificationCenter,
            visibilityProvider: { isVisible },
            scheduler: scheduler.schedule,
            eventHandler: { publishedVisibility.append($0) }
        )

        monitor.start()
        XCTAssertEqual(monitor.observerCount, 5)
        XCTAssertEqual(publishedVisibility, [false])

        isVisible = true
        notificationCenter.post(name: .tinyBuddyHUDWindowDidConfigure, object: nil)
        notificationCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        XCTAssertEqual(scheduler.actionCount, 1)
        scheduler.runNext()
        XCTAssertEqual(publishedVisibility, [false, true])

        notificationCenter.post(name: NSWindow.didDeminiaturizeNotification, object: nil)
        scheduler.runNext()
        XCTAssertEqual(publishedVisibility, [false, true])
    }

    func testHUDVisibilityMonitorStopAndDeinitReleaseObservers() {
        let notificationCenter = NotificationCenter()
        let scheduler = RefreshEnvironmentScheduler()
        var eventCount = 0
        weak var weakMonitor: HUDVisibilityMonitor?

        do {
            let monitor = HUDVisibilityMonitor(
                notificationCenter: notificationCenter,
                visibilityProvider: { true },
                scheduler: scheduler.schedule,
                eventHandler: { _ in eventCount += 1 }
            )
            monitor.start()
            monitor.stop()
            weakMonitor = monitor
            XCTAssertEqual(monitor.observerCount, 0)
        }

        XCTAssertNil(weakMonitor)
        notificationCenter.post(name: .tinyBuddyHUDWindowDidConfigure, object: nil)
        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(scheduler.actionCount, 0)
    }

    func testExtremePowerStateBurstCoalescesToOneEmission() {
        let notificationCenter = NotificationCenter()
        let scheduler = RefreshEnvironmentScheduler()
        var currentState = TinyBuddyPowerState(
            isOnBatteryPower: false,
            isLowPowerModeEnabled: false
        )
        var publishedStateChanges: [TinyBuddyPowerState] = []
        let monitor = TinyBuddyPowerStateMonitor(
            notificationCenter: notificationCenter,
            stateProvider: { currentState },
            scheduler: scheduler.schedule,
            eventHandler: { publishedStateChanges.append($0) }
        )
        monitor.start()
        publishedStateChanges.removeAll()

        currentState = TinyBuddyPowerState(
            isOnBatteryPower: true,
            isLowPowerModeEnabled: true
        )

        for _ in 0..<50 {
            notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }

        XCTAssertEqual(scheduler.actionCount, 1)

        scheduler.runNext()
        XCTAssertEqual(publishedStateChanges.count, 1)
        XCTAssertEqual(publishedStateChanges[0], currentState)
        monitor.stop()
    }

    func testPowerStateMonitorRestartDoesNotDeliverOldGenerationEmission() {
        let notificationCenter = NotificationCenter()
        let scheduler = RefreshEnvironmentScheduler()
        var currentState = TinyBuddyPowerState(
            isOnBatteryPower: false,
            isLowPowerModeEnabled: false
        )
        var publishedStateChanges: [TinyBuddyPowerState] = []
        let monitor = TinyBuddyPowerStateMonitor(
            notificationCenter: notificationCenter,
            stateProvider: { currentState },
            scheduler: scheduler.schedule,
            eventHandler: { publishedStateChanges.append($0) }
        )

        monitor.start()
        publishedStateChanges.removeAll()

        currentState = TinyBuddyPowerState(
            isOnBatteryPower: true,
            isLowPowerModeEnabled: false
        )
        notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

        monitor.stop()
        publishedStateChanges.removeAll()
        currentState = TinyBuddyPowerState(
            isOnBatteryPower: false,
            isLowPowerModeEnabled: false
        )
        scheduler.runNext()

        XCTAssertTrue(publishedStateChanges.isEmpty)

        monitor.start()
        XCTAssertEqual(publishedStateChanges.count, 1)
        monitor.stop()
    }

    func testHUDVisibilityExtremeBurstCoalescesToOneEmission() {
        let notificationCenter = NotificationCenter()
        let scheduler = RefreshEnvironmentScheduler()
        var isVisible = false
        var publishedVisibility: [Bool] = []
        let monitor = HUDVisibilityMonitor(
            notificationCenter: notificationCenter,
            visibilityProvider: { isVisible },
            scheduler: scheduler.schedule,
            eventHandler: { publishedVisibility.append($0) }
        )

        monitor.start()
        publishedVisibility.removeAll()

        isVisible = true
        for _ in 0..<50 {
            notificationCenter.post(name: .tinyBuddyHUDWindowDidConfigure, object: nil)
        }

        XCTAssertEqual(scheduler.actionCount, 1)
        scheduler.runNext()
        XCTAssertEqual(publishedVisibility.count, 1)
        XCTAssertEqual(publishedVisibility[0], true)
        monitor.stop()
    }
}

@MainActor
private final class RefreshEnvironmentScheduler {
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
