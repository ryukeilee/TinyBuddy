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
