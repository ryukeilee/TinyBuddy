import Foundation

// MARK: - Deterministic Scheduler

/// A deterministic event scheduler that replaces real timers, `DispatchQueue.asyncAfter`,
/// and all wait/poll/sleep primitives in tests.
///
/// Actions are scheduled at a specific wall-clock time and executed in deterministic
/// chronological order when `advanceTime(by:)` or `runUntilIdle()` is called.
///
/// This enables tests to control exactly when timers fire, ensuring repeatable behavior
/// without real-time dependencies.
public final class DeterministicScheduler: @unchecked Sendable {

    // MARK: Types

    /// A scheduled action with its fire time and identity.
    private struct ScheduledAction {
        let id: UUID
        let fireTime: TimeInterval
        let action: @Sendable () -> Void
    }

    /// A repeating timer handle that can be invalidated.
    public final class TimerHandle: @unchecked Sendable {
        private weak var scheduler: DeterministicScheduler?
        private let actionID: UUID
        private var isValid = true
        private let lock = NSLock()

        fileprivate init(scheduler: DeterministicScheduler, actionID: UUID) {
            self.scheduler = scheduler
            self.actionID = actionID
        }

        /// Invalidates the timer, preventing future firings.
        public func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            guard isValid else { return }
            isValid = false
            scheduler?.removeAction(id: actionID)
        }

        fileprivate var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isValid
        }
    }

    // MARK: State

    private var currentTime: TimeInterval = 0
    private var pendingActions: [ScheduledAction] = []
    private var history: [SchedulerEvent] = []
    private let lock = NSLock()

    // MARK: Public API

    /// The current virtual time in seconds since an arbitrary epoch.
    public var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    /// All events that have occurred, ordered by virtual time.
    public var eventHistory: [SchedulerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    /// The number of pending (not yet fired) actions.
    public var pendingActionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingActions.count
    }

    /// Schedules a one-shot action to fire after the specified delay.
    /// Returns a handle that can be used to cancel the action.
    @discardableResult
    public func schedule(
        after delay: TimeInterval,
        label: String = "",
        action: @escaping @Sendable () -> Void
    ) -> TimerHandle {
        lock.lock()
        let fireTime = currentTime + delay
        let id = UUID()
        let handle = TimerHandle(scheduler: self, actionID: id)
        let scheduled = ScheduledAction(id: id, fireTime: fireTime, action: action)
        pendingActions.append(scheduled)
        pendingActions.sort { $0.fireTime < $1.fireTime }
        history.append(.scheduled(
            id: id,
            fireTime: fireTime,
            delay: delay,
            label: label
        ))
        lock.unlock()
        return handle
    }

    /// Schedules a repeating action. Returns a handle; call `invalidate()` to stop.
    /// The action fires at `currentTime + delay`, then repeats every `interval`.
    @discardableResult
    public func scheduleRepeating(
        after delay: TimeInterval,
        interval: TimeInterval,
        label: String = "",
        action: @escaping @Sendable () -> Void
    ) -> TimerHandle {
        let id = UUID()
        let handle = TimerHandle(scheduler: self, actionID: id)

        // Box to break the self-reference cycle in the recursive action.
        let box = SendableBox<(@Sendable () -> Void)?>(nil)

        let recurringAction: @Sendable () -> Void = { [weak self, weak handle] in
            guard let self, let handle, handle.isActive else { return }
            action()
            self.lock.lock()
            let nextFire = self.currentTime + interval
            if let current = box.value {
                self.pendingActions.append(ScheduledAction(
                    id: id,
                    fireTime: nextFire,
                    action: current
                ))
                self.pendingActions.sort { $0.fireTime < $1.fireTime }
            }
            self.history.append(.recurringFired(
                id: id,
                at: self.currentTime,
                nextFire: nextFire,
                label: label
            ))
            self.lock.unlock()
        }
        box.value = recurringAction

        lock.lock()
        let fireTime = currentTime + delay
        pendingActions.append(ScheduledAction(id: id, fireTime: fireTime, action: recurringAction))
        pendingActions.sort { $0.fireTime < $1.fireTime }
        history.append(.scheduled(
            id: id,
            fireTime: fireTime,
            delay: delay,
            label: label
        ))
        lock.unlock()

        return handle
    }

    /// Advances virtual time by the specified interval, firing any actions
    /// whose fire time falls within the advanced window in chronological order.
    public func advanceTime(by interval: TimeInterval) {
        guard interval > 0 else { return }
        let targetTime: TimeInterval
        lock.lock()
        currentTime += interval
        targetTime = currentTime
        lock.unlock()

        firePendingActions(upTo: targetTime)
    }

    /// Runs all currently pending actions regardless of fire time, then advances
    /// time to the last fire time. Useful for draining the queue.
    public func runAllPending() {
        lock.lock()
        guard !pendingActions.isEmpty else {
            lock.unlock()
            return
        }
        let maxFireTime = pendingActions.last!.fireTime
        lock.unlock()
        firePendingActions(upTo: maxFireTime)
    }

    /// Advances time to just past the next pending action and fires it.
    /// Returns `true` if an action was fired.
    @discardableResult
    public func fireNext() -> Bool {
        lock.lock()
        guard let next = pendingActions.first else {
            lock.unlock()
            return false
        }
        if next.fireTime > currentTime {
            currentTime = next.fireTime
        }
        lock.unlock()
        return firePendingActions(upTo: currentTime, maxCount: 1) > 0
    }

    /// Advances time until there are no pending actions left to fire at or
    /// before the current time. Returns the number of actions fired.
    @discardableResult
    public func drainPending() -> Int {
        var total = 0
        while fireNext() {
            total += 1
        }
        return total
    }

    /// Removes all pending actions and resets time.
    public func reset() {
        lock.lock()
        currentTime = 0
        pendingActions.removeAll()
        history.removeAll()
        lock.unlock()
    }

    /// Creates a `DispatchQueue`-compatible async-after closure for the specified delay.
    /// Returns a closure that, when called, schedules the work for that delay.
    public func asyncAfter(
        deadline: DispatchTime,
        qos _: DispatchQoS = .unspecified,
        flags _: DispatchWorkItemFlags = [],
        execute work: @escaping @Sendable @convention(block) () -> Void
    ) {
        // Convert DispatchTime to our virtual time.
        // We interpret DispatchTime as seconds from our epoch.
        let delay: TimeInterval
        switch deadline {
        case .now():
            delay = 0
        case let .distantFuture:
            // Never fire in practical tests.
            return
        default:
            let raw = deadline.rawValue
            // DispatchTime uses UInt64 nanoseconds.
            let nanoseconds = raw
            let targetTime = TimeInterval(nanoseconds) / 1_000_000_000.0
            let currentSeconds = now
            delay = max(0, targetTime - currentSeconds)
        }
        schedule(after: delay, label: "asyncAfter", action: work)
    }

    // MARK: Internal

    private func removeAction(id: UUID) {
        lock.lock()
        pendingActions.removeAll { $0.id == id }
        history.append(.cancelled(id: id))
        lock.unlock()
    }

    @discardableResult
    private func firePendingActions(upTo targetTime: TimeInterval, maxCount: Int? = nil) -> Int {
        var fired = 0
        while true {
            lock.lock()
            guard let next = pendingActions.first, next.fireTime <= targetTime else {
                lock.unlock()
                break
            }
            if let max = maxCount, fired >= max {
                lock.unlock()
                break
            }
            pendingActions.removeFirst()
            let action = next.action
            if next.fireTime > currentTime {
                currentTime = next.fireTime
            }
            history.append(.fired(id: next.id, at: currentTime))
            lock.unlock()

            action()
            fired += 1
        }
        return fired
    }
}

// MARK: - Sendable Box

/// A thread-safe box for mutable Sendable values. Used to break
/// self-reference cycles in recursive closures.
private final class SendableBox<T: Sendable>: @unchecked Sendable {
    var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func withLock<T2>(_ body: (inout T) -> T2) -> T2 {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Scheduler Event

/// Recorded event in the scheduler's timeline.
public enum SchedulerEvent: Equatable, Sendable {
    case scheduled(id: UUID, fireTime: TimeInterval, delay: TimeInterval, label: String)
    case fired(id: UUID, at: TimeInterval)
    case cancelled(id: UUID)
    case recurringFired(id: UUID, at: TimeInterval, nextFire: TimeInterval, label: String)

    public var description: String {
        switch self {
        case let .scheduled(id, fireTime, delay, label):
            "SCHEDULED \(id) at \(String(format: "%.3f", fireTime))s (delay=\(String(format: "%.3f", delay))s) \(label)"
        case let .fired(id, at):
            "FIRED \(id) at \(String(format: "%.3f", at))s"
        case let .cancelled(id):
            "CANCELLED \(id)"
        case let .recurringFired(id, at, nextFire, label):
            "RECURRING \(id) at \(String(format: "%.3f", at))s -> next at \(String(format: "%.3f", nextFire))s \(label)"
        }
    }
}
