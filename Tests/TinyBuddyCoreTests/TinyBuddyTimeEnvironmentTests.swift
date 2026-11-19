import XCTest
@testable import TinyBuddyCore

final class TinyBuddyTimeEnvironmentTests: XCTestCase {
    func testSameInstantUsesConfiguredLocalDay() throws {
        let instant = makeDate(year: 2026, month: 7, day: 2, hour: 0, minute: 30, timeZone: utc)
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        XCTAssertEqual(try XCTUnwrap(makeContext(now: instant, timeZone: utc)).dayIdentifier, "2026-07-02")
        XCTAssertEqual(try XCTUnwrap(makeContext(now: instant, timeZone: losAngeles)).dayIdentifier, "2026-07-01")
    }

    func testNextDayBoundaryUsesLocalMidnight() throws {
        let context = try XCTUnwrap(makeContext(
            now: makeDate(year: 2026, month: 7, day: 1, hour: 23, minute: 59, timeZone: utc),
            timeZone: utc
        ))

        XCTAssertEqual(context.dayIdentifier, "2026-07-01")
        XCTAssertEqual(context.nextDayBoundary, makeDate(year: 2026, month: 7, day: 2, hour: 0, minute: 0, timeZone: utc))
    }

    func testDayIdentifiersRemainCorrectAcrossDSTTransitions() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let spring = try XCTUnwrap(makeContext(
            now: makeDate(year: 2026, month: 3, day: 8, hour: 1, minute: 59, timeZone: losAngeles),
            timeZone: losAngeles
        ))
        let fall = try XCTUnwrap(makeContext(
            now: makeDate(year: 2026, month: 11, day: 1, hour: 1, minute: 30, timeZone: losAngeles),
            timeZone: losAngeles
        ))

        XCTAssertEqual(spring.dayIdentifier, "2026-03-08")
        XCTAssertEqual(spring.nextDayBoundary, makeDate(year: 2026, month: 3, day: 9, hour: 0, minute: 0, timeZone: losAngeles))
        XCTAssertEqual(fall.dayIdentifier, "2026-11-01")
        XCTAssertTrue(fall.isSameLocalDay(fall.now, fall.nextDayBoundary.addingTimeInterval(-1)))
    }

    func testBusinessDayIsGregorianDespiteSourceCalendarFingerprint() throws {
        var buddhistCalendar = Calendar(identifier: .buddhist)
        buddhistCalendar.locale = Locale(identifier: "th_TH")
        buddhistCalendar.timeZone = utc
        let context = try XCTUnwrap(TinyBuddyTimeContext(
            now: makeDate(year: 2026, month: 7, day: 1, hour: 12, minute: 0, timeZone: utc),
            timeZone: utc,
            locale: Locale(identifier: "th_TH"),
            sourceCalendar: buddhistCalendar
        ))

        XCTAssertEqual(context.dayIdentifier, "2026-07-01")
        XCTAssertEqual(context.signature.localeIdentifier, "th_TH")
        XCTAssertEqual(context.signature.calendarIdentifier, "buddhist")
    }

    func testScopeIdentifierIsASCIIAndNeverContainsLineOrTabBreaks() {
        let signature = TinyBuddyTimeEnvironmentSignature(
            timeZoneIdentifier: "America/Los_Angeles\nnext",
            localeIdentifier: "en_US\tPOSIX",
            calendarIdentifier: "gregorian\rvalue"
        )

        XCTAssertFalse(signature.scopeIdentifier.contains("\n"))
        XCTAssertFalse(signature.scopeIdentifier.contains("\r"))
        XCTAssertFalse(signature.scopeIdentifier.contains("\t"))
        XCTAssertTrue(signature.scopeIdentifier.unicodeScalars.allSatisfy { $0.isASCII })
    }

    func testStrictDayIdentifierValidationRejectsImpossibleAndNonISOValues() {
        XCTAssertTrue(TinyBuddyTimeContext.isValidDayIdentifier("2026-02-28"))
        XCTAssertTrue(TinyBuddyTimeContext.isValidDayIdentifier("2024-02-29"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("2026-02-30"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("2026-2-3"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("๒๐๒๖-๐๒-๒๘"))
    }

    func testFastDayIdentifierValidationMatchesCalendarReference() {
        // Years from the Gregorian cutover onward use the arithmetic fast path;
        // compare it with the calendar round-trip it replaced across month
        // boundaries, leap days, and a stable sample of the supported range.
        var values: [String] = []
        // Every day of a leap year and a common year.
        for year in [2024, 2026] {
            for month in 1 ... 12 {
                for day in 1 ... 31 {
                    values.append(String(format: "%04d-%02d-%02d", year, month, day))
                }
            }
        }
        // Month/leap boundaries across the whole fast-path range.
        for year in Array(1583 ... 1600) + Array(stride(from: 1610, through: 2400, by: 10)) {
            for month in 1 ... 12 {
                values.append(String(format: "%04d-%02d-01", year, month))
                values.append(String(format: "%04d-%02d-28", year, month))
                values.append(String(format: "%04d-%02d-29", year, month))
                values.append(String(format: "%04d-%02d-31", year, month))
            }
        }
        for year in stride(from: 2401, through: 9_999, by: 97) {
            values.append(String(format: "%04d-02-29", year))
            values.append(String(format: "%04d-12-31", year))
        }
        for value in values {
            XCTAssertEqual(
                TinyBuddyTimeContext.isValidDayIdentifier(value),
                Self.calendarRoundTripDayValidation(value),
                value
            )
        }
    }

    func testDayIdentifierValidationPreservesGregorianCutoverSemantics() {
        XCTAssertTrue(TinyBuddyTimeContext.isValidDayIdentifier("1582-10-04"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("1582-10-05"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("1582-10-10"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("1582-10-14"))
        XCTAssertTrue(TinyBuddyTimeContext.isValidDayIdentifier("1582-10-15"))
        XCTAssertTrue(TinyBuddyTimeContext.isValidDayIdentifier("0001-01-01"))
        XCTAssertTrue(TinyBuddyTimeContext.isValidDayIdentifier("0999-12-31"))
        XCTAssertTrue(TinyBuddyTimeContext.isValidDayIdentifier("9999-12-31"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("0000-01-01"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("2026-00-10"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("2026-01-00"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("2026-13-01"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("2026-01-32"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier("2026/01/01"))
        XCTAssertFalse(TinyBuddyTimeContext.isValidDayIdentifier(""))
    }

    private static func calendarRoundTripDayValidation(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48 ... 57).contains(byte)
              }) else {
            return false
        }
        let year = Int(String(decoding: bytes[0 ..< 4], as: UTF8.self))
        let month = Int(String(decoding: bytes[5 ..< 7], as: UTF8.self))
        let day = Int(String(decoding: bytes[8 ..< 10], as: UTF8.self))
        guard let year, let month, let day, (1 ... 9_999).contains(year) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return false }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) == value
    }

    func testNextRefreshDateUsesEarlierOfMidnightAndInterval() throws {
        let nearMidnight = try XCTUnwrap(makeContext(
            now: makeDate(year: 2026, month: 7, day: 1, hour: 23, minute: 50, timeZone: utc),
            timeZone: utc
        ))
        let daytime = try XCTUnwrap(makeContext(
            now: makeDate(year: 2026, month: 7, day: 1, hour: 12, minute: 0, timeZone: utc),
            timeZone: utc
        ))

        XCTAssertEqual(
            nearMidnight.nextRefreshDate(maxInterval: 60 * 60),
            makeDate(year: 2026, month: 7, day: 2, hour: 0, minute: 0, timeZone: utc)
        )
        XCTAssertEqual(
            daytime.nextRefreshDate(maxInterval: 15 * 60),
            makeDate(year: 2026, month: 7, day: 1, hour: 12, minute: 15, timeZone: utc)
        )
    }

    func testDSTTransitionDayLengths() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let spring = try XCTUnwrap(makeContext(
            now: makeDate(year: 2026, month: 3, day: 8, hour: 12, minute: 0, timeZone: losAngeles),
            timeZone: losAngeles
        ))
        let fall = try XCTUnwrap(makeContext(
            now: makeDate(year: 2026, month: 11, day: 1, hour: 12, minute: 0, timeZone: losAngeles),
            timeZone: losAngeles
        ))
        let normal = try XCTUnwrap(makeContext(
            now: makeDate(year: 2026, month: 7, day: 1, hour: 12, minute: 0, timeZone: losAngeles),
            timeZone: losAngeles
        ))

        // Spring-forward day should be 23h (82800 seconds)
        XCTAssertEqual(spring.localDayLength, 82_800, accuracy: 1.0)
        XCTAssertTrue(spring.isDSTTransitionDay())

        // Fall-back day should be 25h (90000 seconds)
        XCTAssertEqual(fall.localDayLength, 90_000, accuracy: 1.0)
        XCTAssertTrue(fall.isDSTTransitionDay())

        // Normal day should be 24h (86400 seconds)
        XCTAssertEqual(normal.localDayLength, 86_400, accuracy: 1.0)
        XCTAssertFalse(normal.isDSTTransitionDay())
    }

    func testInvalidDateCannotCreateContext() {
        XCTAssertNil(TinyBuddyTimeContext(
            now: Date(timeIntervalSinceReferenceDate: .infinity),
            timeZone: utc,
            locale: Locale(identifier: "en_US_POSIX"),
            sourceCalendar: Calendar(identifier: .gregorian)
        ))
    }

    func testCalendarDateProviderAdapterAndFixedEnvironmentCaptureContexts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = makeDate(year: 2026, month: 7, day: 1, hour: 12, minute: 0, timeZone: utc)

        XCTAssertEqual(
            try XCTUnwrap(TinyBuddyTimeEnvironment(calendar: calendar, dateProvider: { date }).capture()).dayIdentifier,
            "2026-07-01"
        )
        XCTAssertEqual(
            try XCTUnwrap(TinyBuddyTimeEnvironment.fixed(now: date, timeZone: utc).capture()).dayIdentifier,
            "2026-07-01"
        )
    }

    private var utc: TimeZone {
        TimeZone(secondsFromGMT: 0)!
    }

    private func makeContext(now: Date, timeZone: TimeZone) -> TinyBuddyTimeContext? {
        TinyBuddyTimeContext(
            now: now,
            timeZone: timeZone,
            locale: Locale(identifier: "en_US_POSIX"),
            sourceCalendar: Calendar(identifier: .gregorian)
        )
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }
}