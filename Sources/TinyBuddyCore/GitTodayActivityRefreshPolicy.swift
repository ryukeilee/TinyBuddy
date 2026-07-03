import Foundation

public enum GitTodayActivityRefreshTrigger: Equatable, Sendable {
    case launch
    case becameActive
    case reopen
    case didWake
    case screensDidWake
    case sessionDidBecomeActive
    case timer
}

public enum GitTodayActivityRefreshPolicy {
    public static func shouldReloadWidget(
        for trigger: GitTodayActivityRefreshTrigger,
        didChange: Bool
    ) -> Bool {
        switch trigger {
        case .launch, .becameActive, .reopen, .didWake, .screensDidWake, .sessionDidBecomeActive:
            return true
        case .timer:
            return didChange
        }
    }
}
