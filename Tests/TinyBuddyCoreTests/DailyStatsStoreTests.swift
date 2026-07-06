import XCTest
@testable import TinyBuddyCore

final class DailyStatsStoreTests: XCTestCase {
    func testRecordsFocusAndCompletionCountsForToday() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let date = makeDate(year: 2026, month: 7, day: 1)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { date }
        )

        XCTAssertEqual(store.loadToday(), DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0))

        store.recordFocusStarted()
        store.recordFocusStarted()
        store.recordCompletion()

        let reloadedStore = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { date }
        )
        XCTAssertEqual(reloadedStore.loadToday(), DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1))
    }

    func testResetsCountsWhenTheDayChanges() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 1)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate }
        )

        store.recordFocusStarted()
        store.recordCompletion()

        currentDate = makeDate(year: 2026, month: 7, day: 2)

        XCTAssertEqual(store.loadToday(), DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0))
    }

    func testResetsStatusWhenTheDayChanges() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 1)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate }
        )

        store.saveStatus(.focusing)
        XCTAssertEqual(store.loadStatus(), .focusing)

        currentDate = makeDate(year: 2026, month: 7, day: 2)

        XCTAssertEqual(store.loadStatus(), .idle)
        XCTAssertEqual(store.loadToday(), DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0))
        XCTAssertEqual(store.loadStatus(), .idle)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.calendar = makeCalendar()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return components.date!
    }
}
