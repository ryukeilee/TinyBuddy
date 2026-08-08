import Foundation
import XCTest
@testable import TinyBuddy

final class TinyBuddyWidgetReloadCoordinatorTests: XCTestCase {
    /// A Sendable reference box so a `@Sendable`-capable reload closure can
    /// record invocations without capturing a mutable local variable.
    private final class ReloadSpy: @unchecked Sendable {
        var count = 0
    }

    private final class SchedulerSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var workItems: [@Sendable () -> Void] = []

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return workItems.count
        }

        func append(_ work: @escaping @Sendable () -> Void) {
            lock.lock()
            workItems.append(work)
            lock.unlock()
        }

        func fireFirst() {
            lock.lock()
            let work = workItems.first
            lock.unlock()
            work?()
        }
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

    func testConcurrentRequestsArmExactlyOneReloadWindow() {
        let reloadSpy = ReloadSpy()
        let schedulerSpy = SchedulerSpy()
        let coordinator = TinyBuddyWidgetReloadCoordinator(
            coalescingInterval: 1,
            reload: { reloadSpy.count += 1 },
            scheduler: { work, _ in schedulerSpy.append(work) }
        )

        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            coordinator.requestReload()
        }

        XCTAssertEqual(schedulerSpy.count, 1)
        schedulerSpy.fireFirst()
        XCTAssertEqual(reloadSpy.count, 1)
    }
}
