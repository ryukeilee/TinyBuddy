import Foundation

public struct GitTodayActivityTrustedSnapshot: Equatable, Sendable {
    public let revision: Int64
    public let dayIdentifier: String
    public let activity: GitTodayActivitySnapshot

    public init(revision: Int64, dayIdentifier: String, activity: GitTodayActivitySnapshot) {
        self.revision = revision
        self.dayIdentifier = dayIdentifier
        self.activity = activity
    }
}

public final class GitTodayActivityTrustedSnapshotStore {
    public enum Key {
        public static let snapshot = "tinybuddy.gitTodayActivity.trustedSnapshot"
    }

    private let userDefaults: UserDefaults
    private let sharedPreferencesProvider: () -> [String: Any]?
    private let fallbackDefaults: UserDefaults?

    public init(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        sharedPreferencesProvider: @escaping () -> [String: Any]? = {
            TinyBuddySharedData.loadAppGroupPreferencesDictionary()
        },
        fallbackDefaults: UserDefaults? = nil
    ) {
        self.userDefaults = userDefaults
        self.sharedPreferencesProvider = sharedPreferencesProvider
        self.fallbackDefaults = fallbackDefaults
    }

    public func load() -> GitTodayActivityTrustedSnapshot? {
        userDefaults.synchronize()
        fallbackDefaults?.synchronize()

        let candidates = [
            userDefaults.string(forKey: Key.snapshot),
            sharedPreferencesProvider()?[Key.snapshot] as? String,
            fallbackDefaults?.string(forKey: Key.snapshot)
        ]

        return candidates
            .compactMap { value in value.flatMap(Self.decode) }
            .max { lhs, rhs in lhs.revision < rhs.revision }
    }

    @discardableResult
    public func save(_ snapshot: GitTodayActivityTrustedSnapshot) -> Bool {
        if let current = load() {
            if current.revision >= snapshot.revision {
                return false
            }
        }

        userDefaults.set(Self.encode(snapshot), forKey: Key.snapshot)
        return true
    }

    public static func encode(_ snapshot: GitTodayActivityTrustedSnapshot) -> String {
        let projectName = snapshot.activity.recentProjectName ?? ""
        let encodedProjectName = Data(projectName.utf8).base64EncodedString()
        return [
            String(snapshot.revision),
            snapshot.dayIdentifier,
            String(max(0, snapshot.activity.focusBlockCount ?? 0)),
            String(max(0, snapshot.activity.commitCount ?? 0)),
            encodedProjectName
        ].joined(separator: "\t")
    }

    public static func decode(_ value: String) -> GitTodayActivityTrustedSnapshot? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let revision = Int64(fields[0]),
              revision >= 0,
              !fields[1].isEmpty,
              let focusBlockCount = Int(fields[2]),
              focusBlockCount >= 0,
              let commitCount = Int(fields[3]),
              commitCount >= 0,
              let projectData = Data(base64Encoded: String(fields[4])),
              let projectName = String(data: projectData, encoding: .utf8) else {
            return nil
        }

        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitTodayActivityTrustedSnapshot(
            revision: revision,
            dayIdentifier: String(fields[1]),
            activity: GitTodayActivitySnapshot(
                focusBlockCount: focusBlockCount,
                commitCount: commitCount,
                recentProjectName: normalizedProjectName.isEmpty ? nil : normalizedProjectName
            )
        )
    }
}
