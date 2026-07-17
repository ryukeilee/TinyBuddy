import Foundation

public final class GitTodayFocusBlockCountStore {
    public enum Key {
        public static let dayIdentifier = "tinybuddy.gitTodayFocusBlockCount.dayIdentifier"
        public static let count = "tinybuddy.gitTodayFocusBlockCount.count"
    }

    private let userDefaults: UserDefaults
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let sharedFallbacksEnabled: Bool

    public init(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        timeEnvironment: TinyBuddyTimeEnvironment = TinyBuddyTimeEnvironment(),
        sharedFallbacksEnabled: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.timeEnvironment = timeEnvironment
        self.sharedFallbacksEnabled = sharedFallbacksEnabled
    }

    public convenience init(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        calendar: Calendar,
        dateProvider: @escaping () -> Date = Date.init,
        sharedFallbacksEnabled: Bool = true
    ) {
        self.init(
            userDefaults: userDefaults,
            timeEnvironment: TinyBuddyTimeEnvironment(
                calendar: calendar,
                dateProvider: dateProvider
            ),
            sharedFallbacksEnabled: sharedFallbacksEnabled
        )
    }

    public func loadTodayCount() -> Int? {
        guard let context = timeEnvironment.capture() else {
            return loadLastValidCount(from: userDefaults)
        }
        let expectedDayIdentifier = context.dayIdentifier

        if let count = loadTodayCount(from: userDefaults, expectedDayIdentifier: expectedDayIdentifier) {
            return count
        }

        if sharedFallbacksEnabled,
           let directCount = loadTodayCountFromSharedPreferences(
            expectedDayIdentifier: expectedDayIdentifier
           ) {
            return directCount
        }

        guard sharedFallbacksEnabled else {
            return nil
        }

        return loadTodayCount(from: .standard, expectedDayIdentifier: expectedDayIdentifier)
    }

    public func saveTodayCount(_ count: Int) {
        guard let context = timeEnvironment.capture() else {
            return
        }
        if let storedDay = userDefaults.string(forKey: Key.dayIdentifier),
           TinyBuddyTimeContext.isValidDayIdentifier(storedDay),
           storedDay > context.dayIdentifier {
            return
        }
        userDefaults.set(context.dayIdentifier, forKey: Key.dayIdentifier)
        userDefaults.set(max(0, count), forKey: Key.count)
    }

    private func loadTodayCount(
        from defaults: UserDefaults,
        expectedDayIdentifier: String
    ) -> Int? {
        defaults.synchronize()

        guard let storedDay = defaults.string(forKey: Key.dayIdentifier),
              TinyBuddyTimeContext.isValidDayIdentifier(storedDay),
              storedDay == expectedDayIdentifier else {
            return nil
        }

        if let count = defaults.object(forKey: Key.count) as? NSNumber {
            return max(0, count.intValue)
        }

        return defaults.object(forKey: Key.count) as? Int
    }

    private func loadTodayCountFromSharedPreferences(
        expectedDayIdentifier: String
    ) -> Int? {
        guard let preferences = TinyBuddySharedData.loadAppGroupPreferencesDictionary() else {
            return nil
        }

        guard let storedDay = preferences[Key.dayIdentifier] as? String,
              TinyBuddyTimeContext.isValidDayIdentifier(storedDay),
              storedDay == expectedDayIdentifier else {
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

    private func loadLastValidCount(from defaults: UserDefaults) -> Int? {
        guard let storedDay = defaults.string(forKey: Key.dayIdentifier),
              TinyBuddyTimeContext.isValidDayIdentifier(storedDay) else {
            return nil
        }
        if let count = defaults.object(forKey: Key.count) as? NSNumber {
            return max(0, count.intValue)
        }
        return (defaults.object(forKey: Key.count) as? Int).map { max(0, $0) }
    }
}
