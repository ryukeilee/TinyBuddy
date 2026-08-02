import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class FocusSessionAppBridgeResetGateTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyBridgeGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testReportsFlowWhileRunningAndAreDroppedAfterStop() throws {
        let storeURL = temporaryURL.appendingPathComponent("sessions.json")
        let store = FocusSessionFileStore(fileURL: storeURL)
        let clock = SystemFocusClock()
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            dayIdentifier: { _ in "2026-08-02" }
        )
        let coordinator = FocusSessionCoordinator(engine: engine, clock: clock)
        let bridge = FocusSessionAppBridge(
            coordinator: coordinator,
            engine: engine,
            workspaceNotificationCenter: NotificationCenter(),
            notificationCenter: NotificationCenter()
        )

        XCTAssertFalse(bridge.isStopped)

        // A live report flows through the coordinator and persists a session.
        bridge.reportToCoordinator { $0.reportForegroundApp(
            bundleID: "com.apple.dt.Xcode",
            displayName: "Xcode",
            isCodeEditor: true
        ) }
        bridge.reportToCoordinator { $0.reportActiveAfterIdle() }
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        bridge.stop()
        XCTAssertTrue(bridge.isStopped)

        // Reports that arrive after stop (already-enqueued workspace callbacks
        // during a reset) must not mutate or persist session state.
        bridge.reportToCoordinator { $0.reportSleep() }
        bridge.reportToCoordinator { $0.reportActiveAfterIdle() }
        bridge.reportToCoordinator { $0.reportTerminate() }
        XCTAssertEqual(engine.allSessions.count, 1)

        // Restarting must clear the stopped gate for a normal lifecycle.
        bridge.start()
        XCTAssertFalse(bridge.isStopped)
    }

    @MainActor
    func testStopRemovesWorkspaceObserversSoLateNotificationsAreNoOps() throws {
        let storeURL = temporaryURL.appendingPathComponent("sessions.json")
        let store = FocusSessionFileStore(fileURL: storeURL)
        let clock = SystemFocusClock()
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            dayIdentifier: { _ in "2026-08-02" }
        )
        let coordinator = FocusSessionCoordinator(engine: engine, clock: clock)
        let workspaceNC = NotificationCenter()
        let bridge = FocusSessionAppBridge(
            coordinator: coordinator,
            engine: engine,
            workspaceNotificationCenter: workspaceNC,
            notificationCenter: NotificationCenter()
        )

        bridge.start()
        // Ambient user activity may legitimately create a session during start.
        let countBeforeStop = engine.allSessions.count
        bridge.stop()

        // Notifications posted on the injected workspace center after stop
        // reach no observer and must not change session state.
        workspaceNC.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNC.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(engine.allSessions.count, countBeforeStop)
        XCTAssertTrue(bridge.isStopped)
    }
}
