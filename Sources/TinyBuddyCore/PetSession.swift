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

    @discardableResult
    public func select(_ nextStatus: PetStatus) -> DailyStats {
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
