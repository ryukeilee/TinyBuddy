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
        if isRefreshing {
            self = .loading
            return
        }

        guard let refreshStatus else {
            self = .loading
            return
        }

        switch refreshStatus.diagnostic?.reason {
        case .authorizationRequired:
            self = .authorizationRequired
            return
        case .authorizationInvalid:
            self = .authorizationInvalid
            return
        case .partialAuthorizationRecovery, .partialRecovery:
            self = .partial
            return
        default:
            break
        }

        if refreshStatus.outcome == .failed {
            self = .failed
            return
        }

        if refreshStatus.metrics?.authorizedRootCount ?? 0 > 0,
           refreshStatus.metrics?.repositoryCount == 0 {
            self = .noRepositories
            return
        }

        if refreshStatus.metrics?.repositoryCount ?? 0 > 0,
           activitySnapshot.focusBlockCount == 0,
           activitySnapshot.commitCount == 0 {
            self = .noActivity
            return
        }

        self = refreshStatus.outcome == .partial ? .partial : .ready
    }

    public var showsActivityMetrics: Bool {
        self == .ready || self == .partial
    }
}
