import Foundation

public final class GitTodayCommitCountStore {
    public enum Key {
        public static let dayIdentifier = "tinybuddy.gitTodayCommitCount.dayIdentifier"
        public static let count = "tinybuddy.gitTodayCommitCount.count"
    }

    private let userDefaults: UserDefaults
    private let calendar: Calendar
    private let dateProvider: () -> Date

    public init(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.calendar = calendar
        self.dateProvider = dateProvider
    }

    public func loadTodayCount() -> Int? {
        guard userDefaults.string(forKey: Key.dayIdentifier) == todayIdentifier() else {
            return nil
        }

        return userDefaults.object(forKey: Key.count) as? Int
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
}
