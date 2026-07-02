import Foundation

public final class GitTodayRecentProjectStore {
    public enum Key {
        public static let dayIdentifier = "tinybuddy.gitTodayRecentProject.dayIdentifier"
        public static let projectName = "tinybuddy.gitTodayRecentProject.projectName"
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

    public func loadTodayProjectName() -> String? {
        userDefaults.synchronize()

        guard userDefaults.string(forKey: Key.dayIdentifier) == todayIdentifier() else {
            return nil
        }

        guard let projectName = userDefaults.string(forKey: Key.projectName)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !projectName.isEmpty
        else {
            return nil
        }

        return projectName
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
}
