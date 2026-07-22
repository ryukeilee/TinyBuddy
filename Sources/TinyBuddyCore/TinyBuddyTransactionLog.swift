import Foundation
import OSLog

// MARK: - Transaction State

/// State machine for a single transaction in the log.
///
/// States progress as follows:
/// - `prepared` → `committed` (success path: all writes verified durable)
/// - `prepared` → `rolledBack` (failure path: writes failed, rollback initiated)
/// - `committed` → `cleanedUp` (post-commit: log entry can be safely removed)
/// - `rolledBack` → `cleanedUp` (post-rollback: log entry can be safely removed)
///
/// Recovery replays the log: any `prepared` transaction is either committed
/// (if its data is durable) or rolled back (if its data is missing).
public enum TinyBuddyTransactionState: String, Codable, Equatable, Sendable {
    case prepared
    case committed
    case rolledBack
    case cleanedUp
}

// MARK: - Transaction Log Entry

/// A single entry in the transaction log. Each entry is append-only and
/// checksummed so that tampering or truncation is detectable during recovery.
public struct TinyBuddyTransactionLogEntry: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let domain: TinyBuddyDataDomain
    public let state: TinyBuddyTransactionState
    /// Monotonic version number for optimistic concurrency control.
    public let version: Int64
    /// Hash of the payload committed in this transaction (redacted, no user data).
    public let payloadHash: String
    /// Stable redacted diagnostic key for aggregation (no user data).
    public let diagnosticKey: String
    public let timestamp: Date

    public init(
        transactionID: UUID,
        domain: TinyBuddyDataDomain,
        state: TinyBuddyTransactionState,
        version: Int64,
        payloadHash: String,
        diagnosticKey: String,
        timestamp: Date = Date()
    ) {
        self.transactionID = transactionID
        self.domain = domain
        self.state = state
        self.version = version
        self.payloadHash = payloadHash
        self.diagnosticKey = diagnosticKey
        self.timestamp = timestamp
    }

    /// FNV-1a checksum of the entry's critical fields. Detects truncation,
    /// field reordering, or bit flips without exposing user data.
    public var checksum: String {
        let fields = [
            transactionID.uuidString,
            domain.rawValue,
            state.rawValue,
            String(version),
            payloadHash,
            diagnosticKey,
            String(timestamp.timeIntervalSinceReferenceDate)
        ].joined(separator: "\t")
        return Self.fnv1a(fields)
    }

    private static func fnv1a(_ input: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let value = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - value.count) + value
    }
}

// MARK: - Transaction Log

/// Lightweight, append-only transaction log with crash recovery.
///
/// The log provides a unified transaction boundary across all data domains
/// (focus sessions, project identity, config, history aggregation, shared
/// snapshot, daily stats). Each transaction is recorded as a sequence of
/// log entries:
///
/// 1. `prepared` — written before any domain writes begin
/// 2. `committed` — written after all domain writes are verified durable
/// 3. `cleanedUp` — written during log compaction to mark the entry for removal
///
/// On recovery, the log is replayed:
/// - `prepared` transactions are either committed (if data is durable) or
///   rolled back (if data is missing).
/// - `committed` transactions are already durable; their log entries can be
///   cleaned up.
/// - `rolledBack` transactions are already resolved; their log entries can be
///   cleaned up.
/// - `cleanedUp` entries are removed during compaction.
///
/// The log is constrained by existing privacy/capacity policies:
/// - No user data is stored in log entries (only redacted hashes and keys).
/// - Entries are bounded by a maximum count and age.
/// - Cleanup removes old resolved entries.
public final class TinyBuddyTransactionLog: @unchecked Sendable {
    public static let maxEntries = 1000
    public static let maxEntryAge: TimeInterval = 7 * 24 * 3600 // 7 days
    public static let maxPayloadHashLength = 64

    /// The URL of the log file. Exposed for test verification.
    public let fileURL: URL

    /// Result of appending a log entry.
    public enum AppendResult: Equatable, Sendable {
        case saved
        case persistenceFailed
        case rejectedStaleVersion(expected: Int64, actual: Int64)
    }

    /// Result of recovery.
    public struct RecoveryResult: Equatable, Sendable {
        public let preparedTransactions: [UUID]
        public let committedTransactions: [UUID]
        public let rolledBackTransactions: [UUID]
        public let cleanedUpCount: Int

        public init(
            preparedTransactions: [UUID] = [],
            committedTransactions: [UUID] = [],
            rolledBackTransactions: [UUID] = [],
            cleanedUpCount: Int = 0
        ) {
            self.preparedTransactions = preparedTransactions
            self.committedTransactions = committedTransactions
            self.rolledBackTransactions = rolledBackTransactions
            self.cleanedUpCount = cleanedUpCount
        }
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private let logger = Logger(
        subsystem: "local.tinybuddy",
        category: "TinyBuddyTransactionLog"
    )

    public init(
        fileURL: URL,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.fileURL = fileURL
        self.encoder = encoder
        self.decoder = decoder
    }

    // MARK: - Public API

    /// Appends a log entry. The entry is written atomically: either the full
    /// entry is persisted or nothing is written.
    @discardableResult
    public func append(_ entry: TinyBuddyTransactionLogEntry) -> AppendResult {
        lock.lock()
        defer { lock.unlock() }

        guard entry.checksum.count == 16,
              entry.payloadHash.count <= Self.maxPayloadHashLength else {
            return .persistenceFailed
        }

        guard let data = try? encoder.encode(entry) else {
            return .persistenceFailed
        }

        let checksum = entry.checksum
        let line = "\(checksum)|\(data.base64EncodedString())\n"
        return writeLine(line) == true ? .saved : .persistenceFailed
    }

    /// Reads all log entries in order. Used during recovery and compaction.
    public func readAll() -> [TinyBuddyTransactionLogEntry] {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        return content.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2,
                      let data = Data(base64Encoded: String(parts[1])),
                      let entry = try? decoder.decode(TinyBuddyTransactionLogEntry.self, from: data),
                      entry.checksum == String(parts[0]) else {
                    return nil
                }
                return entry
            }
    }

    /// Returns the highest committed version for a given domain.
    public func highestCommittedVersion(for domain: TinyBuddyDataDomain) -> Int64 {
        let entries = readAll()
        return entries
            .filter { $0.domain == domain && $0.state == .committed }
            .map(\.version)
            .max() ?? 0
    }

    /// Returns the highest version (any state) for a given domain.
    public func highestVersion(for domain: TinyBuddyDataDomain) -> Int64 {
        let entries = readAll()
        return entries
            .filter { $0.domain == domain }
            .map(\.version)
            .max() ?? 0
    }

    /// Checks if a transaction ID is already in the log with a committed state.
    public func isCommitted(_ transactionID: UUID) -> Bool {
        let entries = readAll()
        return entries.contains { $0.transactionID == transactionID && $0.state == .committed }
    }

    /// Checks if a transaction ID is already in the log with a rolled-back state.
    public func isRolledBack(_ transactionID: UUID) -> Bool {
        let entries = readAll()
        return entries.contains { $0.transactionID == transactionID && $0.state == .rolledBack }
    }

    /// Performs log recovery. Returns a summary of transactions that need
    /// to be resolved. The caller is responsible for committing or rolling
    /// back prepared transactions based on whether their data is durable.
    @discardableResult
    public func recover() -> RecoveryResult {
        lock.lock()
        defer { lock.unlock() }

        let entries = readAllLocked()
        var prepared: [UUID] = []
        var committed: [UUID] = []
        var rolledBack: [UUID] = []
        var cleanedUpCount = 0

        for entry in entries {
            switch entry.state {
            case .prepared:
                prepared.append(entry.transactionID)
            case .committed:
                committed.append(entry.transactionID)
            case .rolledBack:
                rolledBack.append(entry.transactionID)
            case .cleanedUp:
                cleanedUpCount += 1
            }
        }

        logger.info(
            "Recovery: \(prepared.count) prepared, \(committed.count) committed, \(rolledBack.count) rolled back, \(cleanedUpCount) cleaned up"
        )

        return RecoveryResult(
            preparedTransactions: prepared,
            committedTransactions: committed,
            rolledBackTransactions: rolledBack,
            cleanedUpCount: cleanedUpCount
        )
    }

    /// Compacts the log by removing `cleanedUp` entries and entries older than
    /// `maxEntryAge`. Resolved transactions (committed or rolled back) that are
    /// older than `maxEntryAge` are marked as `cleanedUp` before removal.
    @discardableResult
    public func compact(now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let entries = readAllLocked()
        let cutoff = now.addingTimeInterval(-Self.maxEntryAge)

        var compacted: [TinyBuddyTransactionLogEntry] = []
        var removedCount = 0

        for entry in entries {
            if entry.state == .cleanedUp || entry.timestamp < cutoff {
                removedCount += 1
                continue
            }
            compacted.append(entry)
        }

        // If we've removed entries, rewrite the log
        if removedCount > 0 {
            _ = rewriteLocked(compacted)
        }

        return removedCount
    }

    /// Marks a transaction as cleaned up. This is called after a transaction
    /// has been fully resolved (committed or rolled back) and its data has
    /// been verified durable.
    @discardableResult
    public func markCleanedUp(transactionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let entries = readAllLocked()
        var didChange = false
        let updated = entries.map { entry in
            if entry.transactionID == transactionID,
               entry.state == .committed || entry.state == .rolledBack {
                didChange = true
                return TinyBuddyTransactionLogEntry(
                    transactionID: entry.transactionID,
                    domain: entry.domain,
                    state: .cleanedUp,
                    version: entry.version,
                    payloadHash: entry.payloadHash,
                    diagnosticKey: entry.diagnosticKey,
                    timestamp: entry.timestamp
                )
            }
            return entry
        }

        guard didChange else { return false }
        return rewriteLocked(updated)
    }

    // MARK: - Private Methods

    private func writeLine(_ line: String) -> Bool? {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Read existing content and append
                var existing = try Data(contentsOf: fileURL)
                existing.append(line.data(using: .utf8)!)
                try existing.write(to: fileURL, options: .atomic)
            } else {
                try line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            logger.error("Failed to write transaction log entry: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func readAllLocked() -> [TinyBuddyTransactionLogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        return content.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2,
                      let data = Data(base64Encoded: String(parts[1])),
                      let entry = try? decoder.decode(TinyBuddyTransactionLogEntry.self, from: data),
                      entry.checksum == String(parts[0]) else {
                    return nil
                }
                return entry
            }
    }

    private func rewriteLocked(_ entries: [TinyBuddyTransactionLogEntry]) -> Bool {
        let tempURL = fileURL.appendingPathExtension("tmp")
        do {
            let lines = entries.compactMap { entry -> String? in
                guard let data = try? encoder.encode(entry) else { return nil }
                return "\(entry.checksum)|\(data.base64EncodedString())"
            }.joined(separator: "\n")

            if lines.isEmpty {
                // Remove the log file entirely if no entries remain
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return true
            }

            let content = lines + "\n"
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            return true
        } catch {
            logger.error("Failed to rewrite transaction log: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}

// MARK: - Transaction Context

/// Context for a single transaction, tracking its state across domains.
/// Used by `TinyBuddyTransactionCoordinator` to manage the prepare/commit/
/// rollback lifecycle.
public struct TinyBuddyTransactionContext: Sendable {
    public let transactionID: UUID
    public let domain: TinyBuddyDataDomain
    public let version: Int64
    public let payloadHash: String
    public let diagnosticKey: String
    public let startedAt: Date

    public init(
        transactionID: UUID = UUID(),
        domain: TinyBuddyDataDomain,
        version: Int64,
        payloadHash: String,
        diagnosticKey: String,
        startedAt: Date = Date()
    ) {
        self.transactionID = transactionID
        self.domain = domain
        self.version = version
        self.payloadHash = payloadHash
        self.diagnosticKey = diagnosticKey
        self.startedAt = startedAt
    }

    public func preparedEntry() -> TinyBuddyTransactionLogEntry {
        TinyBuddyTransactionLogEntry(
            transactionID: transactionID,
            domain: domain,
            state: .prepared,
            version: version,
            payloadHash: payloadHash,
            diagnosticKey: diagnosticKey,
            timestamp: startedAt
        )
    }

    public func committedEntry() -> TinyBuddyTransactionLogEntry {
        TinyBuddyTransactionLogEntry(
            transactionID: transactionID,
            domain: domain,
            state: .committed,
            version: version,
            payloadHash: payloadHash,
            diagnosticKey: diagnosticKey,
            timestamp: Date()
        )
    }

    public func rolledBackEntry() -> TinyBuddyTransactionLogEntry {
        TinyBuddyTransactionLogEntry(
            transactionID: transactionID,
            domain: domain,
            state: .rolledBack,
            version: version,
            payloadHash: payloadHash,
            diagnosticKey: diagnosticKey,
            timestamp: Date()
        )
    }
}
