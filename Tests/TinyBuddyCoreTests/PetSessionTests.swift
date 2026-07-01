import XCTest
@testable import TinyBuddyCore

final class PetSessionTests: XCTestCase {
    func testSelectingStatesUpdatesStatusAndDailyCounts() {
        let defaults = makeDefaults()
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: makeCalendar(),
            dateProvider: { self.makeDate(year: 2026, month: 7, day: 1) }
        )
        let session = PetSession(store: store)

        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.stats.focusCount, 0)
        XCTAssertEqual(session.stats.completionCount, 0)

        session.select(.focusing)
        XCTAssertEqual(session.status, .focusing)
        XCTAssertEqual(session.stats.focusCount, 1)
        XCTAssertEqual(session.stats.completionCount, 0)

        session.select(.completedOnce)
        XCTAssertEqual(session.status, .completedOnce)
        XCTAssertEqual(session.stats.focusCount, 1)
        XCTAssertEqual(session.stats.completionCount, 1)

        session.select(.idle)
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.stats.focusCount, 1)
        XCTAssertEqual(session.stats.completionCount, 1)

        let reloadedSession = PetSession(store: store)
        XCTAssertEqual(reloadedSession.status, .idle)
        XCTAssertEqual(reloadedSession.stats.focusCount, 1)
        XCTAssertEqual(reloadedSession.stats.completionCount, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddySessionTests.\(UUID().uuidString)"
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
