import XCTest
@testable import TinyBuddyCore

final class TinyBuddyTimeContinuityRecordTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "TinyBuddyTimeContinuityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Persistence

    func testLoadReturnsEmptyRecordWhenNoPriorState() {
        let defaults = makeDefaults()
        let record = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)

        XCTAssertEqual(record.lastObservedDayIdentifier, "")
        XCTAssertEqual(record.lastObservedTimeZoneIdentifier, "")
        XCTAssertEqual(record.calibrationGeneration, 0)
        XCTAssertEqual(record.discontinuityCount, 0)
    }

    func testSaveAndLoadRoundTrip() {
        let defaults = makeDefaults()
        var record = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "America/Los_Angeles",
            calibrationGeneration: 42,
            lastCalibrationDate: Date(timeIntervalSince1970: 1_700_000_000),
            discontinuityCount: 3,
            lastScopeIdentifier: "scope-abc"
        )

        XCTAssertTrue(record.save(userDefaults: defaults))

        let loaded = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loaded.lastObservedDayIdentifier, "2026-07-22")
        XCTAssertEqual(loaded.lastObservedTimeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(loaded.calibrationGeneration, 42)
        XCTAssertEqual(loaded.lastCalibrationDate.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(loaded.discontinuityCount, 3)
        XCTAssertEqual(loaded.lastScopeIdentifier, "scope-abc")
    }

    func testMultipleSaveUpdatesGeneration() {
        let defaults = makeDefaults()
        var record = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "UTC"
        )

        record.save(userDefaults: defaults)
        record.calibrationGeneration = 5
        record.save(userDefaults: defaults)

        let loaded = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loaded.calibrationGeneration, 5)
    }

    func testRemoveClearsRecord() {
        let defaults = makeDefaults()
        let record = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "UTC"
        )
        record.save(userDefaults: defaults)
        TinyBuddyTimeContinuityRecord.remove(userDefaults: defaults)

        let loaded = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loaded.lastObservedDayIdentifier, "")
        XCTAssertEqual(loaded.calibrationGeneration, 0)
    }

    // MARK: - Equality

    func testEquality() {
        let a = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "UTC",
            calibrationGeneration: 1,
            discontinuityCount: 0
        )
        let b = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "UTC",
            calibrationGeneration: 1,
            discontinuityCount: 0
        )
        let c = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-23",
            lastObservedTimeZoneIdentifier: "UTC",
            calibrationGeneration: 1,
            discontinuityCount: 0
        )

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Last Observed Day Length

    func testDayLengthSecondsRoundTrip() {
        let defaults = makeDefaults()
        var record = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-03-08",
            lastObservedTimeZoneIdentifier: "America/Los_Angeles",
            calibrationGeneration: 10,
            lastObservedDayLengthSeconds: 82_800
        )

        XCTAssertTrue(record.save(userDefaults: defaults))

        let loaded = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loaded.lastObservedDayLengthSeconds, 82_800)
    }

    func testDayLengthSecondsNilByDefault() {
        let record = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "UTC"
        )
        XCTAssertNil(record.lastObservedDayLengthSeconds)
    }

    func testDayLengthSecondsPreservesFallBackValue() {
        let defaults = makeDefaults()
        var record = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-11-01",
            lastObservedTimeZoneIdentifier: "America/Los_Angeles",
            calibrationGeneration: 15,
            lastObservedDayLengthSeconds: 90_000
        )
        record.save(userDefaults: defaults)

        let loaded = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loaded.lastObservedDayLengthSeconds, 90_000)
    }

    // MARK: - Current Calibration Generation Accessor

    func testCurrentCalibrationGenerationReturnsZeroForEmpty() {
        let defaults = makeDefaults()
        XCTAssertEqual(
            TinyBuddyTimeContinuityRecord.currentCalibrationGeneration(userDefaults: defaults),
            0
        )
    }

    func testCurrentCalibrationGenerationReturnsSavedGeneration() {
        let defaults = makeDefaults()
        var record = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "UTC",
            calibrationGeneration: 42
        )
        record.save(userDefaults: defaults)

        XCTAssertEqual(
            TinyBuddyTimeContinuityRecord.currentCalibrationGeneration(userDefaults: defaults),
            42
        )
    }

    // MARK: - Codable Corruption

    func testCorruptedDataReturnsEmptyRecord() {
        let defaults = makeDefaults()
        defaults.set(Data("garbage".utf8), forKey: TinyBuddyTimeContinuityRecord.Key.continuityRecord)

        let loaded = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loaded.lastObservedDayIdentifier, "")
        XCTAssertEqual(loaded.calibrationGeneration, 0)
    }
}
