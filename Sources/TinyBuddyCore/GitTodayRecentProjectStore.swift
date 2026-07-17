import Foundation

public final class GitTodayRecentProjectStore {
    public enum Key {
        public static let dayIdentifier = "tinybuddy.gitTodayRecentProject.dayIdentifier"
        public static let projectName = "tinybuddy.gitTodayRecentProject.projectName"
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

    public func loadTodayProjectName() -> String? {
        guard let context = timeEnvironment.capture() else {
            return loadLastValidProjectName(from: userDefaults)
        }
        let expectedDayIdentifier = context.dayIdentifier

        if let projectName = loadTodayProjectName(
            from: userDefaults,
            expectedDayIdentifier: expectedDayIdentifier
        ) {
            return projectName
        }

        if sharedFallbacksEnabled,
           let directProjectName = loadTodayProjectNameFromSharedPreferences(
            expectedDayIdentifier: expectedDayIdentifier
           ) {
            return directProjectName
        }

        guard sharedFallbacksEnabled else {
            return nil
        }

        return loadTodayProjectName(
            from: .standard,
            expectedDayIdentifier: expectedDayIdentifier
        )
    }

    public func saveTodayProjectName(_ projectName: String?) {
        guard let context = timeEnvironment.capture() else {
            return
        }
        if let storedDay = userDefaults.string(forKey: Key.dayIdentifier),
           TinyBuddyTimeContext.isValidDayIdentifier(storedDay),
           storedDay > context.dayIdentifier {
            return
        }
        userDefaults.set(context.dayIdentifier, forKey: Key.dayIdentifier)

        let normalizedProjectName = projectName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedProjectName, !normalizedProjectName.isEmpty {
            userDefaults.set(normalizedProjectName, forKey: Key.projectName)
        } else {
            userDefaults.removeObject(forKey: Key.projectName)
        }
    }

    private func loadTodayProjectName(
        from defaults: UserDefaults,
        expectedDayIdentifier: String
    ) -> String? {
        defaults.synchronize()

        guard let storedDay = defaults.string(forKey: Key.dayIdentifier),
              TinyBuddyTimeContext.isValidDayIdentifier(storedDay),
              storedDay == expectedDayIdentifier else {
            return nil
        }

        guard let projectName = defaults.string(forKey: Key.projectName) else {
            return nil
        }

        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectName.isEmpty else {
            return nil
        }

        return normalizedProjectName
    }

    private func loadTodayProjectNameFromSharedPreferences(
        expectedDayIdentifier: String
    ) -> String? {
        guard let preferences = TinyBuddySharedData.loadAppGroupPreferencesDictionary() else {
            return nil
        }

        guard let storedDay = preferences[Key.dayIdentifier] as? String,
              TinyBuddyTimeContext.isValidDayIdentifier(storedDay),
              storedDay == expectedDayIdentifier else {
            return nil
        }

        guard let projectName = preferences[Key.projectName] as? String else {
            return nil
        }

        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectName.isEmpty else {
            return nil
        }

        return normalizedProjectName
    }

    private func loadLastValidProjectName(from defaults: UserDefaults) -> String? {
        guard let storedDay = defaults.string(forKey: Key.dayIdentifier),
              TinyBuddyTimeContext.isValidDayIdentifier(storedDay),
              let projectName = defaults.string(forKey: Key.projectName) else {
            return nil
        }
        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedProjectName.isEmpty ? nil : normalizedProjectName
    }
}
