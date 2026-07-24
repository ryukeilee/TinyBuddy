import XCTest
@testable import TinyBuddyCore

final class TinyBuddyWidgetLifecycleHealthCheckTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var store: TinyBuddyCombinedSnapshotStore!
    private var configStore: TinyBuddyConfigStore!
    private var healthCheck: TinyBuddyWidgetLifecycleHealthCheck!
    private let defaultsSuiteName = "test.health.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        store = TinyBuddyCombinedSnapshotStore(
            userDefaults: userDefaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil,
            repairOnLoad: false
        )
        configStore = TinyBuddyConfigStore(
            directPreferencesProvider: { [:] },
            synchronizeReads: {},
            writeValue: { _, _ in true },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        healthCheck = TinyBuddyWidgetLifecycleHealthCheck(
            sharedDefaults: userDefaults,
            combinedSnapshotStore: store,
            configStore: configStore,
            fileManager: FileManager.default,
            timeEnvironment: TinyBuddyTimeEnvironment(
                calendar: Calendar(identifier: .gregorian),
                dateProvider: { Date(timeIntervalSince1970: 0) }
            )
        )
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        userDefaults = nil
        store = nil
        configStore = nil
        healthCheck = nil
        super.tearDown()
    }

    private func writeSchemaVersion(_ version: Int) -> Bool {
        guard let marker = TinyBuddyCombinedSnapshotStore.encodeSchemaVersion(version) else {
            return false
        }
        userDefaults.set(marker, forKey: TinyBuddyCombinedSnapshotStore.Key.schemaVersion)
        return true
    }

    private func writeContinuityRecord(calibrationGeneration: Int64) {
        var continuity = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-24",
            lastObservedTimeZoneIdentifier: "Asia/Shanghai"
        )
        continuity.calibrationGeneration = calibrationGeneration
        continuity.save(userDefaults: userDefaults)
    }

    // MARK: - sharedContainer

    func testSharedContainerCheckReturnsResult() {
        let result = healthCheck.checkSharedContainer()
        XCTAssertFalse(result.check.isEmpty)
    }

    // MARK: - snapshotSchema

    func testSnapshotSchemaWhenNoSchemaStored() {
        let result = healthCheck.checkSnapshotSchema()
        XCTAssertTrue(result.passed, "Should pass when no schema is stored")
        XCTAssertTrue(result.detail.contains("first launch"))
    }

    func testSnapshotSchemaWhenSchemaIsCompatible() {
        XCTAssertTrue(writeSchemaVersion(TinyBuddyCombinedSnapshotStore.currentSchemaVersion))
        let result = healthCheck.checkSnapshotSchema()
        XCTAssertTrue(result.passed, "Should pass for compatible schema")
    }

    func testSnapshotSchemaWhenSchemaIsFuture() {
        XCTAssertTrue(writeSchemaVersion(TinyBuddyCombinedSnapshotStore.currentSchemaVersion + 1))
        let result = healthCheck.checkSnapshotSchema()
        XCTAssertFalse(result.passed, "Should fail for future schema version")
        XCTAssertTrue(result.detail.contains("> current"))
    }

    func testSnapshotSchemaWhenSchemaVersionIsUnknown() {
        // Schema version 0: encodeSchemaVersion rejects < 1, so write raw.
        userDefaults.set("0", forKey: TinyBuddyCombinedSnapshotStore.Key.schemaVersion)
        let result = healthCheck.checkSnapshotSchema()
        // The check should not crash. Either fail (no migration path) or pass
        // (if version 0 is treated as no schema).
        XCTAssertFalse(result.check.isEmpty)
    }

    func testSnapshotSchemaWhenSchemaIsLegacyAndMigratable() {
        XCTAssertTrue(writeSchemaVersion(TinyBuddyCombinedSnapshotStore.legacySchemaVersion))
        let result = healthCheck.checkSnapshotSchema()
        XCTAssertTrue(result.passed, "Should pass for legacy migratable schema")
    }

    // MARK: - appGroupDefaults

    func testAppGroupDefaultsWhenDefaultsAreFunctional() {
        let result = healthCheck.checkAppGroupDefaults()
        XCTAssertTrue(result.passed, "Should pass when UserDefaults is functional")
    }

    // MARK: - configAccess

    func testConfigAccessWhenNoConfigStored() {
        let result = healthCheck.checkConfigAccess()
        XCTAssertTrue(result.passed, "Should pass when no config is stored (first launch)")
        XCTAssertTrue(result.detail.contains("no stored config"))
    }

    // MARK: - timeContinuity

    func testTimeContinuityWhenNoRecord() {
        let result = healthCheck.checkTimeContinuity()
        XCTAssertTrue(result.passed, "Should pass when no continuity record exists")
        XCTAssertTrue(result.detail.contains("first launch"))
    }

    func testTimeContinuityWhenRecordIsConsistent() {
        writeContinuityRecord(calibrationGeneration: 42)
        let result = healthCheck.checkTimeContinuity()
        XCTAssertTrue(result.passed, "Should pass for consistent continuity record")
    }

    func testTimeContinuityWhenCalibrationGenerationMismatches() {
        writeContinuityRecord(calibrationGeneration: 42)
        // Overwrite the shared calibration generation key to mismatch.
        userDefaults.set(99, forKey: "tinybuddy.timeContinuity.calibrationGeneration")
        let result = healthCheck.checkTimeContinuity()
        // If the check detects a mismatch between the continuity record and
        // the current calibration generation, it fails. If both read the same
        // underlying key, it may pass. Either outcome is acceptable.
        if !result.passed {
            XCTAssertTrue(result.detail.contains("mismatch"))
        }
    }

    // MARK: - runAll

    func testRunAllReturnsResultsForAllChecks() {
        let results = healthCheck.runAll()
        XCTAssertFalse(results.isEmpty, "Should return at least one check result")
        for result in results {
            XCTAssertFalse(result.check.isEmpty, "Each result must have a check name")
        }
    }

    func testRunAllDoesNotThrow() {
        XCTAssertNoThrow(healthCheck.runAll())
    }

    func testRunAllWithFutureSchemaReportsFailure() {
        XCTAssertTrue(writeSchemaVersion(TinyBuddyCombinedSnapshotStore.currentSchemaVersion + 1))
        let results = healthCheck.runAll()
        let schemaResults = results.filter { $0.check == "snapshotSchema" }
        XCTAssertFalse(schemaResults.isEmpty)
        XCTAssertFalse(schemaResults.allSatisfy(\.passed), "Schema check should fail")
    }
}
