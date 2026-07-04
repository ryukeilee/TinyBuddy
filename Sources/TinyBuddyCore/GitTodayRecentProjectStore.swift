import Foundation

public final class GitTodayRecentProjectStore {
    public enum Key {
        public static let dayIdentifier = "tinybuddy.gitTodayRecentProject.dayIdentifier"
        public static let projectName = "tinybuddy.gitTodayRecentProject.projectName"
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

    public func loadTodayProjectName() -> String? {
        if let projectName = loadTodayProjectName(from: userDefaults) {
            return projectName
        }

        if sharedFallbacksEnabled,
           let directProjectName = loadTodayProjectNameFromSharedPreferences() {
            return directProjectName
        }

        guard sharedFallbacksEnabled else {
            return nil
        }

        return loadTodayProjectName(from: .standard)
    }

    public func saveTodayProjectName(_ projectName: String?) {
        userDefaults.set(todayIdentifier(), forKey: Key.dayIdentifier)

        let normalizedProjectName = projectName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedProjectName, !normalizedProjectName.isEmpty {
            userDefaults.set(normalizedProjectName, forKey: Key.projectName)
        } else {
            userDefaults.removeObject(forKey: Key.projectName)
        }
    }

    private func todayIdentifier() -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: dateProvider())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func loadTodayProjectName(from defaults: UserDefaults) -> String? {
        defaults.synchronize()

        guard defaults.string(forKey: Key.dayIdentifier) == todayIdentifier() else {
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

    private func loadTodayProjectNameFromSharedPreferences() -> String? {
        guard let preferences = TinyBuddySharedData.loadAppGroupPreferencesDictionary() else {
            return nil
        }

        guard (preferences[Key.dayIdentifier] as? String) == todayIdentifier() else {
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
}
