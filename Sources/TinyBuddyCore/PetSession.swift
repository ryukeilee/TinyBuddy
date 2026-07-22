import Foundation

public final class PetSession {
    public private(set) var status: PetStatus
    public private(set) var stats: DailyStats

    private let store: DailyStatsStore

    public init(store: DailyStatsStore = DailyStatsStore()) {
        self.store = store
        let snapshot = store.loadSnapshot()
        self.status = snapshot.status
        self.stats = snapshot.stats
    }

    /// Selects a new status and records the associated count change.
    ///
    /// Idempotency guarantees:
    /// - Calling `select(.focusing)` when already `.focusing` is a no-op;
    ///   the focus count is not incremented again.
    /// - Calling `select(.completedOnce)` when already `.completedOnce` is a
    ///   no-op; the completion count is not incremented again.
    /// - Calling `select(.idle)` when already `.idle` is a no-op.
    ///
    /// A transition from any status to a different status always records
    /// normally.  This prevents double-tap, duplicate notification, and
    /// retry scenarios from accumulating duplicate counts.
    @discardableResult
    public func select(_ nextStatus: PetStatus) -> DailyStats {
        // State-machine guard: same-status transitions are idempotent no-ops.
        guard status != nextStatus else {
            stats = store.loadToday()
            return stats
        }

        status = nextStatus

        switch nextStatus {
        case .idle:
            stats = store.loadToday()
        case .focusing:
            stats = store.recordFocusStarted()
        case .completedOnce:
            stats = store.recordCompletion()
        }

        store.saveStatus(nextStatus)

        return stats
    }
}
