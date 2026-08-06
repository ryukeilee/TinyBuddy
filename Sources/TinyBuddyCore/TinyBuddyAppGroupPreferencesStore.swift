import CoreFoundation
import Foundation

final class TinyBuddyAppGroupPreferencesStore {
    enum UserScope: Equatable {
        case currentUser
    }

    enum HostScope: Equatable {
        case anyHost
    }

    struct Domain: Equatable {
        let applicationIdentifier: String
        let userScope: UserScope
        let hostScope: HostScope
    }

    typealias LoadValues = (Domain, [String]?) -> [String: Any]?
    typealias SetValue = (Domain, String, Any) -> Void
    typealias RemoveValue = (Domain, String) -> Void
    typealias Synchronize = (Domain) -> Bool

    let domain: Domain

    private let loadValues: LoadValues
    private let setValue: SetValue
    private let removeValue: RemoveValue
    private let synchronizeDomain: Synchronize

    init(
        applicationIdentifier: String = TinyBuddySharedData.appGroupIdentifier,
        loadValues: @escaping LoadValues = { domain, keys in
            // A nil key array copies every key in the domain, which the
            // storage cleanup service needs to see per-day legacy keys that
            // are not part of the combined-snapshot key set.
            let values = CFPreferencesCopyMultiple(
                keys as CFArray?,
                domain.applicationIdentifier as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            return values as NSDictionary as? [String: Any]
        },
        setValue: @escaping SetValue = { domain, key, value in
            CFPreferencesSetValue(
                key as CFString,
                value as CFPropertyList,
                domain.applicationIdentifier as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        },
        removeValue: @escaping RemoveValue = { domain, key in
            CFPreferencesSetValue(
                key as CFString,
                nil,
                domain.applicationIdentifier as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        },
        synchronize: @escaping Synchronize = { domain in
            CFPreferencesSynchronize(
                domain.applicationIdentifier as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
    ) {
        self.domain = Domain(
            applicationIdentifier: applicationIdentifier,
            userScope: .currentUser,
            hostScope: .anyHost
        )
        self.loadValues = loadValues
        self.setValue = setValue
        self.removeValue = removeValue
        self.synchronizeDomain = synchronize
    }

    /// Loads the full preference dictionary for the app-group domain,
    /// including legacy per-day keys outside the combined-snapshot key set.
    func loadDictionary() -> [String: Any]? {
        loadValues(domain, nil)
    }

    /// Loads only the combined-snapshot keys. Used by the snapshot store's
    /// read paths where a bounded key set keeps validation deterministic.
    func loadSnapshotKeysDictionary() -> [String: Any]? {
        loadValues(domain, TinyBuddyCombinedSnapshotStore.Key.all)
    }

    @discardableResult
    func writeValue(_ value: Any, forKey key: String) -> Bool {
        guard PropertyListSerialization.propertyList([key: value], isValidFor: .binary) else {
            return false
        }

        setValue(domain, key, value)
        return true
    }

    /// Removes a key from the app-group domain entirely (rather than leaving
    /// an empty-string placeholder behind).
    @discardableResult
    func removeValue(forKey key: String) -> Bool {
        removeValue(domain, key)
        return true
    }

    func synchronize() -> Bool {
        synchronizeDomain(domain)
    }
}
