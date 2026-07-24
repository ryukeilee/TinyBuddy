import Foundation
import OSLog

public struct TinyBuddyCombinedSnapshot: Equatable, Sendable {
    public let revision: Int64
    public let dayIdentifier: String
    public let snapshot: TinyBuddySnapshot
    public let activitySnapshot: GitTodayActivitySnapshot
    public let activityRevision: Int64?
    /// Optional session-review slice. Older committed payloads decode without it.
    public let focusSessionSnapshot: FocusSessionDerivedSnapshot?
    /// Optional authoritative focus-history publication. Older committed
    /// payloads decode without it while newer writers publish it atomically.
    public let focusHistoryPublication: FocusHistoryPublication?

    public init(
        revision: Int64,
        dayIdentifier: String,
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot,
        activityRevision: Int64? = nil,
        focusSessionSnapshot: FocusSessionDerivedSnapshot? = nil,
        focusHistoryPublication: FocusHistoryPublication? = nil
    ) {
        self.revision = revision
        self.dayIdentifier = dayIdentifier
        self.snapshot = snapshot
        self.activitySnapshot = activitySnapshot
        self.activityRevision = activityRevision
        self.focusSessionSnapshot = focusSessionSnapshot
        self.focusHistoryPublication = focusHistoryPublication
    }
}

public final class TinyBuddyCombinedSnapshotStore {
    public static let legacySchemaVersion = 1
    public static let currentSchemaVersion = 3

    public static func migrationPath(from version: Int) -> [Int]? {
        switch version {
        case 1:
            return [1, 2, 3]
        case 2:
            return [2, 3]
        case 3:
            return [3]
        default:
            return nil
        }
    }

    public enum UpdateOutcome: Equatable, Sendable {
        case saved
        case alreadyCurrent
        case rejectedStaleActivity
        case rejectedInvalidActivityRevision
        case versionIncompatible
        case revisionExhausted
        case persistenceFailed
    }

    public struct UpdateResult: Equatable, Sendable {
        public let snapshot: TinyBuddyCombinedSnapshot?
        public let outcome: UpdateOutcome
        public let didPersist: Bool
        public let observation: TinyBuddySharedSnapshotObservation?

        public init(
            snapshot: TinyBuddyCombinedSnapshot?,
            outcome: UpdateOutcome,
            didPersist: Bool,
            observation: TinyBuddySharedSnapshotObservation? = nil
        ) {
            self.snapshot = snapshot
            self.outcome = outcome
            self.didPersist = didPersist
            self.observation = observation ?? Self.observation(for: outcome)
        }

        private static func observation(
            for outcome: UpdateOutcome
        ) -> TinyBuddySharedSnapshotObservation? {
            let reason: TinyBuddySharedSnapshotReason?
            switch outcome {
            case .persistenceFailed, .revisionExhausted:
                reason = .persistenceFailed
            case .rejectedStaleActivity:
                reason = .staleData
            case .rejectedInvalidActivityRevision:
                reason = .invalidActivityRevision
            case .versionIncompatible:
                reason = .versionIncompatible
            case .saved, .alreadyCurrent:
                reason = nil
            }

            guard let reason else {
                return nil
            }
            return TinyBuddySharedSnapshotObservation(
                phase: .snapshotWrite,
                reason: reason,
                recovery: .stopped,
                attemptCount: 1
            )
        }
    }

    public enum Key {
        // V1 remains mirrored so older app/widget builds can read the latest
        // committed payload and so it can serve as a final recovery candidate.
        public static let snapshot = "tinybuddy.combinedSnapshot"
        public static let highestRevision = "tinybuddy.combinedSnapshot.highestRevision"
        public static let highestRevisionV2 = "tinybuddy.combinedSnapshot.v2.highestRevision"
        public static let committedRevisionV2 = "tinybuddy.combinedSnapshot.v2.committedRevision"
        public static let snapshotV2SlotA = "tinybuddy.combinedSnapshot.v2.slotA"
        public static let snapshotV2SlotB = "tinybuddy.combinedSnapshot.v2.slotB"
        public static let schemaVersion = "tinybuddy.combinedSnapshot.schemaVersion"
        public static let migrationBackupV1 = "tinybuddy.combinedSnapshot.migrationBackup.v1"

        static let all = [
            snapshot,
            highestRevision,
            highestRevisionV2,
            committedRevisionV2,
            snapshotV2SlotA,
            snapshotV2SlotB,
            schemaVersion,
            migrationBackupV1
        ]
    }

    private struct SourceValues {
        let legacySnapshot: String?
        let v2SlotA: String?
        let v2SlotB: String?
        let legacyHighestRevision: Int64?
        let revisionMarker: String?
        let committedRevisionMarker: String?
        let schemaVersionMarker: String?
        let migrationBackupV1: String?
    }

    private struct ReadState {
        let snapshot: TinyBuddyCombinedSnapshot?
        let revisionFloor: Int64
        let diagnosticReason: TinyBuddySharedSnapshotReason?
    }

    private struct DirectSlot {
        let key: String
        let rawValue: String?
        let snapshot: TinyBuddyCombinedSnapshot?
    }

    private final class AppGroupReadTracker {
        private(set) var failure: TinyBuddySharedSnapshotReason?

        func load() -> [String: Any]? {
            let read = TinyBuddySharedData.readAppGroupPreferences()
            failure = read.failure
            return read.values
        }
    }

    private let directPreferencesProvider: () -> [String: Any]
    private let synchronizeReads: () -> Void
    private let sharedPreferencesProvider: () -> [String: Any]?
    private let fallbackDefaults: UserDefaults?
    private let repairOnLoad: Bool
    private let writeValue: (Any, String) -> Bool
    private let synchronizeWrites: () -> Bool
    private let readFailureProvider: () -> TinyBuddySharedSnapshotReason?

    // The main app is the only semantic writer, enforced by the cross-process
    // TinyBuddyInstanceCoordinator (flock-based exclusive lock in the App Group
    // container). Only the primary instance may call updatePetSlice or
    // updateActivitySlice. This process-local writerLock serializes migration
    // and repair within that single process. WidgetKit uses repairOnLoad=false
    // and stays read-only; it never writes through this store.
    private static let writerLock = NSLock()
    private static let logger = Logger(
        subsystem: "local.tinybuddy",
        category: "TinyBuddyCombinedSnapshotStore"
    )

    // Write-failure cooldown prevents pointless retries when storage is full or
    // the preference domain is unavailable. After maxWriteFailuresBeforeCooldown
    // consecutive failures, writes are skipped for writeCooldownSeconds.
    private var writeFailureCount = 0
    private var lastWriteFailure: Date?
    private static let writeCooldownSeconds: TimeInterval = 60
    private static let maxWriteFailuresBeforeCooldown = 3

    private var isInWriteCooldown: Bool {
        writeFailureCount >= Self.maxWriteFailuresBeforeCooldown
            && lastWriteFailure.map { Date().timeIntervalSince($0) < Self.writeCooldownSeconds } == true
    }

    public convenience init(repairOnLoad: Bool = true) {
        let preferencesStore = TinyBuddyAppGroupPreferencesStore()
        let sharedReadTracker = AppGroupReadTracker()
        self.init(
            preferencesStore: preferencesStore,
            sharedPreferencesProvider: {
                sharedReadTracker.load()
            },
            repairOnLoad: repairOnLoad,
            readFailureProvider: {
                if let failure = sharedReadTracker.failure {
                    return failure
                }
                return TinyBuddySharedData.isAppGroupContainerAvailable()
                    && TinyBuddySharedData.isAppGroupDefaultsAvailable()
                    ? nil
                    : .appGroupUnavailable
            }
        )
    }

    convenience init(
        preferencesStore: TinyBuddyAppGroupPreferencesStore,
        sharedPreferencesProvider: @escaping () -> [String: Any]? = {
            TinyBuddySharedData.loadAppGroupPreferencesDictionary()
        },
        repairOnLoad: Bool = true,
        readFailureProvider: @escaping () -> TinyBuddySharedSnapshotReason? = { nil }
    ) {
        self.init(
            directPreferencesProvider: {
                preferencesStore.loadDictionary() ?? [:]
            },
            synchronizeReads: {},
            sharedPreferencesProvider: sharedPreferencesProvider,
            fallbackDefaults: nil,
            repairOnLoad: repairOnLoad,
            writeValue: { value, key in
                preferencesStore.writeValue(value, forKey: key)
            },
            synchronizeWrites: {
                preferencesStore.synchronize()
            },
            readFailureProvider: readFailureProvider
        )
    }

    public convenience init(
        userDefaults: UserDefaults,
        sharedPreferencesProvider: @escaping () -> [String: Any]? = {
            TinyBuddySharedData.loadAppGroupPreferencesDictionary()
        },
        fallbackDefaults: UserDefaults? = nil,
        repairOnLoad: Bool = true
    ) {
        self.init(
            directPreferencesProvider: {
                Self.combinedPreferenceValues(from: userDefaults)
            },
            synchronizeReads: {
                _ = userDefaults.synchronize()
            },
            sharedPreferencesProvider: sharedPreferencesProvider,
            fallbackDefaults: fallbackDefaults,
            repairOnLoad: repairOnLoad,
            writeValue: { value, key in
                userDefaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                // `UserDefaults.synchronize()` can report false on current
                // macOS even when the value is immediately readable. The
                // transactional writer verifies every staged value and commit
                // marker by reading it back, so use that stronger check as the
                // success criterion while still requesting a flush here.
                _ = userDefaults.synchronize()
                return true
            },
            readFailureProvider: { nil }
        )
    }

    convenience init(
        userDefaults: UserDefaults,
        sharedPreferencesProvider: @escaping () -> [String: Any]?,
        fallbackDefaults: UserDefaults? = nil,
        repairOnLoad: Bool = true,
        writeValue: @escaping (Any, String) -> Bool,
        synchronizeWrites: @escaping () -> Bool,
        readFailureProvider: @escaping () -> TinyBuddySharedSnapshotReason? = { nil }
    ) {
        self.init(
            directPreferencesProvider: {
                Self.combinedPreferenceValues(from: userDefaults)
            },
            synchronizeReads: {
                _ = userDefaults.synchronize()
            },
            sharedPreferencesProvider: sharedPreferencesProvider,
            fallbackDefaults: fallbackDefaults,
            repairOnLoad: repairOnLoad,
            writeValue: writeValue,
            synchronizeWrites: synchronizeWrites,
            readFailureProvider: readFailureProvider
        )
    }

    private init(
        directPreferencesProvider: @escaping () -> [String: Any],
        synchronizeReads: @escaping () -> Void,
        sharedPreferencesProvider: @escaping () -> [String: Any]?,
        fallbackDefaults: UserDefaults?,
        repairOnLoad: Bool,
        writeValue: @escaping (Any, String) -> Bool,
        synchronizeWrites: @escaping () -> Bool,
        readFailureProvider: @escaping () -> TinyBuddySharedSnapshotReason?
    ) {
        self.directPreferencesProvider = directPreferencesProvider
        self.synchronizeReads = synchronizeReads
        self.sharedPreferencesProvider = sharedPreferencesProvider
        self.fallbackDefaults = fallbackDefaults
        self.repairOnLoad = repairOnLoad
        self.writeValue = writeValue
        self.synchronizeWrites = synchronizeWrites
        self.readFailureProvider = readFailureProvider
    }

    private static func combinedPreferenceValues(from defaults: UserDefaults) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in Key.all {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            }
        }
        return values
    }

    public func load() -> TinyBuddyCombinedSnapshot? {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }
        let snapshot = readStateLocked(repair: repairOnLoad).snapshot
        guard validateSnapshot(snapshot) else { return nil }
        return snapshot
    }

    public func loadReadOnly() -> TinyBuddyCombinedSnapshot? {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }
        let snapshot = readStateLocked(repair: false).snapshot
        guard validateSnapshot(snapshot) else { return nil }
        return snapshot
    }

    /// Returns the last valid snapshot only when doing so cannot move the
    /// displayed business day backward. This is the rollback-safe fallback for
    /// read-only consumers while a new time scope is being recomputed.
    public func loadReadOnly(
        minimumDayIdentifier: String
    ) -> TinyBuddyCombinedSnapshot? {
        guard TinyBuddyTimeContext.isValidDayIdentifier(minimumDayIdentifier) else {
            return nil
        }

        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }
        guard let snapshot = readStateLocked(repair: false).snapshot,
              TinyBuddyTimeContext.isValidDayIdentifier(snapshot.dayIdentifier),
              snapshot.dayIdentifier >= minimumDayIdentifier else {
            return nil
        }
        guard validateSnapshot(snapshot) else { return nil }
        return snapshot
    }

    /// Reads the stored schema version from the first available source (direct
    /// preferences, shared preferences, or fallback defaults). Returns `nil`
    /// when no schema version has been stored yet (first launch).
    public func loadSchemaVersion() -> Int? {
        synchronizeReads()
        let direct = directPreferencesProvider()
        if let marker = direct[Key.schemaVersion] as? String,
           let version = Self.decodeSchemaVersion(marker) {
            return version
        }
        let shared = sharedPreferencesProvider()
        if let marker = shared?[Key.schemaVersion] as? String,
           let version = Self.decodeSchemaVersion(marker) {
            return version
        }
        if let fallback = fallbackDefaults?.string(forKey: Key.schemaVersion),
           let version = Self.decodeSchemaVersion(fallback) {
            return version
        }
        return nil
    }

    /// Repairs redundant local copies for a snapshot that was already validated
    /// by `readValidated`. This is intentionally unavailable to read-only
    /// WidgetKit callers through their use of `readValidated` alone.
    @discardableResult
    public func repairValidatedSnapshot(_ snapshot: TinyBuddyCombinedSnapshot) -> Bool {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }

        let current = readStateLocked(repair: false)
        guard current.snapshot == snapshot,
              readFailureProvider() == nil,
              let directSource = sourceValues().first,
              readFailureProvider() == nil else {
            return false
        }
        return repairLocked(snapshot, directSource: directSource)
    }

    /// Reads a display-safe snapshot and reports bounded, redacted diagnostics.
    /// A caller that supplies a day identifier will never receive another day's
    /// snapshot. Corrupt V2 input is reread at most once; read-only clients never
    /// write as part of this API.
    public func readValidated(
        expectedDayIdentifier: String? = nil
    ) -> TinyBuddyValidatedCombinedSnapshotRead {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }

        if let expectedDayIdentifier,
           !TinyBuddyTimeContext.isValidDayIdentifier(expectedDayIdentifier) {
            return TinyBuddyValidatedCombinedSnapshotRead(
                snapshot: nil,
                observation: observation(
                    reason: .staleData,
                    recovery: .stopped,
                    attemptCount: 1
                )
            )
        }

        let first = readStateLocked(
            repair: false,
            expectedDayIdentifier: expectedDayIdentifier
        )
        let firstReason = readFailureProvider() ?? first.diagnosticReason
        guard let firstReason else {
            return validatedRead(
                from: first.snapshot,
                expectedDayIdentifier: expectedDayIdentifier,
                attemptCount: 1
            )
        }

        guard firstReason == .snapshotCorrupt else {
            return TinyBuddyValidatedCombinedSnapshotRead(
                // A missing entitlement, denied read, or a newer on-disk
                // format makes the source contract itself untrustworthy. Do
                // not expose a candidate selected from another cache layer as
                // though it were a confirmed shared snapshot.
                snapshot: nil,
                observation: observation(
                    reason: firstReason,
                    recovery: .stopped,
                    attemptCount: 1
                )
            )
        }

        // A second source read is deliberately the only recovery attempt. In
        // particular, unknown formats and permission failures observed on this
        // read are not overwritten or retried.
        let second = readStateLocked(
            repair: false,
            expectedDayIdentifier: expectedDayIdentifier
        )
        let secondReason = readFailureProvider() ?? second.diagnosticReason
        let secondSnapshot = safeSnapshot(
            second.snapshot,
            expectedDayIdentifier: expectedDayIdentifier
        )
        if second.snapshot != nil, secondSnapshot == nil {
            return TinyBuddyValidatedCombinedSnapshotRead(
                snapshot: nil,
                observation: observation(
                    reason: .staleData,
                    recovery: .stopped,
                    attemptCount: 2
                )
            )
        }
        if let secondReason, secondReason != .snapshotCorrupt {
            return TinyBuddyValidatedCombinedSnapshotRead(
                snapshot: nil,
                observation: observation(
                    reason: secondReason,
                    recovery: .stopped,
                    attemptCount: 2
                )
            )
        }
        if let secondSnapshot {
            guard validateSnapshot(secondSnapshot) else {
                return TinyBuddyValidatedCombinedSnapshotRead(
                    snapshot: nil,
                    observation: observation(
                        reason: .snapshotCorrupt,
                        recovery: .stopped,
                        attemptCount: 2
                    )
                )
            }
            return TinyBuddyValidatedCombinedSnapshotRead(
                snapshot: secondSnapshot,
                observation: observation(
                    reason: .snapshotCorrupt,
                    recovery: .rereadSucceeded,
                    attemptCount: 2
                )
            )
        }
        return TinyBuddyValidatedCombinedSnapshotRead(
            snapshot: nil,
            observation: observation(
                reason: secondReason ?? .snapshotCorrupt,
                recovery: .stopped,
                attemptCount: 2
            )
        )
    }

    @discardableResult
    public func updatePetSlice(
        _ snapshot: TinyBuddySnapshot,
        fallbackActivitySnapshot: GitTodayActivitySnapshot?,
        fallbackActivityRevision: Int64? = nil
    ) -> UpdateResult {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }

        guard !isInWriteCooldown else {
            return cooldownResult()
        }

        let state = readStateLocked(repair: true)
        let current = state.snapshot
        guard state.diagnosticReason != .versionIncompatible else {
            return UpdateResult(
                snapshot: nil,
                outcome: .versionIncompatible,
                didPersist: false
            )
        }
        guard fallbackActivityRevision.map({ $0 >= 0 }) ?? true else {
            return UpdateResult(
                snapshot: current,
                outcome: .rejectedInvalidActivityRevision,
                didPersist: false
            )
        }
        let currentPayload = current?.dayIdentifier == snapshot.stats.dayIdentifier ? current : nil
        let useFallbackActivity = fallbackActivitySnapshot != nil && shouldAcceptIncomingActivity(
            currentActivity: currentPayload?.activitySnapshot,
            currentRevision: currentPayload?.activityRevision,
            incomingActivity: fallbackActivitySnapshot,
            incomingRevision: fallbackActivityRevision
        )
        return saveLocked(
            snapshot: snapshot,
            activitySnapshot: useFallbackActivity
                ? fallbackActivitySnapshot
                : currentPayload?.activitySnapshot ?? fallbackActivitySnapshot,
            activityRevision: useFallbackActivity
                ? fallbackActivityRevision
                : currentPayload?.activityRevision,
            highestRevision: state.revisionFloor,
            current: current
        )
    }

    @discardableResult
    public func updateActivitySlice(
        _ activitySnapshot: GitTodayActivitySnapshot,
        activityRevision: Int64? = nil,
        fallbackSnapshot: TinyBuddySnapshot
    ) -> UpdateResult {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }

        guard !isInWriteCooldown else {
            return cooldownResult()
        }

        let state = readStateLocked(repair: true)
        let current = state.snapshot
        guard state.diagnosticReason != .versionIncompatible else {
            return UpdateResult(
                snapshot: nil,
                outcome: .versionIncompatible,
                didPersist: false
            )
        }
        guard activityRevision.map({ $0 >= 0 }) ?? true else {
            return UpdateResult(
                snapshot: current,
                outcome: .rejectedInvalidActivityRevision,
                didPersist: false
            )
        }
        let currentPayload = current?.dayIdentifier == fallbackSnapshot.stats.dayIdentifier ? current : nil
        guard shouldAcceptIncomingActivity(
            currentActivity: currentPayload?.activitySnapshot,
            currentRevision: currentPayload?.activityRevision,
            incomingActivity: activitySnapshot,
            incomingRevision: activityRevision
        ) else {
            let outcome: UpdateOutcome = currentPayload?.activitySnapshot == activitySnapshot
                && currentPayload?.activityRevision == activityRevision
                ? .alreadyCurrent
                : .rejectedStaleActivity
            return UpdateResult(
                snapshot: currentPayload ?? current,
                outcome: outcome,
                didPersist: false
            )
        }
        return saveLocked(
            snapshot: currentPayload?.snapshot ?? fallbackSnapshot,
            activitySnapshot: activitySnapshot,
            activityRevision: activityRevision,
            highestRevision: state.revisionFloor,
            current: current
        )
    }

    /// Publishes user-confirmed focus-session aggregates in the same committed
    /// snapshot read by the app, HUD, and Widget. A delayed older edit cannot
    /// replace a newer session revision.
    @discardableResult
    public func updateFocusSessionSlice(
        _ focusSessionSnapshot: FocusSessionDerivedSnapshot,
        fallbackSnapshot: TinyBuddySnapshot
    ) -> UpdateResult {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }
        guard !isInWriteCooldown else { return cooldownResult() }
        let state = readStateLocked(repair: true)
        let current = state.snapshot
        guard state.diagnosticReason != .versionIncompatible else {
            return UpdateResult(snapshot: nil, outcome: .versionIncompatible, didPersist: false)
        }
        guard focusSessionSnapshot.dayIdentifier == fallbackSnapshot.stats.dayIdentifier else {
            return UpdateResult(snapshot: current, outcome: .alreadyCurrent, didPersist: false)
        }
        let currentPayload = current?.dayIdentifier == focusSessionSnapshot.dayIdentifier ? current : nil
        if let existing = currentPayload?.focusSessionSnapshot,
           existing.revision > focusSessionSnapshot.revision {
            return UpdateResult(snapshot: currentPayload, outcome: .alreadyCurrent, didPersist: false)
        }
        // The legacy DailyStats mirror is updated by the app after this write,
        // but App/HUD/Widget must already agree through this authoritative
        // combined snapshot.  Do not retain its old focusCount here.
        let baseSnapshot = currentPayload?.snapshot ?? fallbackSnapshot
        let synchronizedSnapshot = TinyBuddySnapshot(
            status: baseSnapshot.status,
            stats: DailyStats(
                dayIdentifier: focusSessionSnapshot.dayIdentifier,
                focusCount: focusSessionSnapshot.completedSessionCount,
                completionCount: baseSnapshot.stats.completionCount
            )
        )
        let copied = TinyBuddyCombinedSnapshot(
            revision: currentPayload?.revision ?? 0,
            dayIdentifier: focusSessionSnapshot.dayIdentifier,
            snapshot: synchronizedSnapshot,
            activitySnapshot: currentPayload?.activitySnapshot ?? GitTodayActivitySnapshot(focusBlockCount: nil, commitCount: nil),
            activityRevision: currentPayload?.activityRevision,
            focusSessionSnapshot: focusSessionSnapshot
        )
        return saveLocked(
            snapshot: copied.snapshot,
            activitySnapshot: copied.activitySnapshot,
            activityRevision: copied.activityRevision,
            focusSessionSnapshot: focusSessionSnapshot,
            highestRevision: state.revisionFloor,
            current: current
        )
    }

    /// Publishes the session-archive-derived history view in the same atomic
    /// snapshot consumed by every presentation entry point. The archive
    /// revision is the ordering authority: a delayed publication cannot undo
    /// a newer confirmed archive, while equal revisions may refresh changed
    /// goal/project configuration.
    @discardableResult
    public func updateFocusHistorySlice(
        _ focusHistoryPublication: FocusHistoryPublication,
        fallbackSnapshot: TinyBuddySnapshot
    ) -> UpdateResult {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }
        guard !isInWriteCooldown else { return cooldownResult() }

        let state = readStateLocked(repair: true)
        let current = state.snapshot
        guard state.diagnosticReason != .versionIncompatible else {
            return UpdateResult(snapshot: nil, outcome: .versionIncompatible, didPersist: false)
        }
        guard Self.isValidFocusHistoryPublication(
            focusHistoryPublication,
            dayIdentifier: fallbackSnapshot.stats.dayIdentifier
        ) else {
            return UpdateResult(snapshot: current, outcome: .persistenceFailed, didPersist: false)
        }

        let currentPayload = current?.dayIdentifier == fallbackSnapshot.stats.dayIdentifier
            ? current
            : nil
        if let existing = currentPayload?.focusHistoryPublication {
            if existing.revision > focusHistoryPublication.revision {
                return UpdateResult(
                    snapshot: currentPayload,
                    outcome: .alreadyCurrent,
                    didPersist: false
                )
            }
            if existing == focusHistoryPublication {
                return UpdateResult(
                    snapshot: currentPayload,
                    outcome: .alreadyCurrent,
                    didPersist: false
                )
            }
        }

        return saveLocked(
            snapshot: currentPayload?.snapshot ?? fallbackSnapshot,
            activitySnapshot: currentPayload?.activitySnapshot,
            activityRevision: currentPayload?.activityRevision,
            focusHistoryPublication: focusHistoryPublication,
            highestRevision: state.revisionFloor,
            current: current
        )
    }

    // V1 payload codec. It remains public for compatibility and migration tests.
    public static func encode(_ snapshot: TinyBuddyCombinedSnapshot) -> String {
        let projectName = snapshot.activitySnapshot.recentProjectName ?? ""
        return [
            String(snapshot.revision),
            snapshot.dayIdentifier,
            snapshot.snapshot.status.rawValue,
            snapshot.snapshot.stats.dayIdentifier,
            String(max(0, snapshot.snapshot.stats.focusCount)),
            String(max(0, snapshot.snapshot.stats.completionCount)),
            snapshot.activitySnapshot.focusBlockCount.map { String(max(0, $0)) } ?? "",
            snapshot.activitySnapshot.commitCount.map { String(max(0, $0)) } ?? "",
            Data(projectName.utf8).base64EncodedString(),
            snapshot.activityRevision.map(String.init) ?? ""
        ].joined(separator: "\t")
    }

    public static func decode(_ value: String) -> TinyBuddyCombinedSnapshot? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard (fields.count == 9 || fields.count == 10),
              let revision = Int64(fields[0]), revision >= 0,
              TinyBuddyTimeContext.isValidDayIdentifier(String(fields[1])),
              let status = PetStatus(rawValue: String(fields[2])),
              fields[1] == fields[3],
              let focusCount = Int(fields[4]), focusCount >= 0,
              let completionCount = Int(fields[5]), completionCount >= 0,
              let activityFocusCount = optionalNonnegativeInteger(from: fields[6]),
              let activityCommitCount = optionalNonnegativeInteger(from: fields[7]),
              let projectData = Data(base64Encoded: String(fields[8])),
              let projectName = String(data: projectData, encoding: .utf8) else {
            return nil
        }
        let activityRevision = fields.count == 10
            ? optionalNonnegativeRevision(from: fields[9])
            : .some(nil)
        guard let activityRevision else {
            return nil
        }

        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: String(fields[1]),
            snapshot: TinyBuddySnapshot(
                status: status,
                stats: DailyStats(
                    dayIdentifier: String(fields[3]),
                    focusCount: focusCount,
                    completionCount: completionCount
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: activityFocusCount,
                commitCount: activityCommitCount,
                recentProjectName: normalizedProjectName.isEmpty ? nil : normalizedProjectName
            ),
            activityRevision: activityRevision
        )
    }

    // V2 is a checksummed envelope around the compatible V1 payload. The revision
    // has its own checksum, so payload damage cannot forge the recovery floor.
    public static func encodeV2(_ snapshot: TinyBuddyCombinedSnapshot) -> String {
        let normalizedSnapshot = normalized(snapshot)
        let payload = Data(encode(normalizedSnapshot).utf8).base64EncodedString()
        return [
            "2",
            String(normalizedSnapshot.revision),
            revisionChecksum(normalizedSnapshot.revision),
            checksum(Data(payload.utf8)),
            payload
        ].joined(separator: "\t")
    }

    public static func decodeV2(_ value: String) -> TinyBuddyCombinedSnapshot? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let claimedRevision = verifiedV2ClaimedRevision(value) else {
            return nil
        }
        let payload = String(fields[4])
        guard fields[3] == Substring(checksum(Data(payload.utf8))),
              let payloadData = Data(base64Encoded: payload),
              let legacyValue = String(data: payloadData, encoding: .utf8),
              let snapshot = decode(legacyValue),
              snapshot.revision == claimedRevision else {
            return nil
        }
        return snapshot
    }

    public static func encodeRevisionMarker(_ revision: Int64) -> String? {
        guard revision >= 0 else {
            return nil
        }
        return ["2", String(revision), revisionChecksum(revision)].joined(separator: "\t")
    }

    public static func decodeRevisionMarker(_ value: String) -> Int64? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == "2",
              let revision = Int64(fields[1]), revision >= 0,
              fields[2] == Substring(revisionChecksum(revision)) else {
            return nil
        }
        return revision
    }

    // V3 uses a compact binary plist payload instead of the tab-separated V1
    // text. The envelope format remains compatible: the version field changes
    // from "2" to "3" so V2-only readers see versionIncompatible and stop.
    public static func encodeV3(_ snapshot: TinyBuddyCombinedSnapshot) -> String? {
        let normalizedSnapshot = normalized(snapshot)
        guard let payloadData = v3PayloadData(normalizedSnapshot) else {
            return nil
        }
        let encodedPayload = payloadData.base64EncodedString()
        return [
            "3",
            String(normalizedSnapshot.revision),
            revisionChecksum(normalizedSnapshot.revision),
            checksum(payloadData),
            encodedPayload
        ].joined(separator: "\t")
    }

    public static func decodeV3(_ value: String) -> TinyBuddyCombinedSnapshot? {
        guard let claimedRevision = verifiedV3ClaimedRevision(value) else {
            return nil
        }
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let payloadData = Data(base64Encoded: String(fields[4])) else {
            return nil
        }
        guard fields[3] == Substring(checksum(payloadData)),
              let snapshot = v3Snapshot(from: payloadData),
              snapshot.revision == claimedRevision else {
            return nil
        }
        return snapshot
    }

    private static func v3PayloadData(_ snapshot: TinyBuddyCombinedSnapshot) -> Data? {
        let projectName = snapshot.activitySnapshot.recentProjectName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var dict: [String: Any] = [
            "rv": snapshot.revision,
            "di": snapshot.dayIdentifier,
            "st": snapshot.snapshot.status.rawValue,
            "fc": max(0, snapshot.snapshot.stats.focusCount),
            "cc": max(0, snapshot.snapshot.stats.completionCount)
        ]
        if let af = snapshot.activitySnapshot.focusBlockCount {
            dict["af"] = max(0, af)
        }
        if let ac = snapshot.activitySnapshot.commitCount {
            dict["ac"] = max(0, ac)
        }
        if let rp = projectName, !rp.isEmpty {
            dict["rp"] = rp
        }
        if let ar = snapshot.activityRevision {
            dict["ar"] = ar
        }
        if let focus = snapshot.focusSessionSnapshot,
           focus.dayIdentifier == snapshot.dayIdentifier {
            dict["fsr"] = focus.revision
            dict["fsd"] = max(0, focus.focusDuration)
            dict["fsc"] = max(0, focus.completedSessionCount)
            dict["fsp"] = focus.projectDurations.mapValues { max(0, $0) }
        }
        if let history = snapshot.focusHistoryPublication {
            guard isValidFocusHistoryPublication(history, dayIdentifier: snapshot.dayIdentifier),
                  let historyData = try? PropertyListEncoder().encode(history) else {
                return nil
            }
            dict["fh"] = historyData
        }
        return try? PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .binary,
            options: 0
        )
    }

    private static func v3Snapshot(from payloadData: Data) -> TinyBuddyCombinedSnapshot? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let dict = try? PropertyListSerialization.propertyList(
            from: payloadData,
            options: [],
            format: &format
        ) as? [String: Any] else {
            return nil
        }

        guard let revision = dict["rv"] as? Int64, revision >= 0,
              let dayIdentifier = dict["di"] as? String,
              TinyBuddyTimeContext.isValidDayIdentifier(dayIdentifier),
              let statusRaw = dict["st"] as? String,
              let status = PetStatus(rawValue: statusRaw),
              let focusCount = dict["fc"] as? Int, focusCount >= 0,
              let completionCount = dict["cc"] as? Int, completionCount >= 0 else {
            return nil
        }

        let activityFocusBlockCount = dict["af"] as? Int
        let activityCommitCount = dict["ac"] as? Int
        let recentProjectName = dict["rp"] as? String
        let activityRevision = dict["ar"] as? Int64
        let focusSessionSnapshot: FocusSessionDerivedSnapshot?
        if let revision = dict["fsr"] as? Int64,
           let duration = dict["fsd"] as? Double,
           let count = dict["fsc"] as? Int,
           let projects = dict["fsp"] as? [String: Double],
           revision >= 0, duration >= 0, count >= 0,
           projects.values.allSatisfy({ $0 >= 0 }) {
            focusSessionSnapshot = FocusSessionDerivedSnapshot(
                revision: revision, dayIdentifier: dayIdentifier, focusDuration: duration,
                projectDurations: projects, completedSessionCount: count
            )
        } else if ["fsr", "fsd", "fsc", "fsp"].contains(where: { dict[$0] != nil }) {
            return nil
        } else {
            focusSessionSnapshot = nil
        }

        let focusHistoryPublication: FocusHistoryPublication?
        if let historyData = dict["fh"] as? Data {
            guard let decoded = try? PropertyListDecoder().decode(
                FocusHistoryPublication.self,
                from: historyData
            ), Self.isValidFocusHistoryPublication(decoded, dayIdentifier: dayIdentifier) else {
                return nil
            }
            focusHistoryPublication = decoded
        } else if dict["fh"] != nil {
            return nil
        } else {
            focusHistoryPublication = nil
        }

        let normalizedProjectName = recentProjectName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: status,
                stats: DailyStats(
                    dayIdentifier: dayIdentifier,
                    focusCount: focusCount,
                    completionCount: completionCount
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: activityFocusBlockCount,
                commitCount: activityCommitCount,
                recentProjectName: normalizedProjectName?.isEmpty == false ? normalizedProjectName : nil
            ),
            activityRevision: activityRevision,
            focusSessionSnapshot: focusSessionSnapshot,
            focusHistoryPublication: focusHistoryPublication
        )
    }

    private static func verifiedV3ClaimedRevision(_ value: String) -> Int64? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5,
              fields[0] == "3",
              let revision = Int64(fields[1]), revision >= 0,
              fields[2] == Substring(revisionChecksum(revision)) else {
            return nil
        }
        return revision
    }

    public static func encodeSchemaVersion(_ version: Int = currentSchemaVersion) -> String? {
        guard version >= legacySchemaVersion else {
            return nil
        }
        return [String(version), checksum(Data("schema\t\(version)".utf8))]
            .joined(separator: "\t")
    }

    public static func decodeSchemaVersion(_ value: String) -> Int? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let version = Int(fields[0]), version >= 0,
              fields[1] == Substring(checksum(Data("schema\t\(version)".utf8))) else {
            return nil
        }
        return version
    }

    private func readStateLocked(
        repair: Bool,
        expectedDayIdentifier: String? = nil
    ) -> ReadState {
        synchronizeReads()
        fallbackDefaults?.synchronize()

        let sources = sourceValues()
        var diagnosticReason = Self.diagnosticReason(in: sources)
        if diagnosticReason == .versionIncompatible {
            return ReadState(snapshot: nil, revisionFloor: 0, diagnosticReason: diagnosticReason)
        }
        let committedMarkerRevision = sources.compactMap { source in
            source.committedRevisionMarker.flatMap(Self.decodeRevisionMarker)
        }.max()
        var committedCandidates: [TinyBuddyCombinedSnapshot] = []
        var stagedCandidates: [TinyBuddyCombinedSnapshot] = []
        var hasV2Evidence = committedMarkerRevision != nil

        // V3 takes priority, with V2 as a fallback. V1 legacy is the final
        // recovery path. Direct defaults remain first, followed by the on-disk
        // cache and explicit fallback.
        for source in sources {
            let sourceCommittedRevision = source.committedRevisionMarker
                .flatMap(Self.decodeRevisionMarker)
            if source.revisionMarker.flatMap(Self.decodeRevisionMarker) != nil {
                hasV2Evidence = true
            }
            for value in [source.v2SlotA, source.v2SlotB, source.legacySnapshot] {
                guard let value else {
                    continue
                }
                if Self.verifiedV3ClaimedRevision(value) != nil
                    || Self.verifiedV2ClaimedRevision(value) != nil {
                    hasV2Evidence = true
                }
                guard let snapshot = Self.decodeV3(value)
                    ?? Self.decodeV2(value) else {
                    continue
                }
                if sourceCommittedRevision.map({ snapshot.revision <= $0 }) == true {
                    committedCandidates.append(snapshot)
                } else {
                    stagedCandidates.append(snapshot)
                }
            }
        }

        var legacyCandidates: [TinyBuddyCombinedSnapshot] = []
        for source in sources {
            for value in [source.legacySnapshot, source.migrationBackupV1].compactMap({ $0 }) {
                guard Self.decodeV3(value) == nil,
                      Self.decodeV2(value) == nil,
                      let snapshot = Self.decode(value) else {
                    continue
                }
                let sourceCommittedRevision = source.committedRevisionMarker
                    .flatMap(Self.decodeRevisionMarker)
                let sourceReservedRevision = source.revisionMarker
                    .flatMap(Self.decodeRevisionMarker)
                if !hasV2Evidence
                    || source.legacyHighestRevision == snapshot.revision
                    || sourceReservedRevision.map({ snapshot.revision <= $0 }) == true
                    || sourceCommittedRevision.map({ snapshot.revision <= $0 }) == true {
                    legacyCandidates.append(snapshot)
                }
            }
        }

        let allCandidates = committedCandidates + legacyCandidates
        let candidates = allCandidates.filter {
            expectedDayIdentifier == nil || $0.dayIdentifier == expectedDayIdentifier
        }
        let scopedStagedCandidates = stagedCandidates.filter {
            expectedDayIdentifier == nil || $0.dayIdentifier == expectedDayIdentifier
        }
        let selected = Self.newestSnapshot(in: candidates)
        let newestStaged = Self.newestSnapshot(in: scopedStagedCandidates)
        if diagnosticReason == nil,
           expectedDayIdentifier != nil,
           selected == nil,
           newestStaged == nil,
           (!allCandidates.isEmpty || !stagedCandidates.isEmpty) {
            diagnosticReason = .staleData
        }
        let durableRevisionFloor = max(
            committedMarkerRevision ?? 0,
            allCandidates.map(\.revision).max() ?? 0
        )

        var revisionFloor = durableRevisionFloor
        for source in sources {
            if let marker = source.revisionMarker,
               let markedRevision = Self.decodeRevisionMarker(marker) {
                revisionFloor = max(revisionFloor, markedRevision)
            }
            for value in [source.v2SlotA, source.v2SlotB] {
                if let claimedRevision = value.flatMap(Self.verifiedV3ClaimedRevision)
                    ?? value.flatMap(Self.verifiedV2ClaimedRevision) {
                    revisionFloor = max(revisionFloor, claimedRevision)
                }
            }
            if let value = source.legacySnapshot,
               let claimedRevision = Self.verifiedV3ClaimedRevision(value)
                ?? Self.verifiedV2ClaimedRevision(value) {
                revisionFloor = max(revisionFloor, claimedRevision)
            } else if let legacyHighestRevision = source.legacyHighestRevision,
                      let legacyValue = source.legacySnapshot,
                      Self.legacyClaimedRevision(legacyValue) == legacyHighestRevision {
                revisionFloor = max(revisionFloor, legacyHighestRevision)
            }
        }

        if repair,
           let newestStaged,
           selected.map({ newestStaged.revision > $0.revision }) ?? true,
           repairLocked(newestStaged, directSource: sources[0]) {
            return ReadState(
                snapshot: newestStaged,
                revisionFloor: revisionFloor,
                diagnosticReason: diagnosticReason
            )
        }

        guard let selected else {
            return ReadState(
                snapshot: nil,
                revisionFloor: revisionFloor,
                diagnosticReason: diagnosticReason
            )
        }

        if repair {
            _ = repairLocked(selected, directSource: sources[0])
            return ReadState(
                snapshot: selected,
                revisionFloor: revisionFloor,
                diagnosticReason: diagnosticReason
            )
        }
        return ReadState(
            snapshot: selected,
            revisionFloor: revisionFloor,
            diagnosticReason: diagnosticReason
        )
    }

    private func validatedRead(
        from snapshot: TinyBuddyCombinedSnapshot?,
        expectedDayIdentifier: String?,
        attemptCount: Int
    ) -> TinyBuddyValidatedCombinedSnapshotRead {
        let safe = safeSnapshot(snapshot, expectedDayIdentifier: expectedDayIdentifier)
        if snapshot != nil, safe == nil {
            return TinyBuddyValidatedCombinedSnapshotRead(
                snapshot: nil,
                observation: observation(
                    reason: .staleData,
                    recovery: .stopped,
                    attemptCount: attemptCount
                )
            )
        }
        if let safe, !validateSnapshot(safe) {
            return TinyBuddyValidatedCombinedSnapshotRead(
                snapshot: nil,
                observation: observation(
                    reason: .snapshotCorrupt,
                    recovery: .stopped,
                    attemptCount: attemptCount
                )
            )
        }
        return TinyBuddyValidatedCombinedSnapshotRead(snapshot: safe, observation: nil)
    }

    private func safeSnapshot(
        _ snapshot: TinyBuddyCombinedSnapshot?,
        expectedDayIdentifier: String?
    ) -> TinyBuddyCombinedSnapshot? {
        guard let snapshot else {
            return nil
        }
        guard expectedDayIdentifier == nil || snapshot.dayIdentifier == expectedDayIdentifier else {
            return nil
        }
        return snapshot
    }

    private func observation(
        reason: TinyBuddySharedSnapshotReason,
        recovery: TinyBuddySharedSnapshotRecovery,
        attemptCount: Int
    ) -> TinyBuddySharedSnapshotObservation {
        TinyBuddySharedSnapshotObservation(
            phase: .snapshotRead,
            reason: reason,
            recovery: recovery,
            attemptCount: attemptCount
        )
    }

    private static func diagnosticReason(
        in sources: [SourceValues]
    ) -> TinyBuddySharedSnapshotReason? {
        let snapshotValues = sources.flatMap { source in
            [source.v2SlotA, source.v2SlotB, source.legacySnapshot].compactMap { $0 }
        }
        let markers = sources.flatMap { source in
            [source.revisionMarker, source.committedRevisionMarker].compactMap { $0 }
        }
        let schemaMarkers = sources.compactMap(\.schemaVersionMarker)
        if snapshotValues.contains(where: isUnknownEnvelopeVersion)
            || markers.contains(where: isUnknownMarkerVersion)
            || schemaMarkers.contains(where: isFutureSchemaVersion) {
            return .versionIncompatible
        }
        if snapshotValues.contains(where: isMalformedSnapshotValue)
            || markers.contains(where: isMalformedRevisionMarker)
            || schemaMarkers.contains(where: isMalformedSchemaVersion) {
            return .snapshotCorrupt
        }
        return nil
    }

    private static func isMalformedSnapshotValue(_ value: String) -> Bool {
        guard value.isEmpty == false else {
            return false
        }
        return decodeV3(value) == nil && decodeV2(value) == nil && decode(value) == nil
    }

    private static func isUnknownEnvelopeVersion(_ value: String) -> Bool {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        // A complete legacy payload has 9 or 10 fields and starts with a
        // revision, not an envelope version. Short numeric input instead has
        // enough shape to be a truncated V2 envelope, so preserve the safer
        // version-incompatible distinction for future writers.
        guard fields.count <= 5,
              let firstField = fields.first,
              let version = Int(firstField),
              version >= 0 else {
            return false
        }
        return version != 2 && version != 3
    }

    private static func isUnknownMarkerVersion(_ value: String) -> Bool {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard let firstField = fields.first,
              let version = Int(firstField),
              version >= 0 else {
            return false
        }
        return version != 2
    }

    private static func isMalformedRevisionMarker(_ value: String) -> Bool {
        value.isEmpty == false && decodeRevisionMarker(value) == nil
    }

    private static func isFutureSchemaVersion(_ value: String) -> Bool {
        guard let firstField = value.split(separator: "\t", omittingEmptySubsequences: false).first,
              let version = Int(firstField) else {
            return false
        }
        return version > currentSchemaVersion
    }

    private static func isMalformedSchemaVersion(_ value: String) -> Bool {
        guard value.isEmpty == false, !isFutureSchemaVersion(value) else {
            return false
        }
        guard let version = decodeSchemaVersion(value) else {
            return true
        }
        return migrationPath(from: version) == nil
    }

    private static func newestSnapshot(
        in candidates: [TinyBuddyCombinedSnapshot]
    ) -> TinyBuddyCombinedSnapshot? {
        var selected: TinyBuddyCombinedSnapshot?
        for candidate in candidates {
            if selected == nil || candidate.revision > selected!.revision {
                selected = candidate
            }
        }
        return selected
    }

    private func sourceValues() -> [SourceValues] {
        let directPreferences = directPreferencesProvider()
        let direct = SourceValues(
            legacySnapshot: directPreferences[Key.snapshot] as? String,
            v2SlotA: directPreferences[Key.snapshotV2SlotA] as? String,
            v2SlotB: directPreferences[Key.snapshotV2SlotB] as? String,
            legacyHighestRevision: Self.nonnegativeRevision(
                directPreferences[Key.highestRevision]
            ),
            revisionMarker: directPreferences[Key.highestRevisionV2] as? String,
            committedRevisionMarker: directPreferences[Key.committedRevisionV2] as? String,
            schemaVersionMarker: directPreferences[Key.schemaVersion] as? String,
            migrationBackupV1: directPreferences[Key.migrationBackupV1] as? String
        )
        let sharedPreferences = sharedPreferencesProvider()
        let shared = SourceValues(
            legacySnapshot: sharedPreferences?[Key.snapshot] as? String,
            v2SlotA: sharedPreferences?[Key.snapshotV2SlotA] as? String,
            v2SlotB: sharedPreferences?[Key.snapshotV2SlotB] as? String,
            legacyHighestRevision: Self.nonnegativeRevision(sharedPreferences?[Key.highestRevision]),
            revisionMarker: sharedPreferences?[Key.highestRevisionV2] as? String,
            committedRevisionMarker: sharedPreferences?[Key.committedRevisionV2] as? String,
            schemaVersionMarker: sharedPreferences?[Key.schemaVersion] as? String,
            migrationBackupV1: sharedPreferences?[Key.migrationBackupV1] as? String
        )
        let fallback = SourceValues(
            legacySnapshot: fallbackDefaults?.string(forKey: Key.snapshot),
            v2SlotA: fallbackDefaults?.string(forKey: Key.snapshotV2SlotA),
            v2SlotB: fallbackDefaults?.string(forKey: Key.snapshotV2SlotB),
            legacyHighestRevision: Self.nonnegativeRevision(
                fallbackDefaults?.object(forKey: Key.highestRevision)
            ),
            revisionMarker: fallbackDefaults?.string(forKey: Key.highestRevisionV2),
            committedRevisionMarker: fallbackDefaults?.string(forKey: Key.committedRevisionV2),
            schemaVersionMarker: fallbackDefaults?.string(forKey: Key.schemaVersion),
            migrationBackupV1: fallbackDefaults?.string(forKey: Key.migrationBackupV1)
        )
        return [direct, shared, fallback]
    }

    private func repairLocked(
        _ canonical: TinyBuddyCombinedSnapshot,
        directSource: SourceValues
    ) -> Bool {
        guard ensureCurrentSchemaLocked(directSource: directSource),
              reserveRevisionLocked(
            canonical.revision,
            currentDirectRevision: directSource.revisionMarker.flatMap(Self.decodeRevisionMarker)
        ) else {
            return false
        }

        let slots = directSlots()
        guard let encoded = Self.encodeV3(canonical) else {
            return false
        }
        var writtenTarget: DirectSlot?

        if !slots.contains(where: { $0.snapshot == canonical }) {
            let targetKey = transactionalTargetKey(for: slots)
            let target = slots.first(where: { $0.key == targetKey })
                ?? DirectSlot(key: targetKey, rawValue: nil, snapshot: nil)
            guard writeValue(encoded, targetKey),
                  synchronizeWrites(),
                  directString(forKey: targetKey).flatMap(Self.decodeV3) == canonical else {
                restoreValueLocked(target.rawValue, forKey: target.key)
                _ = synchronizeWrites()
                return false
            }
            writtenTarget = target
        }

        let previousCommittedMarker = directString(forKey: Key.committedRevisionV2)
        let currentCommittedRevision = previousCommittedMarker.flatMap(Self.decodeRevisionMarker)
        if currentCommittedRevision.map({ $0 < canonical.revision }) ?? true {
            guard let marker = Self.encodeRevisionMarker(canonical.revision),
                  writeValue(marker, Key.committedRevisionV2),
                  synchronizeWrites(),
                  directString(forKey: Key.committedRevisionV2)
                    .flatMap(Self.decodeRevisionMarker) == canonical.revision else {
                restoreValueLocked(previousCommittedMarker, forKey: Key.committedRevisionV2)
                if let writtenTarget {
                    restoreValueLocked(writtenTarget.rawValue, forKey: writtenTarget.key)
                }
                _ = synchronizeWrites()
                return false
            }
        }

        repairAncillaryCopiesLocked(canonical)
        let committedRevision = directString(forKey: Key.committedRevisionV2)
            .flatMap(Self.decodeRevisionMarker)
        return committedRevision.map { $0 >= canonical.revision } == true
            && directSlots().contains { $0.snapshot == canonical }
    }

    private func ensureCurrentSchemaLocked(directSource: SourceValues) -> Bool {
        if directSource.schemaVersionMarker.flatMap(Self.decodeSchemaVersion)
            == Self.currentSchemaVersion {
            return true
        }

        // Use the migrator to validate and optionally decode legacy data before
        // backing it up.  `sanitizeToCurrentSchema` handles V1, V2, and V3
        // uniformly so legacy-only decode logic is no longer needed here.
        if directString(forKey: Key.migrationBackupV1) == nil,
           let legacyValue = directSource.legacySnapshot,
           Self.sanitizeToCurrentSchema(legacyValue).snapshot != nil {
            guard writeValue(legacyValue, Key.migrationBackupV1),
                  synchronizeWrites(),
                  directString(forKey: Key.migrationBackupV1) == legacyValue else {
                return false
            }
        }

        let previousMarker = directString(forKey: Key.schemaVersion)
        guard let marker = Self.encodeSchemaVersion(),
              writeValue(marker, Key.schemaVersion),
              synchronizeWrites(),
              directString(forKey: Key.schemaVersion)
                .flatMap(Self.decodeSchemaVersion) == Self.currentSchemaVersion else {
            restoreValueLocked(previousMarker, forKey: Key.schemaVersion)
            _ = synchronizeWrites()
            return false
        }

        Self.logger.info(
            "Schema upgraded to v\(Self.currentSchemaVersion) via migrator"
        )
        return true
    }

    private func repairAncillaryCopiesLocked(_ canonical: TinyBuddyCombinedSnapshot) {
        guard let encodedV3 = Self.encodeV3(canonical) else {
            return
        }
        let slots = directSlots()
        var changed = false

        if slots.contains(where: { $0.snapshot == canonical }) {
            for slot in slots where slot.snapshot == nil
                || (slot.snapshot?.revision == canonical.revision && slot.snapshot != canonical) {
                changed = writeValue(encodedV3, slot.key) || changed
            }
        }

        let legacyValue = Self.encode(canonical)
        if directString(forKey: Key.snapshot) != legacyValue {
            changed = writeValue(legacyValue, Key.snapshot) || changed
        }
        if Self.nonnegativeRevision(directValue(forKey: Key.highestRevision))
            != canonical.revision {
            changed = writeValue(canonical.revision, Key.highestRevision) || changed
        }
        if changed {
            _ = synchronizeWrites()
        }
    }

    private func restoreValueLocked(_ value: String?, forKey key: String) {
        _ = writeValue(value ?? "", key)
    }

    @discardableResult
    private func reserveRevisionLocked(
        _ revision: Int64,
        currentDirectRevision: Int64? = nil
    ) -> Bool {
        let previousMarker = directString(forKey: Key.highestRevisionV2)
        let currentRevision = currentDirectRevision
            ?? previousMarker.flatMap(Self.decodeRevisionMarker)
        guard currentRevision == nil || currentRevision! < revision else {
            return true
        }
        guard let marker = Self.encodeRevisionMarker(revision),
              writeValue(marker, Key.highestRevisionV2),
              synchronizeWrites(),
              directString(forKey: Key.highestRevisionV2)
                .flatMap(Self.decodeRevisionMarker) == revision else {
            restoreValueLocked(previousMarker, forKey: Key.highestRevisionV2)
            _ = synchronizeWrites()
            return false
        }
        _ = writeValue(revision, Key.highestRevision)
        _ = synchronizeWrites()
        return true
    }

    private func directSlots() -> [DirectSlot] {
        let directPreferences = directPreferencesProvider()
        let slotAValue = directPreferences[Key.snapshotV2SlotA] as? String
        let slotBValue = directPreferences[Key.snapshotV2SlotB] as? String
        return [
            DirectSlot(
                key: Key.snapshotV2SlotA,
                rawValue: slotAValue,
                snapshot: slotAValue.flatMap { Self.decodeV3($0) ?? Self.decodeV2($0) }
            ),
            DirectSlot(
                key: Key.snapshotV2SlotB,
                rawValue: slotBValue,
                snapshot: slotBValue.flatMap { Self.decodeV3($0) ?? Self.decodeV2($0) }
            )
        ]
    }

    private func directString(forKey key: String) -> String? {
        directValue(forKey: key) as? String
    }

    private func directValue(forKey key: String) -> Any? {
        directPreferencesProvider()[key]
    }

    private func transactionalTargetKey(for slots: [DirectSlot]) -> String {
        guard slots.count == 2 else {
            return Key.snapshotV2SlotA
        }
        if slots[0].snapshot == nil {
            return slots[0].key
        }
        if slots[1].snapshot == nil {
            return slots[1].key
        }
        if slots[0].snapshot!.revision < slots[1].snapshot!.revision {
            return slots[0].key
        }
        return slots[1].key
    }

    private static func optionalNonnegativeInteger(from value: Substring) -> Int?? {
        guard !value.isEmpty else { return .some(nil) }
        guard let integer = Int(value), integer >= 0 else { return nil }
        return .some(integer)
    }

    private static func optionalNonnegativeRevision(from value: Substring) -> Int64?? {
        guard !value.isEmpty else { return .some(nil) }
        guard let revision = Int64(value), revision >= 0 else { return nil }
        return .some(revision)
    }

    private static func nonnegativeRevision(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              number.int64Value >= 0 else {
            return nil
        }
        return number.int64Value
    }

    private static func verifiedV2ClaimedRevision(_ value: String) -> Int64? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5,
              fields[0] == "2",
              let revision = Int64(fields[1]), revision >= 0,
              fields[2] == Substring(revisionChecksum(revision)) else {
            return nil
        }
        return revision
    }

    private static func legacyClaimedRevision(_ value: String) -> Int64? {
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard (fields.count == 9 || fields.count == 10),
              let revision = Int64(fields[0]), revision >= 0 else {
            return nil
        }
        return revision
    }

    private static func revisionChecksum(_ revision: Int64) -> String {
        checksum(Data("2\t\(revision)".utf8))
    }

    private static func normalized(
        _ snapshot: TinyBuddyCombinedSnapshot
    ) -> TinyBuddyCombinedSnapshot {
        let projectName = snapshot.activitySnapshot.recentProjectName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TinyBuddyCombinedSnapshot(
            revision: snapshot.revision,
            dayIdentifier: snapshot.dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: snapshot.snapshot.status,
                stats: DailyStats(
                    dayIdentifier: snapshot.snapshot.stats.dayIdentifier,
                    focusCount: max(0, snapshot.snapshot.stats.focusCount),
                    completionCount: max(0, snapshot.snapshot.stats.completionCount)
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: snapshot.activitySnapshot.focusBlockCount.map { max(0, $0) },
                commitCount: snapshot.activitySnapshot.commitCount.map { max(0, $0) },
                recentProjectName: projectName?.isEmpty == false ? projectName : nil
            ),
            activityRevision: snapshot.activityRevision,
            focusSessionSnapshot: normalizedFocusSessionSnapshot(
                snapshot.focusSessionSnapshot,
                dayIdentifier: snapshot.dayIdentifier
            ),
            focusHistoryPublication: snapshot.focusHistoryPublication
        )
    }

    private static func checksum(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let value = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - value.count) + value
    }

    private static func normalizedFocusSessionSnapshot(
        _ snapshot: FocusSessionDerivedSnapshot?,
        dayIdentifier: String
    ) -> FocusSessionDerivedSnapshot? {
        guard let snapshot, snapshot.dayIdentifier == dayIdentifier,
              snapshot.revision >= 0, snapshot.focusDuration >= 0,
              snapshot.completedSessionCount >= 0,
              snapshot.projectDurations.values.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        return FocusSessionDerivedSnapshot(
            revision: snapshot.revision,
            dayIdentifier: snapshot.dayIdentifier,
            focusDuration: snapshot.focusDuration,
            projectDurations: snapshot.projectDurations.mapValues { max(0, $0) },
            completedSessionCount: snapshot.completedSessionCount
        )
    }

    private static func isValidFocusHistoryPublication(
        _ publication: FocusHistoryPublication,
        dayIdentifier: String
    ) -> Bool {
        guard publication.revision >= 0,
              TinyBuddyTimeContext.isValidDayIdentifier(dayIdentifier) else {
            return false
        }

        let recentDays = publication.snapshot.recentDays
        guard !recentDays.isEmpty,
              recentDays.last?.dayIdentifier == dayIdentifier,
              recentDays.allSatisfy({ TinyBuddyTimeContext.isValidDayIdentifier($0.dayIdentifier) }),
              zip(recentDays, recentDays.dropFirst()).allSatisfy({ earlier, later in
                  earlier.dayIdentifier < later.dayIdentifier
              }),
              TinyBuddyTimeContext.isValidDayIdentifier(
                publication.snapshot.currentWeek.endDayIdentifier
              ),
              publication.snapshot.currentWeek.endDayIdentifier <= dayIdentifier else {
            return false
        }

        let snapshot = publication.snapshot
        guard recentDays.allSatisfy(isValidFocusHistoryDay),
              isValidFocusHistoryWeek(snapshot.currentWeek),
              snapshot.currentGoalStreakDays.map({ $0 >= 0 }) ?? true else {
            return false
        }

        switch snapshot.sourceHealth {
        case .unavailable:
            return snapshot.state == .unknown
                && recentDays.allSatisfy({ $0.state == .unknown })
                && snapshot.currentWeek.state == .unknown
                && snapshot.currentGoalStreakDays == nil
        case .partial:
            return snapshot.state == .partial
        case .available:
            switch snapshot.state {
            case .unknown:
                return false
            case .noHistory:
                return recentDays.allSatisfy({ $0.state == .noSessions })
            case .available, .partial:
                return true
            }
        }
    }

    private static func isValidFocusHistoryDay(_ day: FocusHistoryDay) -> Bool {
        guard TinyBuddyTimeContext.isValidDayIdentifier(day.dayIdentifier) else {
            return false
        }

        switch day.state {
        case .unknown:
            return day.focusDuration == nil
                && day.completedSessionCount == nil
                && day.goalMinutes == nil
                && day.goalCompletionRate == nil
                && day.isGoalMet == nil
                && day.contributingSessionIDs == nil
        case .noSessions:
            guard day.focusDuration == 0, day.completedSessionCount == 0 else {
                return false
            }
        case .sessions:
            guard let duration = day.focusDuration,
                  duration.isFinite,
                  duration >= 0,
                  let count = day.completedSessionCount,
                  count > 0 else {
                return false
            }
        }

        if let ids = day.contributingSessionIDs {
            guard Set(ids).count == ids.count,
                  ids.count == (day.completedSessionCount ?? -1) else {
                return false
            }
        }

        if let goal = day.goalMinutes {
            guard goal > 0 else { return false }
        }
        if let rate = day.goalCompletionRate {
            guard day.goalMinutes != nil,
                  rate.isFinite,
                  (0 ... 1).contains(rate),
                  day.isGoalMet == (rate >= 1) else {
                return false
            }
        } else if day.isGoalMet != nil {
            return false
        }
        return true
    }

    private static func isValidFocusHistoryWeek(_ week: FocusHistoryWeek) -> Bool {
        guard TinyBuddyTimeContext.isValidDayIdentifier(week.startDayIdentifier),
              TinyBuddyTimeContext.isValidDayIdentifier(week.endDayIdentifier),
              week.startDayIdentifier <= week.endDayIdentifier else {
            return false
        }

        switch week.state {
        case .unknown:
            return week.focusDuration == nil
                && week.completedSessionCount == nil
                && week.goalCompletionRate == nil
                && week.goalMetDayCount == nil
                && week.configuredGoalDayCount == nil
                && week.projectDistribution == nil
        case .available, .partial:
            let hasTotals = week.focusDuration != nil || week.completedSessionCount != nil
            guard !hasTotals || (week.focusDuration != nil && week.completedSessionCount != nil) else {
                return false
            }
            if let duration = week.focusDuration,
               (!duration.isFinite || duration < 0) {
                return false
            }
            if let count = week.completedSessionCount, count < 0 {
                return false
            }
            let hasGoalValues = week.goalCompletionRate != nil
                || week.goalMetDayCount != nil
                || week.configuredGoalDayCount != nil
            guard !hasGoalValues || (week.goalCompletionRate != nil
                && week.goalMetDayCount != nil
                && week.configuredGoalDayCount != nil) else {
                return false
            }
            if let rate = week.goalCompletionRate,
               (!rate.isFinite || !(0 ... 1).contains(rate)) {
                return false
            }
            if let met = week.goalMetDayCount,
               let configured = week.configuredGoalDayCount,
               (met < 0 || configured < 0 || met > configured) {
                return false
            }
            if let projects = week.projectDistribution {
                return projects.allSatisfy { project in
                    !project.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && project.focusDuration.isFinite
                        && project.focusDuration >= 0
                        && project.completedSessionCount >= 0
                        && project.focusShare.isFinite
                        && (0 ... 1).contains(project.focusShare)
                        && (project.contributingSessionIDs.map { ids in
                            Set(ids).count == ids.count
                                && ids.count == project.completedSessionCount
                        } ?? true)
                }
            }
            return true
        }
    }

    private static func completedSessionCount(
        in publication: FocusHistoryPublication,
        for dayIdentifier: String
    ) -> Int? {
        publication.snapshot.recentDays.first(where: { $0.dayIdentifier == dayIdentifier })?
            .completedSessionCount
    }

    private func shouldAcceptIncomingActivity(
        currentActivity: GitTodayActivitySnapshot?,
        currentRevision: Int64?,
        incomingActivity: GitTodayActivitySnapshot?,
        incomingRevision: Int64?
    ) -> Bool {
        if let currentRevision {
            return incomingRevision.map { $0 > currentRevision } ?? false
        }

        if hasActivityData(currentActivity) {
            return incomingRevision != nil || hasActivityData(incomingActivity)
        }

        return incomingActivity != nil
    }

    private func hasActivityData(_ activity: GitTodayActivitySnapshot?) -> Bool {
        guard let activity else {
            return false
        }
        return activity.focusBlockCount != nil
            || activity.commitCount != nil
            || activity.recentProjectName?.isEmpty == false
    }

    private func saveLocked(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot?,
        activityRevision: Int64?,
        focusSessionSnapshot: FocusSessionDerivedSnapshot? = nil,
        focusHistoryPublication: FocusHistoryPublication? = nil,
        highestRevision: Int64,
        current: TinyBuddyCombinedSnapshot?
    ) -> UpdateResult {
        guard TinyBuddyTimeContext.isValidDayIdentifier(snapshot.stats.dayIdentifier) else {
            return UpdateResult(
                snapshot: current,
                outcome: .persistenceFailed,
                didPersist: false
            )
        }
        guard highestRevision < Int64.max else {
            return UpdateResult(
                snapshot: current,
                outcome: .revisionExhausted,
                didPersist: false
            )
        }
        let retainedFocusSessionSnapshot = focusSessionSnapshot
            ?? (current?.dayIdentifier == snapshot.stats.dayIdentifier
                ? current?.focusSessionSnapshot
                : nil)
        let retainedFocusHistoryPublication = focusHistoryPublication
            ?? (current?.dayIdentifier == snapshot.stats.dayIdentifier
                ? current?.focusHistoryPublication
                : nil)
        // Every later activity/status write retains the confirmed focus slice.
        // Keep the legacy count mirror synchronized as well, otherwise a Git
        // refresh between the combined write and its legacy-mirror update can
        // make HUD regress while Widget still renders the newer focus slice.
        let synchronizedSnapshot: TinyBuddySnapshot
        if let retainedFocusHistoryPublication,
           let completedSessionCount = Self.completedSessionCount(
                in: retainedFocusHistoryPublication,
                for: snapshot.stats.dayIdentifier
           ) {
            synchronizedSnapshot = TinyBuddySnapshot(
                status: snapshot.status,
                stats: DailyStats(
                    dayIdentifier: snapshot.stats.dayIdentifier,
                    focusCount: completedSessionCount,
                    completionCount: snapshot.stats.completionCount
                )
            )
        } else if let retainedFocusSessionSnapshot,
           retainedFocusSessionSnapshot.dayIdentifier == snapshot.stats.dayIdentifier {
            synchronizedSnapshot = TinyBuddySnapshot(
                status: snapshot.status,
                stats: DailyStats(
                    dayIdentifier: snapshot.stats.dayIdentifier,
                    focusCount: retainedFocusSessionSnapshot.completedSessionCount,
                    completionCount: snapshot.stats.completionCount
                )
            )
        } else {
            synchronizedSnapshot = snapshot
        }
        let combinedSnapshot = Self.normalized(TinyBuddyCombinedSnapshot(
            revision: highestRevision + 1,
            dayIdentifier: synchronizedSnapshot.stats.dayIdentifier,
            snapshot: synchronizedSnapshot,
            activitySnapshot: activitySnapshot ?? GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            activityRevision: activityRevision,
            focusSessionSnapshot: retainedFocusSessionSnapshot,
            focusHistoryPublication: retainedFocusHistoryPublication
        ))

        guard validateSnapshot(combinedSnapshot) else {
            return failureResult(current: current)
        }

        guard let directSource = sourceValues().first,
              ensureCurrentSchemaLocked(directSource: directSource) else {
            return failureResult(current: current)
        }

        // Reserve before publication. If the process stops between these writes,
        // the previous whole snapshot stays valid while the next save advances
        // strictly beyond this floor.
        guard reserveRevisionLocked(combinedSnapshot.revision) else {
            return failureResult(current: current)
        }
        let slots = directSlots()
        let targetKey = transactionalTargetKey(for: slots)
        let target = slots.first(where: { $0.key == targetKey })
            ?? DirectSlot(key: targetKey, rawValue: nil, snapshot: nil)
        guard let encodedV3 = Self.encodeV3(combinedSnapshot) else {
            return failureResult(current: current)
        }
        guard writeValue(encodedV3, targetKey),
              synchronizeWrites(),
              directString(forKey: targetKey).flatMap(Self.decodeV3) == combinedSnapshot else {
            restoreValueLocked(target.rawValue, forKey: target.key)
            _ = synchronizeWrites()
            return failureResult(current: current)
        }

        // The slot is staged until this independently checksummed marker is
        // durable. Readers ignore revisions newer than the committed marker.
        let previousCommittedMarker = directString(forKey: Key.committedRevisionV2)
        guard let committedMarker = Self.encodeRevisionMarker(combinedSnapshot.revision),
              writeValue(committedMarker, Key.committedRevisionV2),
              synchronizeWrites(),
              directString(forKey: Key.committedRevisionV2)
                .flatMap(Self.decodeRevisionMarker) == combinedSnapshot.revision else {
            restoreValueLocked(previousCommittedMarker, forKey: Key.committedRevisionV2)
            restoreValueLocked(target.rawValue, forKey: target.key)
            _ = synchronizeWrites()
            return failureResult(current: current)
        }

        writeFailureCount = 0
        lastWriteFailure = nil

        // Redundant V2/V1 copies are repairable auxiliaries after the commit
        // marker has published one complete canonical slot.
        repairAncillaryCopiesLocked(combinedSnapshot)

        return UpdateResult(snapshot: combinedSnapshot, outcome: .saved, didPersist: true)
    }

    /// Validates a combined snapshot using `TinyBuddyDataValidator`. Logs all
    /// violations. Returns `false` when critical violations exist (caller should
    /// reject the snapshot). Returns `true` for nil snapshots (nothing to check).
    private func validateSnapshot(_ snapshot: TinyBuddyCombinedSnapshot?) -> Bool {
        guard let snapshot else { return true }
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        guard !violations.isEmpty else { return true }

        let criticalCount = violations.filter { $0.severity == .critical }.count
        Self.logger.debug(
            "\(violations.count) data invariant violation(s) (\(criticalCount) critical)"
        )
        for v in violations {
            Self.logger.debug(
                "[\(v.severity.rawValue, privacy: .public)] \(v.description, privacy: .public)"
            )
        }
        return criticalCount == 0
    }

    private func failureResult(current: TinyBuddyCombinedSnapshot?) -> UpdateResult {
        writeFailureCount += 1
        lastWriteFailure = Date()
        return UpdateResult(
            snapshot: current,
            outcome: .persistenceFailed,
            didPersist: false,
            observation: TinyBuddySharedSnapshotObservation(
                phase: .snapshotWrite,
                reason: .persistenceFailed,
                recovery: .stopped,
                attemptCount: writeFailureCount
            )
        )
    }

    private func cooldownResult() -> UpdateResult {
        UpdateResult(
            snapshot: nil,
            outcome: .persistenceFailed,
            didPersist: false,
            observation: TinyBuddySharedSnapshotObservation(
                phase: .snapshotWrite,
                reason: .persistenceFailed,
                recovery: .stopped,
                attemptCount: writeFailureCount
            )
        )
    }
}
