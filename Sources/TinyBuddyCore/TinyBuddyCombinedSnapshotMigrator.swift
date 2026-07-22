import Foundation

// MARK: - Migration Result

/// Outcome of a single migration operation.
public struct TinyBuddyCombinedSnapshotMigrationResult: Equatable, Sendable {
    /// Detected source schema version.
    public let fromVersion: Int
    /// Target schema version (always current).
    public let toVersion: Int
    /// The fully decoded snapshot, regardless of whether migration was needed.
    public let snapshot: TinyBuddyCombinedSnapshot?
    /// The V3-encoded envelope string, nil if encoding failed.
    public let v3EncodedValue: String?
    /// Whether an actual format conversion was performed.
    public let didPerformMigration: Bool
    /// Stable diagnostic key for telemetry aggregation.
    public let diagnosticKey: String

    public init(
        fromVersion: Int,
        toVersion: Int,
        snapshot: TinyBuddyCombinedSnapshot?,
        v3EncodedValue: String?,
        didPerformMigration: Bool,
        diagnosticKey: String
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.snapshot = snapshot
        self.v3EncodedValue = v3EncodedValue
        self.didPerformMigration = didPerformMigration
        self.diagnosticKey = diagnosticKey
    }
}

// MARK: - Migrator

/// Encapsulates version-to-version migration of the combined snapshot in
/// isolation from the store's write logic. Every migration step is idempotent
/// and independently testable: given the same input, the same output is produced.
///
/// Supported migrations:
/// - V1 (legacy tab-separated text) → V3 (binary plist envelope)
/// - V2 (checksummed tab-separated envelope) → V3
/// - V3 → V3 (no-op, returns decoded + re-encoded)
public enum TinyBuddyCombinedSnapshotMigrator {

    /// Detects the schema version of a raw encoded snapshot string.
    /// Uses the public decode methods to determine the format:
    /// - V3 if `decodeV3` succeeds
    /// - V2 if `decodeV2` succeeds (but V3 fails)
    /// - V1 if `decode` succeeds (but V2/V3 fail)
    /// - Returns nil for unrecognized or empty input.
    public static func detectVersion(of rawValue: String) -> Int? {
        guard !rawValue.isEmpty else { return nil }

        if TinyBuddyCombinedSnapshotStore.decodeV3(rawValue) != nil {
            return 3
        }
        if TinyBuddyCombinedSnapshotStore.decodeV2(rawValue) != nil {
            return 2
        }
        if TinyBuddyCombinedSnapshotStore.decode(rawValue) != nil {
            return 1
        }
        return nil
    }

    /// Migrates a raw encoded value from any supported version to V3.
    /// - Parameter rawValue: Encoded snapshot in V1, V2, or V3 format.
    /// - Returns: A migration result, or nil if the format is unrecognized.
    public static func migrateToV3(_ rawValue: String) -> TinyBuddyCombinedSnapshotMigrationResult? {
        guard let version = detectVersion(of: rawValue) else {
            return nil
        }
        switch version {
        case 1:
            return migrateV1ToV3(rawValue)
        case 2:
            return migrateV2ToV3(rawValue)
        case 3:
            return reencodeV3(rawValue)
        default:
            return nil
        }
    }

    /// Migrates a V1 legacy tab-separated value to V3.
    /// Verifies round-trip integrity: the decoded snapshot must re-encode to
    /// a V3 value that decodes to the identical snapshot.
    public static func migrateV1ToV3(_ v1Value: String) -> TinyBuddyCombinedSnapshotMigrationResult? {
        guard let decoded = TinyBuddyCombinedSnapshotStore.decode(v1Value) else {
            return nil
        }
        guard let encodedV3 = TinyBuddyCombinedSnapshotStore.encodeV3(decoded) else {
            return TinyBuddyCombinedSnapshotMigrationResult(
                fromVersion: 1,
                toVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
                snapshot: decoded,
                v3EncodedValue: nil,
                didPerformMigration: false,
                diagnosticKey: "migrator.v1_encode_failed"
            )
        }
        // Verify round-trip integrity
        guard TinyBuddyCombinedSnapshotStore.decodeV3(encodedV3) == decoded else {
            return TinyBuddyCombinedSnapshotMigrationResult(
                fromVersion: 1,
                toVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
                snapshot: decoded,
                v3EncodedValue: nil,
                didPerformMigration: false,
                diagnosticKey: "migrator.v1_roundtrip_failed"
            )
        }
        return TinyBuddyCombinedSnapshotMigrationResult(
            fromVersion: 1,
            toVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            snapshot: decoded,
            v3EncodedValue: encodedV3,
            didPerformMigration: true,
            diagnosticKey: "migrator.v1_to_v3"
        )
    }

    /// Migrates a V2 checksummed envelope to V3.
    /// Verifies round-trip integrity like V1 migration.
    public static func migrateV2ToV3(_ v2Value: String) -> TinyBuddyCombinedSnapshotMigrationResult? {
        guard let decoded = TinyBuddyCombinedSnapshotStore.decodeV2(v2Value) else {
            return nil
        }
        guard let encodedV3 = TinyBuddyCombinedSnapshotStore.encodeV3(decoded) else {
            return TinyBuddyCombinedSnapshotMigrationResult(
                fromVersion: 2,
                toVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
                snapshot: decoded,
                v3EncodedValue: nil,
                didPerformMigration: false,
                diagnosticKey: "migrator.v2_encode_failed"
            )
        }
        // Verify round-trip integrity
        guard TinyBuddyCombinedSnapshotStore.decodeV3(encodedV3) == decoded else {
            return TinyBuddyCombinedSnapshotMigrationResult(
                fromVersion: 2,
                toVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
                snapshot: decoded,
                v3EncodedValue: nil,
                didPerformMigration: false,
                diagnosticKey: "migrator.v2_roundtrip_failed"
            )
        }
        return TinyBuddyCombinedSnapshotMigrationResult(
            fromVersion: 2,
            toVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            snapshot: decoded,
            v3EncodedValue: encodedV3,
            didPerformMigration: true,
            diagnosticKey: "migrator.v2_to_v3"
        )
    }

    /// Re-encodes an already V3 value. Returns the same decoded snapshot
    /// with didPerformMigration = false.
    public static func reencodeV3(_ v3Value: String) -> TinyBuddyCombinedSnapshotMigrationResult? {
        guard let decoded = TinyBuddyCombinedSnapshotStore.decodeV3(v3Value) else {
            return nil
        }
        let reencoded = TinyBuddyCombinedSnapshotStore.encodeV3(decoded)
        return TinyBuddyCombinedSnapshotMigrationResult(
            fromVersion: 3,
            toVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            snapshot: decoded,
            v3EncodedValue: reencoded,
            didPerformMigration: false,
            diagnosticKey: "migrator.v3_noop"
        )
    }
}

// MARK: - Store Integration Helper

extension TinyBuddyCombinedSnapshotStore {

    /// Attempts to decode and/or migrate a raw preference value to the current
    /// schema. This is a pure function suitable for use in both App and Widget
    /// processes.
    ///
    /// - Parameter rawValue: An encoded snapshot string from any supported
    ///   format (V1, V2, V3), or nil/empty.
    /// - Returns: A tuple with the decoded snapshot and its V3 encoding.
    ///   Both are nil when the input is empty or unrecognized. A non-nil
    ///   snapshot with a nil v3Encoded means the data decoded but the V3
    ///   encoding was not produced (corner case for V2 display-only fallback).
    public static func sanitizeToCurrentSchema(
        _ rawValue: String?
    ) -> (snapshot: TinyBuddyCombinedSnapshot?, v3Encoded: String?) {
        guard let rawValue, !rawValue.isEmpty else {
            return (nil, nil)
        }

        // If already V3, return directly (most common path).
        if let snapshot = decodeV3(rawValue) {
            return (snapshot, rawValue)
        }

        // Attempt migration.
        if let result = TinyBuddyCombinedSnapshotMigrator.migrateToV3(rawValue) {
            return (result.snapshot, result.v3EncodedValue)
        }

        // Last resort: V2-only decode as display-only fallback.
        if let snapshot = decodeV2(rawValue) {
            return (snapshot, nil)
        }

        return (nil, nil)
    }
}
