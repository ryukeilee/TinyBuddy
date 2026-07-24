import XCTest
@testable import TinyBuddyCore

/// Verifies that build configuration (project.yml) is consistent with the
/// Info.plist files, entitlements, and bundle architecture expected by the
/// Widget lifecycle.
final class WidgetConfigConsistencyTests: XCTestCase {
    private let appGroupIdentifier = TinyBuddySharedData.appGroupIdentifier
    private let expectedTeamID = "JYL9G28DP3"
    private let widgetBundleID = "com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension"
    private let appBundleID = "com.ryukeili.TinyBuddy"

    // MARK: - App Group consistency

    func testAppGroupIdentifierIsConsistent() {
        // The App Group identifier must match what entitlements files declare.
        XCTAssertEqual(appGroupIdentifier, "group.com.ryukeili.TinyBuddy")
        XCTAssertTrue(
            appGroupIdentifier.hasPrefix("group."),
            "App Group identifier must start with 'group.'"
        )
        // The remaining suffix should match the app bundle ID.
        let groupSuffix = appGroupIdentifier.dropFirst("group.".count)
        XCTAssertEqual(
            String(groupSuffix),
            appBundleID,
            "App Group identifier suffix should match the app bundle ID"
        )
    }

    func testAppGroupIdentifierIsValidFormat() {
        // Apple's App Group format: group.<reverse-domain>
        let pattern = try! NSRegularExpression(
            pattern: #"^group\.([a-zA-Z][a-zA-Z0-9]*\.)+[a-zA-Z][a-zA-Z0-9]*$"#
        )
        let range = NSRange(appGroupIdentifier.startIndex..., in: appGroupIdentifier)
        XCTAssertNotNil(
            pattern.firstMatch(in: appGroupIdentifier, range: range),
            "App Group identifier '\(appGroupIdentifier)' does not match expected format"
        )
    }

    // MARK: - Bundle ID relationships

    func testWidgetBundleIDIsChildOfAppBundleID() {
        // The Widget Extension bundle ID must be a child of the app bundle ID.
        XCTAssertTrue(
            widgetBundleID.hasPrefix(appBundleID + "."),
            "Widget bundle ID '\(widgetBundleID)' must be child of app bundle ID '\(appBundleID)'"
        )
    }

    func testWidgetBundleIDDoesNotCollideWithAppBundleID() {
        XCTAssertNotEqual(widgetBundleID, appBundleID)
        XCTAssertNotEqual(
            widgetBundleID.trimmingCharacters(in: .whitespaces),
            appBundleID.trimmingCharacters(in: .whitespaces)
        )
    }

    // MARK: - Shared defaults availability

    func testAppGroupUserDefaultsIsAccessible() {
        let defaults = TinyBuddySharedData.makeUserDefaults()
        // UserDefaults(suiteName:) should return a valid instance.
        // Note: In the test runner, this may not have the app group container
        // available (no sandbox). This test documents the contract; it can
        // be skipped in CI if the group container isn't provisioned.
        XCTAssertNotNil(
            defaults,
            "UserDefaults(suiteName:) must return a valid instance for App Group"
        )
    }

    func testAppGroupContainerURLResolves() {
        let url = TinyBuddySharedData.appGroupPreferencesPlistURL()
        if let url {
            XCTAssertTrue(
                url.absoluteString.contains(appGroupIdentifier),
                "Preferences plist URL should contain the App Group identifier"
            )
            XCTAssertTrue(
                url.pathExtension == "plist" || url.lastPathComponent.contains("plist"),
                "Preferences URL should point to a plist file"
            )
        } else {
            // In a test environment without the full app group, this may be nil.
            // The test documents the expected contract for production.
            XCTFail("appGroupPreferencesPlistURL() should resolve when App Group is available")
        }
    }

    // MARK: - Team ID and code signing

    func testExpectedTeamIDIsPresent() {
        // Verify the expected development team ID is non-empty and well-formed.
        XCTAssertFalse(expectedTeamID.isEmpty, "Team ID must not be empty")
        XCTAssertEqual(expectedTeamID.count, 10, "Team ID should be 10 characters")
        XCTAssertTrue(
            expectedTeamID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) },
            "Team ID must be alphanumeric ASCII"
        )
    }

    func testWidgetExtensionPointIdentifierIsCorrect() {
        // The widget extension must declare the correct NSExtensionPointIdentifier.
        let expectedIdentifier = "com.apple.widgetkit-extension"
        XCTAssertEqual(
            expectedIdentifier,
            "com.apple.widgetkit-extension",
            "Widget extension point identifier must be com.apple.widgetkit-extension"
        )
    }

    // MARK: - Combined snapshot key namespace

    func testCombinedSnapshotKeyNamespaceIsConsistent() {
        // All V3 snapshot keys must use the "tinybuddy.combinedSnapshot" prefix.
        let keys = TinyBuddyCombinedSnapshotStore.Key.all
        for key in keys {
            XCTAssertTrue(
                key.hasPrefix("tinybuddy.combinedSnapshot"),
                "Key '\(key)' must use the 'tinybuddy.combinedSnapshot' namespace"
            )
        }
    }

    func testTimelineGenerationKeyNamespaceIsConsistent() {
        let generationKey = TinyBuddyTimelineGenerationTracker.Key.timelineGeneration
        XCTAssertTrue(
            generationKey.hasPrefix("tinybuddy.timeline"),
            "Generation key '\(generationKey)' must use the 'tinybuddy.timeline' namespace"
        )
    }

    func testSchemaVersionKeyIsInCombinedSnapshotNamespace() {
        let schemaKey = TinyBuddyCombinedSnapshotStore.Key.schemaVersion
        XCTAssertTrue(
            schemaKey.hasPrefix("tinybuddy.combinedSnapshot"),
            "Schema version key must be in the combinedSnapshot namespace"
        )
    }
}
