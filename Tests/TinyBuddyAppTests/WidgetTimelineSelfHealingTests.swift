import Foundation
import XCTest

final class WidgetTimelineSelfHealingTests: XCTestCase {
    func testWidgetProviderChecksPostUpgradeRebuildFlag() throws {
        let source = try widgetSource()
        XCTAssertTrue(source.contains("TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired()"))
    }

    func testWidgetProviderFallsBackToAnyDaySnapshotDuringPostUpgradeRebuild() throws {
        let source = try widgetSource()
        XCTAssertTrue(source.contains("combinedSnapshotStore.loadReadOnly()"))
        XCTAssertTrue(source.contains("widget self-healing accepted any-day snapshot"))
        XCTAssertTrue(source.contains("dataAvailability: .stale"))
    }

    func testWidgetProviderSelfHealingUsesStaleAvailabilityNotFailed() throws {
        let source = try widgetSource()
        // Ensure the self-healing entry uses .stale, not .failed or neutral.
        let healingRange = try XCTUnwrap(source.range(of: "Post-upgrade self-healing"))
        let endIndex = source.index(healingRange.lowerBound, offsetBy: min(900, source.count - source.distance(from: source.startIndex, to: healingRange.lowerBound)))
        let healingBlock = String(source[healingRange.lowerBound..<endIndex])
        XCTAssertTrue(healingBlock.contains("dataAvailability: .stale"))
    }

    func testAppDelegateRegistersPostUpgradeReloadObserver() throws {
        let source = try appSource()
        XCTAssertTrue(source.contains("registerPostUpgradeWidgetReloadObserver()"))
        XCTAssertTrue(source.contains("gitActivityRefreshStatusDidChange"))
        XCTAssertTrue(source.contains("Post-upgrade rebuild completed; reloading widget timelines"))
        XCTAssertTrue(source.contains("TinyBuddyVersionUpgradeTracker.clearPostUpgradeRebuildRequired()"))
    }

    func testAppDelegateDoesNotReloadWidgetImmediatelyOnUpgradeDetection() throws {
        let source = try appSource()
        // The old immediate reload was removed; now the reload happens via
        // the observer after a refresh commits.
        let upgradeBlock = source[source.range(of: "Version upgrade detected")!.lowerBound..<source.index(source.range(of: "Version upgrade detected")!.lowerBound, offsetBy: 800)]
        XCTAssertFalse(upgradeBlock.contains("WidgetCenter.shared.reloadAllTimelines()"))
    }

    func testVersionUpgradeTrackerSetsAndClearsRebuildFlag() throws {
        let source = try trackerSource()
        XCTAssertTrue(source.contains("needsPostUpgradeRebuild"))
        XCTAssertTrue(source.contains("isPostUpgradeRebuildRequired"))
        XCTAssertTrue(source.contains("setPostUpgradeRebuildRequired"))
        XCTAssertTrue(source.contains("clearPostUpgradeRebuildRequired"))
        XCTAssertTrue(source.contains("if isUpgrade {"))
        XCTAssertTrue(source.contains("setPostUpgradeRebuildRequired(userDefaults: userDefaults)"))
    }

    private func widgetSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Widget/TinyBuddyWidget/TinyBuddyWidget.swift"),
            encoding: .utf8
        )
    }

    private func appSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Sources/TinyBuddy/TinyBuddyApp.swift"),
            encoding: .utf8
        )
    }

    private func trackerSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Sources/TinyBuddyCore/TinyBuddyVersionUpgradeTracker.swift"),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
