import XCTest
@testable import TinyBuddyCore

final class TinyBuddyV3EncodingTests: XCTestCase {
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

    private func makeNoProjectSnapshot() -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(
                    dayIdentifier: "2026-07-20",
                    focusCount: 2,
                    completionCount: 1
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 4,
                commitCount: 6,
                recentProjectName: nil
            ),
            activityRevision: 10
        )
    }

    // MARK: - Round-trip

    func testFullSnapshotRoundTrip() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(encoded))
        XCTAssertEqual(decoded, snapshot)
    }

    func testMinimalSnapshotRoundTrip() throws {
        let snapshot = makeMinimalSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(encoded))
        XCTAssertEqual(decoded, snapshot)
    }

    func testNoProjectSnapshotRoundTrip() throws {
        let snapshot = makeNoProjectSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(encoded))
        XCTAssertEqual(decoded, snapshot)
    }

    func testLargeRevisionRoundTrip() throws {
        let snapshot = TinyBuddyCombinedSnapshot(
            revision: 9_007_199_254_740_991,
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
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(encoded))
        XCTAssertEqual(decoded, snapshot)
    }

    func testEmptyProjectNameIsTreatedAsNil() throws {
        let snapshot = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(
                    dayIdentifier: "2026-07-20",
                    focusCount: 2,
                    completionCount: 1
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 4,
                commitCount: 6,
                recentProjectName: ""
            ),
            activityRevision: 10
        )
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(encoded))
        XCTAssertNil(decoded.activitySnapshot.recentProjectName)
    }

    func testWhitespaceProjectNameIsTreatedAsNil() throws {
        let snapshot = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(
                    dayIdentifier: "2026-07-20",
                    focusCount: 2,
                    completionCount: 1
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 4,
                commitCount: 6,
                recentProjectName: "   "
            ),
            activityRevision: 10
        )
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let decoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV3(encoded))
        XCTAssertNil(decoded.activitySnapshot.recentProjectName)
    }

    func testEnvelopeStartsWithVersion3() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        XCTAssertTrue(encoded.hasPrefix("3\t"))
    }

    func testEnvelopeHasFiveFields() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let fields = encoded.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 5)
    }

    // MARK: - Integrity rejection

    func testTamperedPayloadChecksumReturnsNil() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        var fields = encoded.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        fields[3] = String(fields[3].reversed())
        let tampered = fields.joined(separator: "\t")
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(tampered))
    }

    func testTamperedRevisionReturnsNil() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        var fields = encoded.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        fields[1] = "999"
        let tampered = fields.joined(separator: "\t")
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(tampered))
    }

    func testTamperedBase64PayloadReturnsNil() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        var fields = encoded.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        fields[4] = String(fields[4].dropLast(5).reversed())
        let tampered = fields.joined(separator: "\t")
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(tampered))
    }

    func testInvalidBase64PayloadReturnsNil() throws {
        var fields: [String] = ["3", "0", "abc", "def", "!!!invalid-base64!!!"]
        let value = fields.joined(separator: "\t")
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(value))
    }

    func testWrongEnvelopeVersionReturnsNil() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        var fields = encoded.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        fields[0] = "2"
        let wrongVersion = fields.joined(separator: "\t")
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(wrongVersion))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(""))
    }

    func testTooFewFieldsReturnsNil() {
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3("3\t0\tabc"))
    }

    // MARK: - Cross-format

    func testV2EnvelopeReturnsNilFromDecodeV3() throws {
        let snapshot = makeFullSnapshot()
        let v2Encoded = TinyBuddyCombinedSnapshotStore.encodeV2(snapshot)
        let v2Value = try XCTUnwrap(v2Encoded)
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(v2Value))
    }

    func testV3EnvelopeReturnsNilFromDecodeV2() throws {
        let snapshot = makeFullSnapshot()
        let v3Encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV2(v3Encoded))
    }

    // MARK: - Envelope structure

    func testV3FormatStaysUnderReasonableLimit() throws {
        let snapshot = makeFullSnapshot()
        let v3Encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        XCTAssertLessThan(v3Encoded.utf8.count, 1024)
    }

    func testV3PayloadIsBinaryPlist() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let fields = encoded.split(separator: "\t", omittingEmptySubsequences: false)
        let payloadData = try XCTUnwrap(Data(base64Encoded: String(fields[4])))
        var format = PropertyListSerialization.PropertyListFormat.binary
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: payloadData,
            options: [],
            format: &format
        ) as? [String: Any])
        XCTAssertEqual(format, .binary)
        XCTAssertNotNil(plist["rv"])
        XCTAssertNotNil(plist["di"])
    }

    func testCorruptV3PayloadIsNotValidV2() throws {
        let snapshot = makeFullSnapshot()
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        var fields = encoded.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        fields[3] = "badchecksum"
        let corrupted = fields.joined(separator: "\t")
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV2(corrupted))
        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(corrupted))
    }
}
