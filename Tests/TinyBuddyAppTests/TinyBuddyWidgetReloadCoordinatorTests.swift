import XCTest
@testable import TinyBuddy

final class TinyBuddyWidgetReloadCoordinatorTests: XCTestCase {
    /// A Sendable reference box so a `@Sendable`-capable reload closure can
    /// record invocations without capturing a mutable local variable.
    private final class ReloadSpy: @unchecked Sendable {
        var count = 0
    }

    func testBurstOfRequestsMergesIntoSingleReload() {
        let spy = ReloadSpy()
        var scheduled: [() -> Void] = []
        let coordinator = TinyBuddyWidgetReloadCoordinator(
            coalescingInterval: 1,
            reload: { spy.count += 1 },
            scheduler: { work, _ in scheduled.append(work) }
        )

        // A focus transition, Git refresh, and history sync arriving within
        // the coalescing window must collapse into one WidgetKit reload.
        coordinator.requestReload()
        coordinator.requestReload()
        coordinator.requestReload()

        XCTAssertEqual(scheduled.count, 1, "only the first request should arm a dispatch")
        XCTAssertEqual(spy.count, 0, "the reload must not fire before the window elapses")
        scheduled.first?()
        XCTAssertEqual(spy.count, 1, "one coalesced reload for the whole burst")
    }

    func testRequestAfterDispatchArmsANewWindow() {
        let spy = ReloadSpy()
        var scheduled: [() -> Void] = []
        let coordinator = TinyBuddyWidgetReloadCoordinator(
            coalescingInterval: 1,
            reload: { spy.count += 1 },
            scheduler: { work, _ in scheduled.append(work) }
        )

        coordinator.requestReload()
        scheduled.first?()
        XCTAssertEqual(spy.count, 1)

        // A request after the first dispatch arms a fresh window; a second
        // request within it merges rather than scheduling again.
        coordinator.requestReload()
        coordinator.requestReload()
        XCTAssertEqual(scheduled.count, 2)
        scheduled.last?()
        XCTAssertEqual(spy.count, 2)
    }

    func testDeferredBurstStillProducesExactlyOneReload() {
        let spy = ReloadSpy()
        var scheduled: [() -> Void] = []
        let coordinator = TinyBuddyWidgetReloadCoordinator(
            coalescingInterval: 1,
            reload: { spy.count += 1 },
            scheduler: { work, _ in scheduled.append(work) }
        )

        // Fire one request, then a trailing request just before the window
        // closes (simulated by both still being pending at dispatch time).
        coordinator.requestReload()
        coordinator.requestReload()
        scheduled.first?()

        XCTAssertEqual(spy.count, 1)
    }
}
