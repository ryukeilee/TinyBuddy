import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

private final class BridgeGateClock: FocusClock, @unchecked Sendable {
    private var date: Date
    var now: Date { date }
    var monotonic: TimeInterval { date.timeIntervalSinceReferenceDate }

    init(_ date: Date) {
        self.date = date
    }

    func set(to date: Date) {
        self.date = date
    }
}

private final class BridgeGateStore: FocusSessionPersisting, @unchecked Sendable {
    private var sessions: [FocusSession] = []

    func load() -> [FocusSession]? { sessions }
    func save(_ sessions: [FocusSession]) -> Bool {
        self.sessions = sessions
        return true
    }
}

final class FocusSessionAppBridgeResetGateTests: XCTestCase {
    private var temporaryURL: URL!

    @MainActor
    func testStartupInputThatStopsMustNotConfirmAtIdleBoundary() {
        let config = FocusSessionConfiguration()
        let idleThreshold = config.idleThreshold
        let idlePollInterval = min(15, max(5, idleThreshold / 8))
        let start = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let clock = BridgeGateClock(start)
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: BridgeGateStore(),
            config: config,
            dayIdentifier: { _ in "2026-09-29" }
        )
        let coordinator = FocusSessionCoordinator(engine: engine, clock: clock)

        coordinator.reportForegroundApp(
            bundleID: "com.apple.dt.Xcode",
            displayName: "Xcode",
            isCodeEditor: true,
            at: start
        )
        // Mirrors sampleInitialActivity(): the app launches immediately after
        // one input event, with no further input during the idle poll sequence.
        coordinator.reportActiveAfterIdle(at: start)

        var wasIdle = false
        var observedActivity: [Bool] = []
        for elapsed in stride(
            from: idlePollInterval,
            through: idleThreshold + idlePollInterval,
            by: idlePollInterval
        ) {
            clock.set(to: start.addingTimeInterval(elapsed))
            let hasRecentInput = FocusSessionAppBridge.hasRecentInputEvent(
                within: idleThreshold
            ) { eventType in
                eventType == .keyDown ? elapsed : .infinity
            }
            observedActivity.append(hasRecentInput)

            if hasRecentInput, wasIdle {
                wasIdle = false
                coordinator.reportUserInput(at: clock.now)
            } else if hasRecentInput {
                coordinator.reportSustainedActivity(at: clock.now)
            } else if !wasIdle {
                wasIdle = true
                coordinator.reportIdle(at: clock.now)
            } else {
                coordinator.reportProlongedIdle(at: clock.now)
            }
        }

        XCTAssertEqual(observedActivity, Array(repeating: true, count: 7) + [false, false])
        XCTAssertTrue(
            engine.allSessions.isEmpty,
            "One startup input must not accumulate the full idle threshold as active focus"
        )
    }

    @MainActor
    func testInputAgeTransitionsMatchFullScanAndShortCircuitByInputType() {
        let idleThreshold = FocusSessionConfiguration().idleThreshold
        let pollInterval: TimeInterval = 15
        let fixtures: [(name: String, eventType: CGEventType)] = [
            ("keyboard", .keyDown),
            ("pointer-motion-only", .mouseMoved),
            ("scroll-only", .scrollWheel),
        ]

        for fixture in fixtures {
            var baselineTransitions: [Bool] = []
            var candidateTransitions: [Bool] = []
            var baselineQueryCount = 0
            var candidateQueryCount = 0

            let eventAges = Array(stride(
                from: 0,
                through: idleThreshold + pollInterval,
                by: pollInterval
            ))
            for eventAge in eventAges {
                let ageForEvent: (CGEventType) -> TimeInterval = { eventType in
                    eventType == fixture.eventType ? eventAge : idleThreshold + pollInterval
                }
                let baselineAges = FocusSessionAppBridge.trackedInputEventTypes.map { eventType in
                    baselineQueryCount += 1
                    return ageForEvent(eventType)
                }
                baselineTransitions.append((baselineAges.min() ?? .infinity) < idleThreshold)

                candidateTransitions.append(
                    FocusSessionAppBridge.hasRecentInputEvent(within: idleThreshold) { eventType in
                        candidateQueryCount += 1
                        return ageForEvent(eventType)
                    }
                )
            }

            let expectedTransitions = eventAges.map { $0 < idleThreshold }
            let recentEventQueryCount =
                (FocusSessionAppBridge.trackedInputEventTypes.firstIndex(of: fixture.eventType) ?? 0) + 1
            let expectedCandidateQueries = eventAges.reduce(into: 0) { count, eventAge in
                count += eventAge < idleThreshold
                    ? recentEventQueryCount
                    : FocusSessionAppBridge.trackedInputEventTypes.count
            }

            XCTAssertEqual(baselineTransitions, expectedTransitions, fixture.name)
            XCTAssertEqual(candidateTransitions, baselineTransitions, fixture.name)
            XCTAssertEqual(
                baselineQueryCount,
                candidateTransitions.count * FocusSessionAppBridge.trackedInputEventTypes.count,
                fixture.name
            )
            XCTAssertEqual(candidateQueryCount, expectedCandidateQueries, fixture.name)
        }
    }

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
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
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
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
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
