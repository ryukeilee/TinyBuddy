import Foundation

public struct RetentionPolicy: Sendable, Equatable {
    // Existing constraints (app group preferences)
    public let maxTotalBytes: Int
    public let maxSnapshotBytes: Int
    public let maxConfigBytes: Int
    public let maxRefreshStatusBytes: Int
    public let staleKeyMaxAgeDays: Int

    // History archive retention
    public let maxHistoryDayCount: Int
    public let maxHistoryBytes: Int64

    // Git repository cache directory limit
    public let maxGitRepositoryCacheBytes: Int64

    // TMPDIR build/release artifact age limit (0 = disable TMPDIR cleanup)
    public let tmpdirArtifactMaxAgeDays: Int

    // Minimum free disk space before diagnostic warnings (0 = disable check)
    public let minFreeDiskSpaceBytes: Int64

    public static let `default` = RetentionPolicy(
        maxTotalBytes: 512_000,
        maxSnapshotBytes: 384_000,
        maxConfigBytes: 64_000,
        maxRefreshStatusBytes: 64_000,
        staleKeyMaxAgeDays: 14,
        maxHistoryDayCount: 30,
        maxHistoryBytes: 2_097_152,
        maxGitRepositoryCacheBytes: 5_242_880,
        tmpdirArtifactMaxAgeDays: 7,
        minFreeDiskSpaceBytes: 50_000_000
    )

    public init(
        maxTotalBytes: Int = 512_000,
        maxSnapshotBytes: Int = 384_000,
        maxConfigBytes: Int = 64_000,
        maxRefreshStatusBytes: Int = 64_000,
        staleKeyMaxAgeDays: Int = 14,
        maxHistoryDayCount: Int = 30,
        maxHistoryBytes: Int64 = 2_097_152,
        maxGitRepositoryCacheBytes: Int64 = 5_242_880,
        tmpdirArtifactMaxAgeDays: Int = 7,
        minFreeDiskSpaceBytes: Int64 = 50_000_000
    ) {
        self.maxTotalBytes = maxTotalBytes
        self.maxSnapshotBytes = maxSnapshotBytes
        self.maxConfigBytes = maxConfigBytes
        self.maxRefreshStatusBytes = maxRefreshStatusBytes
        self.staleKeyMaxAgeDays = max(staleKeyMaxAgeDays, 1)
        self.maxHistoryDayCount = max(maxHistoryDayCount, 1)
        self.maxHistoryBytes = max(maxHistoryBytes, 65_536)
        self.maxGitRepositoryCacheBytes = max(maxGitRepositoryCacheBytes, 65_536)
        self.tmpdirArtifactMaxAgeDays = max(tmpdirArtifactMaxAgeDays, 0)
        self.minFreeDiskSpaceBytes = max(minFreeDiskSpaceBytes, 0)
    }
}

public struct TinyBuddyStorageUsage: Equatable, Sendable {
    // App group preferences
    public let totalEstimatedBytes: Int
    public let snapshotBytes: Int
    public let configBytes: Int
    public let refreshStatusBytes: Int
    public let staleKeyCount: Int

    // History archive
    public let historyFileCount: Int
    public let historyBytes: Int64

    // Git repository cache
    public let gitRepositoryCacheBytes: Int64
    public let gitRepositoryCacheFileCount: Int

    // TMPDIR artifacts
    public let tmpdirArtifactBytes: Int64
    public let tmpdirArtifactFileCount: Int

    // Disk
    public let freeDiskSpaceBytes: Int64

    public init(
        totalEstimatedBytes: Int = 0,
        snapshotBytes: Int = 0,
        configBytes: Int = 0,
        refreshStatusBytes: Int = 0,
        staleKeyCount: Int = 0,
        historyFileCount: Int = 0,
        historyBytes: Int64 = 0,
        gitRepositoryCacheBytes: Int64 = 0,
        gitRepositoryCacheFileCount: Int = 0,
        tmpdirArtifactBytes: Int64 = 0,
        tmpdirArtifactFileCount: Int = 0,
        freeDiskSpaceBytes: Int64 = 0
    ) {
        self.totalEstimatedBytes = totalEstimatedBytes
        self.snapshotBytes = snapshotBytes
        self.configBytes = configBytes
        self.refreshStatusBytes = refreshStatusBytes
        self.staleKeyCount = staleKeyCount
        self.historyFileCount = historyFileCount
        self.historyBytes = historyBytes
        self.gitRepositoryCacheBytes = gitRepositoryCacheBytes
        self.gitRepositoryCacheFileCount = gitRepositoryCacheFileCount
        self.tmpdirArtifactBytes = tmpdirArtifactBytes
        self.tmpdirArtifactFileCount = tmpdirArtifactFileCount
        self.freeDiskSpaceBytes = freeDiskSpaceBytes
    }
}

public struct TinyBuddyStorageCleanupResult: Equatable, Sendable {
    // App group preference cleanup
    public let removedMigrationBackup: Bool
    public let removedV1Mirror: Bool
    public let removedStaleKeys: Int

    // History archive
    public let historyRemovedFileCount: Int
    public let historyRemovedBytes: Int64
    public let historyFileCount: Int
    public let historyBytes: Int64

    // Git repository cache
    public let removedCacheBytes: Int64

    // TMPDIR artifacts
    public let removedTmpdirFileCount: Int
    public let removedTmpdirBytes: Int64

    // Overall
    public let storageUsage: TinyBuddyStorageUsage
    public let isDiskSpaceLow: Bool
    public let observation: TinyBuddySharedSnapshotObservation?

    public init(
        removedMigrationBackup: Bool = false,
        removedV1Mirror: Bool = false,
        removedStaleKeys: Int = 0,
        historyRemovedFileCount: Int = 0,
        historyRemovedBytes: Int64 = 0,
        historyFileCount: Int = 0,
        historyBytes: Int64 = 0,
        removedCacheBytes: Int64 = 0,
        removedTmpdirFileCount: Int = 0,
        removedTmpdirBytes: Int64 = 0,
        storageUsage: TinyBuddyStorageUsage = TinyBuddyStorageUsage(),
        isDiskSpaceLow: Bool = false,
        observation: TinyBuddySharedSnapshotObservation? = nil
    ) {
        self.removedMigrationBackup = removedMigrationBackup
        self.removedV1Mirror = removedV1Mirror
        self.removedStaleKeys = removedStaleKeys
        self.historyRemovedFileCount = historyRemovedFileCount
        self.historyRemovedBytes = historyRemovedBytes
        self.historyFileCount = historyFileCount
        self.historyBytes = historyBytes
        self.removedCacheBytes = removedCacheBytes
        self.removedTmpdirFileCount = removedTmpdirFileCount
        self.removedTmpdirBytes = removedTmpdirBytes
        self.storageUsage = storageUsage
        self.isDiskSpaceLow = isDiskSpaceLow
        self.observation = observation
    }
}

public final class TinyBuddyStorageCleanupService {
    public let retentionPolicy: RetentionPolicy

    private let loadPreferences: () -> [String: Any]?
    private let writeValue: (String, Any) -> Bool
    private let removeValue: (String) -> Bool
    private let synchronize: () -> Bool
    private let timeContextProvider: () -> TinyBuddyTimeContext?
    private let schemaVersionProvider: () -> Int?
    private let committedRevisionProvider: () -> Int64?
    private let fileManager: FileManager
    private let historyStoreProvider: () -> TinyBuddyHistoryStore
    private let appGroupContainerProvider: () -> URL?

    private static let lock = NSLock()
    private static let cleanupMarkerFile = ".tinybuddy-cleanup-in-progress"

    public convenience init() {
        let preferencesStore = TinyBuddyAppGroupPreferencesStore()
        let fileManager = FileManager.default
        self.init(
            loadPreferences: { preferencesStore.loadDictionary() },
            writeValue: { key, value in preferencesStore.writeValue(value, forKey: key) },
            removeValue: { key in preferencesStore.writeValue(NSString(), forKey: key) },
            synchronize: { preferencesStore.synchronize() },
            timeContextProvider: { TinyBuddyTimeEnvironment().capture() },
            schemaVersionProvider: { TinyBuddyCombinedSnapshotStore.readSchemaVersionFromAllSources() },
            committedRevisionProvider: { TinyBuddyCombinedSnapshotStore.readCommittedRevisionFromAllSources() },
            fileManager: fileManager,
            historyStoreProvider: { TinyBuddyHistoryStore() },
            appGroupContainerProvider: {
                fileManager.containerURL(
                    forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
                )
            }
        )
    }

    init(
        loadPreferences: @escaping () -> [String: Any]?,
        writeValue: @escaping (String, Any) -> Bool,
        removeValue: @escaping (String) -> Bool,
        synchronize: @escaping () -> Bool,
        timeContextProvider: @escaping () -> TinyBuddyTimeContext?,
        schemaVersionProvider: @escaping () -> Int?,
        committedRevisionProvider: @escaping () -> Int64?,
        fileManager: FileManager = .default,
        historyStoreProvider: @escaping () -> TinyBuddyHistoryStore = { TinyBuddyHistoryStore() },
        appGroupContainerProvider: @escaping () -> URL? = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
            )
        },
        retentionPolicy: RetentionPolicy = .default
    ) {
        self.loadPreferences = loadPreferences
        self.writeValue = writeValue
        self.removeValue = removeValue
        self.synchronize = synchronize
        self.timeContextProvider = timeContextProvider
        self.schemaVersionProvider = schemaVersionProvider
        self.committedRevisionProvider = committedRevisionProvider
        self.fileManager = fileManager
        self.historyStoreProvider = historyStoreProvider
        self.appGroupContainerProvider = appGroupContainerProvider
        self.retentionPolicy = retentionPolicy
    }

    // MARK: - Main cleanup entry point

    @discardableResult
    public func runCleanup() -> TinyBuddyStorageCleanupResult {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        // 1. Check for stale cleanup marker from interrupted run.
        recoverInterruptedCleanup()

        // 2. Place cleanup marker for crash recovery on file operations.
        //    If the container is unavailable (unit tests, sandbox), file-based
        //    cleanup is skipped but preference cleanup still proceeds.
        let hasMarker = placeCleanupMarker()
        if hasMarker {
            defer { removeCleanupMarker() }
        }

        // 3. Run preference-level cleanup.
        guard let preferences = loadPreferences() else {
            let usage = gatherAllStorageUsage(preferences: nil)
            return TinyBuddyStorageCleanupResult(
                storageUsage: usage,
                observation: TinyBuddySharedSnapshotObservation(
                    phase: .snapshotWrite,
                    reason: .appGroupUnavailable,
                    recovery: .stopped,
                    attemptCount: 1
                )
            )
        }

        let (removedMigrationBackup, removedV1Mirror, removedStaleKeys) = cleanupPreferencesLocked(preferences)
        if removedMigrationBackup || removedV1Mirror || removedStaleKeys > 0 {
            _ = synchronize()
        }

        // 4-6. File-based cleanup requires the app group container (marker).
        //    Without it, these steps are silently skipped. This is the normal
        //    state in unit tests or sandboxed processes without the container.
        let historyResult: TinyBuddyHistoryStore.CleanupResult
        let removedCacheBytes: Int64
        let removedTmpdirCount: Int
        let removedTmpdirBytes: Int64
        if hasMarker {
            historyResult = cleanupHistoryLocked()
            removedCacheBytes = cleanupGitRepositoryCacheLocked()
            (removedTmpdirCount, removedTmpdirBytes) = cleanupTmpdirArtifactsLocked()
        } else {
            historyResult = TinyBuddyHistoryStore.CleanupResult(didComplete: true)
            removedCacheBytes = 0
            removedTmpdirCount = 0
            removedTmpdirBytes = 0
        }

        // 7. Gather comprehensive storage usage.
        let usage = gatherAllStorageUsage(preferences: preferences)
        // Free-space values <= 0 mean the capacity is unknown (e.g., no App Group
        // container in unit tests). Only report low disk space when we have a
        // positive measurement below the threshold.
        let isDiskSpaceLow = usage.freeDiskSpaceBytes > 0
            && usage.freeDiskSpaceBytes < retentionPolicy.minFreeDiskSpaceBytes

        // 8. Build observation.
        let observation = makeObservation(usage: usage, isDiskSpaceLow: isDiskSpaceLow)

        return TinyBuddyStorageCleanupResult(
            removedMigrationBackup: removedMigrationBackup,
            removedV1Mirror: removedV1Mirror,
            removedStaleKeys: removedStaleKeys,
            historyRemovedFileCount: historyResult.removedFileCount,
            historyRemovedBytes: historyResult.removedBytes,
            historyFileCount: historyResult.finalFileCount,
            historyBytes: historyResult.finalSizeBytes,
            removedCacheBytes: removedCacheBytes,
            removedTmpdirFileCount: removedTmpdirCount,
            removedTmpdirBytes: removedTmpdirBytes,
            storageUsage: usage,
            isDiskSpaceLow: isDiskSpaceLow,
            observation: observation
        )
    }

    // MARK: - Storage usage estimation

    public func estimateStorageUsage() -> TinyBuddyStorageUsage {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let preferences = loadPreferences() ?? [:]
        return gatherAllStorageUsage(preferences: preferences)
    }

    // MARK: - Preference cleanup internals

    private func cleanupPreferencesLocked(
        _ preferences: [String: Any]
    ) -> (removedMigrationBackup: Bool, removedV1Mirror: Bool, removedStaleKeys: Int) {
        var removedMigrationBackup = false
        var removedV1Mirror = false
        var removedStaleKeys = 0

        let currentSchema = schemaVersionProvider()
        let committedRevision = committedRevisionProvider()

        if currentSchema == TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
           let committedRevision,
           committedRevision > 0 {
            if preferences[TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1] != nil {
                let result = writeValue(TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1, NSString())
                if result {
                    removedMigrationBackup = true
                }
            }

            if TinyBuddyCombinedSnapshotStore.currentSchemaVersion >= 3,
               committedRevision > 0,
               preferences[TinyBuddyCombinedSnapshotStore.Key.snapshot] != nil {
                let result = writeValue(TinyBuddyCombinedSnapshotStore.Key.snapshot, NSString())
                if result {
                    removedV1Mirror = true
                }
            }
        }

        let context = timeContextProvider()
        if let todayId = context?.dayIdentifier {
            let staleKeys = findStaleKeys(in: preferences, todayIdentifier: todayId)
            for key in staleKeys {
                if writeValue(key, NSString()) {
                    removedStaleKeys += 1
                }
            }
        }

        return (removedMigrationBackup, removedV1Mirror, removedStaleKeys)
    }

    // MARK: - History archive cleanup

    private func cleanupHistoryLocked() -> TinyBuddyHistoryStore.CleanupResult {
        let store = historyStoreProvider()
        return store.pruneExcess()
    }

    // MARK: - Git repository cache cleanup

    private func cleanupGitRepositoryCacheLocked() -> Int64 {
        guard let cacheURL = gitRepositoryCacheURL,
              fileManager.fileExists(atPath: cacheURL.path) else {
            return 0
        }

        // Compute total directory size.
        let totalSize = directorySize(url: cacheURL)
        guard totalSize > retentionPolicy.maxGitRepositoryCacheBytes else {
            return 0
        }

        // Remove oldest files until under limit. Sort by modification date.
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: cacheURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return 0
        }

        let sorted = fileURLs.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap { $0.contentModificationDate } ?? Date.distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap { $0.contentModificationDate } ?? Date.distantPast
            return lDate < rDate
        }

        var removedBytes: Int64 = 0
        var currentSize = totalSize

        for fileURL in sorted {
            guard currentSize > retentionPolicy.maxGitRepositoryCacheBytes else {
                break
            }
            let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))
                .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
            if (try? fileManager.removeItem(at: fileURL)) != nil {
                removedBytes += size
                currentSize -= size
            }
        }

        return removedBytes
    }

    // MARK: - TMPDIR artifact cleanup

    private func cleanupTmpdirArtifactsLocked() -> (fileCount: Int, byteCount: Int64) {
        guard retentionPolicy.tmpdirArtifactMaxAgeDays > 0 else {
            return (0, 0)
        }

        let tmpdir = FileManager.default.temporaryDirectory
        let artifactDirs = [
            "TinyBuddyBuildLogs",
            "TinyBuddyReleaseEvidence"
        ]

        let cutoffDate = Date().addingTimeInterval(
            TimeInterval(-retentionPolicy.tmpdirArtifactMaxAgeDays * 86_400)
        )

        var removedCount = 0
        var removedBytes: Int64 = 0

        for dirName in artifactDirs {
            let dirURL = tmpdir.appendingPathComponent(dirName, isDirectory: true)
            guard fileManager.fileExists(atPath: dirURL.path) else {
                continue
            }

            guard let contents = try? fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for itemURL in contents {
                let attrs = try? fileManager.attributesOfItem(atPath: itemURL.path)
                let modDate = attrs?[.modificationDate] as? Date ?? Date.distantPast
                guard modDate < cutoffDate else {
                    continue
                }
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                if (try? fileManager.removeItem(at: itemURL)) != nil {
                    removedCount += 1
                    removedBytes += size
                }
            }

            // Remove the directory itself if empty and old.
            if let remainingContents = try? fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ), remainingContents.isEmpty {
                let dirAttrs = try? fileManager.attributesOfItem(atPath: dirURL.path)
                let dirModDate = dirAttrs?[.modificationDate] as? Date ?? Date.distantPast
                if dirModDate < cutoffDate {
                    try? fileManager.removeItem(at: dirURL)
                }
            }
        }

        return (removedCount, removedBytes)
    }

    // MARK: - Disk space

    private func freeDiskSpaceBytes() -> Int64 {
        guard let containerURL = appGroupContainerProvider() else {
            return -1
        }
        let values = try? containerURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return (values?.volumeAvailableCapacity).map(Int64.init) ?? -1
    }

    // MARK: - Comprehensive usage

    private func gatherAllStorageUsage(preferences: [String: Any]?) -> TinyBuddyStorageUsage {
        let prefsUsage = preferences.map { estimatePreferencesUsage($0) }
            ?? TinyBuddyStorageUsage()

        let (historyBytesResult, historyFileCountResult) = historyStoreProvider().archiveSize()

        let (cacheBytes, cacheFileCount) = gitRepositoryCacheSize()

        let (tmpdirBytes, tmpdirFileCount) = tmpdirArtifactSize()

        let freeBytes = freeDiskSpaceBytes()

        return TinyBuddyStorageUsage(
            totalEstimatedBytes: prefsUsage.totalEstimatedBytes,
            snapshotBytes: prefsUsage.snapshotBytes,
            configBytes: prefsUsage.configBytes,
            refreshStatusBytes: prefsUsage.refreshStatusBytes,
            staleKeyCount: prefsUsage.staleKeyCount,
            historyFileCount: historyFileCountResult,
            historyBytes: historyBytesResult,
            gitRepositoryCacheBytes: cacheBytes,
            gitRepositoryCacheFileCount: cacheFileCount,
            tmpdirArtifactBytes: tmpdirBytes,
            tmpdirArtifactFileCount: tmpdirFileCount,
            freeDiskSpaceBytes: freeBytes
        )
    }

    private func estimatePreferencesUsage(_ preferences: [String: Any]) -> TinyBuddyStorageUsage {
        var snapshotBytes = 0
        var configBytes = 0
        var refreshStatusBytes = 0
        var totalBytes = 0

        for (key, value) in preferences {
            let bytes = key.utf8.count + estimatedValueSize(value)
            totalBytes += bytes

            if key.hasPrefix("tinybuddy.combinedSnapshot.") || key.hasPrefix("tinybuddy.combinedSnapshot.v2.") {
                snapshotBytes += bytes
            } else if key.hasPrefix("tinybuddy.appConfig.") {
                configBytes += bytes
            } else if key.hasPrefix("tinybuddy.gitRefreshStatus.") {
                refreshStatusBytes += bytes
            }
        }

        let staleCount = preferences.keys.filter(isKnownStaleKey).count

        return TinyBuddyStorageUsage(
            totalEstimatedBytes: totalBytes,
            snapshotBytes: snapshotBytes,
            configBytes: configBytes,
            refreshStatusBytes: refreshStatusBytes,
            staleKeyCount: staleCount
        )
    }

    // MARK: - Observation

    private func makeObservation(
        usage: TinyBuddyStorageUsage,
        isDiskSpaceLow: Bool
    ) -> TinyBuddySharedSnapshotObservation? {
        let hasPreferenceOverflow = usage.totalEstimatedBytes > retentionPolicy.maxTotalBytes
            || usage.snapshotBytes > retentionPolicy.maxSnapshotBytes
            || usage.configBytes > retentionPolicy.maxConfigBytes
            || usage.refreshStatusBytes > retentionPolicy.maxRefreshStatusBytes
        let hasHistoryOverflow = usage.historyBytes > retentionPolicy.maxHistoryBytes
            || usage.historyFileCount > retentionPolicy.maxHistoryDayCount
        let hasCacheOverflow = usage.gitRepositoryCacheBytes > retentionPolicy.maxGitRepositoryCacheBytes

        // TMPDIR artifacts are in a temporary directory that does not affect
        // snapshot persistence. They are cleaned by age but do not produce
        // observations.

        guard hasPreferenceOverflow || hasHistoryOverflow || hasCacheOverflow || isDiskSpaceLow else {
            return nil
        }

        if isDiskSpaceLow {
            return TinyBuddySharedSnapshotObservation(
                phase: .snapshotWrite,
                reason: .persistenceFailed,
                recovery: .stopped,
                attemptCount: 1
            )
        }

        return TinyBuddySharedSnapshotObservation(
            phase: .snapshotWrite,
            reason: .persistenceFailed,
            recovery: .rebuilt,
            attemptCount: 1
        )
    }

    // MARK: - Crash recovery

    private func recoverInterruptedCleanup() {
        guard let markerURL = cleanupMarkerURL,
              fileManager.fileExists(atPath: markerURL.path) else {
            return
        }
        // A previous cleanup was interrupted. Remove the marker so cleanup can
        // proceed normally. Any half-deleted files from the interrupted run are
        // idempotently handled: already-removed files will be skipped, and
        // remaining files will be processed by the current cleanup cycle.
        try? fileManager.removeItem(at: markerURL)
    }

    private func placeCleanupMarker() -> Bool {
        guard let markerURL = cleanupMarkerURL else {
            return false
        }
        let markerDir = markerURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: markerDir.path) {
            try? fileManager.createDirectory(
                at: markerDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        guard (try? Self.cleanupMarkerString.data(using: .utf8)?
            .write(to: markerURL, options: .atomic)) != nil else {
            return false
        }
        return true
    }

    private func removeCleanupMarker() {
        guard let markerURL = cleanupMarkerURL else { return }
        try? fileManager.removeItem(at: markerURL)
    }

    private func interruptedResult() -> TinyBuddyStorageCleanupResult {
        TinyBuddyStorageCleanupResult(
            storageUsage: gatherAllStorageUsage(preferences: loadPreferences()),
            observation: TinyBuddySharedSnapshotObservation(
                phase: .snapshotWrite,
                reason: .persistenceFailed,
                recovery: .stopped,
                attemptCount: 1
            )
        )
    }

    // MARK: - Paths

    private var cleanupMarkerURL: URL? {
        appGroupContainerProvider()?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("com.ryukeili.TinyBuddy", isDirectory: true)
            .appendingPathComponent(Self.cleanupMarkerFile)
    }

    private var gitRepositoryCacheURL: URL? {
        appGroupContainerProvider()?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(".tinybuddy-git-repository-cache")
    }

    // MARK: - Size helpers

    private func gitRepositoryCacheSize() -> (bytes: Int64, fileCount: Int) {
        guard let cacheURL = gitRepositoryCacheURL,
              fileManager.fileExists(atPath: cacheURL.path) else {
            return (0, 0)
        }
        return directorySizeAndCount(url: cacheURL)
    }

    private func tmpdirArtifactSize() -> (bytes: Int64, fileCount: Int) {
        let tmpdir = FileManager.default.temporaryDirectory
        let dirs = ["TinyBuddyBuildLogs", "TinyBuddyReleaseEvidence"]
        var totalBytes: Int64 = 0
        var totalCount = 0

        for dirName in dirs {
            let dirURL = tmpdir.appendingPathComponent(dirName, isDirectory: true)
            guard fileManager.fileExists(atPath: dirURL.path) else {
                continue
            }
            let (bytes, count) = directorySizeAndCount(url: dirURL)
            totalBytes += bytes
            totalCount += count
        }

        return (totalBytes, totalCount)
    }

    private func directorySize(url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    private func directorySizeAndCount(url: URL) -> (Int64, Int) {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var totalBytes: Int64 = 0
        var totalCount = 0
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                  !isDir.boolValue else {
                continue
            }
            guard let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                continue
            }
            totalBytes += Int64(size)
            totalCount += 1
        }
        return (totalBytes, totalCount)
    }

    // MARK: - Stale key detection

    private func findStaleKeys(
        in preferences: [String: Any],
        todayIdentifier: String
    ) -> [String] {
        findKeysOlderThan(in: preferences, todayIdentifier: todayIdentifier, maxAgeDays: retentionPolicy.staleKeyMaxAgeDays)
    }

    private func findKeysOlderThan(
        in preferences: [String: Any],
        todayIdentifier: String,
        maxAgeDays: Int
    ) -> [String] {
        var stale: [String] = []

        let perStorePrefixes = [
            "tinybuddy.gitTodayCommitCount.",
            "tinybuddy.gitTodayFocusBlockCount.",
            "tinybuddy.gitTodayRecentProject."
        ]

        for prefix in perStorePrefixes {
            let dayKey = "\(prefix)dayIdentifier"
            guard let storedDay = preferences[dayKey] as? String,
                  TinyBuddyTimeContext.isValidDayIdentifier(storedDay) else {
                continue
            }

            if storedDay == todayIdentifier {
                continue
            }

            let ageDays = daysBetween(dayIdentifier: storedDay, and: todayIdentifier)
            if ageDays < maxAgeDays {
                continue
            }

            let countKey = "\(prefix)count"
            let projectKey = "\(prefix)projectName"

            if preferences[countKey] != nil {
                stale.append(countKey)
            }
            if preferences[projectKey] != nil {
                stale.append(projectKey)
            }
        }

        return stale
    }

    private static let dayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func daysBetween(dayIdentifier: String, and otherDayIdentifier: String) -> Int {
        guard let date = Self.dayDateFormatter.date(from: dayIdentifier),
              let otherDate = Self.dayDateFormatter.date(from: otherDayIdentifier) else {
            return Int.max
        }
        let seconds = otherDate.timeIntervalSince(date)
        let days = Int(seconds / 86_400)
        return abs(days)
    }

    private func isKnownStaleKey(_ key: String) -> Bool {
        let stalePrefixes = [
            "tinybuddy.gitTodayCommitCount.",
            "tinybuddy.gitTodayFocusBlockCount.",
            "tinybuddy.gitTodayRecentProject.",
            "tinybuddy.dailyStats.",
            "tinybuddy.currentStatus",
            "tinybuddy.gitTodayActivity.trustedSnapshot"
        ]
        return stalePrefixes.contains { key.hasPrefix($0) }
    }

    private func estimatedValueSize(_ value: Any) -> Int {
        if let string = value as? String {
            return string.utf8.count
        }
        if let data = value as? Data {
            return data.count
        }
        if value is NSNumber {
            return 8
        }
        if value is Date {
            return 8
        }
        if let dict = value as? [String: Any] {
            var size = 0
            for (k, v) in dict {
                size += k.utf8.count + estimatedValueSize(v)
            }
            return size
        }
        if let array = value as? [Any] {
            var size = 0
            for element in array {
                size += estimatedValueSize(element)
            }
            return size
        }
        return 0
    }

    private static let cleanupMarkerString = "cleanup"
}

extension TinyBuddyCombinedSnapshotStore {
    public static func readSchemaVersionFromAllSources() -> Int? {
        let direct = TinyBuddyAppGroupPreferencesStore().loadDictionary() ?? [:]
        if let marker = direct[Key.schemaVersion] as? String,
           let version = decodeSchemaVersion(marker) {
            return version
        }
        if let shared = TinyBuddySharedData.loadAppGroupPreferencesDictionary(),
           let marker = shared[Key.schemaVersion] as? String,
           let version = decodeSchemaVersion(marker) {
            return version
        }
        return nil
    }

    public static func readCommittedRevisionFromAllSources() -> Int64? {
        let direct = TinyBuddyAppGroupPreferencesStore().loadDictionary() ?? [:]
        if let marker = direct[Key.committedRevisionV2] as? String,
           let revision = decodeRevisionMarker(marker) {
            return revision
        }
        if let shared = TinyBuddySharedData.loadAppGroupPreferencesDictionary(),
           let marker = shared[Key.committedRevisionV2] as? String,
           let revision = decodeRevisionMarker(marker) {
            return revision
        }
        return nil
    }
}
