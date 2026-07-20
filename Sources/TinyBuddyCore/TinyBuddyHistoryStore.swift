import Foundation

/// Retention policy for historical daily snapshot archives.
public struct TinyBuddyHistoryRetentionPolicy: Sendable, Equatable {
    /// Maximum number of historical daily snapshots to retain.
    public let maxDayCount: Int
    /// Maximum total size in bytes for the history archive directory.
    public let maxTotalBytes: Int64

    public static let `default` = TinyBuddyHistoryRetentionPolicy(
        maxDayCount: 30,
        maxTotalBytes: 2_097_152  // 2 MB
    )

    public init(
        maxDayCount: Int = 30,
        maxTotalBytes: Int64 = 2_097_152
    ) {
        self.maxDayCount = max(maxDayCount, 1)
        self.maxTotalBytes = max(maxTotalBytes, 1024)
    }
}

public struct TinyBuddyHistoryArchiveResult: Equatable, Sendable {
    public let archivedDayIdentifiers: [String]
    public let removedExcessCount: Int
    public let totalSizeBytes: Int64
    public let totalFileCount: Int

    public init(
        archivedDayIdentifiers: [String] = [],
        removedExcessCount: Int = 0,
        totalSizeBytes: Int64 = 0,
        totalFileCount: Int = 0
    ) {
        self.archivedDayIdentifiers = archivedDayIdentifiers
        self.removedExcessCount = removedExcessCount
        self.totalSizeBytes = totalSizeBytes
        self.totalFileCount = totalFileCount
    }
}

/// Manages versioned daily snapshot history in the App Group container's cache
/// directory. Historical snapshots are stored as individual compressed V3-format
/// files keyed by day identifier. The archive is rebuildable from subsequent git
/// refreshes and thus follows cache lifecycle rules.
///
/// Each file is a UTF-8 encoded V3 combined snapshot string. Files are named
/// `<dayIdentifier>.snapshot` (e.g., `2026-07-20.snapshot`).
public final class TinyBuddyHistoryStore {
    public enum ReadResult: Equatable, Sendable {
        case available(TinyBuddyCombinedSnapshot)
        case notFound
        case corrupt
    }

    public struct CleanupResult: Equatable, Sendable {
        public let removedFileCount: Int
        public let removedBytes: Int64
        public let finalFileCount: Int
        public let finalSizeBytes: Int64
        public let didComplete: Bool

        public init(
            removedFileCount: Int = 0,
            removedBytes: Int64 = 0,
            finalFileCount: Int = 0,
            finalSizeBytes: Int64 = 0,
            didComplete: Bool = true
        ) {
            self.removedFileCount = removedFileCount
            self.removedBytes = removedBytes
            self.finalFileCount = finalFileCount
            self.finalSizeBytes = finalSizeBytes
            self.didComplete = didComplete
        }
    }

    private let fileManager: FileManager
    private let snapshotEncoder: (TinyBuddyCombinedSnapshot) -> String?
    private let snapshotDecoder: (String) -> TinyBuddyCombinedSnapshot?
    private let retentionPolicy: TinyBuddyHistoryRetentionPolicy
    private let customContainerURL: URL?

    private static let lock = NSLock()
    private static let snapshotFileExtension = "snapshot"
    private static let cleanupMarkerFile = ".cleanup-in-progress"

    public convenience init(
        retentionPolicy: TinyBuddyHistoryRetentionPolicy = .default
    ) {
        self.init(
            fileManager: .default,
            snapshotEncoder: TinyBuddyCombinedSnapshotStore.encodeV3,
            snapshotDecoder: TinyBuddyCombinedSnapshotStore.decodeV3,
            retentionPolicy: retentionPolicy,
            customContainerURL: nil
        )
    }

    /// Test-only init with an explicit container URL. When nil, falls back to
    /// the App Group container.
    init(
        fileManager: FileManager = .default,
        snapshotEncoder: @escaping (TinyBuddyCombinedSnapshot) -> String?,
        snapshotDecoder: @escaping (String) -> TinyBuddyCombinedSnapshot?,
        retentionPolicy: TinyBuddyHistoryRetentionPolicy = .default,
        customContainerURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.snapshotEncoder = snapshotEncoder
        self.snapshotDecoder = snapshotDecoder
        self.retentionPolicy = retentionPolicy
        self.customContainerURL = customContainerURL
    }

    // MARK: - Public API

    /// Archives the current combined snapshot to a day-specific history file.
    /// The snapshot is stored in V3 compressed format. Older snapshots for the
    /// same day are overwritten. Returns the archived day identifier on success.
    @discardableResult
    public func archiveSnapshot(
        _ snapshot: TinyBuddyCombinedSnapshot
    ) -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard TinyBuddyTimeContext.isValidDayIdentifier(snapshot.dayIdentifier),
              let encoded = snapshotEncoder(snapshot),
              let directoryURL = historyDirectoryURL else {
            return nil
        }

        guard ensureDirectoryExists(directoryURL) else {
            return nil
        }

        let fileURL = snapshotFileURL(for: snapshot.dayIdentifier, in: directoryURL)

        // Write atomically to prevent partial files on crash.
        let data = Data(encoded.utf8)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        return snapshot.dayIdentifier
    }

    /// Reads a historical snapshot for a given day identifier.
    public func readSnapshot(for dayIdentifier: String) -> ReadResult {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard TinyBuddyTimeContext.isValidDayIdentifier(dayIdentifier),
              let directoryURL = historyDirectoryURL else {
            return .notFound
        }

        let fileURL = snapshotFileURL(for: dayIdentifier, in: directoryURL)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .notFound
        }

        guard let data = try? Data(contentsOf: fileURL),
              let encoded = String(data: data, encoding: .utf8),
              let snapshot = snapshotDecoder(encoded) else {
            return .corrupt
        }

        return .available(snapshot)
    }

    /// Lists all archived day identifiers sorted newest-first.
    public func archivedDayIdentifiers() -> [String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard let directoryURL = historyDirectoryURL,
              let fileURLs = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.nameKey],
                options: .skipsHiddenFiles
              ) else {
            return []
        }

        return fileURLs
            .filter { $0.pathExtension == Self.snapshotFileExtension }
            .compactMap { dayIdentifier(from: $0) }
            .sorted(by: >)
    }

    /// Returns archive size and file count.
    public func archiveSize() -> (byteCount: Int64, fileCount: Int) {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        return computeArchiveSize()
    }

    /// Removes excess historical snapshots according to retention policy.
    /// Returns a cleanup result. This is safe to call on every refresh cycle
    /// because it only removes files that exceed policy limits.
    @discardableResult
    public func pruneExcess() -> CleanupResult {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        return pruneExcessLocked()
    }

    /// Removes all history files. Returns the count of removed files.
    @discardableResult
    public func clearAll() -> Int {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard let directoryURL = historyDirectoryURL,
              let fileURLs = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
              ) else {
            return 0
        }

        var removed = 0
        for fileURL in fileURLs {
            guard fileURL.pathExtension == Self.snapshotFileExtension else {
                continue
            }
            if (try? fileManager.removeItem(at: fileURL)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Paths

    /// Internal for test access.
    var historyDirectoryURL: URL? {
        let containerURL: URL?
        if let customContainerURL {
            containerURL = customContainerURL
        } else {
            containerURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
            )
        }
        guard let containerURL else {
            return nil
        }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("com.ryukeili.TinyBuddy", isDirectory: true)
            .appendingPathComponent("SnapshotHistory", isDirectory: true)
    }

    private func snapshotFileURL(
        for dayIdentifier: String,
        in directoryURL: URL
    ) -> URL {
        directoryURL
            .appendingPathComponent(dayIdentifier)
            .appendingPathExtension(Self.snapshotFileExtension)
    }

    private func dayIdentifier(from fileURL: URL) -> String? {
        let name = fileURL.deletingPathExtension().lastPathComponent
        guard TinyBuddyTimeContext.isValidDayIdentifier(name) else {
            return nil
        }
        return name
    }

    // MARK: - Internal

    private func ensureDirectoryExists(_ url: URL) -> Bool {
        guard !fileManager.fileExists(atPath: url.path) else {
            return true
        }
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return true
        } catch {
            return false
        }
    }

    private func computeArchiveSize() -> (Int64, Int) {
        guard let directoryURL = historyDirectoryURL,
              let fileURLs = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .nameKey],
                options: .skipsHiddenFiles
              ) else {
            return (0, 0)
        }

        var totalBytes: Int64 = 0
        var count = 0
        for fileURL in fileURLs {
            guard fileURL.pathExtension == Self.snapshotFileExtension else {
                continue
            }
            if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? NSNumber {
                totalBytes += size.int64Value
            }
            count += 1
        }
        return (totalBytes, count)
    }

    @discardableResult
    private func pruneExcessLocked() -> CleanupResult {
        guard let directoryURL = historyDirectoryURL,
              fileManager.fileExists(atPath: directoryURL.path) else {
            return CleanupResult(didComplete: true)
        }

        // 1. Check for stale cleanup marker from a previous interrupted run.
        let markerURL = directoryURL.appendingPathComponent(Self.cleanupMarkerFile)
        let hadStaleMarker = fileManager.fileExists(atPath: markerURL.path)
        if hadStaleMarker {
            // A previous cleanup was interrupted. Remove the marker and retry.
            try? fileManager.removeItem(at: markerURL)
        }

        // 2. Place the cleanup marker atomically.
        guard (try? Self.cleanupMarker.data(
            using: .utf8
        )?.write(to: markerURL, options: .atomic)) != nil else {
            return CleanupResult(didComplete: false)
        }
        defer { try? fileManager.removeItem(at: markerURL) }

        // 3. Collect all snapshot files.
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .nameKey],
            options: .skipsHiddenFiles
        ) else {
            return CleanupResult(didComplete: true)
        }

        let snapshotFiles = fileURLs.filter { $0.pathExtension == Self.snapshotFileExtension }

        // 4. Compute current size.
        var totalBytes: Int64 = 0
        var fileDetails: [(url: URL, size: Int64, dayIdentifier: String)] = []
        for fileURL in snapshotFiles {
            guard let dayId = dayIdentifier(from: fileURL) else {
                continue
            }
            let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))
                .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
            totalBytes += size
            fileDetails.append((fileURL, size, dayId))
        }

        // 5. Sort by day descending (newest first).
        fileDetails.sort { $0.dayIdentifier > $1.dayIdentifier }

        var removedCount = 0
        var removedBytes: Int64 = 0

        // 6. Remove excess by count limit (keep newest N).
        if fileDetails.count > retentionPolicy.maxDayCount {
            let excess = fileDetails.suffix(fileDetails.count - retentionPolicy.maxDayCount)
            for entry in excess {
                if (try? fileManager.removeItem(at: entry.url)) != nil {
                    removedCount += 1
                    removedBytes += entry.size
                    totalBytes -= entry.size
                }
            }
            fileDetails = Array(fileDetails.prefix(retentionPolicy.maxDayCount))
        }

        // 7. Remove excess by size limit (remove oldest until under limit).
        if totalBytes > retentionPolicy.maxTotalBytes {
            for entry in fileDetails.reversed() {
                guard totalBytes > retentionPolicy.maxTotalBytes else {
                    break
                }
                if (try? fileManager.removeItem(at: entry.url)) != nil {
                    removedCount += 1
                    removedBytes += entry.size
                    totalBytes -= entry.size
                }
            }
        }

        return CleanupResult(
            removedFileCount: removedCount,
            removedBytes: removedBytes,
            finalFileCount: fileDetails.count - removedCount,
            finalSizeBytes: totalBytes,
            didComplete: true
        )
    }

    private static let cleanupMarker = "cleanup"
}
