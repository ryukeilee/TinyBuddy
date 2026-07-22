import XCTest
@testable import TinyBuddyCore

/// Thread-safe holder for mutable test state captured by Sendable closures.
private final class TestObserver: @unchecked Sendable {
    var onChangeCallCount = 0
    var lastOutcome: TinyBuddyCalibrationOutcome?
}

final class TinyBuddyTimeCalibratorTests: XCTestCase {
    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let name = "TinyBuddyTimeCalibratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeDate(
        year: Int, month: Int, day: Int,
        hour: Int, minute: Int = 0, second: Int = 0,
        timeZone: TimeZone? = nil
    ) -> Date {
        let tz = timeZone ?? TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: DateComponents(
            calendar: calendar, timeZone: tz,
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    private func makeTimeEnvironment(
        now: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> TinyBuddyTimeEnvironment {
        TinyBuddyTimeEnvironment.fixed(now: now, timeZone: timeZone, locale: locale)
    }

    // MARK: - Stable

    func testSameDaySameZoneReturnsStable() {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0)
        let env = makeTimeEnvironment(now: now, timeZone: utc)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 10,
            lastCalibrationDate: now.addingTimeInterval(-60)
        )
        seed.save(userDefaults: defaults)

        let observer = TestObserver()
        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults,
            monotonicProvider: { 1000 },
            onChange: { _ in observer.onChangeCallCount += 1 }
        )

        let outcome = calibrator.calibrate()

        guard case .stable(let continuity) = outcome else {
            XCTFail("Expected .stable, got \(outcome)")
            return
        }
        XCTAssertEqual(continuity.lastObservedDayIdentifier, "2026-07-22")
        XCTAssertEqual(continuity.calibrationGeneration, seed.calibrationGeneration + 1)
        XCTAssertEqual(observer.onChangeCallCount, 0,
                       "Stable should not emit onChange when prior continuity exists")
    }

    // MARK: - Day Change

    func testDayChangeDetected() {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 23, hour: 0, minute: 5)
        let env = makeTimeEnvironment(now: now, timeZone: utc)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 5,
            lastCalibrationDate: now.addingTimeInterval(-3600)
        )
        seed.save(userDefaults: defaults)

        let observer = TestObserver()
        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults,
            onChange: { outcome in
                observer.onChangeCallCount += 1
                observer.lastOutcome = outcome
            }
        )

        let outcome = calibrator.calibrate()

        guard case .dayChanged(let from, let to, let continuity) = outcome else {
            XCTFail("Expected .dayChanged, got \(outcome)")
            return
        }
        XCTAssertEqual(from, "2026-07-22")
        XCTAssertEqual(to, "2026-07-23")
        XCTAssertEqual(continuity.calibrationGeneration, 6)

        XCTAssertEqual(observer.onChangeCallCount, 1)
        if case .dayChanged(let ofrom, let oto, _)? = observer.lastOutcome {
            XCTAssertEqual(ofrom, "2026-07-22")
            XCTAssertEqual(oto, "2026-07-23")
        } else {
            XCTFail("onChange expected .dayChanged")
        }
    }

    // MARK: - Timezone Change

    func testTimezoneChangeWithoutDayChange() {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0)
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let env = makeTimeEnvironment(now: now, timeZone: losAngeles)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 3,
            lastCalibrationDate: now.addingTimeInterval(-120)
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults
        )

        let outcome = calibrator.calibrate()

        guard case .timeZoneChanged(let from, let to, let continuity) = outcome else {
            XCTFail("Expected .timeZoneChanged, got \(outcome)")
            return
        }
        XCTAssertEqual(from, "GMT")
        XCTAssertTrue(to.contains("Los_Angeles"), "to=\(to)")
        XCTAssertEqual(continuity.calibrationGeneration, 4)
    }

    // MARK: - Clock Discontinuity

    func testClockDiscontinuityDetected() {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0)
        let env = makeTimeEnvironment(now: now, timeZone: utc)

        let monotonicStart: TimeInterval = 10_000
        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 7,
            lastCalibrationDate: now.addingTimeInterval(-600),
            discontinuityCount: 0,
            lastMonotonicTime: monotonicStart
        )
        seed.save(userDefaults: defaults)

        // Simulate a clock jump: monotonic time advanced only 100s while
        // wall time advanced 600s (500s difference > 5s threshold)
        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults,
            monotonicProvider: { monotonicStart + 100 },
            discontinuityThreshold: 5.0
        )

        let outcome = calibrator.calibrate()

        guard case .discontinuityDetected(
            let prevDay, let currDay,
            let prevZone, let currZone,
            let continuity
        ) = outcome else {
            XCTFail("Expected .discontinuityDetected, got \(outcome)")
            return
        }
        XCTAssertEqual(prevDay, "2026-07-22")
        XCTAssertEqual(currDay, "2026-07-22")
        XCTAssertEqual(prevZone, "GMT")
        XCTAssertTrue(currZone.contains("GMT"))
        XCTAssertEqual(continuity.discontinuityCount, 1)
        XCTAssertEqual(continuity.calibrationGeneration, 8)
    }

    func testSmallClockDriftIsNotDiscontinuity() {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0)
        let env = makeTimeEnvironment(now: now, timeZone: utc)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 7,
            lastCalibrationDate: now.addingTimeInterval(-60),
            discontinuityCount: 0
        )
        seed.save(userDefaults: defaults)

        // Monotonic also advanced ~60s → no significant drift
        let monotonicStart: TimeInterval = 10_000
        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults,
            monotonicProvider: { monotonicStart + 61 },
            discontinuityThreshold: 5.0
        )

        let outcome = calibrator.calibrate()

        guard case .stable = outcome else {
            XCTFail("Expected .stable for small drift, got \(outcome)")
            return
        }
    }

    // MARK: - Invalid

    func testInvalidTimeContext() {
        let defaults = makeDefaults()
        let env = TinyBuddyTimeEnvironment(capture: { nil })

        let observer = TestObserver()
        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults,
            onChange: { outcome in
                observer.onChangeCallCount += 1
                observer.lastOutcome = outcome
            }
        )

        let outcome = calibrator.calibrate()
        XCTAssertEqual(outcome, .invalid)
        XCTAssertEqual(observer.onChangeCallCount, 1)
        if case .invalid? = observer.lastOutcome {
            // Expected
        } else {
            XCTFail("onChange expected .invalid")
        }
    }

    // MARK: - First Calibration

    func testFirstCalibrationWithEmptyRecord() {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0)
        let env = makeTimeEnvironment(now: now, timeZone: utc)

        let observer = TestObserver()
        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults,
            onChange: { _ in observer.onChangeCallCount += 1 }
        )

        let outcome = calibrator.calibrate()

        guard case .stable(let continuity) = outcome else {
            XCTFail("Expected .stable (first), got \(outcome)")
            return
        }
        XCTAssertEqual(continuity.lastObservedDayIdentifier, "2026-07-22")
        XCTAssertEqual(continuity.calibrationGeneration, 1)
        // First calibration with empty record should emit onChange
        XCTAssertEqual(observer.onChangeCallCount, 1)
    }

    // MARK: - Reset

    func testResetContinuityClearsRecord() {
        let defaults = makeDefaults()
        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 10
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: makeTimeEnvironment(
                now: makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0),
                timeZone: utc
            ),
            userDefaults: defaults
        )

        calibrator.resetContinuity()

        let loaded = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loaded.lastObservedDayIdentifier, "")
        XCTAssertEqual(loaded.lastObservedTimeZoneIdentifier, "")
        XCTAssertEqual(loaded.calibrationGeneration, 0)
    }

    // MARK: - Bump Generation

    func testBumpGenerationAdvancesGeneration() {
        let defaults = makeDefaults()
        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 7
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: makeTimeEnvironment(
                now: makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0),
                timeZone: utc
            ),
            userDefaults: defaults
        )

        calibrator.bumpGeneration()

        let loaded = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loaded.calibrationGeneration, 8)

        calibrator.bumpGeneration()
        let loadedAgain = TinyBuddyTimeContinuityRecord.load(userDefaults: defaults)
        XCTAssertEqual(loadedAgain.calibrationGeneration, 9)
    }

    // MARK: - Calibrated Context

    func testCalibratedContextReturnsBothContextAndOutcome() {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0)
        let env = makeTimeEnvironment(now: now, timeZone: utc)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 3,
            lastCalibrationDate: now.addingTimeInterval(-300)
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults
        )

        let (context, outcome) = calibrator.calibratedContext()

        XCTAssertNotNil(context)
        XCTAssertEqual(context?.dayIdentifier, "2026-07-22")
        guard case .stable = outcome else {
            XCTFail("Expected .stable from calibratedContext, got \(outcome)")
            return
        }
    }

    func testCalibratedContextReturnsNilForInvalid() {
        let defaults = makeDefaults()
        let env = TinyBuddyTimeEnvironment(capture: { nil })

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults
        )

        let (context, outcome) = calibrator.calibratedContext()
        XCTAssertNil(context)
        XCTAssertEqual(outcome, .invalid)
    }

    // MARK: - DST Transition Day Detection

    func testNormalDayDoesNotSetDayLengthSeconds() {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 22, hour: 12, minute: 0)
        let env = makeTimeEnvironment(now: now, timeZone: utc)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-22",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 5,
            lastCalibrationDate: now.addingTimeInterval(-3600)
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults
        )

        let outcome = calibrator.calibrate()
        guard case .stable(let continuity) = outcome else {
            XCTFail("Expected .stable, got \(outcome)")
            return
        }
        XCTAssertNil(continuity.lastObservedDayLengthSeconds,
                     "Normal day should not set day-length seconds")
    }

    func testSpringForwardDayRecords82800Seconds() {
        let defaults = makeDefaults()
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        // 2026-03-08 12:00 PT is a spring-forward day (clocks spring ahead)
        let now = makeDate(year: 2026, month: 3, day: 8, hour: 12, minute: 0, timeZone: losAngeles)
        let env = makeTimeEnvironment(now: now, timeZone: losAngeles)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-03-08",
            lastObservedTimeZoneIdentifier: "America/Los_Angeles",
            calibrationGeneration: 5,
            lastCalibrationDate: now.addingTimeInterval(-3600)
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults
        )

        let outcome = calibrator.calibrate()
        guard case .stable(let continuity) = outcome else {
            XCTFail("Expected .stable for DST spring-forward, got \(outcome)")
            return
        }
        XCTAssertEqual(continuity.lastObservedDayLengthSeconds, 82_800,
                       "Spring-forward day should have 23h (82800s)")
    }

    func testFallBackDayRecords90000Seconds() {
        let defaults = makeDefaults()
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        // 2026-11-01 12:00 PT is a fall-back day (clocks fall back)
        let now = makeDate(year: 2026, month: 11, day: 1, hour: 12, minute: 0, timeZone: losAngeles)
        let env = makeTimeEnvironment(now: now, timeZone: losAngeles)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-11-01",
            lastObservedTimeZoneIdentifier: "America/Los_Angeles",
            calibrationGeneration: 5,
            lastCalibrationDate: now.addingTimeInterval(-3600)
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults
        )

        let outcome = calibrator.calibrate()
        guard case .stable(let continuity) = outcome else {
            XCTFail("Expected .stable for DST fall-back, got \(outcome)")
            return
        }
        XCTAssertEqual(continuity.lastObservedDayLengthSeconds, 90_000,
                       "Fall-back day should have 25h (90000s)")
    }

    // MARK: - DST-like Transition

    func testTimezoneChangeWithDSTCrossing() {
        let defaults = makeDefaults()
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let now = makeDate(year: 2026, month: 3, day: 8, hour: 10, minute: 0, timeZone: utc)
        let env = makeTimeEnvironment(now: now, timeZone: losAngeles)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-03-08",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 5,
            lastCalibrationDate: now.addingTimeInterval(-86400)
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults
        )

        let outcome = calibrator.calibrate()
        guard case .timeZoneChanged(let from, let to, _) = outcome else {
            XCTFail("Expected .timeZoneChanged for DST zone shift, got \(outcome)")
            return
        }
        XCTAssertEqual(from, "GMT")
        XCTAssertTrue(to.contains("Los_Angeles"))
    }

    // MARK: - Cross-Day Timezone Change

    func testTimezoneChangeThatAlsoChangesDay() {
        let defaults = makeDefaults()
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let now = makeDate(year: 2026, month: 7, day: 22, hour: 16, minute: 0, timeZone: losAngeles)
        let env = makeTimeEnvironment(now: now, timeZone: losAngeles)

        var seed = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "2026-07-23",
            lastObservedTimeZoneIdentifier: "GMT",
            calibrationGeneration: 5,
            lastCalibrationDate: now.addingTimeInterval(-1800)
        )
        seed.save(userDefaults: defaults)

        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: env,
            userDefaults: defaults
        )

        let outcome = calibrator.calibrate()
        // Both day and timezone changed; expect dayChanged (day differs)
        guard case .dayChanged(let from, let to, let continuity) = outcome else {
            XCTFail("Expected .dayChanged, got \(outcome)")
            return
        }
        XCTAssertEqual(from, "2026-07-23")
        XCTAssertEqual(to, "2026-07-22")
        XCTAssertTrue(continuity.lastObservedTimeZoneIdentifier.contains("Los_Angeles"))
    }
}
