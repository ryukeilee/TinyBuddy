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

    // MARK: - Current-day protection

    func testPruneExcessNeverRemovesCurrentDayEvenUnderCountLimit() {
        let store = makeStoreWithRetentionPolicy(
            TinyBuddyHistoryRetentionPolicy(maxDayCount: 2, maxTotalBytes: 2_097_152)
        )

        store.archiveSnapshot(makeSnapshot(dayIdentifier: olderIdentifier, revision: 1))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: yesterdayIdentifier, revision: 2))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 3))

        _ = store.pruneExcess()

        let days = store.archivedDayIdentifiers()
        XCTAssertEqual(days.count, 2)
        XCTAssertTrue(days.contains(dayIdentifier), "current day must never be pruned")
        XCTAssertFalse(days.contains(olderIdentifier))

        store.clearAll()
    }

    func testPruneExcessNeverRemovesCurrentDayUnderSizeLimit() {
        // Tiny size limit (clamped to the policy minimum): the current day
        // must survive even when the archive is above the byte budget.
        let store = makeStoreWithRetentionPolicy(
            TinyBuddyHistoryRetentionPolicy(maxDayCount: 100, maxTotalBytes: 1)
        )

        // Several older days so the total exceeds the clamped 1 KB budget.
        for i in 1...5 {
            let dayId = "2026-07-\(String(format: "%02d", i))"
            store.archiveSnapshot(makeSnapshot(dayIdentifier: dayId, revision: Int64(i)))
        }
        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 6))

        let result = store.pruneExcess()

        let days = store.archivedDayIdentifiers()
        XCTAssertTrue(days.contains(dayIdentifier), "current day must survive size-based pruning")
        XCTAssertGreaterThanOrEqual(result.removedFileCount, 1)

        store.clearAll()
    }

    func testPruneExcessProtectsFutureDatedFilesAfterClockSkew() {
        let store = makeStoreWithRetentionPolicy(
            TinyBuddyHistoryRetentionPolicy(maxDayCount: 1, maxTotalBytes: 2_097_152)
        )
        let futureIdentifier = "2026-08-01"

        store.archiveSnapshot(makeSnapshot(dayIdentifier: olderIdentifier, revision: 1))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: futureIdentifier, revision: 2))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 3))

        _ = store.pruneExcess()

        let days = store.archivedDayIdentifiers()
        XCTAssertTrue(days.contains(futureIdentifier), "future-dated file must be protected")
        XCTAssertTrue(days.contains(dayIdentifier), "current day must be protected")
        XCTAssertFalse(days.contains(olderIdentifier))

        store.clearAll()
    }

    // MARK: - Interrupted cleanup recovery

    func testPruneExcessRecoversFromInterruptedCleanupMarker() {
        let store = makeStore()
        store.archiveSnapshot(makeSnapshot(dayIdentifier: yesterdayIdentifier, revision: 1))
        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 2))

        // Simulate a crash during a previous cleanup: the marker file remains.
        guard let directoryURL = store.historyDirectoryURL else {
            XCTFail("No history directory URL")
            return
        }
        let markerURL = directoryURL.appendingPathComponent(".cleanup-in-progress")
        try! "cleanup".data(using: .utf8)!.write(to: markerURL)

        // A new prune must recover the interrupted run and complete normally.
        let first = store.pruneExcess()
        XCTAssertTrue(first.didComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        // Re-running is idempotent and leaves the archive intact.
        let second = store.pruneExcess()
        XCTAssertTrue(second.didComplete)
        let days = store.archivedDayIdentifiers()
        XCTAssertEqual(days, [dayIdentifier, yesterdayIdentifier])

        store.clearAll()
    }

    // MARK: - Corrupted file quarantine

    func testReadCorruptFileIsQuarantinedAndRemovedFromArchive() {
        let store = makeStore()
        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 1))

        guard let directoryURL = store.historyDirectoryURL else {
            XCTFail("No history directory URL")
            return
        }
        let fileURL = directoryURL
            .appendingPathComponent(dayIdentifier)
            .appendingPathExtension("snapshot")
        try! "not-valid-v3-data".write(to: fileURL, atomically: true, encoding: .utf8)

        // The read reports corrupt and isolates the file.
        let result = store.readSnapshot(for: dayIdentifier)
        XCTAssertEqual(result, .corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // The quarantine preserves a redacted copy for diagnostics.
        let quarantine = TinyBuddyCorruptedRecordQuarantine(storageURL: quarantineURL(for: store))
        let entries = quarantine.loadAll()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.domain, .historyArchive)
        XCTAssertEqual(entries.first?.diagnosticKey, "historyArchive:\(dayIdentifier)")

        // Subsequent reads see the file as gone, never as corrupt again.
        XCTAssertEqual(store.readSnapshot(for: dayIdentifier), .notFound)
        XCTAssertTrue(store.archivedDayIdentifiers().isEmpty)

        store.clearAll()
    }

    func testPruneQuarantinesUnrecognizedSnapshotFiles() {
        let store = makeStore()
        store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 1))

        guard let directoryURL = store.historyDirectoryURL else {
            XCTFail("No history directory URL")
            return
        }
        // A file that looks like a snapshot attempt but has no valid day name.
        let junkURL = directoryURL
            .appendingPathComponent("garbage")
            .appendingPathExtension("snapshot")
        try! "junk".write(to: junkURL, atomically: true, encoding: .utf8)

        let result = store.pruneExcess()
        XCTAssertGreaterThanOrEqual(result.removedFileCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: junkURL.path))

        let quarantine = TinyBuddyCorruptedRecordQuarantine(storageURL: quarantineURL(for: store))
        XCTAssertEqual(quarantine.loadAll().count, 1)
        XCTAssertEqual(quarantine.loadAll().first?.diagnosticKey, "historyArchive:unrecognizedFile")

        store.clearAll()
    }

    // MARK: - Result accuracy

    func testPruneExcessReportsAccurateFinalCounts() {
        let store = makeStoreWithRetentionPolicy(
            TinyBuddyHistoryRetentionPolicy(maxDayCount: 2, maxTotalBytes: 2_097_152)
        )

        for i in 10...20 {
            let dayId = "2026-07-\(String(format: "%02d", i))"
            store.archiveSnapshot(makeSnapshot(dayIdentifier: dayId, revision: Int64(i)))
        }

        let result = store.pruneExcess()
        XCTAssertEqual(result.removedFileCount, 9)
        XCTAssertEqual(result.finalFileCount, 2)
        XCTAssertGreaterThanOrEqual(result.finalSizeBytes, 0)
        XCTAssertEqual(result.finalFileCount, store.archivedDayIdentifiers().count)

        store.clearAll()
    }

    func testArchiveRejectsWriteThatFailsReadBackVerification() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-history-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

        // Encoder produces a value that cannot round-trip through the decoder,
        // simulating a silent write corruption.
        let store = TinyBuddyHistoryStore(
            fileManager: .default,
            snapshotEncoder: { _ in "garbage-that-cannot-decode" },
            snapshotDecoder: { _ in nil },
            retentionPolicy: TinyBuddyHistoryRetentionPolicy(maxDayCount: 100, maxTotalBytes: 10_000_000),
            customContainerURL: tmpURL,
            currentDayIdentifierProvider: { [dayIdentifier] in dayIdentifier }
        )

        let archived = store.archiveSnapshot(makeSnapshot(dayIdentifier: dayIdentifier, revision: 1))
        XCTAssertNil(archived)
        XCTAssertEqual(store.readSnapshot(for: dayIdentifier), .notFound)
        XCTAssertTrue(store.archivedDayIdentifiers().isEmpty)
    }

    // MARK: - Concurrency

    /// Concurrent archive, prune, and read operations must be serialized by
    /// the store lock: no crashes, no corrupt files, and the current day is
    /// never removed even under concurrent pruning.
    func testConcurrentArchivePruneAndReadAreSafe() {
        let store = makeStoreWithRetentionPolicy(
            TinyBuddyHistoryRetentionPolicy(maxDayCount: 5, maxTotalBytes: 10_000_000)
        )

        let group = DispatchGroup()
        let iterations = 40

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let dayId = "2026-07-\(String(format: "%02d", (i % 10) + 1))"
                _ = store.archiveSnapshot(self.makeSnapshot(dayIdentifier: dayId, revision: Int64(i)))
                group.leave()
            }
            if i % 5 == 0 {
                // The current day is archived alongside the noise so its
                // survival under concurrent pruning is actually exercised.
                group.enter()
                DispatchQueue.global().async {
                    _ = store.archiveSnapshot(
                        self.makeSnapshot(dayIdentifier: self.dayIdentifier, revision: Int64(i))
                    )
                    group.leave()
                }
            }
            if i % 5 == 0 {
                group.enter()
                DispatchQueue.global().async {
                    _ = store.pruneExcess()
                    group.leave()
                }
            }
            group.enter()
            DispatchQueue.global().async {
                _ = store.archivedDayIdentifiers()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        // The current day survives every interleaving.
        let days = store.archivedDayIdentifiers()
        XCTAssertTrue(days.contains(dayIdentifier))
        // Every archived file must still decode (no torn writes).
        for day in days {
            guard case .available = store.readSnapshot(for: day) else {
                XCTFail("archived day \(day) is unreadable after concurrent access")
                break
            }
        }

        store.clearAll()
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
        makeStoreWithRetentionPolicy(
            TinyBuddyHistoryRetentionPolicy(maxDayCount: 100, maxTotalBytes: 10_000_000)
        )
    }

    private func makeStoreWithRetentionPolicy(
        _ policy: TinyBuddyHistoryRetentionPolicy
    ) -> TinyBuddyHistoryStore {
        makeStoreWithRetentionPolicy(
            policy,
            currentDayIdentifier: dayIdentifier
        )
    }

    private func makeStoreWithRetentionPolicy(
        _ policy: TinyBuddyHistoryRetentionPolicy,
        currentDayIdentifier: String?
    ) -> TinyBuddyHistoryStore {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-history-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

        let quarantineURL = tmpURL
            .appendingPathComponent("Quarantine", isDirectory: true)
            .appendingPathComponent("corrupted_records.json")
        let quarantine = TinyBuddyCorruptedRecordQuarantine(storageURL: quarantineURL)

        return TinyBuddyHistoryStore(
            fileManager: .default,
            snapshotEncoder: TinyBuddyCombinedSnapshotStore.encodeV3,
            snapshotDecoder: TinyBuddyCombinedSnapshotStore.decodeV3,
            retentionPolicy: policy,
            customContainerURL: tmpURL,
            currentDayIdentifierProvider: { currentDayIdentifier },
            quarantine: quarantine
        )
    }

    private func quarantineURL(for store: TinyBuddyHistoryStore) -> URL {
        // historyDirectoryURL = <tmp>/Library/Caches/com.ryukeili.TinyBuddy/SnapshotHistory
        let tmpRoot = store.historyDirectoryURL!
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return tmpRoot
            .appendingPathComponent("Quarantine", isDirectory: true)
            .appendingPathComponent("corrupted_records.json")
    }
}
