import Foundation

public final class DailyStatsStore {
    private enum Key {
        static let dayIdentifier = "tinybuddy.dailyStats.dayIdentifier"
        static let focusCount = "tinybuddy.dailyStats.focusCount"
        static let completionCount = "tinybuddy.dailyStats.completionCount"
        static let currentStatus = "tinybuddy.currentStatus"
        static let currentStatusDayIdentifier = "tinybuddy.currentStatus.dayIdentifier"
    }

    private let userDefaults: UserDefaults
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let combinedSnapshotStoreFactory: () -> TinyBuddyCombinedSnapshotStore

    public convenience init(
        timeEnvironment: TinyBuddyTimeEnvironment = TinyBuddyTimeEnvironment()
    ) {
        let userDefaults = TinyBuddySharedData.makeUserDefaults()
        self.init(
            userDefaults: userDefaults,
            timeEnvironment: timeEnvironment,
            combinedSnapshotStoreFactory: {
                TinyBuddyCombinedSnapshotStore()
            }
        )
    }

    public convenience init(
        userDefaults: UserDefaults,
        timeEnvironment: TinyBuddyTimeEnvironment = TinyBuddyTimeEnvironment()
    ) {
        self.init(
            userDefaults: userDefaults,
            timeEnvironment: timeEnvironment,
            combinedSnapshotStoreFactory: {
                TinyBuddyCombinedSnapshotStore(
                    userDefaults: userDefaults,
                    sharedPreferencesProvider: { nil }
                )
            }
        )
    }

    public convenience init(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        calendar: Calendar,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.init(
            userDefaults: userDefaults,
            timeEnvironment: TinyBuddyTimeEnvironment(
                calendar: calendar,
                dateProvider: dateProvider
            )
        )
    }

    private init(
        userDefaults: UserDefaults,
        timeEnvironment: TinyBuddyTimeEnvironment,
        combinedSnapshotStoreFactory: @escaping () -> TinyBuddyCombinedSnapshotStore
    ) {
        self.userDefaults = userDefaults
        self.timeEnvironment = timeEnvironment
        self.combinedSnapshotStoreFactory = combinedSnapshotStoreFactory
    }

    public func loadToday() -> DailyStats {
        guard let context = timeEnvironment.capture() else {
            return loadLastValidStats()
                ?? DailyStats(dayIdentifier: "1970-01-01", focusCount: 0, completionCount: 0)
        }

        let today = context.dayIdentifier
        let storedDay = userDefaults.string(forKey: Key.dayIdentifier)

        guard let storedDay,
              TinyBuddyTimeContext.isValidDayIdentifier(storedDay) else {
            resetStatusForNewDay(todayIdentifier: today)
            return save(DailyStats(dayIdentifier: today, focusCount: 0, completionCount: 0))
        }

        if storedDay > today {
            return loadLastValidStats()
                ?? DailyStats(dayIdentifier: storedDay, focusCount: 0, completionCount: 0)
        }

        guard storedDay == today else {
            resetStatusForNewDay(todayIdentifier: today)
            return save(DailyStats(dayIdentifier: today, focusCount: 0, completionCount: 0))
        }

        return DailyStats(
            dayIdentifier: today,
            focusCount: max(0, userDefaults.integer(forKey: Key.focusCount)),
            completionCount: max(0, userDefaults.integer(forKey: Key.completionCount))
        )
    }

    @discardableResult
    public func recordFocusStarted() -> DailyStats {
        var stats = loadToday()
        guard timeEnvironment.capture()?.dayIdentifier == stats.dayIdentifier else {
            return stats
        }
        stats.focusCount += 1
        return save(stats)
    }

    @discardableResult
    public func recordCompletion() -> DailyStats {
        var stats = loadToday()
        guard timeEnvironment.capture()?.dayIdentifier == stats.dayIdentifier else {
            return stats
        }
        stats.completionCount += 1
        return save(stats)
    }

    public func loadStatus() -> PetStatus {
        guard let statusDay = userDefaults.string(forKey: Key.currentStatusDayIdentifier),
              TinyBuddyTimeContext.isValidDayIdentifier(statusDay),
              let context = timeEnvironment.capture() else {
            return loadLastValidStatus() ?? .idle
        }

        guard statusDay >= context.dayIdentifier else {
            return .idle
        }

        guard let rawValue = userDefaults.string(forKey: Key.currentStatus),
              let status = PetStatus(rawValue: rawValue) else {
            return .idle
        }

        return status
    }

    public func saveStatus(_ status: PetStatus) {
        guard let context = timeEnvironment.capture() else {
            return
        }
        if let storedDay = userDefaults.string(forKey: Key.dayIdentifier),
           TinyBuddyTimeContext.isValidDayIdentifier(storedDay),
           storedDay > context.dayIdentifier {
            return
        }
        userDefaults.set(status.rawValue, forKey: Key.currentStatus)
        userDefaults.set(context.dayIdentifier, forKey: Key.currentStatusDayIdentifier)
    }

    public func loadSnapshot() -> TinyBuddySnapshot {
        TinyBuddySnapshot(status: loadStatus(), stats: loadToday())
    }

    public func makeCombinedSnapshotStore() -> TinyBuddyCombinedSnapshotStore {
        combinedSnapshotStoreFactory()
    }

    private func save(_ stats: DailyStats) -> DailyStats {
        guard TinyBuddyTimeContext.isValidDayIdentifier(stats.dayIdentifier) else {
            return loadLastValidStats()
                ?? DailyStats(dayIdentifier: "1970-01-01", focusCount: 0, completionCount: 0)
        }
        userDefaults.set(stats.dayIdentifier, forKey: Key.dayIdentifier)
        userDefaults.set(max(0, stats.focusCount), forKey: Key.focusCount)
        userDefaults.set(max(0, stats.completionCount), forKey: Key.completionCount)
        return DailyStats(
            dayIdentifier: stats.dayIdentifier,
            focusCount: max(0, stats.focusCount),
            completionCount: max(0, stats.completionCount)
        )
    }

    private func resetStatusForNewDay(todayIdentifier: String) {
        userDefaults.set(PetStatus.idle.rawValue, forKey: Key.currentStatus)
        userDefaults.set(todayIdentifier, forKey: Key.currentStatusDayIdentifier)
    }

    private func loadLastValidStats() -> DailyStats? {
        guard let dayIdentifier = userDefaults.string(forKey: Key.dayIdentifier),
              TinyBuddyTimeContext.isValidDayIdentifier(dayIdentifier) else {
            return nil
        }
        return DailyStats(
            dayIdentifier: dayIdentifier,
            focusCount: max(0, userDefaults.integer(forKey: Key.focusCount)),
            completionCount: max(0, userDefaults.integer(forKey: Key.completionCount))
        )
    }

    private func loadLastValidStatus() -> PetStatus? {
        guard let statusDay = userDefaults.string(forKey: Key.currentStatusDayIdentifier),
              TinyBuddyTimeContext.isValidDayIdentifier(statusDay),
              statusDay == userDefaults.string(forKey: Key.dayIdentifier),
              let rawValue = userDefaults.string(forKey: Key.currentStatus) else {
            return nil
        }
        return PetStatus(rawValue: rawValue)
    }
}
