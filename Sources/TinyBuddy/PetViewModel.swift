import Foundation
import WidgetKit
import TinyBuddyCore

@MainActor
final class PetViewModel: ObservableObject {
    @Published private(set) var status: PetStatus
    @Published private(set) var stats: DailyStats

    private let session: PetSession

    init(store: DailyStatsStore = DailyStatsStore()) {
        let session = PetSession(store: store)
        self.session = session
        self.status = session.status
        self.stats = session.stats
    }

    func select(_ nextStatus: PetStatus) {
        stats = session.select(nextStatus)
        status = session.status
        WidgetCenter.shared.reloadAllTimelines()
    }
}
