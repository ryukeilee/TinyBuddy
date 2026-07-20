import XCTest
@testable import TinyBuddyCore

final class TinyBuddyAppConfigTests: XCTestCase {
    private let dayID = "2026-07-20"

    func testModelCreationAndEquality() {
        let a = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/Users/test/Code"],
            launchAtLoginEnabled: true,
            hudEnabled: true,
            refreshStrategy: .automatic,
            dayIdentifier: dayID
        )
        let b = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/Users/test/Code"],
            launchAtLoginEnabled: true,
            hudEnabled: true,
            refreshStrategy: .automatic,
            dayIdentifier: dayID
        )
        XCTAssertEqual(a, b)
    }

    func testModelInequality() {
        let a = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/Users/test/Code"],
            dayIdentifier: dayID
        )
        let b = TinyBuddyAppConfig(
            configVersion: 2,
            scanRootPaths: ["/Users/test/Code"],
            dayIdentifier: dayID
        )
        XCTAssertNotEqual(a, b)
    }

    func testExclusionPatternNormalizationRejectsAuthorizationEscapesAndGlobs() {
        XCTAssertEqual(
            TinyBuddyExclusionRule.normalizedPattern(" ./Teams/Private/ "),
            "Teams/Private"
        )
        XCTAssertEqual(TinyBuddyExclusionRule.normalizedPattern("Archived"), "Archived")
        XCTAssertNil(TinyBuddyExclusionRule.normalizedPattern("../Outside"))
        XCTAssertNil(TinyBuddyExclusionRule.normalizedPattern("/Absolute"))
        XCTAssertNil(TinyBuddyExclusionRule.normalizedPattern("Team/*"))
        XCTAssertNil(TinyBuddyExclusionRule.normalizedPattern("Team//Private"))
    }

    func testDictionaryRoundTrip() {
        let original = TinyBuddyAppConfig(
            configVersion: 42,
            scanRootPaths: ["/Users/test/Code", "/Users/test/Projects"],
            launchAtLoginEnabled: true,
            hudEnabled: false,
            refreshStrategy: .aggressive,
            exclusionRules: [
                TinyBuddyExclusionRule(id: "rule1", pattern: "node_modules")
            ],
            dayIdentifier: dayID
        )
        let dict = original.dictionaryValue
        let reconstructed = TinyBuddyAppConfig(dictionary: dict)
        XCTAssertEqual(reconstructed, original)
    }

    func testDictionaryRoundTripDefaultRefreshStrategy() {
        let original = TinyBuddyAppConfig(
            configVersion: 1,
            dayIdentifier: dayID
        )
        let dict = original.dictionaryValue
        let reconstructed = TinyBuddyAppConfig(dictionary: dict)
        XCTAssertEqual(reconstructed, original)
        XCTAssertEqual(reconstructed?.refreshStrategy, .automatic)
    }

    func testDictionaryInvalidVersionReturnsNil() {
        var dict = TinyBuddyAppConfig(
            configVersion: 1,
            dayIdentifier: dayID
        ).dictionaryValue
        dict["version"] = 999
        XCTAssertNil(TinyBuddyAppConfig(dictionary: dict))
    }

    func testDictionaryMissingFieldsReturnsNil() {
        let dict: [String: Any] = ["configVersion": 1]
        XCTAssertNil(TinyBuddyAppConfig(dictionary: dict))
    }

    func testWithIncrementedVersionPartialOverrides() {
        let base = TinyBuddyAppConfig(
            configVersion: 10,
            scanRootPaths: ["/old/path"],
            dayIdentifier: dayID
        )
        let updated = base.withIncrementedVersion(scanRootPaths: ["/new/path"])
        XCTAssertEqual(updated.configVersion, 11)
        XCTAssertEqual(updated.scanRootPaths, ["/new/path"])
        XCTAssertEqual(updated.launchAtLoginEnabled, base.launchAtLoginEnabled)
        XCTAssertEqual(updated.hudEnabled, base.hudEnabled)
    }

    func testWithIncrementedVersionWithoutChanges() {
        let base = TinyBuddyAppConfig(
            configVersion: 5,
            dayIdentifier: dayID
        )
        let updated = base.withIncrementedVersion(dayIdentifier: dayID)
        XCTAssertEqual(updated.configVersion, 6)
        XCTAssertEqual(updated.scanRootPaths, [])
    }

    func testRefreshStrategyAllCases() {
        let allCases = TinyBuddyRefreshStrategy.allCases
        XCTAssertEqual(allCases, [.automatic, .aggressive, .conservative, .manual])
        for strategy in allCases {
            let config = TinyBuddyAppConfig(
                configVersion: 1,
                refreshStrategy: strategy,
                dayIdentifier: dayID
            )
            let dict = config.dictionaryValue
            let reconstructed = TinyBuddyAppConfig(dictionary: dict)
            XCTAssertEqual(reconstructed?.refreshStrategy, strategy)
        }
    }

    func testExclusionRuleModel() {
        let rule = TinyBuddyExclusionRule(id: "abc", pattern: "node_modules")
        XCTAssertEqual(rule.id, "abc")
        XCTAssertEqual(rule.pattern, "node_modules")

        let dict = rule.dictionaryValue
        let reconstructed = TinyBuddyExclusionRule(dictionary: dict)
        XCTAssertEqual(reconstructed, rule)
    }
}
