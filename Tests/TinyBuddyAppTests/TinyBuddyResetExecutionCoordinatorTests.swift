import XCTest
@testable import TinyBuddy

final class TinyBuddyResetExecutionCoordinatorTests: XCTestCase {
    @MainActor
    func testSuccessfulResetQuiescesBeforeDeletionThenReloadsWidgetAndTerminates() {
        var events: [String] = []
        let coordinator = TinyBuddyResetExecutionCoordinator(
            quiesceRuntime: { events.append("quiesce") },
            performReset: { level in
                events.append("reset:\(level.rawValue)")
                return .success(TinyBuddyResetResult(
                    level: level,
                    removedPreferenceKeyCount: 0,
                    removedFileCount: 0
                ))
            },
            reloadWidget: { events.append("reloadWidget") },
            terminate: { events.append("terminate") },
            reportFailure: { _ in events.append("failure") }
        )

        XCTAssertTrue(coordinator.execute(.allAppData))
        XCTAssertTrue(coordinator.isExecuting)
        XCTAssertEqual(events, ["quiesce", "reset:allAppData", "reloadWidget", "terminate"])
    }

    @MainActor
    func testFailedResetRemainsQuiescedAndDoesNotReloadOrTerminate() {
        var events: [String] = []
        let coordinator = TinyBuddyResetExecutionCoordinator(
            quiesceRuntime: { events.append("quiesce") },
            performReset: { _ in
                events.append("reset")
                return .failure(.removalFailed)
            },
            reloadWidget: { events.append("reloadWidget") },
            terminate: { events.append("terminate") },
            reportFailure: { error in events.append("failure:\(error)") }
        )

        XCTAssertTrue(coordinator.execute(.runtimeState))
        XCTAssertFalse(coordinator.execute(.runtimeState), "a failed reset must not restart background work or retry automatically")
        XCTAssertEqual(events, ["quiesce", "reset", "failure:removalFailed"])
    }
}
