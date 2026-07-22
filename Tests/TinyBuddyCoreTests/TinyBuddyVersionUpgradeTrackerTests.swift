import Foundation
import XCTest
@testable import TinyBuddyCore

final class TinyBuddyVersionUpgradeTrackerTests: XCTestCase {
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "test.TinyBuddyVersionUpgradeTracker.\(UUID().uuidString)")
        userDefaults.removePersistentDomain(forName: "test.TinyBuddyVersionUpgradeTracker.\(UUID().uuidString)")
    }

    override func tearDown() {
        if let userDefaults {
            userDefaults.removePersistentDomain(forName: userDefaults.value(forKey: "suiteName") as? String ?? "")
        }
        userDefaults = nil
        super.tearDown()
    }

    func testTestBundleOverrideWorks() {
        let bundle = testBundle(shortVersion: "1.1", build: "2")
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        XCTAssertEqual(short, "1.1")
        XCTAssertEqual(build, "2")
    }

    func testFirstLaunchIsNotUpgradeAndDoesNotSetRebuildFlag() {
        let state = TinyBuddyVersionUpgradeTracker.checkForUpgrade(
            userDefaults: userDefaults,
            bundle: testBundle(shortVersion: "1.0", build: "1")
        )
        XCTAssertFalse(state.isUpgrade)
        XCTAssertFalse(TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired(userDefaults: userDefaults))
    }

    func testSameVersionIsNotUpgradeAndDoesNotSetRebuildFlag() {
        TinyBuddyVersionUpgradeTracker.recordCurrentVersion(
            userDefaults: userDefaults,
            bundle: testBundle(shortVersion: "1.0", build: "1")
        )
        let state = TinyBuddyVersionUpgradeTracker.checkForUpgrade(
            userDefaults: userDefaults,
            bundle: testBundle(shortVersion: "1.0", build: "1")
        )
        XCTAssertFalse(state.isUpgrade)
        XCTAssertFalse(TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired(userDefaults: userDefaults))
    }

    func testShortVersionChangeIsUpgradeAndSetsRebuildFlag() {
        let previousBundle = testBundle(shortVersion: "1.0", build: "1")
        let currentBundle = testBundle(shortVersion: "1.1", build: "1")
        TinyBuddyVersionUpgradeTracker.recordCurrentVersion(
            userDefaults: userDefaults,
            bundle: previousBundle
        )
        let state = TinyBuddyVersionUpgradeTracker.checkForUpgrade(
            userDefaults: userDefaults,
            bundle: currentBundle
        )
        XCTAssertTrue(state.isUpgrade)
        XCTAssertEqual(state.previousShortVersion, "1.0")
        XCTAssertEqual(state.currentShortVersion, "1.1")
        XCTAssertTrue(TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired(userDefaults: userDefaults))
    }

    func testBuildVersionChangeIsUpgradeAndSetsRebuildFlag() {
        TinyBuddyVersionUpgradeTracker.recordCurrentVersion(
            userDefaults: userDefaults,
            bundle: testBundle(shortVersion: "1.0", build: "1")
        )
        let state = TinyBuddyVersionUpgradeTracker.checkForUpgrade(
            userDefaults: userDefaults,
            bundle: testBundle(shortVersion: "1.0", build: "2")
        )
        XCTAssertTrue(state.isUpgrade)
        XCTAssertEqual(state.previousBuildVersion, "1")
        XCTAssertEqual(state.currentBuildVersion, "2")
        XCTAssertTrue(TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired(userDefaults: userDefaults))
    }

    func testClearRebuildFlag() {
        TinyBuddyVersionUpgradeTracker.setPostUpgradeRebuildRequired(userDefaults: userDefaults)
        XCTAssertTrue(TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired(userDefaults: userDefaults))
        TinyBuddyVersionUpgradeTracker.clearPostUpgradeRebuildRequired(userDefaults: userDefaults)
        XCTAssertFalse(TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired(userDefaults: userDefaults))
    }

    func testRecordCurrentVersionClearsNothing() {
        TinyBuddyVersionUpgradeTracker.setPostUpgradeRebuildRequired(userDefaults: userDefaults)
        TinyBuddyVersionUpgradeTracker.recordCurrentVersion(
            userDefaults: userDefaults,
            bundle: testBundle(shortVersion: "2.0", build: "10")
        )
        XCTAssertTrue(TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired(userDefaults: userDefaults))
        XCTAssertEqual(userDefaults.string(forKey: "tinybuddy.lastLaunchedShortVersion"), "2.0")
        XCTAssertEqual(userDefaults.string(forKey: "tinybuddy.lastLaunchedBuildVersion"), "10")
    }

    func testClearRecordedVersionRemovesEverything() {
        TinyBuddyVersionUpgradeTracker.recordCurrentVersion(
            userDefaults: userDefaults,
            bundle: testBundle(shortVersion: "1.0", build: "1")
        )
        TinyBuddyVersionUpgradeTracker.setPostUpgradeRebuildRequired(userDefaults: userDefaults)
        TinyBuddyVersionUpgradeTracker.clearRecordedVersion(userDefaults: userDefaults)
        XCTAssertNil(userDefaults.string(forKey: "tinybuddy.lastLaunchedShortVersion"))
        XCTAssertNil(userDefaults.string(forKey: "tinybuddy.lastLaunchedBuildVersion"))
        XCTAssertFalse(TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired(userDefaults: userDefaults))
    }

    // MARK: - Helpers

    private func testBundle(shortVersion: String, build: String) -> Bundle {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": build
        ]
        let data = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
        try! data.write(to: tempDir.appendingPathComponent("Info.plist"))
        return Bundle(url: tempDir)!
    }
}
