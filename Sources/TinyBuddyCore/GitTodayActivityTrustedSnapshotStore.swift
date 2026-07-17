import Foundation

public struct GitTodayActivityTrustedSnapshot: Equatable, Sendable {
    public let revision: Int64
    public let dayIdentifier: String
    public let timeScopeIdentifier: String?
    public let timeScopeToken: String?
    public let activity: GitTodayActivitySnapshot

    public init(
        revision: Int64,
        dayIdentifier: String,
        timeScopeIdentifier: String? = nil,
        timeScopeToken: String? = nil,
        activity: GitTodayActivitySnapshot
    ) {
        self.revision = revision
        self.dayIdentifier = dayIdentifier
        self.timeScopeIdentifier = timeScopeIdentifier
        self.timeScopeToken = timeScopeToken
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
        load(dayIdentifier: nil)
    }

    public func load(dayIdentifier: String) -> GitTodayActivityTrustedSnapshot? {
        guard TinyBuddyTimeContext.isValidDayIdentifier(dayIdentifier) else {
            return nil
        }
        return load(dayIdentifier: Optional(dayIdentifier), timeScopeIdentifier: nil)
    }

    public func load(
        dayIdentifier: String,
        timeScopeIdentifier: String,
        timeScopeToken: String?
    ) -> GitTodayActivityTrustedSnapshot? {
        guard TinyBuddyTimeContext.isValidDayIdentifier(dayIdentifier),
              !timeScopeIdentifier.isEmpty else {
            return nil
        }
        return load(
            dayIdentifier: Optional(dayIdentifier),
            timeScopeIdentifier: timeScopeIdentifier,
            timeScopeToken: timeScopeToken
        )
    }

    public func containsEnvironmentScopedSnapshot(dayIdentifier: String) -> Bool {
        guard TinyBuddyTimeContext.isValidDayIdentifier(dayIdentifier) else {
            return false
        }
        return decodedCandidates().contains {
            $0.dayIdentifier == dayIdentifier
                && ($0.timeScopeIdentifier != nil || $0.timeScopeToken != nil)
        }
    }

    private func load(
        dayIdentifier: String?,
        timeScopeIdentifier: String? = nil,
        timeScopeToken: String? = nil
    ) -> GitTodayActivityTrustedSnapshot? {
        let dayCandidates = decodedCandidates()
            .filter { dayIdentifier == nil || $0.dayIdentifier == dayIdentifier }
        let scopedCandidates: [GitTodayActivityTrustedSnapshot]
        if let timeScopeIdentifier {
            let environmentScopedCandidates = dayCandidates.filter {
                $0.timeScopeIdentifier != nil
            }
            let exactMatches = dayCandidates.filter {
                $0.timeScopeIdentifier == timeScopeIdentifier
            }
            scopedCandidates = environmentScopedCandidates.isEmpty
                ? dayCandidates.filter { $0.timeScopeIdentifier == nil }
                : exactMatches
        } else {
            scopedCandidates = dayCandidates
        }
        let tokenCandidates: [GitTodayActivityTrustedSnapshot]
        if timeScopeIdentifier != nil {
            let tokenScopedCandidates = scopedCandidates.filter {
                $0.timeScopeToken != nil
            }
            let exactTokenMatches = scopedCandidates.filter {
                $0.timeScopeToken == timeScopeToken && $0.timeScopeToken != nil
            }
            tokenCandidates = tokenScopedCandidates.isEmpty
                ? scopedCandidates.filter { $0.timeScopeToken == nil }
                : exactTokenMatches
        } else {
            tokenCandidates = scopedCandidates
        }
        return tokenCandidates.max { lhs, rhs in lhs.revision < rhs.revision }
    }

    private func decodedCandidates() -> [GitTodayActivityTrustedSnapshot] {
        userDefaults.synchronize()
        fallbackDefaults?.synchronize()

        return [
            userDefaults.string(forKey: Key.snapshot),
            sharedPreferencesProvider()?[Key.snapshot] as? String,
            fallbackDefaults?.string(forKey: Key.snapshot)
        ].compactMap { value in value.flatMap(Self.decode) }
    }

    @discardableResult
    public func save(_ snapshot: GitTodayActivityTrustedSnapshot) -> Bool {
        guard TinyBuddyTimeContext.isValidDayIdentifier(snapshot.dayIdentifier) else {
            return false
        }
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
        var fields = [
            String(snapshot.revision),
            snapshot.dayIdentifier
        ]
        if let timeScopeIdentifier = snapshot.timeScopeIdentifier,
           !timeScopeIdentifier.isEmpty {
            fields.append(timeScopeIdentifier)
            if let timeScopeToken = snapshot.timeScopeToken,
               !timeScopeToken.isEmpty {
                fields.append(timeScopeToken)
            }
        }
        fields.append(contentsOf: [
            String(max(0, snapshot.activity.focusBlockCount ?? 0)),
            String(max(0, snapshot.activity.commitCount ?? 0)),
            encodedProjectName
        ])
        return fields.joined(separator: "\t")
    }

    public static func decode(_ value: String) -> GitTodayActivityTrustedSnapshot? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5 || fields.count == 6 || fields.count == 7,
              let revision = Int64(fields[0]),
              revision >= 0,
              TinyBuddyTimeContext.isValidDayIdentifier(String(fields[1])) else {
            return nil
        }

        let hasTimeScope = fields.count >= 6
        let hasTimeScopeToken = fields.count == 7
        let timeScopeIdentifier = hasTimeScope ? String(fields[2]) : nil
        let timeScopeToken = hasTimeScopeToken ? String(fields[3]) : nil
        let focusIndex = hasTimeScopeToken ? 4 : (hasTimeScope ? 3 : 2)
        let commitIndex = hasTimeScopeToken ? 5 : (hasTimeScope ? 4 : 3)
        let projectIndex = hasTimeScopeToken ? 6 : (hasTimeScope ? 5 : 4)
        guard timeScopeIdentifier?.isEmpty != true,
              timeScopeToken?.isEmpty != true,
              let focusBlockCount = Int(fields[focusIndex]),
              focusBlockCount >= 0,
              let commitCount = Int(fields[commitIndex]),
              commitCount >= 0,
              let projectData = Data(base64Encoded: String(fields[projectIndex])),
              let projectName = String(data: projectData, encoding: .utf8) else {
            return nil
        }

        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitTodayActivityTrustedSnapshot(
            revision: revision,
            dayIdentifier: String(fields[1]),
            timeScopeIdentifier: timeScopeIdentifier,
            timeScopeToken: timeScopeToken,
            activity: GitTodayActivitySnapshot(
                focusBlockCount: focusBlockCount,
                commitCount: commitCount,
                recentProjectName: normalizedProjectName.isEmpty ? nil : normalizedProjectName
            )
        )
    }
}
