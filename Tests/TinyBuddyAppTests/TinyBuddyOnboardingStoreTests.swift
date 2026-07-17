import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class TinyBuddyOnboardingStoreTests: XCTestCase {
    func testFirstInstallationStartsPendingAndPersistsTheDecisionBeforeOtherStoresWrite() {
        let defaults = makeDefaults(prefix: "onboarding")
        let sharedDefaults = makeDefaults(prefix: "shared")

        let first = TinyBuddyOnboardingStore(
            userDefaults: defaults,
            sharedDefaults: sharedDefaults
        )
        sharedDefaults.set("2026-07-17", forKey: "tinybuddy.dailyStats.dayIdentifier")
        let recreated = TinyBuddyOnboardingStore(
            userDefaults: defaults,
            sharedDefaults: sharedDefaults
        )

        XCTAssertEqual(first.state, .pending)
        XCTAssertEqual(recreated.state, .pending)
    }

    func testUpgradeWithExistingConfigurationCompletesMigrationWithoutOverwritingValues() {
        let defaults = makeDefaults(prefix: "onboarding")
        let sharedDefaults = makeDefaults(prefix: "shared")
        let legacyRecords: [[String: Any]] = [[
            "id": "existing-id",
            "bookmarkData": Data("bookmark".utf8),
            "displayName": "Existing",
            "lastKnownPath": "/Existing"
        ]]
        defaults.set(legacyRecords, forKey: GitScanRootAuthorizationStore.Constants.authorizationRecordsKey)
        sharedDefaults.set("2026-07-16", forKey: "tinybuddy.dailyStats.dayIdentifier")

        let store = TinyBuddyOnboardingStore(
            userDefaults: defaults,
            sharedDefaults: sharedDefaults
        )

        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(
            (defaults.array(forKey: GitScanRootAuthorizationStore.Constants.authorizationRecordsKey) as? [[String: Any]])?.first?["id"] as? String,
            "existing-id"
        )
        XCTAssertEqual(sharedDefaults.string(forKey: "tinybuddy.dailyStats.dayIdentifier"), "2026-07-16")
    }

    func testCompletedInitializationNeverReturnsToOnboarding() {
        let defaults = makeDefaults(prefix: "onboarding")
        let sharedDefaults = makeDefaults(prefix: "shared")
        let store = TinyBuddyOnboardingStore(userDefaults: defaults, sharedDefaults: sharedDefaults)

        XCTAssertTrue(store.markCompleted())
        defaults.set([], forKey: GitScanRootAuthorizationStore.Constants.authorizationRecordsKey)

        let recreated = TinyBuddyOnboardingStore(
            userDefaults: defaults,
            sharedDefaults: sharedDefaults
        )
        XCTAssertEqual(recreated.state, .completed)
        XCTAssertFalse(recreated.markCompleted())
    }

    private func makeDefaults(prefix: String) -> UserDefaults {
        let suiteName = "TinyBuddyOnboardingStoreTests.\(prefix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
