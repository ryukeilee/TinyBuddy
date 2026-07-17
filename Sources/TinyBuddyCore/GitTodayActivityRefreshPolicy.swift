import Foundation

public enum GitTodayActivityRefreshTrigger: String, Equatable, Sendable {
    case launch
    case becameActive
    case reopen
    case didWake
    case screensDidWake
    case sessionDidBecomeActive
    case timeEnvironmentChanged
    case timer
}

/// Inputs that affect the cost and usefulness of another Git activity scan.
///
/// The policy intentionally has no dependency on AppKit, power APIs, or timers
/// so the app can provide live values and tests can exercise every state
/// deterministically.
public struct GitTodayActivityRefreshCadenceConditions: Equatable, Sendable {
    public let isApplicationActive: Bool
    public let isInterfaceVisible: Bool
    public let isOnBatteryPower: Bool
    public let isLowPowerModeEnabled: Bool
    public let unchangedRefreshStreak: Int

    public init(
        isApplicationActive: Bool,
        isInterfaceVisible: Bool,
        isOnBatteryPower: Bool,
        isLowPowerModeEnabled: Bool,
        unchangedRefreshStreak: Int
    ) {
        self.isApplicationActive = isApplicationActive
        self.isInterfaceVisible = isInterfaceVisible
        self.isOnBatteryPower = isOnBatteryPower
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.unchangedRefreshStreak = unchangedRefreshStreak
    }

    public var isForegroundVisible: Bool {
        isApplicationActive && isInterfaceVisible
    }
}

public enum GitTodayActivityRefreshChange: Equatable, Sendable {
    case changed
    case unchanged
    case unknown
}

public struct GitTodayActivityRefreshCadence: Equatable, Sendable {
    public let nextRefreshInterval: TimeInterval
    public let allowsRepositoryEventListening: Bool

    public init(nextRefreshInterval: TimeInterval, allowsRepositoryEventListening: Bool) {
        self.nextRefreshInterval = nextRefreshInterval
        self.allowsRepositoryEventListening = allowsRepositoryEventListening
    }
}

public enum GitTodayActivityRefreshPolicy {
    public static let maximumUnchangedRefreshStreak = 6
    public static let maximumRefreshInterval: TimeInterval = 60 * 60

    public static func shouldReloadWidget(
        for trigger: GitTodayActivityRefreshTrigger,
        didChange: Bool
    ) -> Bool {
        didChange
    }

    public static func cadence(
        for conditions: GitTodayActivityRefreshCadenceConditions
    ) -> GitTodayActivityRefreshCadence {
        let streak = boundedUnchangedRefreshStreak(conditions.unchangedRefreshStreak)
        let interval: TimeInterval

        if conditions.isLowPowerModeEnabled {
            interval = conditions.isForegroundVisible ? 30 * 60 : 60 * 60
        } else if conditions.isOnBatteryPower {
            interval = conditions.isForegroundVisible
                ? (streak == 0 ? 15 * 60 : 30 * 60)
                : 60 * 60
        } else if conditions.isForegroundVisible {
            switch streak {
            case 0:
                interval = 5 * 60
            case 1...2:
                interval = 10 * 60
            default:
                interval = 20 * 60
            }
        } else {
            interval = streak == 0 ? 30 * 60 : 60 * 60
        }

        return GitTodayActivityRefreshCadence(
            nextRefreshInterval: min(interval, maximumRefreshInterval),
            allowsRepositoryEventListening: conditions.isForegroundVisible
                && !conditions.isOnBatteryPower
                && !conditions.isLowPowerModeEnabled
        )
    }

    public static func updatedUnchangedRefreshStreak(
        currentStreak: Int,
        result: GitTodayActivityRefreshChange
    ) -> Int {
        let currentStreak = boundedUnchangedRefreshStreak(currentStreak)
        switch result {
        case .changed:
            return 0
        case .unchanged:
            return min(currentStreak + 1, maximumUnchangedRefreshStreak)
        case .unknown:
            return currentStreak
        }
    }

    private static func boundedUnchangedRefreshStreak(_ streak: Int) -> Int {
        min(max(0, streak), maximumUnchangedRefreshStreak)
    }
}
