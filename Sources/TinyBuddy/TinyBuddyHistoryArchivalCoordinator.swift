import Foundation
import OSLog
import TinyBuddyCore

/// Coordinates the historical daily-snapshot archive and the storage cleanup
/// flow across the app lifecycle.
///
/// Guarantees (mirroring the storage invariants):
/// - The current local day's snapshot (including any in-progress focus
///   session) is never archived away by cleanup, and cleanup never deletes
///   the current day, recovery backups, or still-referenced data. The
///   `TinyBuddyHistoryStore` enforces current-day protection during pruning.
/// - Archiving is atomic (`.atomic` writes plus read-back verification in the
///   history store) and idempotent (same-day writes overwrite; re-running
///   archive/cleanup after a crash is safe).
/// - A cross-day transition archives the final state of the day that just
///   ended *before* the refresh coordinator can re-initialize the snapshot
///   store for the new day, so the closing snapshot is never lost.
/// - Corrupted history files are isolated into the corrupted-record
///   quarantine by the history store and never re-enter the readable archive.
/// - Cleanup runs off the main thread and its failures are only logged: they
///   never propagate into HUD, history, or Widget presentation paths.
@MainActor
final class TinyBuddyHistoryArchivalCoordinator {
    typealias SnapshotReader = (String?) -> TinyBuddyValidatedCombinedSnapshotRead

    enum PriorDayLaunchArchiveResult: Equatable {
        case noCandidate
        case archived
        case existingArchivePreserved
        case failed
    }

    private let snapshotReader: SnapshotReader
    private let historyStore: TinyBuddyHistoryStore
    private let cleanupService: TinyBuddyStorageCleanupService
    private let timeContextProvider: () -> TinyBuddyTimeContext?
    private let throttleInterval: TimeInterval
    private let logger: Logger

    private var lastArchiveDayIdentifier: String?
    private var lastArchiveDate: Date?

    private static let cleanupQueue = DispatchQueue(
        label: "local.tinybuddy.history-archival-cleanup",
        qos: .utility
    )

    public init(
        snapshotReader: @escaping SnapshotReader,
        historyStore: TinyBuddyHistoryStore,
        cleanupService: TinyBuddyStorageCleanupService,
        timeContextProvider: @escaping () -> TinyBuddyTimeContext?,
        throttleInterval: TimeInterval = 30
    ) {
        self.snapshotReader = snapshotReader
        self.historyStore = historyStore
        self.cleanupService = cleanupService
        self.timeContextProvider = timeContextProvider
        self.throttleInterval = max(0, throttleInterval)
        self.logger = Logger(
            subsystem: "local.tinybuddy",
            category: "TinyBuddyHistoryArchival"
        )
    }

    // MARK: - Lifecycle entry points

    /// Recovers an older committed snapshot before launch starts any writer
    /// that can advance the combined store to the current day. This covers the
    /// startup calibration callback, which is delivered on a deferred MainActor
    /// Task and can otherwise run after the refresh coordinator has rolled the
    /// store forward.
    ///
    /// Only the exact valid snapshot day is archived. Same-day, future, and
    /// invalid snapshots are ignored; no missing intermediate days are made.
    /// A readable history entry with an equal or newer combined revision is
    /// retained. Failure is logged and startup remains best-effort: this does
    /// not recover every crash window or a snapshot another writer advanced
    /// before this method ran.
    @discardableResult
    func archivePriorDaySnapshotBeforeLaunchWrites() -> PriorDayLaunchArchiveResult {
        guard let currentDay = timeContextProvider()?.dayIdentifier,
              TinyBuddyTimeContext.isValidDayIdentifier(currentDay) else {
            return .noCandidate
        }

        let read = snapshotReader(nil)
        guard let snapshot = read.snapshot else {
            if let observation = read.observation {
                logger.debug(
                    "prelaunch history recovery skipped: \(observation.identifier, privacy: .public)"
                )
            }
            return .noCandidate
        }
        guard TinyBuddyTimeContext.isValidDayIdentifier(snapshot.dayIdentifier),
              snapshot.dayIdentifier < currentDay else {
            return .noCandidate
        }

        if case .available(let existing) = historyStore.readSnapshot(for: snapshot.dayIdentifier),
           existing.revision >= snapshot.revision {
            logger.debug(
                "prelaunch history recovery preserved existing day=\(snapshot.dayIdentifier, privacy: .public) revision=\(existing.revision, privacy: .public)"
            )
            return .existingArchivePreserved
        }

        guard archive(snapshot) else {
            return .failed
        }
        logger.notice(
            "archived prior-day snapshot for day=\(snapshot.dayIdentifier, privacy: .public) before startup writes for day=\(currentDay, privacy: .public)"
        )
        return .archived
    }

    /// Launch-time archival and cleanup. Archives the committed snapshot for
    /// the current day (if one exists) and schedules a best-effort cleanup on
    /// a background queue so HUD startup is never blocked.
    public func runAtLaunch() {
        archiveCurrentDayIfAvailable()
        scheduleCleanup()
    }

    /// Cross-day transition. Must run on the main actor *before* the refresh
    /// coordinator re-initializes the snapshot store for the new day. The
    /// committed snapshot for the day that just ended (when the store still
    /// carries it) is archived synchronously; the current day is untouched.
    public func handleDayTransition(to newDayIdentifier: String) {
        guard TinyBuddyTimeContext.isValidDayIdentifier(newDayIdentifier) else {
            return
        }
        let read = snapshotReader(nil)
        guard let snapshot = read.snapshot else {
            logger.debug(
                "day transition to \(newDayIdentifier, privacy: .public): no committed snapshot to archive"
            )
            scheduleCleanup()
            return
        }
        if snapshot.dayIdentifier == newDayIdentifier {
            // The store has already rolled to the new day; the closing
            // snapshot was archived by the previous transition or termination.
            logger.debug(
                "day transition to \(newDayIdentifier, privacy: .public): store already rolled"
            )
        } else if archive(snapshot) {
            logger.notice(
                "archived closing snapshot for day=\(snapshot.dayIdentifier, privacy: .public) at transition to \(newDayIdentifier, privacy: .public)"
            )
        }
        scheduleCleanup()
    }

    /// Called after a combined snapshot commit (activity refresh or focus
    /// history publication). Archives the current day's snapshot at most once
    /// per throttle interval; the write is atomic and idempotent.
    public func handleCommittedSnapshot(dayIdentifier: String) {
        guard TinyBuddyTimeContext.isValidDayIdentifier(dayIdentifier) else {
            return
        }
        // Only the current local day is archived on commit. A stale or
        // future-dated commit must never displace the current day's file.
        guard let currentDay = timeContextProvider()?.dayIdentifier,
              currentDay == dayIdentifier else {
            return
        }
        if let lastArchiveDate,
           lastArchiveDayIdentifier == dayIdentifier,
           Date().timeIntervalSince(lastArchiveDate) < throttleInterval {
            return
        }
        guard archiveCurrentDayIfAvailable() else {
            return
        }
        lastArchiveDayIdentifier = dayIdentifier
        lastArchiveDate = Date()
    }

    /// Termination archival. Archives the final committed snapshot of the
    /// current day so the day's last state survives an app exit.
    public func handleTermination() {
        archiveCurrentDayIfAvailable()
    }

    /// Reacts to disk-space pressure by running cleanup immediately. The
    /// cleanup never deletes the current day, active focus sessions, recovery
    /// backups, or still-referenced data; it only reclaims caches and
    /// age-expired temporary artifacts.
    public func handleDiskSpacePressure() {
        scheduleCleanup()
    }

    // MARK: - Internal

    @discardableResult
    private func archiveCurrentDayIfAvailable() -> Bool {
        guard let currentDay = timeContextProvider()?.dayIdentifier else {
            return false
        }
        let read = snapshotReader(currentDay)
        guard let snapshot = read.snapshot,
              snapshot.dayIdentifier == currentDay else {
            if let observation = read.observation {
                logger.debug(
                    "archive current day \(currentDay, privacy: .public) skipped: \(observation.identifier, privacy: .public)"
                )
            }
            return false
        }
        return archive(snapshot)
    }

    @discardableResult
    private func archive(_ snapshot: TinyBuddyCombinedSnapshot) -> Bool {
        if case .available(let existing) = historyStore.readSnapshot(for: snapshot.dayIdentifier),
           existing.revision >= snapshot.revision {
            logger.debug(
                "history archive preserved existing day=\(snapshot.dayIdentifier, privacy: .public) revision=\(existing.revision, privacy: .public) over candidate revision=\(snapshot.revision, privacy: .public)"
            )
            return true
        }

        let archived = historyStore.archiveSnapshot(snapshot)
        if archived == nil {
            logger.error(
                "history archive failed for day=\(snapshot.dayIdentifier, privacy: .public); combined snapshot was left untouched, but a later writer may replace this recovery opportunity"
            )
        }
        return archived != nil
    }

    private func scheduleCleanup() {
        Self.cleanupQueue.async { [cleanupService, logger] in
            let result = cleanupService.runCleanup()
            if result.observation != nil {
                logger.notice(
                    "storage cleanup observation: \(result.observation?.identifier ?? "none", privacy: .public)"
                )
            }
        }
    }
}
