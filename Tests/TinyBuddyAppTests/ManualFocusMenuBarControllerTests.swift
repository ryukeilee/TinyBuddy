import AppKit
import XCTest
import TinyBuddyCore
@testable import TinyBuddy

private final class MenuFocusStore: FocusSessionPersisting, @unchecked Sendable {
    private var sessions: [FocusSession] = []
    func load() -> [FocusSession]? { sessions }
    func save(_ sessions: [FocusSession]) -> Bool {
        self.sessions = sessions
        return true
    }
}

private final class MenuFocusClock: FocusClock, @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 3_000_000)
    var monotonic: TimeInterval { now.timeIntervalSinceReferenceDate }
}

@MainActor
private final class MenuTimerRecorder {
    var timers: [Timer] = []
    var delays: [TimeInterval] = []
    func schedule(_ interval: TimeInterval, _ repeats: Bool, _ action: @escaping @MainActor () -> Void) -> Timer {
        XCTAssertFalse(repeats)
        delays.append(interval)
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { action() }
        }
        timers.append(timer)
        return timer
    }
}

/// Event-driven menu state, duration precision, and timer lifecycle regression coverage.
final class ManualFocusMenuBarControllerTests: XCTestCase {
    @MainActor
    func testDurationSchedulingMatchesVisiblePrecision() {
        let project = FocusProjectContext(key: "test", displayName: "Test")
        let start = Date()
        XCTAssertNil(ManualFocusMenuBarController.refreshInterval(for: .idle, popoverIsShown: true))
        XCTAssertNil(ManualFocusMenuBarController.refreshInterval(
            for: .paused(project: project, startedAt: start, pausedAt: start, activeDuration: 25),
            popoverIsShown: true
        ))
        for (duration, closed, shown) in [(0.0, 60.0, 1.0), (25.25, 34.75, 0.75), (60.0, 60.0, 1.0)] {
            let state = ManualFocusControlState.focusing(project: project, startedAt: start, activeDuration: duration)
            XCTAssertEqual(ManualFocusMenuBarController.refreshInterval(for: state, popoverIsShown: false), closed)
            XCTAssertEqual(ManualFocusMenuBarController.refreshInterval(for: state, popoverIsShown: true), shown)
        }
    }

    @MainActor
    func testTransitionsCancelObsoleteTimersAndRefreshImmediately() {
        let clock = MenuFocusClock()
        let engine = makeEngine(clock: clock)
        let recorder = MenuTimerRecorder()
        let controller = ManualFocusMenuBarController(scheduleRefresh: recorder.schedule)
        controller.start(with: engine)
        defer { controller.stop() }
        XCTAssertEqual(controller.statusTitle, "🎯")
        XCTAssertTrue(recorder.timers.isEmpty)

        _ = engine.startManualFocus(project: .init(key: "test", displayName: "Test"), at: clock.now, commandToken: UUID())
        controller.refresh()
        XCTAssertEqual(controller.statusTitle, "▶ 0m")
        XCTAssertEqual(recorder.delays.last, 60)
        clock.now.addTimeInterval(61)
        recorder.timers.last?.fire()
        XCTAssertEqual(controller.statusTitle, "▶ 1m")
        XCTAssertEqual(recorder.delays.last, 59)

        _ = engine.pauseManualFocus(at: clock.now, commandToken: UUID())
        controller.refresh()
        XCTAssertEqual(controller.statusTitle, "⏸ 1m")
        XCTAssertTrue(recorder.timers.allSatisfy { !$0.isValid })
        clock.now.addTimeInterval(90)
        _ = engine.resumeManualFocus(at: clock.now, commandToken: UUID())
        controller.refresh()
        XCTAssertEqual(controller.statusTitle, "▶ 1m")
        XCTAssertEqual(recorder.delays.last, 59)
        _ = engine.endManualFocus(at: clock.now, commandToken: UUID())
        controller.refresh()
        XCTAssertEqual(controller.statusTitle, "🎯")
        XCTAssertTrue(recorder.timers.allSatisfy { !$0.isValid })
        controller.stop()
        controller.start(with: engine)
        XCTAssertEqual(controller.statusTitle, "🎯")
    }

    @MainActor
    func testWakeTimeChangeAndRegistryEventsResynchronizeWithoutPolling() {
        let clock = MenuFocusClock()
        let engine = makeEngine(clock: clock)
        let recorder = MenuTimerRecorder()
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        let controller = ManualFocusMenuBarController(
            notificationCenter: center, workspaceNotificationCenter: workspace,
            scheduleRefresh: recorder.schedule
        )
        _ = engine.startManualFocus(project: .init(key: "test", displayName: "Test"), at: clock.now, commandToken: UUID())
        controller.start(with: engine)
        clock.now.addTimeInterval(125)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(controller.statusTitle, "▶ 2m")
        XCTAssertEqual(recorder.delays.last, 55)
        clock.now.addTimeInterval(60)
        center.post(name: .tinyBuddyTimeEnvironmentDidChange, object: nil)
        XCTAssertEqual(controller.statusTitle, "▶ 3m")
        clock.now.addTimeInterval(60)
        center.post(name: Notification.Name("TinyBuddy.projectRegistryDidChange"), object: nil)
        XCTAssertEqual(controller.statusTitle, "▶ 4m")
        clock.now.addTimeInterval(60)
        center.post(name: .gitActivitySnapshotDidChange, object: nil)
        XCTAssertEqual(controller.statusTitle, "▶ 5m")
        controller.stop()
        let count = recorder.timers.count
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: .gitActivitySnapshotDidChange, object: nil)
        XCTAssertEqual(recorder.timers.count, count)
        XCTAssertTrue(recorder.timers.allSatisfy { !$0.isValid })
    }

    @MainActor
    func testCommittedEngineCallbackUpdatesIdleMenuWithoutTimer() async throws {
        let clock = MenuFocusClock()
        let engine = makeEngine(clock: clock)
        let recorder = MenuTimerRecorder()
        let controller = ManualFocusMenuBarController(scheduleRefresh: recorder.schedule)
        controller.start(with: engine)
        defer { controller.stop() }
        engine.committedReminderEvaluationHandler = { [weak controller] _ in
            DispatchQueue.main.async { controller?.refresh() }
        }
        _ = engine.startManualFocus(project: .init(key: "test", displayName: "Test"), at: clock.now, commandToken: UUID())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.statusTitle, "▶ 0m")
        _ = engine.pauseManualFocus(at: clock.now, commandToken: UUID())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.statusTitle, "⏸ 0m")
        XCTAssertTrue(recorder.timers.allSatisfy { !$0.isValid })
        _ = engine.endManualFocus(at: clock.now, commandToken: UUID())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.statusTitle, "🎯")
    }

    private func makeEngine(clock: FocusClock) -> FocusSessionEngine {
        FocusSessionEngine(clock: clock, persisting: MenuFocusStore(), dayIdentifier: { _ in "2026-10-06" })
    }

    @MainActor
    private func makePopoverAnchorWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    @MainActor
    func testOpeningAndClosingRealPopoverSwitchesDurationPrecision() async throws {
        _ = NSApplication.shared
        let clock = MenuFocusClock()
        let engine = makeEngine(clock: clock)
        let recorder = MenuTimerRecorder()
        let controller = ManualFocusMenuBarController(scheduleRefresh: recorder.schedule)
        _ = engine.startManualFocus(project: .init(key: "test", displayName: "Test"), at: clock.now, commandToken: UUID())
        controller.start(with: engine)
        defer { controller.stop() }
        XCTAssertEqual(recorder.delays.last, 60)
        let window = makePopoverAnchorWindow()
        defer { window.close() }
        controller.showPopover(relativeTo: try XCTUnwrap(window.contentView))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.popover?.isShown == true)
        XCTAssertEqual(recorder.delays.last, 1)
        controller.togglePopover()
        XCTAssertEqual(recorder.delays.last, 60)
        XCTAssertEqual(recorder.timers.filter(\.isValid).count, 1)
    }

    @MainActor
    func testTransientPopoverCloseRestoresMinuteTimerAndReleasesHiddenContent() async throws {
        _ = NSApplication.shared
        let clock = MenuFocusClock()
        let engine = makeEngine(clock: clock)
        let recorder = MenuTimerRecorder()
        let controller = ManualFocusMenuBarController(scheduleRefresh: recorder.schedule)
        _ = engine.startManualFocus(project: .init(key: "test", displayName: "Test"), at: clock.now, commandToken: UUID())
        controller.start(with: engine)
        defer { controller.stop() }
        let window = makePopoverAnchorWindow()
        defer { window.close() }
        controller.showPopover(relativeTo: try XCTUnwrap(window.contentView))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.popover?.isShown == true)
        XCTAssertEqual(recorder.delays.last, 1)
        let popover = try XCTUnwrap(controller.popover)
        popover.animates = false
        popover.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.popover)
        XCTAssertEqual(recorder.delays.last, 60)
        XCTAssertEqual(recorder.timers.filter(\.isValid).count, 1)
        // A delayed callback from a previously closed popover cannot clear a
        // newer one or downgrade its second-precision timer.
        controller.showPopover(relativeTo: try XCTUnwrap(window.contentView))
        try await Task.sleep(for: .milliseconds(500))
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        XCTAssertTrue(controller.popover?.isShown == true)
        XCTAssertEqual(recorder.delays.last, 1)
    }

}
