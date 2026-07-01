import XCTest
@testable import TinyBuddyCore

final class WidgetSharedDataLinkTests: XCTestCase {
    func testWidgetReadsAndPresentsStateWrittenByMainAppSession() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 1)

        let appStore = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let appSession = PetSession(store: appStore)

        appSession.select(.focusing)
        appSession.select(.focusing)
        appSession.select(.completedOnce)

        let widgetStore = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let widgetSnapshot = widgetStore.loadSnapshot()
        let presentation = TinyBuddyWidgetPresentation(snapshot: widgetSnapshot)

        XCTAssertEqual(widgetSnapshot.status, .completedOnce)
        XCTAssertEqual(widgetSnapshot.stats.focusCount, 2)
        XCTAssertEqual(widgetSnapshot.stats.completionCount, 1)
        XCTAssertEqual(presentation.expression, "★ᴗ★")
        XCTAssertEqual(presentation.statusTitle, "完成一次")
        XCTAssertEqual(presentation.focusCount, 2)
        XCTAssertEqual(presentation.completionCount, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyWidgetLinkTests.\(UUID().uuidString)"
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

