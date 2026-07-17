import Foundation
import TinyBuddyCore

final class TinyBuddyOnboardingStore {
    enum State: String, Equatable {
        case pending
        case completed
    }

    enum Key {
        static let state = "tinybuddy.onboarding.state.v1"
    }

    private let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) {
        self.userDefaults = userDefaults

        guard userDefaults.string(forKey: Key.state).flatMap(State.init(rawValue:)) == nil else {
            return
        }

        let initialState: State = Self.hasLegacyInstallationEvidence(
            userDefaults: userDefaults,
            sharedDefaults: sharedDefaults
        ) ? .completed : .pending
        userDefaults.set(initialState.rawValue, forKey: Key.state)
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
        return true
    }

    private static func hasLegacyInstallationEvidence(
        userDefaults: UserDefaults,
        sharedDefaults: UserDefaults
    ) -> Bool {
        let standardKeys = [
            GitScanRootAuthorizationStore.Constants.bookmarkDataKey,
            GitScanRootAuthorizationStore.Constants.authorizationRecordsKey
        ]
        if standardKeys.contains(where: { userDefaults.object(forKey: $0) != nil }) {
            return true
        }

        let sharedKeys = [
            "tinybuddy.dailyStats.dayIdentifier",
            "tinybuddy.currentStatus",
            GitActivityRefreshStatusStore.Key.refreshedAt,
            TinyBuddyCombinedSnapshotStore.Key.snapshot,
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA,
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB
        ]
        return sharedKeys.contains(where: { sharedDefaults.object(forKey: $0) != nil })
    }
}
