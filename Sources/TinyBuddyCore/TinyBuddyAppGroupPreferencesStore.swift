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

    typealias LoadValues = (Domain, [String]) -> [String: Any]?
    typealias SetValue = (Domain, String, Any) -> Void
    typealias Synchronize = (Domain) -> Bool

    let domain: Domain

    private let loadValues: LoadValues
    private let setValue: SetValue
    private let synchronizeDomain: Synchronize

    init(
        applicationIdentifier: String = TinyBuddySharedData.appGroupIdentifier,
        loadValues: @escaping LoadValues = { domain, keys in
            let values = CFPreferencesCopyMultiple(
                keys as CFArray,
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
        self.synchronizeDomain = synchronize
    }

    func loadDictionary() -> [String: Any]? {
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

    func synchronize() -> Bool {
        synchronizeDomain(domain)
    }
}
