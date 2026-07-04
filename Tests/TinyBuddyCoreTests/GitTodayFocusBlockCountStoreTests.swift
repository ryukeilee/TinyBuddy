import XCTest
@testable import TinyBuddyCore

final class GitTodayFocusBlockCountStoreTests: XCTestCase {
    func testLoadsSavedCountForToday() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let date = makeDate(year: 2026, month: 7, day: 2)
        let store = GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { date },
            sharedFallbacksEnabled: false
        )

        XCTAssertNil(store.loadTodayCount())

        store.saveTodayCount(5)

        XCTAssertEqual(store.loadTodayCount(), 5)
    }

    func testIgnoresStaleCountAndNormalizesNegativeValues() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 2)
        let store = GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate },
            sharedFallbacksEnabled: false
        )

        store.saveTodayCount(-7)
        XCTAssertEqual(store.loadTodayCount(), 0)

        currentDate = makeDate(year: 2026, month: 7, day: 3)

        XCTAssertNil(store.loadTodayCount())
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitTodayFocusBlockCountTests.\(UUID().uuidString)"
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
