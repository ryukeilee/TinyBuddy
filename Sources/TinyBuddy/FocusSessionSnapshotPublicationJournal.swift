import Foundation
import TinyBuddyCore

/// Durable hand-off journal between the session file and the transactional
/// Combined Snapshot store. A surviving entry is replayed at primary-app
/// startup; it is never treated as a successful presentation publication.
final class FocusSessionSnapshotPublicationJournal {
    private static let key = "tinybuddy.focusSession.snapshotPublication.v1"
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
}
