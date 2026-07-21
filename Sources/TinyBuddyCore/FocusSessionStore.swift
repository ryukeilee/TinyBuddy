import Foundation
import OSLog

/// Abstraction over focus session persistence so the engine can be tested with
/// an in-memory store.
public protocol FocusSessionPersisting: Sendable {
    func load() -> [FocusSession]?
    @discardableResult func save(_ sessions: [FocusSession]) -> Bool
}

/// Whether an archive can establish that it contains the complete history.
/// A backup restored after a missing/corrupt primary is still useful for
/// recovery, but it cannot prove that writes made after that backup survived.
public enum FocusSessionArchiveCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case partialRecovery
}

/// The versioned on-disk representation of the focus-session journal.
///
/// Revision zero is the initial revision, including archives migrated from the
/// legacy bare-array format. Revisions are intentionally independent from a
/// session's optional `manualRevision` field.
public struct FocusSessionArchive: Codable, Equatable, Sendable {
    /// Schema version 3 adds `ruleVersion` to `FocusSession` and supports
    /// rule-based session attribution tracking.
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let revision: Int64
    public let sessions: [FocusSession]
    /// Defaults to `.complete` for legacy envelopes. A recovery from backup
    /// persists `.partialRecovery`, preventing a later restart from silently
    /// turning potentially missing records into trusted zeros.
    public let historyCompleteness: FocusSessionArchiveCompleteness
    /// Evidence archive carried alongside sessions. `nil` for archives that
    /// predate evidence tracking. Evidence is always present for sessions
    /// created or modified by schema v2+ engines.
    public let evidenceArchive: FocusSessionEvidenceArchive?

    public init(
        schemaVersion: Int = FocusSessionArchive.currentSchemaVersion,
        revision: Int64 = 0,
        sessions: [FocusSession],
        historyCompleteness: FocusSessionArchiveCompleteness = .complete,
        evidenceArchive: FocusSessionEvidenceArchive? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.sessions = sessions
        self.historyCompleteness = historyCompleteness
        self.evidenceArchive = evidenceArchive
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case sessions
        case historyCompleteness
        case evidenceArchive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(Int64.self, forKey: .revision)
        sessions = try container.decode([FocusSession].self, forKey: .sessions)
        historyCompleteness = try container.decodeIfPresent(
            FocusSessionArchiveCompleteness.self,
            forKey: .historyCompleteness
        ) ?? .complete
        evidenceArchive = try container.decodeIfPresent(
            FocusSessionEvidenceArchive.self,
            forKey: .evidenceArchive
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(historyCompleteness, forKey: .historyCompleteness)
        try container.encodeIfPresent(evidenceArchive, forKey: .evidenceArchive)
    }

    /// Decoding JSON proves only its syntax. This check protects history
    /// consumers from treating a structurally decodable but impossible journal
    /// as a trusted empty day. A failed check is deliberately fail-closed: the
    /// archive is unavailable until a valid primary or backup is recovered.
    public var isSemanticallyValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              revision >= 0,
              Set(sessions.map(\.id)).count == sessions.count else {
            return false
        }
        let decisionIDs = sessions.compactMap(\.decisionEvents).flatMap { $0 }.map(\.id)
        guard Set(decisionIDs).count == decisionIDs.count else { return false }

        for session in sessions {
            guard TinyBuddyTimeContext.isValidDayIdentifier(session.dayIdentifier),
                  !session.project.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !session.project.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.isFinite(session.startedAt),
                  Self.isFinite(session.lastUserActivityAt),
                  Self.isFinite(session.lastStateChangeAt),
                  session.lastUserActivityAt >= session.startedAt,
                  session.lastStateChangeAt >= session.startedAt,
                  session.pausedTotal.isFinite,
                  session.pausedTotal >= 0,
                  session.manualRevision.map({ $0 >= 0 }) ?? true,
                  session.decisionEvents?.allSatisfy({ event in
                      event.at.timeIntervalSinceReferenceDate.isFinite
                  }) ?? true else {
                return false
            }

            switch session.status {
            case .ended:
                guard let end = session.endedAt,
                      Self.isFinite(end),
                      end >= session.startedAt,
                      session.lastUserActivityAt <= end,
                      session.lastStateChangeAt <= end,
                      session.currentPauseStartedAt == nil,
                      session.pausedTotal <= end.timeIntervalSince(session.startedAt) else {
                    return false
                }
            case .active:
                guard session.endedAt == nil,
                      session.currentPauseStartedAt == nil,
                      !session.isManuallyConfirmed else {
                    return false
                }
            case .paused:
                guard session.endedAt == nil,
                      let pauseStart = session.currentPauseStartedAt,
                      Self.isFinite(pauseStart),
                      pauseStart >= session.startedAt,
                      !session.isManuallyConfirmed else {
                    return false
                }
            }
        }

        let sorted = sessions.sorted { $0.startedAt < $1.startedAt }
        for index in sorted.indices where index + 1 < sorted.count {
            let end = sorted[index].endedAt ?? .distantFuture
            guard sorted[index + 1].startedAt >= end else { return false }
        }
        return true
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }
}

/// Whether a readable archive was encoded in the current envelope or was
/// interpreted from the legacy bare `[FocusSession]` JSON format.
public enum FocusSessionArchiveFormat: Equatable, Sendable {
    case envelope
    case legacyMigrated
}

/// The health of a file-store read. In particular, `missing` is never treated
/// as an empty archive, and `corrupt` is never treated as `missing`.
public enum FocusSessionArchiveLoadHealth: Equatable, Sendable {
    case missing
    case available
    case recoveredFromBackup
    case corrupt
}

/// The result of an archive-aware load. `archive` is present only for healthy
/// reads, so callers can distinguish an empty but valid journal from unknown
/// data without inventing zero-valued statistics.
public struct FocusSessionArchiveLoadResult: Equatable, Sendable {
    public let health: FocusSessionArchiveLoadHealth
    public let archive: FocusSessionArchive?
    public let format: FocusSessionArchiveFormat?

    public init(
        health: FocusSessionArchiveLoadHealth,
        archive: FocusSessionArchive? = nil,
        format: FocusSessionArchiveFormat? = nil
    ) {
        self.health = health
        self.archive = archive
        self.format = format
    }
}

/// Optional richer persistence API for callers that need archive revision and
/// load health. `FocusSessionPersisting` remains the compatibility boundary for
/// existing engine callers.
public protocol FocusSessionArchivePersisting: FocusSessionPersisting {
    func loadArchive() -> FocusSessionArchiveLoadResult
    @discardableResult func saveArchive(_ archive: FocusSessionArchive) -> Bool
}

/// File-backed store using a versioned archive envelope and atomic replacement.
/// The previous complete archive is retained as `.bak`, allowing a corrupt or
/// interrupted primary write to be recovered without representing it as an
/// empty journal.
public final class FocusSessionFileStore: FocusSessionArchivePersisting {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let quarantine: TinyBuddyCorruptedRecordQuarantine?
    private let logger = Logger(subsystem: "local.tinybuddy", category: "FocusSessionFileStore")

    public init(
        fileURL: URL,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        quarantine: TinyBuddyCorruptedRecordQuarantine? = nil
    ) {
        self.fileURL = fileURL
        self.encoder = encoder
        self.decoder = decoder
        self.quarantine = quarantine
    }

    /// Compatibility load API. Both an absent and an unrecoverable corrupt
    /// archive continue to return `nil`, while a recovered backup is visible as
    /// its valid session list.
    public func load() -> [FocusSession]? {
        loadArchive().archive?.sessions
    }

    public func loadArchive() -> FocusSessionArchiveLoadResult {
        let primary = readArchive(at: fileURL)
        switch primary {
        case .valid(let archive, let format):
            return validateAndCleanArchive(archive, format: format)
        case .missing:
            return recoverFromBackupIfPossible(primaryWasCorrupt: false)
        case .corrupt:
            return recoverFromBackupIfPossible(primaryWasCorrupt: true)
        }
    }

    /// Validates the loaded archive using `TinyBuddyDataValidator` and isolates
    /// sessions affected by critical invariant violations via the quarantine
    /// store. Returns an archive containing only the valid sessions.
    private func validateAndCleanArchive(
        _ archive: FocusSessionArchive,
        format: FocusSessionArchiveFormat
    ) -> FocusSessionArchiveLoadResult {
        let violations = TinyBuddyDataValidator.validateFocusSessions(archive.sessions)

        guard !violations.isEmpty else {
            return FocusSessionArchiveLoadResult(health: .available, archive: archive, format: format)
        }

        let criticalViolations = violations.filter { $0.severity == .critical }
        let errors = violations.filter { $0.severity == .error }
        let warnings = violations.filter { $0.severity == .warning }

        logger.debug("Archive validation: \(violations.count) violation(s) (\(criticalViolations.count) critical, \(errors.count) error(s), \(warnings.count) warning(s))")

        for violation in violations {
            logger.debug("[\(violation.severity.rawValue, privacy: .public)] \(violation.description, privacy: .public)")
        }

        // Isolate sessions affected by critical violations
        if !criticalViolations.isEmpty, let quarantine {
            var affectedSessionIDs = Set<UUID>()

            for violation in criticalViolations {
                for idString in violation.affectedIdentifiers {
                    if let uuid = UUID(uuidString: idString),
                       archive.sessions.contains(where: { $0.id == uuid }) {
                        affectedSessionIDs.insert(uuid)
                    }
                }
            }

            // Remove quarantined sessions from the archive
            let cleanSessions = archive.sessions.filter { !affectedSessionIDs.contains($0.id) }

            // Isolate each corrupted session in the quarantine store
            for sessionID in affectedSessionIDs {
                let sessionViolations = criticalViolations.filter {
                    $0.affectedIdentifiers.contains(sessionID.uuidString)
                }
                for violation in sessionViolations {
                    quarantine.isolate(
                        domain: .focusSession,
                        violationKind: violation.kind,
                        redactedOriginalData: "session_id=\(sessionID.uuidString)",
                        diagnosticKey: violation.diagnosticKey
                    )
                }
            }

            logger.debug("Quarantined \(affectedSessionIDs.count) session(s), cleaned archive has \(cleanSessions.count) session(s)")

            let cleanedArchive = FocusSessionArchive(
                schemaVersion: archive.schemaVersion,
                revision: archive.revision,
                sessions: cleanSessions,
                historyCompleteness: archive.historyCompleteness
            )

            return FocusSessionArchiveLoadResult(
                health: .available,
                archive: cleanedArchive,
                format: format
            )
        }

        // Non-critical violations only, or no quarantine configured — return as-is
        return FocusSessionArchiveLoadResult(
            health: .available,
            archive: archive,
            format: format
        )
    }

    /// Saves a current-schema envelope. Invalid schema versions and negative
    /// revisions are rejected rather than persisted as an apparently healthy
    /// archive.
    @discardableResult
    public func saveArchive(_ archive: FocusSessionArchive) -> Bool {
        guard archive.schemaVersion == FocusSessionArchive.currentSchemaVersion,
              archive.revision >= 0,
              archive.isSemanticallyValid,
              let data = try? encoder.encode(archive) else {
            return false
        }
        return replacePrimary(with: data, retainingPreviousBackup: true)
    }

    /// Compatibility save API. It writes the current envelope and advances a
    /// healthy archive revision; a missing, corrupt, or exhausted revision
    /// starts safely at zero rather than overflowing.
    @discardableResult
    public func save(_ sessions: [FocusSession]) -> Bool {
        let current = loadArchive()
        let currentRevision = current.archive?.revision
        let nextRevision: Int64
        if let currentRevision, currentRevision < Int64.max {
            nextRevision = currentRevision + 1
        } else {
            nextRevision = 0
        }
        let completeness: FocusSessionArchiveCompleteness
        switch current.archive?.historyCompleteness {
        case .partialRecovery:
            completeness = .partialRecovery
        case .complete:
            completeness = .complete
        case nil:
            completeness = current.health == .corrupt ? .partialRecovery : .complete
        }
        return saveArchive(FocusSessionArchive(
            revision: nextRevision,
            sessions: sessions,
            historyCompleteness: completeness
        ))
    }

    private func recoverFromBackupIfPossible(primaryWasCorrupt: Bool) -> FocusSessionArchiveLoadResult {
        switch readArchive(at: backupURL) {
        case .valid(let archive, let format):
            // Preserve the valid backup while atomically replacing a corrupt
            // primary. If the primary is absent, the backup remains available
            // until the staged replacement has become the new primary.
            let recoveredArchive = FocusSessionArchive(
                schemaVersion: archive.schemaVersion,
                revision: archive.revision,
                sessions: archive.sessions,
                historyCompleteness: .partialRecovery
            )
            guard let data = try? encoder.encode(recoveredArchive),
                  replacePrimary(with: data, retainingPreviousBackup: false) else {
                return FocusSessionArchiveLoadResult(health: primaryWasCorrupt ? .corrupt : .missing)
            }
            return FocusSessionArchiveLoadResult(
                health: .recoveredFromBackup,
                archive: recoveredArchive,
                format: format
            )
        case .missing:
            return FocusSessionArchiveLoadResult(health: primaryWasCorrupt ? .corrupt : .missing)
        case .corrupt:
            return FocusSessionArchiveLoadResult(health: .corrupt)
        }
    }

    private func replacePrimary(with data: Data, retainingPreviousBackup: Bool) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent("\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: tempURL, options: .atomic)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                if retainingPreviousBackup {
                    // Do not rely on `backupItemName`: its observable backup
                    // lifetime differs across Foundation implementations. Make
                    // the recovery point durable first, then replace primary.
                    try writeBackup(Data(contentsOf: fileURL))
                }
                try replaceStagedItem(at: tempURL, destination: fileURL)
            } else {
                // The temp file and destination are in the same directory, so
                // this rename is atomic. A pre-existing valid backup is left in
                // place until this new primary is visible.
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    private func writeBackup(_ data: Data) throws {
        let directory = backupURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent("\(backupURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            try replaceStagedItem(at: tempURL, destination: backupURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func replaceStagedItem(at stagedURL: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        }
    }

    private func readArchive(at url: URL) -> ReadArchiveResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .corrupt }

        if let archive = try? decoder.decode(FocusSessionArchive.self, from: data) {
            guard archive.schemaVersion == FocusSessionArchive.currentSchemaVersion,
                  archive.revision >= 0,
                  archive.isSemanticallyValid else {
                return .corrupt
            }
            return .valid(archive, .envelope)
        }

        if let sessions = try? decoder.decode([FocusSession].self, from: data) {
            let archive = FocusSessionArchive(revision: 0, sessions: sessions)
            guard archive.isSemanticallyValid else { return .corrupt }
            return .valid(archive, .legacyMigrated)
        }
        return .corrupt
    }

    private enum ReadArchiveResult {
        case missing
        case valid(FocusSessionArchive, FocusSessionArchiveFormat)
        case corrupt
    }

    private var backupURL: URL {
        let directory = fileURL.deletingLastPathComponent()
        return directory.appendingPathComponent("\(fileURL.lastPathComponent).bak")
    }
}
