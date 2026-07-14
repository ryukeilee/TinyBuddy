import AppKit
import XCTest
@testable import TinyBuddy

@MainActor
final class HUDWindowPositionControllerTests: XCTestCase {
    func testOriginStoreRoundTripsFiniteOrigin() {
        let defaults = makeDefaults()
        let store = HUDWindowOriginStore(userDefaults: defaults)
        let origin = CGPoint(x: -1280.5, y: 42.25)

        store.save(origin)

        XCTAssertEqual(store.load(), origin)
    }

    func testOriginStoreRejectsCorruptAndNonFiniteValues() {
        let defaults = makeDefaults()
        let store = HUDWindowOriginStore(userDefaults: defaults)

        defaults.set(["x": "invalid", "y": 12], forKey: HUDWindowOriginStore.Key.origin)
        XCTAssertNil(store.load())

        defaults.set(["x": Double.infinity, "y": 12], forKey: HUDWindowOriginStore.Key.origin)
        XCTAssertNil(store.load())
    }

    func testFiniteExtremeSavedOriginIsClampedAndRewritten() {
        let defaults = makeDefaults()
        let store = HUDWindowOriginStore(userDefaults: defaults)
        let controller = HUDWindowPositionController(
            originStore: store,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter(),
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1000, height: 800)] }
        )
        let window = makeWindow(frame: CGRect(x: 100, y: 100, width: 284, height: 520))
        store.save(CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude))

        controller.attach(to: window)

        XCTAssertEqual(window.frame.origin, CGPoint(x: 716, y: 280))
        XCTAssertEqual(store.load(), CGPoint(x: 716, y: 280))
        controller.stop()
    }

    func testKeepsFullyVisibleSecondaryDisplayOrigin() {
        let frame = CGRect(x: 1320, y: 100, width: 284, height: 520)
        let visibleFrames = [
            CGRect(x: 0, y: 0, width: 1280, height: 800),
            CGRect(x: 1280, y: 0, width: 1920, height: 1080)
        ]

        XCTAssertEqual(HUDWindowPositioning.correctedOrigin(for: frame, visibleFrames: visibleFrames), frame.origin)
    }

    func testRemovedDisplayFallsBackToNearestVisibleFrame() {
        let frame = CGRect(x: 2200, y: 100, width: 284, height: 520)
        let visibleFrames = [
            CGRect(x: 0, y: 0, width: 1280, height: 800),
            CGRect(x: -1440, y: 0, width: 1440, height: 900)
        ]

        XCTAssertEqual(
            HUDWindowPositioning.correctedOrigin(for: frame, visibleFrames: visibleFrames),
            CGPoint(x: 996, y: 100)
        )
    }

    func testNearestScreenTieKeepsVisibleFrameOrder() {
        let frame = CGRect(x: 1358, y: 100, width: 284, height: 520)
        let visibleFrames = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 2000, y: 0, width: 1000, height: 800)
        ]

        XCTAssertEqual(
            HUDWindowPositioning.correctedOrigin(for: frame, visibleFrames: visibleFrames),
            CGPoint(x: 716, y: 100)
        )
    }

    func testShrunkenVisibleFrameClampsPosition() {
        let frame = CGRect(x: 900, y: 600, width: 284, height: 520)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(
            HUDWindowPositioning.correctedOrigin(for: frame, visibleFrames: [visibleFrame]),
            CGPoint(x: 716, y: 280)
        )
    }

    func testChoosesScreenWithLargestIntersection() {
        let frame = CGRect(x: 900, y: 100, width: 500, height: 400)
        let visibleFrames = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1000, height: 800)
        ]

        XCTAssertEqual(
            HUDWindowPositioning.correctedOrigin(for: frame, visibleFrames: visibleFrames),
            CGPoint(x: 1000, y: 100)
        )
    }

    func testOversizedWindowKeepsTopLeftDragAreaReachable() {
        let frame = CGRect(x: 50, y: 50, width: 1200, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(
            HUDWindowPositioning.correctedOrigin(for: frame, visibleFrames: [visibleFrame]),
            CGPoint(x: 0, y: -100)
        )
    }

    func testNoValidVisibleFrameLeavesWindowUnchanged() {
        let frame = CGRect(x: 500, y: 400, width: 284, height: 520)
        let invalidFrames = [
            CGRect(x: 0, y: 0, width: 0, height: 800),
            CGRect(x: CGFloat.infinity, y: 0, width: 1000, height: 800)
        ]

        XCTAssertNil(HUDWindowPositioning.correctedOrigin(for: frame, visibleFrames: invalidFrames))
    }

    func testCorrectionIsIdempotent() {
        let frame = CGRect(x: 2200, y: 900, width: 284, height: 520)
        let visibleFrames = [CGRect(x: 0, y: 0, width: 1280, height: 800)]
        let corrected = HUDWindowPositioning.correctedOrigin(for: frame, visibleFrames: visibleFrames)!
        let correctedFrame = CGRect(origin: corrected, size: frame.size)

        XCTAssertEqual(HUDWindowPositioning.correctedOrigin(for: correctedFrame, visibleFrames: visibleFrames), corrected)
    }

    func testAttachRestoresSavedOriginIntoAVisibleDisplay() {
        let defaults = makeDefaults()
        let store = HUDWindowOriginStore(userDefaults: defaults)
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let visibleFrames = [
            CGRect(x: 0, y: 0, width: 1280, height: 800),
            CGRect(x: 1280, y: 0, width: 1920, height: 1080)
        ]
        let controller = HUDWindowPositionController(
            originStore: store,
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            visibleFramesProvider: { visibleFrames }
        )
        let window = makeWindow(frame: CGRect(x: 100, y: 100, width: 284, height: 520))
        store.save(CGPoint(x: 1320, y: 200))

        controller.attach(to: window)

        XCTAssertEqual(window.frame.origin, CGPoint(x: 1320, y: 200))
        controller.stop()
    }

    func testRepeatedAttachDoesNotInterruptManualCrossDisplayMovement() {
        let defaults = makeDefaults()
        let notificationCenter = NotificationCenter()
        let controller = HUDWindowPositionController(
            originStore: HUDWindowOriginStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: NotificationCenter(),
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1000, height: 800)] }
        )
        let window = makeWindow(frame: CGRect(x: 100, y: 100, width: 284, height: 520))
        controller.attach(to: window)

        window.setFrameOrigin(CGPoint(x: 900, y: 100))
        controller.attach(to: window)

        XCTAssertEqual(window.frame.origin, CGPoint(x: 900, y: 100))
        controller.stop()
    }

    func testScreenParametersNotificationRepairsAndPersistsAttachedWindow() async {
        let defaults = makeDefaults()
        let store = HUDWindowOriginStore(userDefaults: defaults)
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        var visibleFrames = [CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let controller = HUDWindowPositionController(
            originStore: store,
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            visibleFramesProvider: { visibleFrames }
        )
        let window = makeWindow(frame: CGRect(x: 1200, y: 100, width: 284, height: 520))
        controller.start()
        controller.attach(to: window)

        visibleFrames = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(window.frame.origin, CGPoint(x: 716, y: 100))
        XCTAssertEqual(store.load(), CGPoint(x: 716, y: 100))
        controller.stop()
    }

    func testWindowMoveNotificationPersistsTheLatestOrigin() async {
        let defaults = makeDefaults()
        let store = HUDWindowOriginStore(userDefaults: defaults)
        let notificationCenter = NotificationCenter()
        let controller = HUDWindowPositionController(
            originStore: store,
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: NotificationCenter(),
            visibleFramesProvider: { [CGRect(x: 0, y: 0, width: 1000, height: 800)] }
        )
        let window = makeWindow(frame: CGRect(x: 100, y: 100, width: 284, height: 520))
        controller.attach(to: window)

        window.setFrameOrigin(CGPoint(x: 220, y: 180))
        notificationCenter.post(name: NSWindow.didMoveNotification, object: window)
        await Task.yield()

        XCTAssertEqual(store.load(), CGPoint(x: 220, y: 180))
        controller.stop()
    }

    func testWakeNotificationsRepairAttachedWindow() async {
        for notificationName in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let defaults = makeDefaults()
            let notificationCenter = NotificationCenter()
            let workspaceNotificationCenter = NotificationCenter()
            var visibleFrames = [CGRect(x: 1000, y: 0, width: 1000, height: 800)]
            let controller = HUDWindowPositionController(
                originStore: HUDWindowOriginStore(userDefaults: defaults),
                notificationCenter: notificationCenter,
                workspaceNotificationCenter: workspaceNotificationCenter,
                visibleFramesProvider: { visibleFrames }
            )
            let window = makeWindow(frame: CGRect(x: 1200, y: 100, width: 284, height: 520))
            controller.start()
            controller.attach(to: window)

            visibleFrames = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
            workspaceNotificationCenter.post(name: notificationName, object: nil)
            await Task.yield()

            XCTAssertEqual(window.frame.origin, CGPoint(x: 716, y: 100))
            controller.stop()
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyAppTests.HUDWindowPositionControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeWindow(frame: CGRect) -> NSWindow {
        NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }
}
