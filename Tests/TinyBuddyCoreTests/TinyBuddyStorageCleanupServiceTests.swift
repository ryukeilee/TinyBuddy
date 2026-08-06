import XCTest
@testable import TinyBuddyCore

final class TinyBuddyStorageCleanupServiceTests: XCTestCase {
    private func makeSchemaVersion(current: Int = TinyBuddyCombinedSnapshotStore.currentSchemaVersion) -> String? {
        TinyBuddyCombinedSnapshotStore.encodeSchemaVersion(current)
    }

    private func makeRevisionMarker(_ revision: Int64) -> String? {
        TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(revision)
    }

    // MARK: - Migration backup removal

    func testRunCleanupRemovesMigrationBackupWhenSchemaIsCurrentAndRevisionAboveZero() {
        var prefs: [String: Any] = [
            TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1: "legacy data"
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                if key == TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1,
                   value is NSString {
                    prefs.removeValue(forKey: key)
                    removedKeys.append(key)
                    return true
                }
                return false
            },
            removeValue: { key in
                prefs.removeValue(forKey: key)
                return true
            },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 },
            retentionPolicy: RetentionPolicy(
                maxTotalBytes: RetentionPolicy.default.maxTotalBytes,
                maxSnapshotBytes: RetentionPolicy.default.maxSnapshotBytes,
                maxConfigBytes: RetentionPolicy.default.maxConfigBytes,
                maxRefreshStatusBytes: RetentionPolicy.default.maxRefreshStatusBytes,
                staleKeyMaxAgeDays: 1
            )
        )

        let result = service.runCleanup()
        XCTAssertTrue(result.removedMigrationBackup)
        XCTAssertTrue(removedKeys.contains(TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1))
    }

    func testRunCleanupSkipsMigrationBackupRemovalWhenRevisionIsZero() {
        var prefs: [String: Any] = [
            TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1: "legacy data"
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                removedKeys.append(key)
                return false
            },
            removeValue: { key in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 0 }
        )

        let result = service.runCleanup()
        XCTAssertFalse(result.removedMigrationBackup)
        XCTAssertTrue(removedKeys.isEmpty)
    }

    func testRunCleanupSkipsMigrationBackupRemovalWhenSchemaVersionIsOld() {
        var prefs: [String: Any] = [
            TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1: "legacy data"
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                removedKeys.append(key)
                return false
            },
            removeValue: { key in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { 1 },
            committedRevisionProvider: { 42 }
        )

        let result = service.runCleanup()
        XCTAssertFalse(result.removedMigrationBackup)
        XCTAssertTrue(removedKeys.isEmpty)
    }

    func testRunCleanupSkipsMigrationBackupRemovalWhenNoBackupExists() {
        let prefs: [String: Any] = [:]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                removedKeys.append(key)
                return false
            },
            removeValue: { key in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 }
        )

        let result = service.runCleanup()
        XCTAssertFalse(result.removedMigrationBackup)
        XCTAssertTrue(removedKeys.isEmpty)
    }

    // MARK: - V1 mirror removal

    func testRunCleanupRemovesV1MirrorWhenSchemaIsV3AndRevisionAboveZero() {
        var prefs: [String: Any] = [
            TinyBuddyCombinedSnapshotStore.Key.snapshot: "legacy mirror data"
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                if key == TinyBuddyCombinedSnapshotStore.Key.snapshot,
                   value is NSString {
                    prefs.removeValue(forKey: key)
                    removedKeys.append(key)
                    return true
                }
                return false
            },
            removeValue: { key in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 }
        )

        let result = service.runCleanup()
        XCTAssertTrue(result.removedV1Mirror)
        XCTAssertTrue(removedKeys.contains(TinyBuddyCombinedSnapshotStore.Key.snapshot))
    }

    func testRunCleanupSkipsV1MirrorRemovalWhenNoLegacySnapshotKeyExists() {
        let prefs: [String: Any] = [:]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                removedKeys.append(key)
                return false
            },
            removeValue: { key in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 }
        )

        let result = service.runCleanup()
        XCTAssertFalse(result.removedV1Mirror)
        XCTAssertTrue(removedKeys.isEmpty)
    }

    func testRunCleanupSkipsV1MirrorRemovalWhenCommittedRevisionIsZero() {
        var prefs: [String: Any] = [
            TinyBuddyCombinedSnapshotStore.Key.snapshot: "legacy mirror data"
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                removedKeys.append(key)
                return false
            },
            removeValue: { key in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 0 }
        )

        let result = service.runCleanup()
        XCTAssertFalse(result.removedV1Mirror)
        XCTAssertTrue(removedKeys.isEmpty)
    }

    // MARK: - Stale key removal

    func testRunCleanupRemovesStaleDayIdentifierKeys() {
        let today = "2026-07-20"
        let yesterday = "2026-07-19"
        var prefs: [String: Any] = [
            "tinybuddy.gitTodayCommitCount.dayIdentifier": yesterday,
            "tinybuddy.gitTodayCommitCount.count": "5",
            "tinybuddy.gitTodayFocusBlockCount.dayIdentifier": yesterday,
            "tinybuddy.gitTodayFocusBlockCount.count": "3",
            "tinybuddy.gitTodayRecentProject.dayIdentifier": today
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                if value is NSString {
                    removedKeys.append(key)
                    return true
                }
                return false
            },
            removeValue: { key in
                prefs.removeValue(forKey: key)
                removedKeys.append(key)
                return true
            },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Self.fixedDateForDay("2026-07-20"),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 },
            retentionPolicy: RetentionPolicy(staleKeyMaxAgeDays: 1)
        )

        let result = service.runCleanup()
        XCTAssertGreaterThan(result.removedStaleKeys, 0)
        XCTAssertTrue(removedKeys.contains("tinybuddy.gitTodayCommitCount.count"))
        XCTAssertTrue(removedKeys.contains("tinybuddy.gitTodayFocusBlockCount.count"))
        XCTAssertFalse(removedKeys.contains("tinybuddy.gitTodayRecentProject.dayIdentifier"))
    }

    func testRunCleanupLeavesCurrentDayIdentifierKeysAlone() {
        let dayId = "2026-07-20"
        var prefs: [String: Any] = [
            "tinybuddy.gitTodayCommitCount.dayIdentifier": dayId,
            "tinybuddy.gitTodayCommitCount.count": "5",
            "tinybuddy.gitTodayFocusBlockCount.dayIdentifier": dayId,
            "tinybuddy.gitTodayFocusBlockCount.count": "3"
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                if value is NSString {
                    removedKeys.append(key)
                    return true
                }
                return false
            },
            removeValue: { key in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(timeIntervalSince1970: 1_784_548_800),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 },
            retentionPolicy: RetentionPolicy(staleKeyMaxAgeDays: 1)
        )

        let result = service.runCleanup()
        XCTAssertEqual(result.removedStaleKeys, 0)
        XCTAssertTrue(removedKeys.isEmpty)
    }

    // MARK: - Storage estimation

    func testEstimateStorageUsageReturnsZeroForEmptyStore() {
        let prefs: [String: Any] = [:]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil }
        )

        let usage = service.estimateStorageUsage()
        XCTAssertEqual(usage.totalEstimatedBytes, 0)
        XCTAssertEqual(usage.snapshotBytes, 0)
        XCTAssertEqual(usage.configBytes, 0)
        XCTAssertEqual(usage.refreshStatusBytes, 0)
        XCTAssertEqual(usage.staleKeyCount, 0)
    }

    func testEstimateStorageUsageCategorizesKeys() {
        let prefs: [String: Any] = [
            "tinybuddy.combinedSnapshot.v2.slotA": "some-value",
            "tinybuddy.appConfig.displayMode": "dark",
            "tinybuddy.gitRefreshStatus.lastRun": "2026-07-20",
            "tinybuddy.combinedSnapshot.migrationBackup.v1": "legacy"
        ]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil }
        )

        let usage = service.estimateStorageUsage()
        XCTAssertGreaterThan(usage.totalEstimatedBytes, 0)
        XCTAssertGreaterThan(usage.snapshotBytes, 0)
        XCTAssertGreaterThan(usage.configBytes, 0)
        XCTAssertGreaterThan(usage.refreshStatusBytes, 0)
    }

    // MARK: - Observation

    func testRunCleanupReturnsObservationWhenStorageExceedsLimit() {
        let bigKey = "tinybuddy.combinedSnapshot.v2.slotA"
        let bigData = String(repeating: "x", count: 600_000)
        let prefs: [String: Any] = [bigKey: bigData]

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 }
        )

        let result = service.runCleanup()
        XCTAssertNotNil(result.observation)
        XCTAssertEqual(result.observation?.reason, .persistenceFailed)
    }

    func testRunCleanupReturnsNilObservationWhenStorageIsWithinLimit() {
        let prefs: [String: Any] = [
            "tinybuddy.combinedSnapshot.v2.slotA": "small-value"
        ]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 }
        )

        let result = service.runCleanup()
        XCTAssertNil(result.observation)
    }

    func testRunCleanupReturnsAppGroupUnavailableWhenPreferencesUnloadable() {
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { nil },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil }
        )

        let result = service.runCleanup()
        XCTAssertEqual(result.observation?.reason, .appGroupUnavailable)
        XCTAssertEqual(result.observation?.recovery, .stopped)
    }

    // MARK: - History archive integration

    func testRunCleanupPrunesHistoryExcess() {
        let prefs: [String: Any] = [
            TinyBuddyCombinedSnapshotStore.Key.schemaVersion: makeSchemaVersion() ?? ""
        ]
        let store = TinyBuddyHistoryStore(
            retentionPolicy: TinyBuddyHistoryRetentionPolicy(
                maxDayCount: 5,
                maxTotalBytes: 10_000_000
            )
        )
        // Archive several days.
        let dayIDs = ["2026-07-10", "2026-07-11", "2026-07-12", "2026-07-13", "2026-07-14", "2026-07-15"]
        for (i, dayID) in dayIDs.enumerated() {
            let snap = makeCombinedSnapshot(dayIdentifier: dayID, revision: Int64(i + 1))
            store.archiveSnapshot(snap)
        }
        defer { store.clearAll() }

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Date(),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 },
            fileManager: .default,
            historyStoreProvider: { store },
            appGroupContainerProvider: {
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
                )
            },
            retentionPolicy: RetentionPolicy(
                staleKeyMaxAgeDays: 1
            )
        )

        let result = service.runCleanup()
        XCTAssertGreaterThanOrEqual(result.historyRemovedFileCount, 1)
        XCTAssertGreaterThan(result.historyBytes, 0)
        XCTAssertGreaterThan(result.historyFileCount, 0)
    }

    // MARK: - Disk space monitoring

    func testRunCleanupReportsLowDiskSpace() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let prefs: [String: Any] = [:]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil },
            fileManager: .default,
            historyStoreProvider: { TinyBuddyHistoryStore() },
            // Use a tiny tmp dir as the "App Group container" so volume capacity
            // check returns a small value. The tmp dir likely has enough space,
            // but we set minFreeDiskSpaceBytes high enough to trigger.
            appGroupContainerProvider: { tmpURL },
            retentionPolicy: RetentionPolicy(
                minFreeDiskSpaceBytes: 9_007_199_254_740_991
            )
        )

        let result = service.runCleanup()
        XCTAssertTrue(result.isDiskSpaceLow)
        XCTAssertNotNil(result.observation)
    }

    func testRunCleanupDoesNotReportLowDiskSpaceWhenSpaceIsAdequate() {
        let prefs: [String: Any] = ["tinybuddy.combinedSnapshot.v2.slotA": "small"]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 },
            retentionPolicy: RetentionPolicy(
                staleKeyMaxAgeDays: 1,
                minFreeDiskSpaceBytes: 0
            )
        )

        let result = service.runCleanup()
        XCTAssertFalse(result.isDiskSpaceLow)
        XCTAssertNil(result.observation)
    }

    // MARK: - Storage usage with history

    func testEstimateStorageUsageIncludesHistory() {
        let store = TinyBuddyHistoryStore(
            retentionPolicy: TinyBuddyHistoryRetentionPolicy(
                maxDayCount: 100,
                maxTotalBytes: 10_000_000
            )
        )
        let snap = makeCombinedSnapshot(dayIdentifier: "2026-07-20", revision: 1)
        store.archiveSnapshot(snap)
        defer { store.clearAll() }

        let prefs: [String: Any] = [:]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil },
            fileManager: .default,
            historyStoreProvider: { store },
            appGroupContainerProvider: {
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
                )
            }
        )

        let usage = service.estimateStorageUsage()
        XCTAssertGreaterThan(usage.historyFileCount, 0)
        XCTAssertGreaterThan(usage.historyBytes, 0)
    }

    // MARK: - Cleanup result completeness

    func testRunCleanupResultContainsAllNewFields() {
        let prefs: [String: Any] = [:]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil },
            retentionPolicy: RetentionPolicy(
                staleKeyMaxAgeDays: 1,
                minFreeDiskSpaceBytes: 0
            )
        )

        let result = service.runCleanup()
        XCTAssertEqual(result.removedCacheBytes, 0)
        XCTAssertEqual(result.removedTmpdirFileCount, 0)
        XCTAssertEqual(result.removedTmpdirBytes, 0)
        XCTAssertFalse(result.isDiskSpaceLow)
    }

    // MARK: - Helpers

    private static func fixedDateForDay(_ dayId: String) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: Int(dayId.prefix(4)),
            month: Int(dayId.dropFirst(5).prefix(2)),
            day: Int(dayId.suffix(2)),
            hour: 12
        ))!
    }

    private func makeCombinedSnapshot(
        dayIdentifier: String,
        revision: Int64
    ) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: dayIdentifier,
                    focusCount: 1,
                    completionCount: 2
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 4,
                recentProjectName: "Test"
            ),
            activityRevision: revision
        )
    }

    // MARK: - Stale key accounting

    func testStaleKeyCountOnlyCountsRemovableKeys() {
        let today = "2026-07-20"
        let thirtyDaysAgo = "2026-06-20"
        // Still-referenced keys (dailyStats, currentStatus) are never counted
        // as stale even though they carry a per-day shape.
        let prefs: [String: Any] = [
            "tinybuddy.dailyStats.dayIdentifier": today,
            "tinybuddy.dailyStats.focusCount": "3",
            "tinybuddy.currentStatus": "idle",
            "tinybuddy.currentStatus.dayIdentifier": today,
            "tinybuddy.gitTodayActivity.trustedSnapshot": "x",
            "tinybuddy.gitTodayCommitCount.dayIdentifier": thirtyDaysAgo,
            "tinybuddy.gitTodayCommitCount.count": "5"
        ]

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Self.fixedDateForDay(today),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 },
            retentionPolicy: RetentionPolicy(staleKeyMaxAgeDays: 1)
        )

        let usage = service.estimateStorageUsage()
        XCTAssertEqual(usage.staleKeyCount, 1, "only the removable stale count key counts")
    }

    // MARK: - Interrupted cleanup recovery

    func testRunCleanupRecoversInterruptedCleanupMarker() {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-cleanup-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: containerURL) }

        let markerURL = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("com.ryukeili.TinyBuddy", isDirectory: true)
            .appendingPathComponent(".tinybuddy-cleanup-in-progress")
        try! FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! "cleanup".data(using: .utf8)!.write(to: markerURL)

        let prefs: [String: Any] = [:]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil },
            fileManager: .default,
            historyStoreProvider: { TinyBuddyHistoryStore() },
            appGroupContainerProvider: { containerURL },
            retentionPolicy: RetentionPolicy(
                staleKeyMaxAgeDays: 1,
                minFreeDiskSpaceBytes: 0
            )
        )

        let result = service.runCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path), "interrupted marker must be recovered")
        XCTAssertNotNil(result.storageUsage)

        // The next cleanup starts clean.
        let second = service.runCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertNotNil(second.storageUsage)
    }

    // MARK: - TMPDIR artifact cleanup

    func testRunCleanupRemovesAgedTmpdirArtifactsAndKeepsFreshOnes() {
        let tmpdir = FileManager.default.temporaryDirectory
        let oldDate = Date().addingTimeInterval(-10 * 86_400)
        let freshDate = Date()

        func makeItem(_ url: URL, modifiedAt date: Date) {
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: url.path
            )
        }

        let evidenceDir = tmpdir.appendingPathComponent("TinyBuddyRegressionEvidence", isDirectory: true)
        try! FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        let evidenceOld = evidenceDir.appendingPathComponent("overall.status")
        makeItem(evidenceOld, modifiedAt: oldDate)
        let evidenceFresh = evidenceDir.appendingPathComponent("fresh.log")
        makeItem(evidenceFresh, modifiedAt: freshDate)
        defer { try? FileManager.default.removeItem(at: evidenceDir) }

        let benchmarkDir = tmpdir.appendingPathComponent("TinyBuddyGitBenchmark.ABC123", isDirectory: true)
        try! FileManager.default.createDirectory(at: benchmarkDir, withIntermediateDirectories: true)
        let benchmarkOld = benchmarkDir.appendingPathComponent("fixture.git")
        makeItem(benchmarkOld, modifiedAt: oldDate)
        try! FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: benchmarkDir.path
        )
        defer { try? FileManager.default.removeItem(at: benchmarkDir) }

        let probeURL = tmpdir.appendingPathComponent("tinybuddy-probe.QWERTY")
        makeItem(probeURL, modifiedAt: oldDate)
        defer { try? FileManager.default.removeItem(at: probeURL) }

        let unrelated = tmpdir.appendingPathComponent("unrelated-file-\(UUID().uuidString)")
        makeItem(unrelated, modifiedAt: oldDate)
        defer { try? FileManager.default.removeItem(at: unrelated) }

        let prefs: [String: Any] = [:]
        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil },
            appGroupContainerProvider: { tmpdir },
            retentionPolicy: RetentionPolicy(
                staleKeyMaxAgeDays: 1,
                tmpdirArtifactMaxAgeDays: 7
            )
        )

        let result = service.runCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceOld.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceFresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: benchmarkOld.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertGreaterThan(result.removedTmpdirFileCount, 0)
        XCTAssertGreaterThan(result.removedTmpdirBytes, 0)
    }

    // MARK: - Retention policy age threshold

    func testRunCleanupLeavesRecentStaleKeysWhenAgeThresholdIsHigh() {
        let today = "2026-07-20"
        let twoDaysAgo = "2026-07-18"
        var prefs: [String: Any] = [
            "tinybuddy.gitTodayCommitCount.dayIdentifier": twoDaysAgo,
            "tinybuddy.gitTodayCommitCount.count": "3"
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                if value is NSString {
                    removedKeys.append(key)
                    return true
                }
                return false
            },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Self.fixedDateForDay("2026-07-20"),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 },
            retentionPolicy: RetentionPolicy(staleKeyMaxAgeDays: 7)
        )

        let result = service.runCleanup()
        XCTAssertEqual(result.removedStaleKeys, 0)
        XCTAssertTrue(removedKeys.isEmpty)
    }

    func testRunCleanupRemovesOldStaleKeysWhenAgeThresholdIsExceeded() {
        let today = "2026-07-20"
        let thirtyDaysAgo = "2026-06-20"
        var prefs: [String: Any] = [
            "tinybuddy.gitTodayCommitCount.dayIdentifier": thirtyDaysAgo,
            "tinybuddy.gitTodayCommitCount.count": "3"
        ]
        var removedKeys: [String] = []

        let service = TinyBuddyStorageCleanupService(
            loadPreferences: { prefs },
            writeValue: { key, value in
                if value is NSString {
                    removedKeys.append(key)
                    return true
                }
                return false
            },
            removeValue: { key in
                prefs.removeValue(forKey: key)
                removedKeys.append(key)
                return true
            },
            synchronize: { true },
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Self.fixedDateForDay("2026-07-20"),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.currentSchemaVersion },
            committedRevisionProvider: { 42 },
            retentionPolicy: RetentionPolicy(staleKeyMaxAgeDays: 14)
        )

        let result = service.runCleanup()
        XCTAssertGreaterThan(result.removedStaleKeys, 0)
        XCTAssertTrue(removedKeys.contains("tinybuddy.gitTodayCommitCount.count"))
    }
}
