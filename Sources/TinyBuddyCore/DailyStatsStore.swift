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
    private let calendar: Calendar
    private let dateProvider: () -> Date
    private let combinedSnapshotStoreFactory: () -> TinyBuddyCombinedSnapshotStore

    public convenience init(
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        let userDefaults = TinyBuddySharedData.makeUserDefaults()
        self.init(
            userDefaults: userDefaults,
            calendar: calendar,
            dateProvider: dateProvider,
            combinedSnapshotStoreFactory: {
                TinyBuddyCombinedSnapshotStore()
            }
        )
    }

    public convenience init(
        userDefaults: UserDefaults,
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.init(
            userDefaults: userDefaults,
            calendar: calendar,
            dateProvider: dateProvider,
            combinedSnapshotStoreFactory: {
                TinyBuddyCombinedSnapshotStore(
                    userDefaults: userDefaults,
                    sharedPreferencesProvider: { nil }
                )
            }
        )
    }

    private init(
        userDefaults: UserDefaults,
        calendar: Calendar,
        dateProvider: @escaping () -> Date,
        combinedSnapshotStoreFactory: @escaping () -> TinyBuddyCombinedSnapshotStore
    ) {
        self.userDefaults = userDefaults
        self.calendar = calendar
        self.dateProvider = dateProvider
        self.combinedSnapshotStoreFactory = combinedSnapshotStoreFactory
    }

    public func loadToday() -> DailyStats {
        let today = todayIdentifier()
        let storedDay = userDefaults.string(forKey: Key.dayIdentifier)

        guard storedDay == today else {
            resetStatusForNewDay(todayIdentifier: today)
            return save(DailyStats(dayIdentifier: today, focusCount: 0, completionCount: 0))
        }

        return DailyStats(
            dayIdentifier: today,
            focusCount: userDefaults.integer(forKey: Key.focusCount),
            completionCount: userDefaults.integer(forKey: Key.completionCount)
        )
    }

    @discardableResult
    public func recordFocusStarted() -> DailyStats {
        var stats = loadToday()
        stats.focusCount += 1
        return save(stats)
    }

    @discardableResult
    public func recordCompletion() -> DailyStats {
        var stats = loadToday()
        stats.completionCount += 1
        return save(stats)
    }

    public func loadStatus() -> PetStatus {
        guard userDefaults.string(forKey: Key.currentStatusDayIdentifier) == todayIdentifier() else {
            return .idle
        }

        guard let rawValue = userDefaults.string(forKey: Key.currentStatus),
              let status = PetStatus(rawValue: rawValue) else {
            return .idle
        }

        return status
    }

    public func saveStatus(_ status: PetStatus) {
        userDefaults.set(status.rawValue, forKey: Key.currentStatus)
        userDefaults.set(todayIdentifier(), forKey: Key.currentStatusDayIdentifier)
    }

    public func loadSnapshot() -> TinyBuddySnapshot {
        TinyBuddySnapshot(status: loadStatus(), stats: loadToday())
    }

    public func makeCombinedSnapshotStore() -> TinyBuddyCombinedSnapshotStore {
        combinedSnapshotStoreFactory()
    }

    private func save(_ stats: DailyStats) -> DailyStats {
        userDefaults.set(stats.dayIdentifier, forKey: Key.dayIdentifier)
        userDefaults.set(stats.focusCount, forKey: Key.focusCount)
        userDefaults.set(stats.completionCount, forKey: Key.completionCount)
        return stats
    }

    private func resetStatusForNewDay(todayIdentifier: String) {
        userDefaults.set(PetStatus.idle.rawValue, forKey: Key.currentStatus)
        userDefaults.set(todayIdentifier, forKey: Key.currentStatusDayIdentifier)
    }

    private func todayIdentifier() -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: dateProvider())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
