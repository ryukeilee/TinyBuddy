import XCTest
@testable import TinyBuddyCore

final class FocusSessionFileStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddy.FocusSessionFileStoreTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("focus-sessions.json")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        fileURL = nil
        try super.tearDownWithError()
    }

    func testLegacyArrayLoadsAsMigratedArchive() throws {
        let session = makeSession()
        try JSONEncoder().encode([session]).write(to: fileURL)

        let result = FocusSessionFileStore(fileURL: fileURL).loadArchive()

        XCTAssertEqual(result.health, .available)
        XCTAssertEqual(result.format, .legacyMigrated)
        XCTAssertEqual(result.archive, FocusSessionArchive(revision: 0, sessions: [session]))
        XCTAssertEqual(FocusSessionFileStore(fileURL: fileURL).load(), [session])
    }

    func testNewArchiveRoundTripPreservesRevisionAndEnvelope() throws {
        let session = makeSession()
        let archive = FocusSessionArchive(revision: 42, sessions: [session])
        let store = FocusSessionFileStore(fileURL: fileURL)

        XCTAssertTrue(store.saveArchive(archive))
        XCTAssertEqual(store.loadArchive(), FocusSessionArchiveLoadResult(health: .available, archive: archive, format: .envelope))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, FocusSessionArchive.currentSchemaVersion)
        XCTAssertEqual(object["revision"] as? Int, 42)
        XCTAssertNotNil(object["sessions"] as? [[String: Any]])
    }

    func testPreCompletenessEnvelopeMigratesAsCompleteHistory() throws {
        let archive = FocusSessionArchive(revision: 4, sessions: [makeSession()])
        let encoded = try JSONEncoder().encode(archive)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "historyCompleteness")
        let legacyEnvelope = try JSONSerialization.data(withJSONObject: object)
        try legacyEnvelope.write(to: fileURL)

        let result = FocusSessionFileStore(fileURL: fileURL).loadArchive()

        XCTAssertEqual(result.health, .available)
        XCTAssertEqual(result.archive, archive)
        XCTAssertEqual(result.archive?.historyCompleteness, .complete)
    }

    func testSecondSaveRetainsPriorEnvelopeAsBackup() throws {
        let store = FocusSessionFileStore(fileURL: fileURL)
        let first = FocusSessionArchive(revision: 1, sessions: [makeSession()])
        let second = FocusSessionArchive(revision: 2, sessions: [])

        XCTAssertTrue(store.saveArchive(first))
        XCTAssertTrue(store.saveArchive(second))

        XCTAssertEqual(store.loadArchive().archive, second)
        let backup = try JSONDecoder().decode(FocusSessionArchive.self, from: Data(contentsOf: backupURL))
        XCTAssertEqual(backup, first)
    }

    func testMissingAndCorruptAreDistinctAndLoadRemainsNil() throws {
        let store = FocusSessionFileStore(fileURL: fileURL)
        XCTAssertEqual(store.loadArchive().health, .missing)
        XCTAssertNil(store.load())

        try Data("not json".utf8).write(to: fileURL)
        XCTAssertEqual(store.loadArchive().health, .corrupt)
        XCTAssertNil(store.load())
    }

    func testCorruptPrimaryRecoversValidBackup() throws {
        let session = makeSession()
        let archive = FocusSessionArchive(revision: 7, sessions: [session])
        let recoveredArchive = FocusSessionArchive(
            revision: 7,
            sessions: [session],
            historyCompleteness: .partialRecovery
        )
        try Data("not json".utf8).write(to: fileURL)
        try JSONEncoder().encode(archive).write(to: backupURL)

        let store = FocusSessionFileStore(fileURL: fileURL)
        let result = store.loadArchive()

        XCTAssertEqual(result, FocusSessionArchiveLoadResult(health: .recoveredFromBackup, archive: recoveredArchive, format: .envelope))
        XCTAssertEqual(store.loadArchive(), FocusSessionArchiveLoadResult(health: .available, archive: recoveredArchive, format: .envelope))
    }

    func testRecoveredBackupPublishesPartialHistoryRatherThanTrustedZeroes() throws {
        let session = makeSession()
        let archive = FocusSessionArchive(revision: 7, sessions: [session])
        try Data("not json".utf8).write(to: fileURL)
        try JSONEncoder().encode(archive).write(to: backupURL)

        let clock = FixedClock(session.endedAt!.addingTimeInterval(1))
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: FocusSessionFileStore(fileURL: fileURL),
            dayIdentifier: { _ in "2001-01-01" }
        )
        let publication = try XCTUnwrap(engine.focusHistoryPublication())

        XCTAssertEqual(publication.snapshot.state, .partial)
        XCTAssertEqual(publication.snapshot.recentDays.last?.state, .unknown)
        XCTAssertNil(publication.snapshot.recentDays.last?.focusDuration)
        XCTAssertEqual(
            FocusSessionFileStore(fileURL: fileURL).loadArchive().archive?.historyCompleteness,
            .partialRecovery
        )
    }

    func testCompatibilitySavePreservesPartialRecoveryMarker() throws {
        let session = makeSession()
        try Data("not json".utf8).write(to: fileURL)
        try JSONEncoder().encode(FocusSessionArchive(revision: 7, sessions: [session])).write(to: backupURL)
        let store = FocusSessionFileStore(fileURL: fileURL)

        XCTAssertEqual(store.loadArchive().health, .recoveredFromBackup)
        XCTAssertTrue(store.save([session]))

        XCTAssertEqual(store.loadArchive().archive?.historyCompleteness, .partialRecovery)
    }

    func testBothPrimaryAndBackupCorruptRemainUnknown() throws {
        try Data("not json".utf8).write(to: fileURL)
        try Data("also not json".utf8).write(to: backupURL)

        let result = FocusSessionFileStore(fileURL: fileURL).loadArchive()

        XCTAssertEqual(result.health, .corrupt)
        XCTAssertNil(result.archive)
        XCTAssertNil(FocusSessionFileStore(fileURL: fileURL).load())
    }

    func testStructurallyDecodableButSemanticallyInvalidArchiveIsCorrupt() throws {
        var invalid = makeSession()
        invalid.dayIdentifier = "not-a-local-day"
        let archive = FocusSessionArchive(revision: 9, sessions: [invalid])
        try JSONEncoder().encode(archive).write(to: fileURL)

        let result = FocusSessionFileStore(fileURL: fileURL).loadArchive()

        XCTAssertEqual(result.health, .corrupt)
        XCTAssertNil(result.archive)
        XCTAssertNil(FocusSessionFileStore(fileURL: fileURL).load())
    }

    private var backupURL: URL {
        directory.appendingPathComponent("\(fileURL.lastPathComponent).bak")
    }

    private func makeSession() -> FocusSession {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        return FocusSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            project: FocusProjectContext(key: "project", displayName: "Project"),
            dayIdentifier: "2001-01-01",
            startedAt: date,
            endedAt: date.addingTimeInterval(60),
            status: .ended,
            lastUserActivityAt: date,
            lastStateChangeAt: date.addingTimeInterval(60),
            isManuallyConfirmed: true,
            manualRevision: 3
        )
    }
}

private final class FixedClock: FocusClock, @unchecked Sendable {
    let now: Date
    let monotonic: TimeInterval

    init(_ now: Date) {
        self.now = now
        self.monotonic = now.timeIntervalSinceReferenceDate
    }
}
