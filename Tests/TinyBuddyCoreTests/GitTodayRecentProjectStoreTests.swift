import XCTest
@testable import TinyBuddyCore

final class GitTodayRecentProjectStoreTests: XCTestCase {
    func testLoadsSavedProjectNameForToday() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let date = makeDate(year: 2026, month: 7, day: 2)
        let store = GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { date },
            sharedFallbacksEnabled: false
        )

        XCTAssertNil(store.loadTodayProjectName())

        store.saveTodayProjectName("TinyBuddy")

        XCTAssertEqual(store.loadTodayProjectName(), "TinyBuddy")
    }

    func testIgnoresStaleProjectNameAndNormalizesEmptyValues() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 2)
        let store = GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate },
            sharedFallbacksEnabled: false
        )

        store.saveTodayProjectName("  \n  ")
        XCTAssertNil(store.loadTodayProjectName())

        store.saveTodayProjectName("  TinyBuddy  ")
        XCTAssertEqual(store.loadTodayProjectName(), "TinyBuddy")

        currentDate = makeDate(year: 2026, month: 7, day: 3)

        XCTAssertNil(store.loadTodayProjectName())
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitTodayRecentProjectTests.\(UUID().uuidString)"
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
