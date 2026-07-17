import Foundation
import TinyBuddyCore

enum GitActivityExperienceAction: Equatable {
    case chooseDirectories
    case reauthorize
    case addDirectory
    case rescan
}

struct GitActivityExperiencePresentation: Equatable {
    let state: GitActivityExperienceState
    let title: String
    let message: String
    let systemImage: String
    let action: GitActivityExperienceAction?
    let actionTitle: String?

    static func make(
        from presentation: TinyBuddyDisplayPresentation
    ) -> GitActivityExperiencePresentation {
        GitActivityExperiencePresentation(
            state: legacyState(for: presentation.state),
            title: presentation.title,
            message: presentation.message,
            systemImage: presentation.systemImage,
            action: presentation.action.map(legacyAction),
            actionTitle: presentation.actionTitle
        )
    }

    static func make(
        refreshStatus: GitActivityRefreshStatus?,
        activitySnapshot: GitTodayActivitySnapshot,
        isRefreshing: Bool,
        onboardingCompleted: Bool
    ) -> GitActivityExperiencePresentation {
        let focusCount = max(0, activitySnapshot.focusBlockCount ?? 0)
        let completionCount = max(0, activitySnapshot.commitCount ?? 0)
        let petStatus: PetStatus = completionCount > 0
            ? .completedOnce
            : (focusCount > 0 ? .focusing : .idle)
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
            dataAvailability: refreshStatus == nil ? .loading : .available,
            isRefreshing: isRefreshing,
            onboardingCompleted: onboardingCompleted
        )

        return make(from: presentation)
    }

    private static func legacyState(
        for state: TinyBuddyDisplayState
    ) -> GitActivityExperienceState {
        switch state {
        case .loading:
            return .loading
        case .authorizationRequired:
            return .authorizationRequired
        case .authorizationInvalid:
            return .authorizationInvalid
        case .noRepositories:
            return .noRepositories
        case .noActivity:
            return .noActivity
        case .readFailed, .stale:
            return .failed
        case .partial:
            return .partial
        case .idle, .focusing, .completedToday:
            return .ready
        }
    }

    private static func legacyAction(
        _ action: TinyBuddyDisplayAction
    ) -> GitActivityExperienceAction {
        switch action {
        case .chooseDirectories:
            return .chooseDirectories
        case .reauthorize:
            return .reauthorize
        case .addDirectory:
            return .addDirectory
        case .rescan:
            return .rescan
        }
    }
}
