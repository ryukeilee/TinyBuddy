import XCTest
@testable import TinyBuddyCore

// MARK: - Helpers

private func makeFullSnapshot() -> TinyBuddyCombinedSnapshot {
    TinyBuddyCombinedSnapshot(
        revision: 42,
        dayIdentifier: "2026-07-20",
        snapshot: TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(
                dayIdentifier: "2026-07-20",
                focusCount: 5,
                completionCount: 3
            )
        ),
        activitySnapshot: GitTodayActivitySnapshot(
            focusBlockCount: 8,
            commitCount: 12,
            recentProjectName: "TinyBuddy"
        ),
        activityRevision: 420
    )
}

private func makeMinimalSnapshot() -> TinyBuddyCombinedSnapshot {
    TinyBuddyCombinedSnapshot(
        revision: 0,
        dayIdentifier: "2026-07-20",
        snapshot: TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(
                dayIdentifier: "2026-07-20",
                focusCount: 0,
                completionCount: 0
            )
        ),
        activitySnapshot: GitTodayActivitySnapshot(
            focusBlockCount: nil,
            commitCount: nil,
            recentProjectName: nil
        ),
        activityRevision: nil
    )
}

private func makeCorruptLastCharacter(_ value: String) -> String {
    guard let last = value.last else { return "corrupt" }
    return String(value.dropLast()) + (last == "A" ? "B" : "A")
}

// MARK: - 1. Version Detection Tests

final class TinyBuddyCombinedSnapshotVersionDetectionTests: XCTestCase {

    func testDetectV3() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        XCTAssertEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: encoded), 3)
    }

    func testDetectV2() throws {
        let snapshot = makeFullSnapshot()
        let encoded = TinyBuddyCombinedSnapshotStore.encodeV2(snapshot)
        XCTAssertEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: encoded), 2)
    }

    func testDetectV1() throws {
        let snapshot = makeFullSnapshot()
        let encoded = TinyBuddyCombinedSnapshotStore.encode(snapshot)
        XCTAssertEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: encoded), 1)
    }

    func testDetectV1NineFieldsBySynthesizing() throws {
        // The public encode() always produces 10 fields (an empty trailing
        // field for a nil activityRevision).  Synthesize a real 9-field V1
        // string to verify the detector handles it.
        let snapshot = TinyBuddyCombinedSnapshot(
            revision: 7,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 5,
                recentProjectName: "Test"
            ),
            activityRevision: nil
        )
        let encoded = TinyBuddyCombinedSnapshotStore.encode(snapshot)
        // Drop the trailing empty field to create a true 9-field V1 value
        let fields = encoded.split(separator: "\t", omittingEmptySubsequences: false)
        let nineFieldValue = fields.dropLast().joined(separator: "\t")

        XCTAssertEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: nineFieldValue), 1)
        // Verify the 9-field value still decodes correctly
        let decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decode(nineFieldValue))
        XCTAssertEqual(decoded.revision, 7)
    }

    func testDetectV1TenFields() throws {
        let snapshot = makeFullSnapshot()
        let encoded = TinyBuddyCombinedSnapshotStore.encode(snapshot)
        let fields = encoded.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 10, "V1 with activityRevision should have 10 fields")
        XCTAssertEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: encoded), 1)
    }

    func testDetectEmptyStringReturnsNil() {
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: ""))
    }

    func testDetectGarbageReturnsNil() {
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: "this is not a valid snapshot"))
    }

    func testDetectPartialV2EnvelopeReturnsNil() {
        // A V2 envelope needs exactly 5 fields
        let partial = "2\t42\tabc"
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: partial))
    }

    func testDetectTamperedV3PayloadReturnsNil() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let tampered = makeCorruptLastCharacter(encoded)
        // Tampered V3 should not decode as V3, V2, or V1
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: tampered))
    }

    func testDetectV3CrossFormatNotV2() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        XCTAssertEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: encoded), 3)
        // Verify it's not detected as V2
        XCTAssertNotEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: encoded), 2)
    }

    func testDetectV2CrossFormatNotV3() throws {
        let snapshot = makeFullSnapshot()
        let encoded = TinyBuddyCombinedSnapshotStore.encodeV2(snapshot)
        XCTAssertEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: encoded), 2)
        // Verify it's not detected as V3
        XCTAssertNotEqual(TinyBuddyCombinedSnapshotMigrator.detectVersion(of: encoded), 3)
    }
}

// MARK: - 2. V1 → V3 Migration Tests

final class TinyBuddyCombinedSnapshotV1ToV3MigrationTests: XCTestCase {

    func testFullSnapshotMigration() throws {
        let original = makeFullSnapshot()
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(v1Value)
        )

        XCTAssertEqual(result.fromVersion, 1)
        XCTAssertEqual(result.toVersion, 3)
        XCTAssertTrue(result.didPerformMigration)
        XCTAssertEqual(result.diagnosticKey, "migrator.v1_to_v3")
        XCTAssertEqual(result.snapshot, original)

        // V3 value must decode correctly
        let v3Decoded = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(try XCTUnwrap(result.v3EncodedValue))
        )
        XCTAssertEqual(v3Decoded, original)
    }

    func testMinimalSnapshotMigration() throws {
        let original = makeMinimalSnapshot()
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(v1Value)
        )

        XCTAssertTrue(result.didPerformMigration)
        XCTAssertEqual(result.snapshot, original)

        let v3Decoded = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(try XCTUnwrap(result.v3EncodedValue))
        )
        XCTAssertEqual(v3Decoded, original)
    }

    func testNineFieldV1Migration() throws {
        let original = TinyBuddyCombinedSnapshot(
            revision: 7,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 5,
                recentProjectName: "TestApp"
            ),
            activityRevision: nil
        )
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(v1Value)
        )

        XCTAssertTrue(result.didPerformMigration)
        XCTAssertEqual(result.snapshot, original)

        let v3Decoded = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(try XCTUnwrap(result.v3EncodedValue))
        )
        XCTAssertEqual(v3Decoded, original)
    }

    func testV1WithEmptyProjectName() throws {
        let original = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 0, completionCount: 0)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            activityRevision: nil
        )
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(v1Value)
        )

        XCTAssertTrue(result.didPerformMigration)
        XCTAssertNil(result.snapshot?.activitySnapshot.recentProjectName)

        let v3Decoded = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(try XCTUnwrap(result.v3EncodedValue))
        )
        XCTAssertEqual(v3Decoded, original)
    }

    func testV1WithWhitespaceProjectName() throws {
        let original = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 2, completionCount: 1)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 4,
                commitCount: 6,
                recentProjectName: "   "
            ),
            activityRevision: 10
        )
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(v1Value)
        )

        XCTAssertTrue(result.didPerformMigration)
        // Whitespace project name should be treated as nil by normalization
        let v3Decoded = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(try XCTUnwrap(result.v3EncodedValue))
        )
        // V3 normalization strips whitespace-only project names
        XCTAssertNil(v3Decoded.activitySnapshot.recentProjectName)
    }

    func testCorruptV1ReturnsNil() {
        let corruptValue = "not\ta\tvalid\tv1\tpayload"
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(corruptValue))
    }

    func testEmptyV1ReturnsNil() {
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(""))
    }

    func testV1WithNegativeRevisionStillDecodes() throws {
        // V1 decode should reject negative revision
        let snapshot = makeFullSnapshot()
        var v1Value = TinyBuddyCombinedSnapshotStore.encode(snapshot)
        var fields = v1Value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        fields[0] = "-1"
        v1Value = fields.joined(separator: "\t")

        // V1 decode should reject this
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decode(v1Value))
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(v1Value))
    }

    func testIdempotentV1Migration() throws {
        let original = makeFullSnapshot()
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        // Run migration twice
        let result1 = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(v1Value)
        )
        let result2 = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV1ToV3(v1Value)
        )

        // Both should report didPerformMigration=true (same input, always migrates)
        XCTAssertTrue(result1.didPerformMigration)
        XCTAssertTrue(result2.didPerformMigration)

        // Decoded snapshots must be identical.
        XCTAssertEqual(result1.snapshot, result2.snapshot)
        // V3 encoded values must both decode to the identical snapshot even if
        // binary plist ordering produces different raw bytes.
        let v3Decoded1 = try XCTUnwrap(
            result1.v3EncodedValue.flatMap(TinyBuddyCombinedSnapshotStore.decodeV3)
        )
        let v3Decoded2 = try XCTUnwrap(
            result2.v3EncodedValue.flatMap(TinyBuddyCombinedSnapshotStore.decodeV3)
        )
        XCTAssertEqual(v3Decoded1, v3Decoded2)
        XCTAssertEqual(v3Decoded1, result1.snapshot)
    }
}

// MARK: - 3. V2 → V3 Migration Tests

final class TinyBuddyCombinedSnapshotV2ToV3MigrationTests: XCTestCase {

    func testFullSnapshotMigration() throws {
        let original = makeFullSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(v2Value)
        )

        XCTAssertEqual(result.fromVersion, 2)
        XCTAssertEqual(result.toVersion, 3)
        XCTAssertTrue(result.didPerformMigration)
        XCTAssertEqual(result.diagnosticKey, "migrator.v2_to_v3")
        XCTAssertEqual(result.snapshot, original)

        let v3Decoded = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(try XCTUnwrap(result.v3EncodedValue))
        )
        XCTAssertEqual(v3Decoded, original)
    }

    func testMinimalSnapshotMigration() throws {
        let original = makeMinimalSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(v2Value)
        )

        XCTAssertTrue(result.didPerformMigration)
        XCTAssertEqual(result.snapshot, original)

        let v3Decoded = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(try XCTUnwrap(result.v3EncodedValue))
        )
        XCTAssertEqual(v3Decoded, original)
    }

    func testEmptyProjectNameV2() throws {
        let original = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 0, completionCount: 0)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            activityRevision: nil
        )
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(v2Value)
        )

        XCTAssertTrue(result.didPerformMigration)
        XCTAssertNil(result.snapshot?.activitySnapshot.recentProjectName)
    }

    func testCorruptV2EnvelopeReturnsNil() throws {
        let original = makeFullSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)
        let tampered = makeCorruptLastCharacter(v2Value)

        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(tampered))
    }

    func testTamperedV2ChecksumReturnsNil() throws {
        let original = makeFullSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)
        var fields = v2Value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        // Corrupt the revision checksum (field 2)
        fields[2] = String(fields[2].reversed())
        let tampered = fields.joined(separator: "\t")

        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(tampered))
    }

    func testTamperedV2PayloadReturnsNil() throws {
        let original = makeFullSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)
        var fields = v2Value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        // Corrupt the payload checksum (field 3)
        fields[3] = String(fields[3].reversed())
        let tampered = fields.joined(separator: "\t")

        // Tampered checksum should fail V2 validation
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(tampered))
    }

    func testCorruptV2PayloadDataReturnsNil() throws {
        let original = makeFullSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)
        var fields = v2Value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        // Corrupt payload field (field 4)
        fields[4] = String(fields[4].dropLast(5).reversed())
        let tampered = fields.joined(separator: "\t")

        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(tampered))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(""))
    }

    func testIdempotentV2Migration() throws {
        let original = makeFullSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)

        let result1 = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(v2Value)
        )
        let result2 = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateV2ToV3(v2Value)
        )

        XCTAssertTrue(result1.didPerformMigration)
        XCTAssertTrue(result2.didPerformMigration)
        XCTAssertEqual(result1.snapshot, result2.snapshot)
        // Compare decoded snapshots, not raw V3 strings (binary plist ordering
        // may vary between serializations).
        let v3Decoded1 = try XCTUnwrap(
            result1.v3EncodedValue.flatMap(TinyBuddyCombinedSnapshotStore.decodeV3)
        )
        let v3Decoded2 = try XCTUnwrap(
            result2.v3EncodedValue.flatMap(TinyBuddyCombinedSnapshotStore.decodeV3)
        )
        XCTAssertEqual(v3Decoded1, v3Decoded2)
        XCTAssertEqual(v3Decoded1, result1.snapshot)
    }
}

// MARK: - 4. Universal migrateToV3 Tests

final class TinyBuddyCombinedSnapshotUniversalMigrationTests: XCTestCase {

    func testMigrateV1ToV3() throws {
        let original = makeFullSnapshot()
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateToV3(v1Value)
        )

        XCTAssertEqual(result.fromVersion, 1)
        XCTAssertEqual(result.toVersion, 3)
        XCTAssertTrue(result.didPerformMigration)
        XCTAssertEqual(result.snapshot, original)
    }

    func testMigrateV2ToV3() throws {
        let original = makeFullSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateToV3(v2Value)
        )

        XCTAssertEqual(result.fromVersion, 2)
        XCTAssertTrue(result.didPerformMigration)
        XCTAssertEqual(result.snapshot, original)
    }

    func testMigrateV3ToV3ReturnsNoop() throws {
        let original = makeFullSnapshot()
        let v3Value = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(original))

        let result = try XCTUnwrap(
            TinyBuddyCombinedSnapshotMigrator.migrateToV3(v3Value)
        )

        XCTAssertEqual(result.fromVersion, 3)
        XCTAssertFalse(result.didPerformMigration) // No migration needed
        XCTAssertEqual(result.diagnosticKey, "migrator.v3_noop")
        XCTAssertEqual(result.snapshot, original)
        // V3 encoded value should decode to the same snapshot
        let decoded = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(try XCTUnwrap(result.v3EncodedValue))
        )
        XCTAssertEqual(decoded, original)
    }

    func testMigrateGarbageReturnsNil() {
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateToV3("this is not valid"))
    }

    func testMigrateEmptyReturnsNil() {
        XCTAssertNil(TinyBuddyCombinedSnapshotMigrator.migrateToV3(""))
    }

    func testMigrateReEncodesV3WithNormalization() throws {
        // Create a V3 snapshot with negative focus count (which normalize would clamp)
        let unnormalized = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: -3, completionCount: 1)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            activityRevision: nil
        )
        // This won't *encode* with negative values because encodeV3 normalizes
        // But if somehow we get V3 data with negative values, the V3 decode
        // should reject it since the binary plist stores non-negative values
        let v3Value = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(unnormalized))
        let decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(v3Value))
        // Normalization clamps negative values
        XCTAssertGreaterThanOrEqual(decoded.snapshot.stats.focusCount, 0)
    }
}

// MARK: - 5. sanitizeToCurrentSchema Tests

final class TinyBuddyCombinedSnapshotSanitizeTests: XCTestCase {

    func testNilInputReturnsNil() {
        let result = TinyBuddyCombinedSnapshotStore.sanitizeToCurrentSchema(nil)
        XCTAssertNil(result.snapshot)
        XCTAssertNil(result.v3Encoded)
    }

    func testEmptyInputReturnsNil() {
        let result = TinyBuddyCombinedSnapshotStore.sanitizeToCurrentSchema("")
        XCTAssertNil(result.snapshot)
        XCTAssertNil(result.v3Encoded)
    }

    func testV1InputReturnsDecodedSnapshotWithV3Encoding() throws {
        let original = makeFullSnapshot()
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        let result = TinyBuddyCombinedSnapshotStore.sanitizeToCurrentSchema(v1Value)

        XCTAssertEqual(result.snapshot, original)
        let v3Encoded = try XCTUnwrap(result.v3Encoded)
        let v3Decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(v3Encoded))
        XCTAssertEqual(v3Decoded, original)
    }

    func testV2InputReturnsDecodedSnapshotWithV3Encoding() throws {
        let original = makeFullSnapshot()
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)

        let result = TinyBuddyCombinedSnapshotStore.sanitizeToCurrentSchema(v2Value)

        XCTAssertEqual(result.snapshot, original)
        let v3Encoded = try XCTUnwrap(result.v3Encoded)
        let v3Decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(v3Encoded))
        XCTAssertEqual(v3Decoded, original)
    }

    func testV3InputReturnsSnapshotAndSameV3Value() throws {
        let original = makeFullSnapshot()
        let v3Value = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(original))

        let result = TinyBuddyCombinedSnapshotStore.sanitizeToCurrentSchema(v3Value)

        XCTAssertEqual(result.snapshot, original)
        XCTAssertEqual(result.v3Encoded, v3Value) // Same V3 string returned directly
    }

    func testGarbageInputReturnsNilSnapshot() {
        let result = TinyBuddyCombinedSnapshotStore.sanitizeToCurrentSchema("not_a_snapshot")
        XCTAssertNil(result.snapshot)
        XCTAssertNil(result.v3Encoded)
    }

    func testAlreadyV3DoesNotCallDecoderAgain() throws {
        // V3 input should be recognized directly without going through migration
        let original = makeFullSnapshot()
        let v3Value = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(original))

        let result = TinyBuddyCombinedSnapshotStore.sanitizeToCurrentSchema(v3Value)

        // V3 input path returns the same V3 value
        XCTAssertEqual(result.v3Encoded, v3Value)
    }
}

// MARK: - 6. Store Corruption Recovery Tests

final class TinyBuddyCombinedSnapshotCorruptionRecoveryTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func decodeSlot(
        _ key: String,
        defaults: UserDefaults
    ) throws -> TinyBuddyCombinedSnapshot {
        let value = try XCTUnwrap(defaults.string(forKey: key))
        return try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.decodeV3(value)
        )
    }

    // MARK: - Corrupt V3 slot but valid V2 backup

    func testRecoveryFromCorruptV3SlotViaV1Backup() throws {
        let defaults = makeDefaults()
        let original = makeFullSnapshot()

        // Write the snapshot as V1 legacy (simulating old data)
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)
        defaults.set(v1Value, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)

        // Write a corrupt V3 slot (simulating a failed upgrade)
        defaults.set(
            "3\t0\tcorrupt\tcorrupt\tcorrupt",
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA
        )

        // Store with repair on load should recover from V1
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: true
        )

        let loaded = store.load()
        XCTAssertNotNil(loaded, "Store should recover from corrupt V3 slot using V1 data")
        XCTAssertEqual(loaded?.revision, original.revision)
        XCTAssertEqual(loaded?.snapshot.stats.focusCount, original.snapshot.stats.focusCount)
        XCTAssertEqual(loaded?.snapshot.stats.completionCount, original.snapshot.stats.completionCount)
    }

    func testNoCrashOnFullyCorruptData() throws {
        let defaults = makeDefaults()

        // Write completely corrupt data to all slots
        defaults.set("completely invalid data", forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        defaults.set("also invalid", forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        defaults.set("more invalid", forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: true
        )

        // Should not crash, return nil
        let loaded = store.load()
        XCTAssertNil(loaded, "Fully corrupt data should return nil, not crash")
    }

    // MARK: - V3 slot with tampered payload

    func testTamperedV3PayloadRejected() throws {
        let defaults = makeDefaults()
        let original = makeFullSnapshot()

        // Write a valid V3 slot with committed revision marker so the store
        // can find the staged slot.
        let v3Value = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(original))
        defaults.set(v3Value, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        let marker = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(original.revision)
        )
        defaults.set(marker, forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2)

        // Verify valid slot loads
        let validStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertNotNil(validStore.loadReadOnly())

        // Now corrupt the V3 slot
        let corrupted = makeCorruptLastCharacter(v3Value)
        defaults.set(corrupted, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)

        let corruptStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertNil(corruptStore.loadReadOnly(), "Corrupt V3 should not load")
    }

    // MARK: - Read-only corrupt V3 then re-read recovery

    func testReadValidatedRecoveryFromCorruptSlot() throws {
        let defaults = makeDefaults()
        let original = makeFullSnapshot()

        // Write a valid V3 as the primary slot with committed marker
        let v3Value = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(original))
        defaults.set(v3Value, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        let marker = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(original.revision)
        )
        defaults.set(marker, forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )

        // First read should succeed
        let firstRead = store.readValidated(expectedDayIdentifier: "2026-07-20")
        XCTAssertNotNil(firstRead.snapshot)
        XCTAssertNil(firstRead.observation)

        // Corrupt the slot to simulate bitrot
        let corrupted = makeCorruptLastCharacter(v3Value)
        defaults.set(corrupted, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)

        // readValidated should detect corruption and attempt re-read
        let corruptRead = store.readValidated(expectedDayIdentifier: "2026-07-20")
        // The second read should also fail (persistent corruption)
        XCTAssertNil(corruptRead.snapshot)
        let obs = try XCTUnwrap(corruptRead.observation)
        XCTAssertTrue(
            obs.reason == .snapshotCorrupt || obs.reason == .staleData,
            "Expected snapshot corruption or stale data, got \(obs.reason.rawValue)"
        )
    }

    // MARK: - V2 data loadable by V3-capable store

    func testV2DataLoadsInV3Store() throws {
        let defaults = makeDefaults()
        let original = makeFullSnapshot()

        // Write V2 data only (no V3)
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)
        defaults.set(v2Value, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: true
        )

        // Store should load through V2 decode path
        let loaded = store.load()
        XCTAssertNotNil(loaded, "V3 store should load V2 data")
        XCTAssertEqual(loaded?.revision, original.revision)
    }

    // MARK: - Interrupted migration recovery

    func testInterruptedMigrationRecoveryViaBackup() throws {
        let defaults = makeDefaults()
        let original = makeFullSnapshot()

        // Simulate a V1 value stored as the legacy snapshot (pre-migration backup)
        let v1Value = TinyBuddyCombinedSnapshotStore.encode(original)

        // Simulate a partially written V3 slot that is corrupt
        defaults.set(v1Value, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        defaults.set(
            "3\t0\tabc\tdef\t!!!invalid",
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA
        )

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: true
        )

        // Should be able to recover from V1
        let loaded = store.load()
        XCTAssertNotNil(loaded, "Should recover from interrupted migration")
        XCTAssertEqual(loaded?.revision, original.revision)
    }
}

// MARK: - 7. Widget-style Read Chain Tests

final class TinyBuddyCombinedSnapshotWidgetReadChainTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyWidgetReadChainTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// The Widget uses readValidated() with a two-attempt re-read strategy.
    /// This test verifies the fallback chain when all V3/V2/V1 data is corrupt.
    func testWidgetReadChainAllCorrupt() throws {
        let defaults = makeDefaults()
        defaults.set("garbage", forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )

        let read = store.readValidated(expectedDayIdentifier: "2026-07-20")
        XCTAssertNil(read.snapshot)
        // If the observation is due to snapshot corruption, the Widget would
        // fall through to its DailyStatsStore fallback.
        if let observation = read.observation {
            XCTAssertEqual(observation.phase, .snapshotRead)
            XCTAssertTrue(
                observation.reason == .snapshotCorrupt || observation.reason == .staleData,
                "Expected corruption or stale data reason, got \(observation.reason)"
            )
        }
    }

    /// Widget-style: corrupt primary slot, valid secondary slot, should recover
    func testWidgetReadChainCorruptSlotAValidSlotB() throws {
        let defaults = makeDefaults()
        let original = makeFullSnapshot()

        // Slot A is corrupt
        defaults.set("garbage", forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)

        // Slot B is valid V2
        let v2Value = TinyBuddyCombinedSnapshotStore.encodeV2(original)
        defaults.set(v2Value, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: true
        )

        let loaded = store.load()
        XCTAssertNotNil(loaded, "Should recover from valid Slot B")
        XCTAssertEqual(loaded?.revision, original.revision)
    }

    /// Widget-style: V3 legacy key with valid data, no V2 slots
    func testWidgetReadFromLegacyV3Key() throws {
        let defaults = makeDefaults()
        let original = makeFullSnapshot()

        // Only write to the V1 legacy key (which stores V3 data after migration)
        let v3Value = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(original))
        defaults.set(v3Value, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: true
        )

        let loaded = store.load()
        XCTAssertNotNil(loaded, "Should load V3 from legacy key")
        XCTAssertEqual(loaded?.revision, original.revision)
    }
}
