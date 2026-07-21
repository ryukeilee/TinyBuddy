import XCTest
@testable import TinyBuddyCore

final class FocusSessionRuleVersioningTests: XCTestCase {

    private let projectA = FocusProjectContext(key: "repo/a", displayName: "Project A")
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Rule Set Diff

    func testRuleSetDiffIdentifiesConfigurationChanges() {
        let oldConfig = FocusSessionConfiguration(idleThreshold: 120, briefInterruptionThreshold: 60, longAbsenceThreshold: 600)
        let newConfig = FocusSessionConfiguration(idleThreshold: 60, briefInterruptionThreshold: 120, longAbsenceThreshold: 300)

        let oldRuleSet = FocusSessionRuleSet(version: FocusSessionRuleVersion(major: 1, minor: 0), configuration: oldConfig, label: "v1")
        let newRuleSet = FocusSessionRuleSet(version: FocusSessionRuleVersion(major: 2, minor: 0), configuration: newConfig, label: "v2")

        let diffs = newRuleSet.differences(from: oldRuleSet)

        XCTAssertTrue(diffs.contains(where: { $0.contains("Rule version") && $0.contains("1.0") && $0.contains("2.0") }))
        XCTAssertTrue(diffs.contains(where: { $0.contains("Idle threshold") }))
        XCTAssertTrue(diffs.contains(where: { $0.contains("Brief interruption threshold") }))
        XCTAssertTrue(diffs.contains(where: { $0.contains("Long absence threshold") }))
    }

    func testRuleSetDiffEmptyWhenIdentical() {
        let config = FocusSessionConfiguration()
        let ruleSet1 = FocusSessionRuleSet(version: .current, configuration: config, label: "same")
        let ruleSet2 = FocusSessionRuleSet(version: .current, configuration: config, label: "same")

        XCTAssertTrue(ruleSet2.differences(from: ruleSet1).isEmpty)
    }

    func testRuleSetDiffDetectsAttributionPolicyChange() {
        let old = FocusAttributionPolicy(gitAttributionWindow: 300)
        let new = FocusAttributionPolicy(gitAttributionWindow: nil)
        let oldRuleSet = FocusSessionRuleSet(
            version: FocusSessionRuleVersion(major: 1, minor: 0),
            configuration: FocusSessionConfiguration(),
            attributionPolicy: old
        )
        let newRuleSet = FocusSessionRuleSet(
            version: FocusSessionRuleVersion(major: 1, minor: 1),
            configuration: FocusSessionConfiguration(),
            attributionPolicy: new
        )

        let diffs = newRuleSet.differences(from: oldRuleSet)
        XCTAssertTrue(diffs.contains(where: { $0.contains("Git attribution window") }))
    }

    // MARK: - Rule Version Comparison

    func testRuleVersionComparison() {
        let v1 = FocusSessionRuleVersion(major: 1, minor: 0)
        let v2 = FocusSessionRuleVersion(major: 2, minor: 0)
        let v1_1 = FocusSessionRuleVersion(major: 1, minor: 1)

        XCTAssertLessThan(v1, v2)
        XCTAssertLessThan(v1, v1_1)
        XCTAssertGreaterThan(v2, v1)
        XCTAssertEqual(v1, v1)
        XCTAssertEqual(FocusSessionRuleVersion(major: 1, minor: 0), FocusSessionRuleVersion.current)
    }

    // MARK: - Rule Set Codable

    func testRuleSetCodableRoundTrip() throws {
        let original = FocusSessionRuleSet(
            version: FocusSessionRuleVersion(major: 2, minor: 1),
            configuration: FocusSessionConfiguration(idleThreshold: 60, briefInterruptionThreshold: 30, longAbsenceThreshold: 300),
            attributionPolicy: FocusAttributionPolicy(gitAttributionWindow: 600),
            label: "test config"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FocusSessionRuleSet.self, from: data)

        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.configuration.idleThreshold, 60)
        XCTAssertEqual(decoded.configuration.briefInterruptionThreshold, 30)
        XCTAssertEqual(decoded.configuration.longAbsenceThreshold, 300)
        XCTAssertEqual(decoded.attributionPolicy.gitAttributionWindow, 600)
        XCTAssertEqual(decoded.label, "test config")
    }

    // MARK: - Session Rule Version Tagging

    func testEngineTagsSessionsWithRuleVersion() {
        let clock = FakeClock(t0)
        let store = MemoryStore()
        let engine = makeEngine(clock: clock, store: store)

        engine.userActivity(in: projectA, at: t0)

        let session = try! XCTUnwrap(engine.allSessions.first)
        XCTAssertEqual(session.ruleVersion, FocusSessionRuleVersion.current)
        XCTAssertEqual(session.mode, .automatic)
    }

    func testManualSessionCarriesRuleVersion() {
        let clock = FakeClock(t0)
        let store = MemoryStore()
        let engine = makeEngine(clock: clock, store: store)

        engine.startManualFocus(project: projectA, at: t0)

        let session = try! XCTUnwrap(engine.allSessions.first)
        XCTAssertEqual(session.ruleVersion, FocusSessionRuleVersion.current)
        XCTAssertEqual(session.mode, .manual)
    }

    func testCustomRuleVersionProvider() {
        let clock = FakeClock(t0)
        let store = MemoryStore()
        let customVersion = FocusSessionRuleVersion(major: 99, minor: 99)
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            dayIdentifier: { _ in "2026-07-22" },
            ruleVersionProvider: { customVersion }
        )

        engine.userActivity(in: projectA, at: t0)

        let session = try! XCTUnwrap(engine.allSessions.first)
        XCTAssertEqual(session.ruleVersion, customVersion)
    }

    // MARK: - Registry Persistence

    func testRuleRegistryRoundTrip() {
        let defaults = TinyBuddySharedData.makeUserDefaults()
        // Clear any pre-existing state
        defaults.removeObject(forKey: "tinybuddy.focusRule.currentRuleSet.v1")
        defaults.removeObject(forKey: "tinybuddy.focusRule.previousRuleSet.v1")

        let registry = FocusSessionRuleRegistry(userDefaults: defaults)

        // Initial state: default rule set
        let initial = registry.currentRuleSet
        XCTAssertEqual(initial.version, FocusSessionRuleVersion.current)
        XCTAssertNil(registry.previousRuleSet)

        // Register a new rule set
        let newVersion = FocusSessionRuleVersion(major: 2, minor: 0)
        let newConfig = FocusSessionConfiguration(idleThreshold: 30)
        let newRuleSet = FocusSessionRuleSet(version: newVersion, configuration: newConfig, label: "v2 fast")
        XCTAssertTrue(registry.registerNewRuleSet(newRuleSet))

        // Verify current changed
        XCTAssertEqual(registry.currentRuleSet.version, newVersion)
        XCTAssertEqual(registry.currentRuleSet.configuration.idleThreshold, 30)

        // Previous should now be the initial/default
        let previous = try! XCTUnwrap(registry.previousRuleSet)
        XCTAssertEqual(previous.version, initial.version)
    }

    func testRuleRegistryRollback() {
        let defaults = TinyBuddySharedData.makeUserDefaults()
        defaults.removeObject(forKey: "tinybuddy.focusRule.currentRuleSet.v1")
        defaults.removeObject(forKey: "tinybuddy.focusRule.previousRuleSet.v1")

        let registry = FocusSessionRuleRegistry(userDefaults: defaults)
        let initial = registry.currentRuleSet

        let newRuleSet = FocusSessionRuleSet(
            version: FocusSessionRuleVersion(major: 2, minor: 0),
            configuration: FocusSessionConfiguration(),
            label: "v2"
        )
        XCTAssertTrue(registry.registerNewRuleSet(newRuleSet))
        XCTAssertEqual(registry.currentRuleSet.version.major, 2)

        // Rollback
        XCTAssertTrue(registry.rollbackToPrevious())
        XCTAssertEqual(registry.currentRuleSet.version, initial.version)
    }

    func testRegistryRollbackFailsWithoutPrevious() {
        let defaults = TinyBuddySharedData.makeUserDefaults()
        defaults.removeObject(forKey: "tinybuddy.focusRule.currentRuleSet.v1")
        defaults.removeObject(forKey: "tinybuddy.focusRule.previousRuleSet.v1")

        let registry = FocusSessionRuleRegistry(userDefaults: defaults)
        XCTAssertFalse(registry.rollbackToPrevious())
    }

    // MARK: - Upgrade Recovery State

    func testUpgradeRecoveryStateRoundTrip() {
        let defaults = TinyBuddySharedData.makeUserDefaults()
        defaults.removeObject(forKey: "tinybuddy.focusRule.upgradeState.v1")

        let registry = FocusSessionRuleRegistry(userDefaults: defaults)
        let state = FocusSessionRuleRegistry.UpgradeRecoveryState(
            newRuleSet: FocusSessionRuleSet(version: FocusSessionRuleVersion(major: 2, minor: 0), configuration: FocusSessionConfiguration()),
            oldRuleSet: FocusSessionRuleSet(version: FocusSessionRuleVersion(major: 1, minor: 0), configuration: FocusSessionConfiguration()),
            dayStart: "2026-07-01",
            dayEnd: "2026-07-22",
            archiveRevision: 42
        )

        XCTAssertTrue(registry.saveUpgradeState(state))

        let loaded = try! XCTUnwrap(registry.loadUpgradeState())
        XCTAssertEqual(loaded.newRuleSet.version.major, 2)
        XCTAssertEqual(loaded.oldRuleSet.version.major, 1)
        XCTAssertEqual(loaded.dayStart, "2026-07-01")
        XCTAssertEqual(loaded.dayEnd, "2026-07-22")
        XCTAssertEqual(loaded.archiveRevision, 42)

        // Clear
        XCTAssertTrue(registry.clearUpgradeState())
        XCTAssertNil(registry.loadUpgradeState())
    }

    // MARK: - Helpers

    private func makeEngine(clock: FakeClock, store: MemoryStore) -> FocusSessionEngine {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return FocusSessionEngine(
            clock: clock,
            persisting: store,
            dayIdentifier: { date in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            },
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            }
        )
    }
}
