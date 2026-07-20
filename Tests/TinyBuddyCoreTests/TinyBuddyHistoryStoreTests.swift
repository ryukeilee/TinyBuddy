import XCTest
@testable import TinyBuddyCore

final class TinyBuddyHistoryStoreTests: XCTestCase {
    private let dayIdentifier = "2026-07-20"
    private let yesterdayIdentifier = "2026-07-19"
    private let olderIdentifier = "2026-07-18"

    private func makeSnapshot(dayIdentifier: String, revision: Int64 = 1) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: dayIdentifier, focusCount: 1, completionCount: 2)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 4,
                recentProjectName: "TestProject"
            ),
            activityRevision: 100
        )
    }

    // MARK: - Archive and read

    func testArchiveAndReadSnapshot() {
        let store = makeStore()
        let snapshot = makeSnapshot(dayIdentifier: dayIdentifier)

        let archived = store.archiveSnapshot(snapshot)
        XCTAssertEqual(archived, dayIdentifier)

        let result = store.readSnapshot(for: dayIdentifier)
        guard case .available(let read) = result else {
            XCTFail("Expected .available, got \(result)")
            return
        }
        XCTAssertEqual(read.revision, snapshot.revision)
        XCTAssertEqual(read.dayIdentifier, dayIdentifier)
        XCTAssertEqual(read.snapshot.stats.focusCount, 1)
        XCTAssertEqual(read.activitySnapshot.recentProjectName, "TestProject")

        store.clearAll()
    }

    func testReadNotFoundForMissingDay() {
        let store = makeStore()
        let result = store.readSnapshot(for: "2026-01-01")
        XCTAssertEqual(result, .notFound)
    }

    func testReadCorruptFile() {
        let store = makeStore()
        let snapshot = makeSnapshot(dayIdentifier: dayIdentifier)
        store.archiveSnapshot(snapshot)

        // Corrupt the file directly using the store's own directory.
        guard let directoryURL = store.historyDirectoryURL else {
            XCTFail("No history directory URL")
            return
        }
        let fileURL = directoryURL
            .appendingPathComponent(dayIdentifier)
            .appendingPathExtension("snapshot")
        try! "not-valid-v3-data".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = store.readSnapshot(for: dayIdentifier)
        XCTAssertEqual(result, .corrupt)

        store.clearAll()
    }

    // MARK: - Archive overwrite

    func testArchiveOverwritesExistingDay() {
        let store = makeStore()
        let snapshot1 = makeSnapshot(dayIdentifier: dayIdentifier, revision: 1)
        let snapshot2 = makeSnapshot(dayIdentifier: dayIdentifier, revision: 2)

        store.archiveSnapshot(snapshot1)
        store.archiveSnapshot(snapshot2)

        let result = store.readSnapshot(for: dayIdentifier)
        guard case .available(let read) = result else {
            XCTFail("Expected .available, got \(result)")
            return
        }
        XCTAssertEqual(read.revision, 2)

        store.clearAll()
    }

    // MARK: - List archived days

    func testArchivedDayIdentifiersOrderedNewestFirst() {
        let store = makeStore()

        store.archiveSnapshot(makeSnapshot(dayIdentifier: olderIdentifier, revision: 1))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: yesterdayIdentifier, revision: 2))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 3))

        let days = store.archivedDayIdentifiers()
        XCTAssertEqual(days, [dayIdentifier, yesterdayIdentifier, olderIdentifier])

        store.clearAll()
    }

    func testArchivedDayIdentifiersEmptyWhenNoHistory() {
        let store = makeStore()
        XCTAssertTrue(store.archivedDayIdentifiers().isEmpty)
    }

    // MARK: - Archive size

    func testArchiveSize() {
        let store = makeStore()

        var size = store.archiveSize()
        XCTAssertEqual(size.fileCount, 0)
        XCTAssertEqual(size.byteCount, 0)

        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 1))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: yesterdayIdentifier, revision: 2))

        size = store.archiveSize()
        XCTAssertEqual(size.fileCount, 2)
        XCTAssertGreaterThan(size.byteCount, 0)

        store.clearAll()
    }

    // MARK: - Prune excess

    func testPruneExcessByCount() {
        let store = makeStoreWithRetentionPolicy(
            TinyBuddyHistoryRetentionPolicy(maxDayCount: 2, maxTotalBytes: 2_097_152)
        )

        store.archiveSnapshot(makeSnapshot(dayIdentifier: "2026-07-15", revision: 1))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: "2026-07-16", revision: 2))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: "2026-07-17", revision: 3))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 4))

        let result = store.pruneExcess()

        // Keep only 2 newest.
        let days = store.archivedDayIdentifiers()
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days, [dayIdentifier, "2026-07-17"])
        XCTAssertEqual(result.removedFileCount, 2)

        store.clearAll()
    }

    func testPruneExcessBySize() {
        // Use a small size limit to force removal. With enough entries the
        // oldest should be pruned.
        let store = makeStoreWithRetentionPolicy(
            TinyBuddyHistoryRetentionPolicy(maxDayCount: 100, maxTotalBytes: 1024)
        )

        // Write enough entries to exceed the minimum.
        for i in 1...5 {
            let dayId = "2026-07-\(String(format: "%02d", i))"
            store.archiveSnapshot(makeSnapshot(dayIdentifier: dayId, revision: Int64(i)))
        }

        let result = store.pruneExcess()

        // Should remove at least the oldest entry.
        XCTAssertGreaterThan(result.removedFileCount, 0)

        store.clearAll()
    }

    func testPruneExcessDoesNotRemoveWhenWithinLimits() {
        let store = TinyBuddyHistoryStore(
            retentionPolicy: TinyBuddyHistoryRetentionPolicy(
                maxDayCount: 10,
                maxTotalBytes: 2_097_152
            )
        )

        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 1))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: yesterdayIdentifier, revision: 2))

        let before = store.archivedDayIdentifiers().count
        let result = store.pruneExcess()
        let after = store.archivedDayIdentifiers().count

        XCTAssertEqual(before, after)
        XCTAssertEqual(result.removedFileCount, 0)

        store.clearAll()
    }

    // MARK: - Clear all

    func testClearAllRemovesAllFiles() {
        let store = makeStore()

        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 1))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: yesterdayIdentifier, revision: 2))

        let removed = store.clearAll()
        XCTAssertEqual(removed, 2)
        XCTAssertTrue(store.archivedDayIdentifiers().isEmpty)
        XCTAssertEqual(store.archiveSize().fileCount, 0)
    }

    func testClearAllIsIdempotent() {
        let store = makeStore()

        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 1))
        store.clearAll()

        let second = store.clearAll()
        // Should not fail; may be 0 if the directory structure was cleaned.
        XCTAssertGreaterThanOrEqual(second, 0)
    }

    // MARK: - Retention policy defaults

    func testDefaultRetentionPolicy() {
        let policy = TinyBuddyHistoryRetentionPolicy.default
        XCTAssertEqual(policy.maxDayCount, 30)
        XCTAssertEqual(policy.maxTotalBytes, 2_097_152)
    }

    func testRetentionPolicyClampsMinimums() {
        let policy = TinyBuddyHistoryRetentionPolicy(
            maxDayCount: 0,
            maxTotalBytes: 0
        )
        XCTAssertEqual(policy.maxDayCount, 1)
        XCTAssertEqual(policy.maxTotalBytes, 1024)
    }

    // MARK: - Helpers

    private func makeStore() -> TinyBuddyHistoryStore {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-history-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

        return TinyBuddyHistoryStore(
            fileManager: .default,
            snapshotEncoder: TinyBuddyCombinedSnapshotStore.encodeV3,
            snapshotDecoder: TinyBuddyCombinedSnapshotStore.decodeV3,
            retentionPolicy: TinyBuddyHistoryRetentionPolicy(
                maxDayCount: 100,
                maxTotalBytes: 10_000_000
            ),
            customContainerURL: tmpURL
        )
    }

    private func makeStoreWithRetentionPolicy(
        _ policy: TinyBuddyHistoryRetentionPolicy
    ) -> TinyBuddyHistoryStore {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-history-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

        return TinyBuddyHistoryStore(
            fileManager: .default,
            snapshotEncoder: TinyBuddyCombinedSnapshotStore.encodeV3,
            snapshotDecoder: TinyBuddyCombinedSnapshotStore.decodeV3,
            retentionPolicy: policy,
            customContainerURL: tmpURL
        )
    }
}
