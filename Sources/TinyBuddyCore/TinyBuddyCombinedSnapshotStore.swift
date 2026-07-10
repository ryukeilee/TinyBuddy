import Foundation

public struct TinyBuddyCombinedSnapshot: Equatable, Sendable {
    public let revision: Int64
    public let dayIdentifier: String
    public let snapshot: TinyBuddySnapshot
    public let activitySnapshot: GitTodayActivitySnapshot
    public let activityRevision: Int64?

    public init(
        revision: Int64,
        dayIdentifier: String,
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot,
        activityRevision: Int64? = nil
    ) {
        self.revision = revision
        self.dayIdentifier = dayIdentifier
        self.snapshot = snapshot
        self.activitySnapshot = activitySnapshot
        self.activityRevision = activityRevision
    }
}

public final class TinyBuddyCombinedSnapshotStore {
    public enum UpdateOutcome: Equatable, Sendable {
        case saved
        case rejectedStaleActivity
        case rejectedInvalidActivityRevision
        case revisionExhausted
    }

    public struct UpdateResult: Equatable, Sendable {
        public let snapshot: TinyBuddyCombinedSnapshot?
        public let outcome: UpdateOutcome
        public let didPersist: Bool

        public init(snapshot: TinyBuddyCombinedSnapshot?, outcome: UpdateOutcome, didPersist: Bool) {
            self.snapshot = snapshot
            self.outcome = outcome
            self.didPersist = didPersist
        }
    }

    public enum Key {
        public static let snapshot = "tinybuddy.combinedSnapshot"
        public static let highestRevision = "tinybuddy.combinedSnapshot.highestRevision"
    }

    private let userDefaults: UserDefaults
    private let sharedPreferencesProvider: () -> [String: Any]?
    private let fallbackDefaults: UserDefaults?
    // WidgetKit only reads this store. The app process is the sole writer: HUD state
    // owns the pet slice and GitActivityRefreshCoordinator owns the activity slice.
    private static let writerLock = NSLock()

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

    public func load() -> TinyBuddyCombinedSnapshot? {
        userDefaults.synchronize()
        fallbackDefaults?.synchronize()

        // Preserve source order for equal revisions: direct defaults, cached plist,
        // then explicit fallback. This makes migration ties deterministic.
        return snapshotCandidates().reduce(nil) { current, candidate in
            guard let current else {
                return candidate
            }
            return candidate.revision > current.revision ? candidate : current
        }
    }

    @discardableResult
    public func updatePetSlice(
        _ snapshot: TinyBuddySnapshot,
        fallbackActivitySnapshot: GitTodayActivitySnapshot?,
        fallbackActivityRevision: Int64? = nil
    ) -> UpdateResult {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }

        let current = load()
        guard fallbackActivityRevision.map({ $0 >= 0 }) ?? true else {
            return UpdateResult(
                snapshot: current,
                outcome: .rejectedInvalidActivityRevision,
                didPersist: false
            )
        }
        let currentPayload = current?.dayIdentifier == snapshot.stats.dayIdentifier ? current : nil
        let useFallbackActivity = fallbackActivitySnapshot != nil && shouldAcceptIncomingActivity(
            currentActivity: currentPayload?.activitySnapshot,
            currentRevision: currentPayload?.activityRevision,
            incomingActivity: fallbackActivitySnapshot,
            incomingRevision: fallbackActivityRevision
        )
        return saveLocked(
            snapshot: snapshot,
            activitySnapshot: useFallbackActivity
                ? fallbackActivitySnapshot
                : currentPayload?.activitySnapshot ?? fallbackActivitySnapshot,
            activityRevision: useFallbackActivity
                ? fallbackActivityRevision
                : currentPayload?.activityRevision,
            highestRevision: highestKnownRevision(current: current),
            current: current
        )
    }

    @discardableResult
    public func updateActivitySlice(
        _ activitySnapshot: GitTodayActivitySnapshot,
        activityRevision: Int64? = nil,
        fallbackSnapshot: TinyBuddySnapshot
    ) -> UpdateResult {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }

        let current = load()
        guard activityRevision.map({ $0 >= 0 }) ?? true else {
            return UpdateResult(
                snapshot: current,
                outcome: .rejectedInvalidActivityRevision,
                didPersist: false
            )
        }
        let currentPayload = current?.dayIdentifier == fallbackSnapshot.stats.dayIdentifier ? current : nil
        guard shouldAcceptIncomingActivity(
            currentActivity: currentPayload?.activitySnapshot,
            currentRevision: currentPayload?.activityRevision,
            incomingActivity: activitySnapshot,
            incomingRevision: activityRevision
        ) else {
            return UpdateResult(
                snapshot: currentPayload ?? current,
                outcome: .rejectedStaleActivity,
                didPersist: false
            )
        }
        return saveLocked(
            snapshot: currentPayload?.snapshot ?? fallbackSnapshot,
            activitySnapshot: activitySnapshot,
            activityRevision: activityRevision,
            highestRevision: highestKnownRevision(current: current),
            current: current
        )
    }

    public static func encode(_ snapshot: TinyBuddyCombinedSnapshot) -> String {
        let projectName = snapshot.activitySnapshot.recentProjectName ?? ""
        return [
            String(snapshot.revision),
            snapshot.dayIdentifier,
            snapshot.snapshot.status.rawValue,
            snapshot.snapshot.stats.dayIdentifier,
            String(max(0, snapshot.snapshot.stats.focusCount)),
            String(max(0, snapshot.snapshot.stats.completionCount)),
            snapshot.activitySnapshot.focusBlockCount.map { String(max(0, $0)) } ?? "",
            snapshot.activitySnapshot.commitCount.map { String(max(0, $0)) } ?? "",
            Data(projectName.utf8).base64EncodedString(),
            snapshot.activityRevision.map(String.init) ?? ""
        ].joined(separator: "\t")
    }

    public static func decode(_ value: String) -> TinyBuddyCombinedSnapshot? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard (fields.count == 9 || fields.count == 10),
              let revision = Int64(fields[0]), revision >= 0,
              !fields[1].isEmpty,
              let status = PetStatus(rawValue: String(fields[2])),
              fields[1] == fields[3],
              let focusCount = Int(fields[4]), focusCount >= 0,
              let completionCount = Int(fields[5]), completionCount >= 0,
              let activityFocusCount = optionalNonnegativeInteger(from: fields[6]),
              let activityCommitCount = optionalNonnegativeInteger(from: fields[7]),
              let projectData = Data(base64Encoded: String(fields[8])),
              let projectName = String(data: projectData, encoding: .utf8) else {
            return nil
        }
        let activityRevision = fields.count == 10
            ? optionalNonnegativeRevision(from: fields[9])
            : .some(nil)
        guard let activityRevision else {
            return nil
        }

        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: String(fields[1]),
            snapshot: TinyBuddySnapshot(
                status: status,
                stats: DailyStats(
                    dayIdentifier: String(fields[3]),
                    focusCount: focusCount,
                    completionCount: completionCount
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: activityFocusCount,
                commitCount: activityCommitCount,
                recentProjectName: normalizedProjectName.isEmpty ? nil : normalizedProjectName
            ),
            activityRevision: activityRevision
        )
    }

    private func snapshotCandidates() -> [TinyBuddyCombinedSnapshot] {
        [
            userDefaults.string(forKey: Key.snapshot),
            sharedPreferencesProvider()?[Key.snapshot] as? String,
            fallbackDefaults?.string(forKey: Key.snapshot)
        ]
        .compactMap { $0.flatMap(Self.decode) }
    }

    private static func optionalNonnegativeInteger(from value: Substring) -> Int?? {
        guard !value.isEmpty else { return .some(nil) }
        guard let integer = Int(value), integer >= 0 else { return nil }
        return .some(integer)
    }

    private static func optionalNonnegativeRevision(from value: Substring) -> Int64?? {
        guard !value.isEmpty else { return .some(nil) }
        guard let revision = Int64(value), revision >= 0 else { return nil }
        return .some(revision)
    }

    private func highestKnownRevision(current: TinyBuddyCombinedSnapshot?) -> Int64 {
        let counters: Int64 = [
            userDefaults.object(forKey: Key.highestRevision) as? NSNumber,
            sharedPreferencesProvider()?[Key.highestRevision] as? NSNumber,
            fallbackDefaults?.object(forKey: Key.highestRevision) as? NSNumber
        ]
            .compactMap { candidate -> Int64? in
                guard let candidate, candidate.int64Value >= 0 else {
                    return nil
                }
                return candidate.int64Value
            }
            .max() ?? 0
        return max(current?.revision ?? 0, counters)
    }

    private func shouldAcceptIncomingActivity(
        currentActivity: GitTodayActivitySnapshot?,
        currentRevision: Int64?,
        incomingActivity: GitTodayActivitySnapshot?,
        incomingRevision: Int64?
    ) -> Bool {
        if let currentRevision {
            return incomingRevision.map { $0 > currentRevision } ?? false
        }

        if hasActivityData(currentActivity) {
            return incomingRevision != nil || hasActivityData(incomingActivity)
        }

        return incomingActivity != nil
    }

    private func hasActivityData(_ activity: GitTodayActivitySnapshot?) -> Bool {
        guard let activity else {
            return false
        }
        return activity.focusBlockCount != nil
            || activity.commitCount != nil
            || activity.recentProjectName?.isEmpty == false
    }

    private func saveLocked(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot?,
        activityRevision: Int64?,
        highestRevision: Int64,
        current: TinyBuddyCombinedSnapshot?
    ) -> UpdateResult {
        guard highestRevision < Int64.max else {
            return UpdateResult(
                snapshot: current,
                outcome: .revisionExhausted,
                didPersist: false
            )
        }
        let combinedSnapshot = TinyBuddyCombinedSnapshot(
            revision: highestRevision + 1,
            dayIdentifier: snapshot.stats.dayIdentifier,
            snapshot: snapshot,
            activitySnapshot: activitySnapshot ?? GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            activityRevision: activityRevision
        )
        userDefaults.set(Self.encode(combinedSnapshot), forKey: Key.snapshot)
        userDefaults.set(combinedSnapshot.revision, forKey: Key.highestRevision)
        userDefaults.synchronize()
        return UpdateResult(snapshot: combinedSnapshot, outcome: .saved, didPersist: true)
    }
}
