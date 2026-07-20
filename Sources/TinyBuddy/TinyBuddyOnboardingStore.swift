import Foundation
import TinyBuddyCore

final class TinyBuddyOnboardingStore {
    enum State: String, Equatable {
        case pending
        case completed
    }

    enum Key {
        static let state = TinyBuddyDisplaySharedState.onboardingStateKey
    }

    private let userDefaults: UserDefaults
    private let sharedDefaults: UserDefaults
    private let legacyAuthorizationIsValid: () -> Bool

    init(
        userDefaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        legacyAuthorizationIsValid: (() -> Bool)? = nil
    ) {
        self.userDefaults = userDefaults
        self.sharedDefaults = sharedDefaults
        self.legacyAuthorizationIsValid = legacyAuthorizationIsValid
            ?? { Self.hasStructurallyValidLegacyAuthorization(userDefaults: userDefaults) }

        if let persistedState = userDefaults.string(forKey: Key.state).flatMap(State.init(rawValue:)) {
            TinyBuddyDisplaySharedState.saveOnboardingCompleted(
                persistedState == .completed,
                userDefaults: sharedDefaults
            )
            return
        }

        if let sharedState = TinyBuddyDisplaySharedState.onboardingCompleted(
            userDefaults: sharedDefaults
        ) {
            userDefaults.set(
                sharedState ? State.completed.rawValue : State.pending.rawValue,
                forKey: Key.state
            )
            return
        }

        let initialState: State = self.legacyAuthorizationIsValid() ? .completed : .pending
        userDefaults.set(initialState.rawValue, forKey: Key.state)
        TinyBuddyDisplaySharedState.saveOnboardingCompleted(
            initialState == .completed,
            userDefaults: sharedDefaults
        )
    }

    var state: State {
        userDefaults.string(forKey: Key.state).flatMap(State.init(rawValue:)) ?? .pending
    }

    var isCompleted: Bool {
        state == .completed
    }

    @discardableResult
    func markCompleted() -> Bool {
        guard !isCompleted else {
            return false
        }
        userDefaults.set(State.completed.rawValue, forKey: Key.state)
        TinyBuddyDisplaySharedState.saveOnboardingCompleted(
            true,
            userDefaults: sharedDefaults
        )
        return true
    }

    private static func hasStructurallyValidLegacyAuthorization(
        userDefaults: UserDefaults
    ) -> Bool {
        // Snapshot, refresh-status and daily-stat values are caches, not a
        // configuration contract. A stale or malformed shared snapshot must
        // never turn an uninstall/reinstall into a completed onboarding.
        if let records = userDefaults.array(
            forKey: GitScanRootAuthorizationStore.Constants.authorizationRecordsKey
        ), records.contains(where: isStructurallyValidAuthorizationRecord) {
            return true
        }

        // The pre-v2 format contains only bookmark blobs. Require at least one
        // nonempty blob rather than trusting an arbitrary key or a corrupt
        // property-list value.
        return (userDefaults.array(
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        ) as? [Data])?.contains(where: { !$0.isEmpty }) == true
    }

    private static func isStructurallyValidAuthorizationRecord(_ value: Any) -> Bool {
        guard let record = value as? [String: Any],
              let id = record["id"] as? String,
              !id.isEmpty,
              let bookmarkData = record["bookmarkData"] as? Data,
              !bookmarkData.isEmpty,
              let displayName = record["displayName"] as? String,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let path = record["lastKnownPath"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }
}
