import Foundation
import WidgetKit

/// Coalesces app-side Widget timeline reload requests so bursts of semantic
/// changes (focus start/pause/end, Git refresh, time calibration, history
/// synchronization) merge into a single `reloadAllTimelines()` call.
///
/// WidgetKit has no cross-call coalescing and every reload request consumes
/// the Widget's bounded daily refresh budget. Without this, several subsystems
/// can request a reload within the same second after one user action, and a
/// live focus session's per-minute republish would each wake WidgetKit.
///
/// The coordinator applies a short coalescing window: the first request arms a
/// trailing dispatch, and every request that arrives before it fires is
/// covered by that same pending dispatch. The actual WidgetKit reload runs
/// once per window, so a burst of N requests produces exactly one reload.
///
/// Calls may originate from lifecycle or refresh callbacks on different
/// executors. Scheduling state is protected by a lock; the injected scheduler
/// decides where the eventual WidgetKit reload runs (the production scheduler
/// uses the main queue).
public final class TinyBuddyWidgetReloadCoordinator: @unchecked Sendable {
    public static let shared = TinyBuddyWidgetReloadCoordinator()

    private let coalescingInterval: TimeInterval
    private let reload: () -> Void
    private let scheduler: (@escaping @Sendable () -> Void, TimeInterval) -> Void

    private let lock = NSLock()
    private var isDispatchScheduled = false

    /// - Parameters:
    ///   - coalescingInterval: Requests that arrive within this window of a
    ///     pending dispatch merge into it. Kept short so reloads stay timely.
    ///   - reload: The WidgetKit reload to run once per coalesced window.
    ///   - scheduler: Runs `reload` after `coalescingInterval`. Injected so
    ///     tests can capture and fire the merged dispatch deterministically.
    public init(
        coalescingInterval: TimeInterval = 0.5,
        reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        scheduler: @escaping (@escaping @Sendable () -> Void, TimeInterval) -> Void = {
            work, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.coalescingInterval = coalescingInterval
        self.reload = reload
        self.scheduler = scheduler
    }

    /// Requests a Widget timeline reload. Multiple calls within the coalescing
    /// window merge into one actual `reloadAllTimelines()`.
    public func requestReload() {
        lock.lock()
        guard !isDispatchScheduled else {
            lock.unlock()
            return
        }
        isDispatchScheduled = true
        lock.unlock()

        scheduler({ [weak self] in
            self?.dispatchPendingReload()
        }, coalescingInterval)
    }

    private func dispatchPendingReload() {
        lock.lock()
        guard isDispatchScheduled else {
            lock.unlock()
            return
        }
        isDispatchScheduled = false
        lock.unlock()
        reload()
    }
}
