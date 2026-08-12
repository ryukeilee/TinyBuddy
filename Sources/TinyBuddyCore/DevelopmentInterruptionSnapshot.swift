import Foundation

/// A path-free summary of the last repository state that TinyBuddy could
/// validate during a successful Git refresh. The scanner keeps repository
/// paths private and persists only the stable fingerprint and display data.
public struct DevelopmentInterruptionSnapshot: Equatable, Sendable {
    public struct WorkingTreeSummary: Equatable, Sendable {
        public let stagedCount: Int
        public let modifiedCount: Int
        public let untrackedCount: Int
        public let conflictedCount: Int

        public init(
            stagedCount: Int,
            modifiedCount: Int,
            untrackedCount: Int,
            conflictedCount: Int
        ) {
            self.stagedCount = stagedCount
            self.modifiedCount = modifiedCount
            self.untrackedCount = untrackedCount
            self.conflictedCount = conflictedCount
        }

        public var totalCount: Int {
            stagedCount + modifiedCount + untrackedCount + conflictedCount
        }

        public var isClean: Bool { totalCount == 0 }
    }

    public struct RecentCommit: Equatable, Sendable {
        public let abbreviatedHash: String
        public let subject: String
        public let committedAt: Date

        public init(abbreviatedHash: String, subject: String, committedAt: Date) {
            self.abbreviatedHash = abbreviatedHash
            self.subject = subject
            self.committedAt = committedAt
        }
    }

    public let repositoryFingerprint: String
    public let repositoryName: String
    public let branchName: String
    public let workingTree: WorkingTreeSummary
    public let recentCommit: RecentCommit?
    public let lastActivityAt: Date
    public let capturedAt: Date

    public init(
        repositoryFingerprint: String,
        repositoryName: String,
        branchName: String,
        workingTree: WorkingTreeSummary,
        recentCommit: RecentCommit?,
        lastActivityAt: Date,
        capturedAt: Date
    ) {
        self.repositoryFingerprint = repositoryFingerprint
        self.repositoryName = repositoryName
        self.branchName = branchName
        self.workingTree = workingTree
        self.recentCommit = recentCommit
        self.lastActivityAt = lastActivityAt
        self.capturedAt = capturedAt
    }
}

public final class DevelopmentInterruptionSnapshotStore {
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    public static let allowedFutureSkew: TimeInterval = 5 * 60

    public enum Key {
        public static let snapshot = "tinybuddy.developmentInterruption.snapshot.v1"
    }

    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()) {
        defaults = userDefaults
    }

    public func load(
        at now: Date = Date(),
        maximumAge: TimeInterval = DevelopmentInterruptionSnapshotStore.maximumAge
    ) -> DevelopmentInterruptionSnapshot? {
        defaults.synchronize()
        guard let rawValue = defaults.string(forKey: Key.snapshot),
              let snapshot = Self.decode(rawValue),
              snapshot.lastActivityAt.timeIntervalSince(now) <= Self.allowedFutureSkew,
              now.timeIntervalSince(snapshot.lastActivityAt) <= max(0, maximumAge) else {
            return nil
        }
        return snapshot
    }

    /// Main-app maintenance path. Widget and other readers remain read-only.
    @discardableResult
    public func clearIfExpired(
        at now: Date = Date(),
        maximumAge: TimeInterval = DevelopmentInterruptionSnapshotStore.maximumAge
    ) -> Bool {
        defaults.synchronize()
        guard defaults.object(forKey: Key.snapshot) != nil,
              load(at: now, maximumAge: maximumAge) == nil else {
            return false
        }
        defaults.removeObject(forKey: Key.snapshot)
        return defaults.synchronize()
    }

    public static func decode(_ rawValue: String) -> DevelopmentInterruptionSnapshot? {
        let fields = rawValue.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 13,
              fields[0] == "v1",
              let fingerprint = decodeText(fields[1], maximumLength: 512),
              let repositoryName = decodeText(fields[2], maximumLength: 256),
              let branchName = decodeText(fields[3], maximumLength: 512),
              let stagedCount = boundedCount(fields[4]),
              let modifiedCount = boundedCount(fields[5]),
              let untrackedCount = boundedCount(fields[6]),
              let conflictedCount = boundedCount(fields[7]),
              let commitHash = decodeText(fields[8], maximumLength: 128, allowsEmpty: true),
              let commitSubject = decodeText(fields[9], maximumLength: 1_024, allowsEmpty: true),
              let commitEpoch = TimeInterval(fields[10]),
              let activityEpoch = TimeInterval(fields[11]),
              let capturedEpoch = TimeInterval(fields[12]),
              activityEpoch.isFinite,
              capturedEpoch.isFinite,
              activityEpoch > 0,
              capturedEpoch >= activityEpoch else {
            return nil
        }

        let recentCommit: DevelopmentInterruptionSnapshot.RecentCommit?
        if commitHash.isEmpty && commitSubject.isEmpty && commitEpoch == 0 {
            recentCommit = nil
        } else {
            guard !commitHash.isEmpty,
                  !commitSubject.isEmpty,
                  commitEpoch.isFinite,
                  commitEpoch > 0,
                  commitEpoch <= capturedEpoch + allowedFutureSkew else {
                return nil
            }
            recentCommit = .init(
                abbreviatedHash: commitHash,
                subject: commitSubject,
                committedAt: Date(timeIntervalSince1970: commitEpoch)
            )
        }

        return DevelopmentInterruptionSnapshot(
            repositoryFingerprint: fingerprint,
            repositoryName: repositoryName,
            branchName: branchName,
            workingTree: .init(
                stagedCount: stagedCount,
                modifiedCount: modifiedCount,
                untrackedCount: untrackedCount,
                conflictedCount: conflictedCount
            ),
            recentCommit: recentCommit,
            lastActivityAt: Date(timeIntervalSince1970: activityEpoch),
            capturedAt: Date(timeIntervalSince1970: capturedEpoch)
        )
    }

    private static func decodeText(
        _ field: Substring,
        maximumLength: Int,
        allowsEmpty: Bool = false
    ) -> String? {
        guard let data = Data(base64Encoded: String(field)),
              data.count <= maximumLength * 4,
              let value = String(data: data, encoding: .utf8),
              value.count <= maximumLength,
              !value.contains("\0"),
              allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func boundedCount(_ field: Substring) -> Int? {
        guard let value = Int(field), (0...1_000_000).contains(value) else { return nil }
        return value
    }
}

public struct DevelopmentInterruptionPresentation: Equatable, Sendable {
    public let repositoryName: String
    public let branchName: String
    public let workingTreeText: String
    public let recentCommitText: String?
    public let awayDurationText: String

    public init(snapshot: DevelopmentInterruptionSnapshot, now: Date = Date()) {
        repositoryName = snapshot.repositoryName
        branchName = snapshot.branchName
        workingTreeText = Self.workingTreeText(snapshot.workingTree)
        recentCommitText = snapshot.recentCommit.map {
            "\($0.abbreviatedHash) · \($0.subject)"
        }
        awayDurationText = Self.awayDurationText(
            max(0, now.timeIntervalSince(snapshot.lastActivityAt))
        )
    }

    private static func workingTreeText(
        _ summary: DevelopmentInterruptionSnapshot.WorkingTreeSummary
    ) -> String {
        guard !summary.isClean else { return "工作区干净" }
        var parts: [String] = []
        if summary.conflictedCount > 0 { parts.append("冲突 \(summary.conflictedCount)") }
        if summary.stagedCount > 0 { parts.append("已暂存 \(summary.stagedCount)") }
        if summary.modifiedCount > 0 { parts.append("已修改 \(summary.modifiedCount)") }
        if summary.untrackedCount > 0 { parts.append("未跟踪 \(summary.untrackedCount)") }
        return parts.joined(separator: " · ")
    }

    private static func awayDurationText(_ duration: TimeInterval) -> String {
        let minutes = Int(duration / 60)
        if minutes < 1 { return "刚刚离开" }
        if minutes < 60 { return "离开 \(minutes) 分钟" }
        let hours = minutes / 60
        if hours < 24 { return "离开 \(hours) 小时 \(minutes % 60) 分钟" }
        let days = hours / 24
        return "离开 \(days) 天 \(hours % 24) 小时"
    }
}
