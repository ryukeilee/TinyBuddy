import Foundation

public enum TinyBuddySharedData {
    public static let appGroupIdentifier = "group.com.ryukeili.TinyBuddy"

    public static func makeUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static func appGroupPreferencesPlistURL(fileManager: FileManager = .default) -> URL? {
        if let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent("\(appGroupIdentifier).plist")
        }

        let homeDirectoryPath = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) })
        let homeDirectory = homeDirectoryPath
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupIdentifier, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(appGroupIdentifier).plist")
    }

    public static func loadAppGroupPreferencesDictionary(
        fileManager: FileManager = .default
    ) -> [String: Any]? {
        guard let url = appGroupPreferencesPlistURL(fileManager: fileManager),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) else {
            return nil
        }

        return plist as? [String: Any]
    }
}

public struct TinyBuddySnapshot: Equatable, Sendable {
    public let status: PetStatus
    public let stats: DailyStats

    public init(status: PetStatus, stats: DailyStats) {
        self.status = status
        self.stats = stats
    }
}
