import Foundation

public final class GitTodayCommitCountStore {
    public enum Key {
        public static let dayIdentifier = "tinybuddy.gitTodayCommitCount.dayIdentifier"
        public static let count = "tinybuddy.gitTodayCommitCount.count"
    }

    private let userDefaults: UserDefaults
    private let calendar: Calendar
    private let dateProvider: () -> Date
    private let sharedFallbacksEnabled: Bool

    public init(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init,
        sharedFallbacksEnabled: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.calendar = calendar
        self.dateProvider = dateProvider
        self.sharedFallbacksEnabled = sharedFallbacksEnabled
    }

    public func loadTodayCount() -> Int? {
        if let count = loadTodayCount(from: userDefaults) {
            return count
        }

        if sharedFallbacksEnabled,
           let directCount = loadTodayCountFromSharedPreferences() {
            return directCount
        }

        guard sharedFallbacksEnabled else {
            return nil
        }

        return loadTodayCount(from: .standard)
    }

    public func saveTodayCount(_ count: Int) {
        userDefaults.set(todayIdentifier(), forKey: Key.dayIdentifier)
        userDefaults.set(max(0, count), forKey: Key.count)
    }

    private func todayIdentifier() -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: dateProvider())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func loadTodayCount(from defaults: UserDefaults) -> Int? {
        defaults.synchronize()

        guard defaults.string(forKey: Key.dayIdentifier) == todayIdentifier() else {
            return nil
        }

        if let count = defaults.object(forKey: Key.count) as? NSNumber {
            return max(0, count.intValue)
        }

        return defaults.object(forKey: Key.count) as? Int
    }

    private func loadTodayCountFromSharedPreferences() -> Int? {
        guard let preferences = TinyBuddySharedData.loadAppGroupPreferencesDictionary() else {
            return nil
        }

        guard (preferences[Key.dayIdentifier] as? String) == todayIdentifier() else {
            return nil
        }

        if let count = preferences[Key.count] as? NSNumber {
            return max(0, count.intValue)
        }

        if let count = preferences[Key.count] as? Int {
            return max(0, count)
        }

        return nil
    }
}
