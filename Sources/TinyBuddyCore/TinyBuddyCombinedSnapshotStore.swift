import Foundation

public struct TinyBuddyCombinedSnapshot: Equatable, Sendable {
    public let revision: Int64
    public let dayIdentifier: String
    public let snapshot: TinyBuddySnapshot
    public let activitySnapshot: GitTodayActivitySnapshot
    public let activityRevision: Int64?

    public init(
        revision: Int64,
        dayIdentifier: String,
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot,
        activityRevision: Int64? = nil
    ) {
        self.revision = revision
        self.dayIdentifier = dayIdentifier
        self.snapshot = snapshot
        self.activitySnapshot = activitySnapshot
        self.activityRevision = activityRevision
    }
}

public final class TinyBuddyCombinedSnapshotStore {
    public enum UpdateOutcome: Equatable, Sendable {
        case saved
        case alreadyCurrent
        case rejectedStaleActivity
        case rejectedInvalidActivityRevision
        case revisionExhausted
        case persistenceFailed
    }

    public struct UpdateResult: Equatable, Sendable {
        public let snapshot: TinyBuddyCombinedSnapshot?
        public let outcome: UpdateOutcome
        public let didPersist: Bool

        public init(snapshot: TinyBuddyCombinedSnapshot?, outcome: UpdateOutcome, didPersist: Bool) {
            self.snapshot = snapshot
            self.outcome = outcome
            self.didPersist = didPersist
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

        static let all = [
            snapshot,
            highestRevision,
            highestRevisionV2,
            committedRevisionV2,
            snapshotV2SlotA,
            snapshotV2SlotB
        ]
    }

    private struct SourceValues {
        let legacySnapshot: String?
        let v2SlotA: String?
        let v2SlotB: String?
        let legacyHighestRevision: Int64?
        let revisionMarker: String?
        let committedRevisionMarker: String?
    }

    private struct ReadState {
        let snapshot: TinyBuddyCombinedSnapshot?
        let revisionFloor: Int64
    }

    private struct DirectSlot {
        let key: String
        let rawValue: String?
        let snapshot: TinyBuddyCombinedSnapshot?
    }

    private let directPreferencesProvider: () -> [String: Any]
    private let synchronizeReads: () -> Void
    private let sharedPreferencesProvider: () -> [String: Any]?
    private let fallbackDefaults: UserDefaults?
    private let repairOnLoad: Bool
    private let writeValue: (Any, String) -> Bool
    private let synchronizeWrites: () -> Bool

    // The app is the only semantic writer. This lock also serializes migration and
    // repair inside that process. WidgetKit uses repairOnLoad=false and stays read-only.
    private static let writerLock = NSLock()

    public convenience init(repairOnLoad: Bool = true) {
        let preferencesStore = TinyBuddyAppGroupPreferencesStore()
        self.init(
            preferencesStore: preferencesStore,
            repairOnLoad: repairOnLoad
        )
    }

    convenience init(
        preferencesStore: TinyBuddyAppGroupPreferencesStore,
        sharedPreferencesProvider: @escaping () -> [String: Any]? = {
            TinyBuddySharedData.loadAppGroupPreferencesDictionary()
        },
        repairOnLoad: Bool = true
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
            }
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
                userDefaults.synchronize()
            }
        )
    }

    convenience init(
        userDefaults: UserDefaults,
        sharedPreferencesProvider: @escaping () -> [String: Any]?,
        fallbackDefaults: UserDefaults? = nil,
        repairOnLoad: Bool = true,
        writeValue: @escaping (Any, String) -> Bool,
        synchronizeWrites: @escaping () -> Bool
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
            synchronizeWrites: synchronizeWrites
        )
    }

    private init(
        directPreferencesProvider: @escaping () -> [String: Any],
        synchronizeReads: @escaping () -> Void,
        sharedPreferencesProvider: @escaping () -> [String: Any]?,
        fallbackDefaults: UserDefaults?,
        repairOnLoad: Bool,
        writeValue: @escaping (Any, String) -> Bool,
        synchronizeWrites: @escaping () -> Bool
    ) {
        self.directPreferencesProvider = directPreferencesProvider
        self.synchronizeReads = synchronizeReads
        self.sharedPreferencesProvider = sharedPreferencesProvider
        self.fallbackDefaults = fallbackDefaults
        self.repairOnLoad = repairOnLoad
        self.writeValue = writeValue
        self.synchronizeWrites = synchronizeWrites
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
        return readStateLocked(repair: repairOnLoad).snapshot
    }

    public func loadReadOnly() -> TinyBuddyCombinedSnapshot? {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }
        return readStateLocked(repair: false).snapshot
    }

    @discardableResult
    public func updatePetSlice(
        _ snapshot: TinyBuddySnapshot,
        fallbackActivitySnapshot: GitTodayActivitySnapshot?,
        fallbackActivityRevision: Int64? = nil
    ) -> UpdateResult {
        Self.writerLock.lock()
        defer { Self.writerLock.unlock() }

        let state = readStateLocked(repair: true)
        let current = state.snapshot
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

        let state = readStateLocked(repair: true)
        let current = state.snapshot
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
              !fields[1].isEmpty,
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

    private func readStateLocked(repair: Bool) -> ReadState {
        synchronizeReads()
        fallbackDefaults?.synchronize()

        let sources = sourceValues()
        let committedMarkerRevision = sources.compactMap { source in
            source.committedRevisionMarker.flatMap(Self.decodeRevisionMarker)
        }.max()
        var committedV2Candidates: [TinyBuddyCombinedSnapshot] = []
        var stagedV2Candidates: [TinyBuddyCombinedSnapshot] = []
        var hasV2Evidence = committedMarkerRevision != nil

        // V2 wins equal-revision migration ties. Direct defaults remain first,
        // followed by the on-disk cache and explicit fallback.
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
                if Self.verifiedV2ClaimedRevision(value) != nil {
                    hasV2Evidence = true
                }
                guard let snapshot = Self.decodeV2(value) else {
                    continue
                }
                // A commit marker only publishes slots from the same source. This
                // prevents an unrelated fallback marker from exposing a staged
                // direct-defaults write after a failed synchronization.
                if sourceCommittedRevision.map({ snapshot.revision <= $0 }) == true {
                    committedV2Candidates.append(snapshot)
                } else {
                    stagedV2Candidates.append(snapshot)
                }
            }
        }

        var legacyCandidates: [TinyBuddyCombinedSnapshot] = []
        for source in sources {
            if let value = source.legacySnapshot,
               let snapshot = Self.decode(value) {
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

        let candidates = committedV2Candidates + legacyCandidates
        let selected = Self.newestSnapshot(in: candidates)
        let newestStaged = Self.newestSnapshot(in: stagedV2Candidates)
        let durableRevisionFloor = max(
            committedMarkerRevision ?? 0,
            candidates.map(\.revision).max() ?? 0
        )

        var revisionFloor = durableRevisionFloor
        for source in sources {
            if let marker = source.revisionMarker,
               let markedRevision = Self.decodeRevisionMarker(marker) {
                revisionFloor = max(revisionFloor, markedRevision)
            }
            for value in [source.v2SlotA, source.v2SlotB] {
                if let claimedRevision = value.flatMap(Self.verifiedV2ClaimedRevision) {
                    revisionFloor = max(revisionFloor, claimedRevision)
                }
            }
            if let value = source.legacySnapshot,
               let claimedRevision = Self.verifiedV2ClaimedRevision(value) {
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
            return ReadState(snapshot: newestStaged, revisionFloor: revisionFloor)
        }

        guard let selected else {
            return ReadState(snapshot: nil, revisionFloor: revisionFloor)
        }

        if repair {
            _ = repairLocked(selected, directSource: sources[0])
            return ReadState(snapshot: selected, revisionFloor: revisionFloor)
        }
        return ReadState(snapshot: selected, revisionFloor: revisionFloor)
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
            committedRevisionMarker: directPreferences[Key.committedRevisionV2] as? String
        )
        let sharedPreferences = sharedPreferencesProvider()
        let shared = SourceValues(
            legacySnapshot: sharedPreferences?[Key.snapshot] as? String,
            v2SlotA: sharedPreferences?[Key.snapshotV2SlotA] as? String,
            v2SlotB: sharedPreferences?[Key.snapshotV2SlotB] as? String,
            legacyHighestRevision: Self.nonnegativeRevision(sharedPreferences?[Key.highestRevision]),
            revisionMarker: sharedPreferences?[Key.highestRevisionV2] as? String,
            committedRevisionMarker: sharedPreferences?[Key.committedRevisionV2] as? String
        )
        let fallback = SourceValues(
            legacySnapshot: fallbackDefaults?.string(forKey: Key.snapshot),
            v2SlotA: fallbackDefaults?.string(forKey: Key.snapshotV2SlotA),
            v2SlotB: fallbackDefaults?.string(forKey: Key.snapshotV2SlotB),
            legacyHighestRevision: Self.nonnegativeRevision(
                fallbackDefaults?.object(forKey: Key.highestRevision)
            ),
            revisionMarker: fallbackDefaults?.string(forKey: Key.highestRevisionV2),
            committedRevisionMarker: fallbackDefaults?.string(forKey: Key.committedRevisionV2)
        )
        return [direct, shared, fallback]
    }

    private func repairLocked(
        _ canonical: TinyBuddyCombinedSnapshot,
        directSource: SourceValues
    ) -> Bool {
        guard reserveRevisionLocked(
            canonical.revision,
            currentDirectRevision: directSource.revisionMarker.flatMap(Self.decodeRevisionMarker)
        ) else {
            return false
        }

        let slots = directSlots()
        let encoded = Self.encodeV2(canonical)
        var writtenTarget: DirectSlot?

        if !slots.contains(where: { $0.snapshot == canonical }) {
            let targetKey = transactionalTargetKey(for: slots)
            let target = slots.first(where: { $0.key == targetKey })
                ?? DirectSlot(key: targetKey, rawValue: nil, snapshot: nil)
            guard writeValue(encoded, targetKey),
                  synchronizeWrites(),
                  directString(forKey: targetKey).flatMap(Self.decodeV2) == canonical else {
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

    private func repairAncillaryCopiesLocked(_ canonical: TinyBuddyCombinedSnapshot) {
        let encodedV2 = Self.encodeV2(canonical)
        let slots = directSlots()
        var changed = false

        if slots.contains(where: { $0.snapshot == canonical }) {
            for slot in slots where slot.snapshot == nil
                || (slot.snapshot?.revision == canonical.revision && slot.snapshot != canonical) {
                changed = writeValue(encodedV2, slot.key) || changed
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
                snapshot: slotAValue.flatMap(Self.decodeV2)
            ),
            DirectSlot(
                key: Key.snapshotV2SlotB,
                rawValue: slotBValue,
                snapshot: slotBValue.flatMap(Self.decodeV2)
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
            activityRevision: snapshot.activityRevision
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
        highestRevision: Int64,
        current: TinyBuddyCombinedSnapshot?
    ) -> UpdateResult {
        guard highestRevision < Int64.max else {
            return UpdateResult(
                snapshot: current,
                outcome: .revisionExhausted,
                didPersist: false
            )
        }
        let combinedSnapshot = Self.normalized(TinyBuddyCombinedSnapshot(
            revision: highestRevision + 1,
            dayIdentifier: snapshot.stats.dayIdentifier,
            snapshot: snapshot,
            activitySnapshot: activitySnapshot ?? GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            activityRevision: activityRevision
        ))

        // Reserve before publication. If the process stops between these writes,
        // the previous whole snapshot stays valid while the next save advances
        // strictly beyond this floor.
        guard reserveRevisionLocked(combinedSnapshot.revision) else {
            return UpdateResult(
                snapshot: current,
                outcome: .persistenceFailed,
                didPersist: false
            )
        }
        let slots = directSlots()
        let targetKey = transactionalTargetKey(for: slots)
        let target = slots.first(where: { $0.key == targetKey })
            ?? DirectSlot(key: targetKey, rawValue: nil, snapshot: nil)
        let encodedV2 = Self.encodeV2(combinedSnapshot)
        guard writeValue(encodedV2, targetKey),
              synchronizeWrites(),
              directString(forKey: targetKey).flatMap(Self.decodeV2) == combinedSnapshot else {
            restoreValueLocked(target.rawValue, forKey: target.key)
            _ = synchronizeWrites()
            return UpdateResult(
                snapshot: current,
                outcome: .persistenceFailed,
                didPersist: false
            )
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
            return UpdateResult(
                snapshot: current,
                outcome: .persistenceFailed,
                didPersist: false
            )
        }

        // Redundant V2/V1 copies are repairable auxiliaries after the commit
        // marker has published one complete canonical slot.
        repairAncillaryCopiesLocked(combinedSnapshot)

        return UpdateResult(snapshot: combinedSnapshot, outcome: .saved, didPersist: true)
    }
}
