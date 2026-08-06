import Foundation
import OSLog

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
    /// Supplies the current local day identifier. Cleanup never removes the
    /// current day (or later, possibly future-dated) snapshot files, so a
    /// clock skew or timezone change cannot discard the active day's history.
    private let currentDayIdentifierProvider: () -> String?
    /// Isolates corrupted or unrecognized history files so they never re-enter
    /// the readable archive and never accumulate as unmanaged junk.
    private let quarantineProvider: () -> TinyBuddyCorruptedRecordQuarantine?

    private static let lock = NSLock()
    private static let snapshotFileExtension = "snapshot"
    private static let cleanupMarkerFile = ".cleanup-in-progress"
    private let logger = Logger(subsystem: "local.tinybuddy", category: "TinyBuddyHistoryStore")

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
    /// the App Group container. The current-day provider defaults to the real
    /// local day; tests inject a fixed identifier so pruning is deterministic.
    init(
        fileManager: FileManager = .default,
        snapshotEncoder: @escaping (TinyBuddyCombinedSnapshot) -> String?,
        snapshotDecoder: @escaping (String) -> TinyBuddyCombinedSnapshot?,
        retentionPolicy: TinyBuddyHistoryRetentionPolicy = .default,
        customContainerURL: URL? = nil,
        currentDayIdentifierProvider: @escaping () -> String? = {
            TinyBuddyTimeEnvironment().capture()?.dayIdentifier
        },
        quarantine: TinyBuddyCorruptedRecordQuarantine? = nil
    ) {
        self.fileManager = fileManager
        self.snapshotEncoder = snapshotEncoder
        self.snapshotDecoder = snapshotDecoder
        self.retentionPolicy = retentionPolicy
        self.customContainerURL = customContainerURL
        self.currentDayIdentifierProvider = currentDayIdentifierProvider
        if let quarantine {
            self.quarantineProvider = { quarantine }
        } else {
            let lazilyCreated = TinyBuddyCorruptedRecordQuarantine()
            self.quarantineProvider = { lazilyCreated }
        }
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

        guard TinyBuddyTimeContext.isValidDayIdentifier(snapshot.dayIdentifier) else {
            return nil
        }

        // Validate before archiving — reject snapshots with critical violations.
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        let criticalViolations = violations.filter { $0.severity == .critical }
        if !criticalViolations.isEmpty {
            logger.debug("archiveSnapshot(\(snapshot.dayIdentifier, privacy: .public)): rejected — \(criticalViolations.count) critical violation(s)")
            for v in criticalViolations {
                logger.debug("[critical] \(v.description, privacy: .public)")
            }
            return nil
        }
        if !violations.isEmpty {
            logger.debug("archiveSnapshot(\(snapshot.dayIdentifier, privacy: .public)): \(violations.count) non-critical violation(s)")
        }

        guard let encoded = snapshotEncoder(snapshot),
              let directoryURL = historyDirectoryURL else {
            return nil
        }

        guard ensureDirectoryExists(directoryURL) else {
            return nil
        }

        let fileURL = snapshotFileURL(for: snapshot.dayIdentifier, in: directoryURL)

        // Write atomically to prevent partial files on crash, then read back
        // and decode so an interrupted or silently corrupt write is never
        // accepted as archived history. The read-back failure removes the
        // file and reports failure; the source snapshot itself is untouched.
        let data = Data(encoded.utf8)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }
        guard let writtenData = try? Data(contentsOf: fileURL),
              let writtenString = String(data: writtenData, encoding: .utf8),
              snapshotDecoder(writtenString) != nil else {
            try? fileManager.removeItem(at: fileURL)
            logger.debug("archiveSnapshot(\(snapshot.dayIdentifier, privacy: .public)): read-back verification failed; removed partial file")
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
            // Isolate the corrupted file so it cannot re-enter the readable
            // archive or accumulate as unmanaged data. The quarantine keeps a
            // redacted copy; the active archive drops the file atomically.
            isolateCorruptFile(at: fileURL, dayIdentifier: dayIdentifier, reason: "decodeFailed")
            return .corrupt
        }

        // Validate decoded snapshot for invariant violations.
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        let criticalViolations = violations.filter { $0.severity == .critical }
        if !violations.isEmpty {
            logger.debug("readSnapshot(\(dayIdentifier, privacy: .public)): \(violations.count) violation(s) (\(criticalViolations.count) critical)")
            for violation in violations {
                logger.debug("[\(violation.severity.rawValue, privacy: .public)] \(violation.description, privacy: .public)")
            }
        }
        if !criticalViolations.isEmpty {
            isolateCorruptFile(at: fileURL, dayIdentifier: dayIdentifier, reason: "invalidSnapshot")
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

        // 4. Compute current size. Unrecognized files that look like snapshot
        //    attempts (valid extension, invalid day name) are corrupted or
        //    foreign data: isolate them into quarantine and remove them from
        //    the active archive so they cannot accumulate without bound.
        var totalBytes: Int64 = 0
        var removedJunkCount = 0
        var fileDetails: [(url: URL, size: Int64, dayIdentifier: String)] = []
        for fileURL in snapshotFiles {
            guard let dayId = dayIdentifier(from: fileURL) else {
                if isolateCorruptFile(at: fileURL, dayIdentifier: nil, reason: "unrecognizedDayIdentifier") {
                    removedJunkCount += 1
                }
                continue
            }
            let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))
                .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
            totalBytes += size
            fileDetails.append((fileURL, size, dayId))
        }

        // 5. Sort by day descending (newest first).
        fileDetails.sort { $0.dayIdentifier > $1.dayIdentifier }
        let initialValidCount = fileDetails.count

        // 5a. Never remove the current local day (or any later, possibly
        //     future-dated file from a clock adjustment). This preserves the
        //     active day's snapshot, including any in-progress focus session
        //     state, under every cleanup condition (startup, cross-day, low
        //     disk, interrupted cleanup, concurrent writes).
        let currentDay = currentDayIdentifierProvider()
        let isProtected: (String) -> Bool = { day in
            guard let currentDay else { return false }
            return day >= currentDay
        }

        // 6. Remove excess by count limit (keep newest N, never protected).
        var removedExcessCount = 0
        var removedBytes: Int64 = 0
        if fileDetails.count > retentionPolicy.maxDayCount {
            // Candidates for removal are the entries beyond the newest
            // `maxDayCount`, examined oldest-first; protected days are skipped.
            var keptCount = fileDetails.count
            for entry in fileDetails.reversed() where keptCount > retentionPolicy.maxDayCount {
                guard !isProtected(entry.dayIdentifier) else {
                    continue
                }
                if (try? fileManager.removeItem(at: entry.url)) != nil {
                    removedExcessCount += 1
                    removedBytes += entry.size
                    totalBytes -= entry.size
                    keptCount -= 1
                }
            }
            fileDetails.removeAll { !fileManager.fileExists(atPath: $0.url.path) }
        }

        // 7. Remove excess by size limit (remove oldest until under limit,
        //    never removing a protected day).
        if totalBytes > retentionPolicy.maxTotalBytes {
            for entry in fileDetails.reversed() {
                guard totalBytes > retentionPolicy.maxTotalBytes else {
                    break
                }
                guard !isProtected(entry.dayIdentifier) else {
                    continue
                }
                if (try? fileManager.removeItem(at: entry.url)) != nil {
                    removedExcessCount += 1
                    removedBytes += entry.size
                    totalBytes -= entry.size
                }
            }
        }

        let finalFileCount = max(0, initialValidCount - removedExcessCount)

        return CleanupResult(
            removedFileCount: removedJunkCount + removedExcessCount,
            removedBytes: removedBytes,
            finalFileCount: finalFileCount,
            finalSizeBytes: max(0, totalBytes),
            didComplete: true
        )
    }

    /// Moves a corrupted or unrecognized history file out of the active
    /// archive into the quarantine store (redacted) and removes it from disk.
    /// The operation is idempotent: an already-removed file is skipped.
    /// Returns whether the file was removed from the active archive.
    @discardableResult
    private func isolateCorruptFile(
        at fileURL: URL,
        dayIdentifier: String?,
        reason: String
    ) -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        let rawData = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let diagnosticKey = dayIdentifier.map { "historyArchive:\($0)" }
            ?? "historyArchive:unrecognizedFile"
        _ = quarantineProvider()?.isolate(
            domain: .historyArchive,
            violationKind: .unknown(reason),
            redactedOriginalData: String(rawData.prefix(4096)),
            diagnosticKey: diagnosticKey
        )
        try? fileManager.removeItem(at: fileURL)
        logger.debug("isolated corrupted history file \(diagnosticKey, privacy: .public)")
        return !fileManager.fileExists(atPath: fileURL.path)
    }

    private static let cleanupMarker = "cleanup"
}
