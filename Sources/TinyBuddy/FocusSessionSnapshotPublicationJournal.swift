import Foundation
import TinyBuddyCore

/// Durable hand-off journal between the session file and the transactional
/// Combined Snapshot store. A surviving entry is replayed at primary-app
/// startup; it is never treated as a successful presentation publication.
final class FocusSessionSnapshotPublicationJournal {
    enum HistoryPublicationStageResult: Equatable {
        /// The supplied payload is now the durable replay candidate.
        case staged
        /// The same payload was already durable; retrying the downstream
        /// combined-snapshot write is still safe.
        case alreadyCurrent
        /// A newer archive revision is already durable. The delayed callback
        /// must not replace that replay candidate.
        case rejectedStale
        case persistenceFailed
    }

    private static let key = "tinybuddy.focusSession.snapshotPublication.v1"
    private static let historyKey = "tinybuddy.focusSession.historyPublication.v1"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()) {
        self.defaults = defaults
    }

    var pending: FocusSessionDerivedSnapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? decoder.decode(FocusSessionDerivedSnapshot.self, from: data)
    }

    /// Durable hand-off for the cache-backed history presentation. This is a
    /// separate key so an interrupted upgrade can still replay the legacy
    /// current-day payload before it is eventually retired.
    var pendingHistory: FocusHistoryPublication? {
        guard let data = defaults.data(forKey: Self.historyKey) else { return nil }
        return try? decoder.decode(FocusHistoryPublication.self, from: data)
    }

    func stage(_ snapshot: FocusSessionDerivedSnapshot) -> Bool {
        guard let data = try? encoder.encode(snapshot) else { return false }
        defaults.set(data, forKey: Self.key)
        _ = defaults.synchronize()
        return pending == snapshot
    }

    func clear(expected snapshot: FocusSessionDerivedSnapshot) -> Bool {
        guard pending == snapshot else { return false }
        defaults.removeObject(forKey: Self.key)
        _ = defaults.synchronize()
        return pending == nil
    }

    func stage(_ publication: FocusHistoryPublication) -> HistoryPublicationStageResult {
        if let pending = pendingHistory {
            if pending.revision > publication.revision {
                return .rejectedStale
            }
            if pending == publication {
                return .alreadyCurrent
            }
        }
        // Equal archive revisions may legitimately differ after a user changes
        // goal configuration. A later durable hand-off wins in that case;
        // manual session edits always advance the archive revision and are
        // therefore protected by the branch above.
        guard let data = try? encoder.encode(publication) else { return .persistenceFailed }
        defaults.set(data, forKey: Self.historyKey)
        _ = defaults.synchronize()
        return pendingHistory == publication ? .staged : .persistenceFailed
    }

    func clear(expected publication: FocusHistoryPublication) -> Bool {
        guard pendingHistory == publication else { return false }
        defaults.removeObject(forKey: Self.historyKey)
        _ = defaults.synchronize()
        return pendingHistory == nil
    }
}
