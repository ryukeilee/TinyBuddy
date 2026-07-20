import Foundation

/// Stable, non-sensitive reasons for rejecting a release snapshot export.
public enum TinyBuddyReleaseSnapshotVerificationFailure: String, Equatable, Sendable {
    case invalidExpectedDay
    case schemaInvalid
    case committedRevisionInvalid
    case committedSnapshotMissing
    case legacyMirrorMismatch
}

/// A release-safe description of a committed shared snapshot. It deliberately
/// omits repository names, paths, and the activity snapshot's project name.
public struct TinyBuddyReleaseSnapshotVerificationResult: Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int64
    public let dayIdentifier: String
    public let status: String
    public let focusCount: Int
    public let completionCount: Int
    public let activityFocusBlockCount: Int?
    public let activityCommitCount: Int?
    public let activityRevision: Int64?

    public init(
        schemaVersion: Int,
        revision: Int64,
        dayIdentifier: String,
        status: String,
        focusCount: Int,
        completionCount: Int,
        activityFocusBlockCount: Int?,
        activityCommitCount: Int?,
        activityRevision: Int64?
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.dayIdentifier = dayIdentifier
        self.status = status
        self.focusCount = focusCount
        self.completionCount = completionCount
        self.activityFocusBlockCount = activityFocusBlockCount
        self.activityCommitCount = activityCommitCount
        self.activityRevision = activityRevision
    }
}

public enum TinyBuddyReleaseSnapshotVerificationOutcome: Equatable, Sendable {
    case valid(TinyBuddyReleaseSnapshotVerificationResult)
    case invalid(TinyBuddyReleaseSnapshotVerificationFailure)
}

/// Validates a preferences plist without loading, repairing, or writing shared
/// state. This is intentionally stricter than runtime recovery: a release
/// artifact must carry the current schema, a valid commit marker, and a V3
/// (or V2) slot that precisely represents that committed snapshot.
public enum TinyBuddyReleaseSnapshotVerifier {
    public static func verify(
        plist: [String: Any],
        expectedDayIdentifier: String
    ) -> TinyBuddyReleaseSnapshotVerificationOutcome {
        guard TinyBuddyTimeContext.isValidDayIdentifier(expectedDayIdentifier) else {
            return .invalid(.invalidExpectedDay)
        }

        guard let schemaMarker = plist[TinyBuddyCombinedSnapshotStore.Key.schemaVersion] as? String,
              TinyBuddyCombinedSnapshotStore.decodeSchemaVersion(schemaMarker)
                == TinyBuddyCombinedSnapshotStore.currentSchemaVersion else {
            return .invalid(.schemaInvalid)
        }

        guard let committedMarker = plist[
            TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
        ] as? String,
        let committedRevision = TinyBuddyCombinedSnapshotStore.decodeRevisionMarker(
            committedMarker
        ) else {
            return .invalid(.committedRevisionInvalid)
        }

        let decodeFormats: [(String) -> TinyBuddyCombinedSnapshot?] = [
            TinyBuddyCombinedSnapshotStore.decodeV3,
            TinyBuddyCombinedSnapshotStore.decodeV2
        ]

        let committedSnapshot = [
            plist[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA] as? String,
            plist[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB] as? String
        ]
        .compactMap { $0 }
        .compactMap { value in
            decodeFormats.lazy.compactMap { $0(value) }.first
        }
        .first {
            $0.revision == committedRevision && $0.dayIdentifier == expectedDayIdentifier
        }

        guard let committedSnapshot else {
            return .invalid(.committedSnapshotMissing)
        }

        if let legacyValue = plist[TinyBuddyCombinedSnapshotStore.Key.snapshot] {
            guard let legacyValue = legacyValue as? String,
                  let legacySnapshot = TinyBuddyCombinedSnapshotStore.decode(legacyValue),
                  legacySnapshot == committedSnapshot else {
                return .invalid(.legacyMirrorMismatch)
            }
        }

        return .valid(TinyBuddyReleaseSnapshotVerificationResult(
            schemaVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            revision: committedSnapshot.revision,
            dayIdentifier: committedSnapshot.dayIdentifier,
            status: committedSnapshot.snapshot.status.rawValue,
            focusCount: committedSnapshot.snapshot.stats.focusCount,
            completionCount: committedSnapshot.snapshot.stats.completionCount,
            activityFocusBlockCount: committedSnapshot.activitySnapshot.focusBlockCount,
            activityCommitCount: committedSnapshot.activitySnapshot.commitCount,
            activityRevision: committedSnapshot.activityRevision
        ))
    }
}
