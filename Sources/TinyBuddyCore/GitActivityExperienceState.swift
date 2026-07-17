import Foundation

public enum GitActivityExperienceState: Equatable, Sendable {
    case loading
    case authorizationRequired
    case authorizationInvalid
    case noRepositories
    case noActivity
    case failed
    case partial
    case ready

    public init(
        refreshStatus: GitActivityRefreshStatus?,
        activitySnapshot: GitTodayActivitySnapshot,
        isRefreshing: Bool = false
    ) {
        let focusCount = max(0, activitySnapshot.focusBlockCount ?? 0)
        let completionCount = max(0, activitySnapshot.commitCount ?? 0)
        let petStatus: PetStatus
        if completionCount > 0 {
            petStatus = .completedOnce
        } else if focusCount > 0 {
            petStatus = .focusing
        } else {
            petStatus = .idle
        }
        let availability: TinyBuddyDisplayDataAvailability = refreshStatus == nil
            ? .loading
            : .available
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: TinyBuddySnapshot(
                status: petStatus,
                stats: DailyStats(
                    dayIdentifier: "",
                    focusCount: focusCount,
                    completionCount: completionCount
                )
            ),
            activitySnapshot: activitySnapshot,
            refreshStatus: refreshStatus,
            dataAvailability: availability,
            isRefreshing: isRefreshing
        )

        switch presentation.state {
        case .loading:
            self = .loading
        case .authorizationRequired:
            self = .authorizationRequired
        case .authorizationInvalid:
            self = .authorizationInvalid
        case .noRepositories:
            self = .noRepositories
        case .noActivity:
            self = .noActivity
        case .readFailed, .stale:
            self = .failed
        case .partial:
            self = .partial
        case .idle, .focusing, .completedToday:
            self = .ready
        }
    }

    public var showsActivityMetrics: Bool {
        self == .ready || self == .partial
    }
}
