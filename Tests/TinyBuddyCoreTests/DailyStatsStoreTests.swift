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

    // MARK: - Token-based idempotent record methods

    func testFocusTokenDeduplicatesWithinSameDay() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let date = makeDate(year: 2026, month: 8, day: 15)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { date }
        )

        let token = UUID()
        let first = store.recordFocusStarted(token: token)
        XCTAssertEqual(first.focusCount, 1)

        // Same token: must be a no-op.
        let second = store.recordFocusStarted(token: token)
        XCTAssertEqual(second.focusCount, 1, "Same token must not increment focus count again")

        // Different token: must increment.
        let third = store.recordFocusStarted(token: UUID())
        XCTAssertEqual(third.focusCount, 2, "Different token should increment focus count")
    }

    func testCompletionTokenDeduplicatesWithinSameDay() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let date = makeDate(year: 2026, month: 8, day: 15)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { date }
        )

        let token = UUID()
        let first = store.recordCompletion(token: token)
        XCTAssertEqual(first.completionCount, 1)

        // Same token: must be a no-op.
        let second = store.recordCompletion(token: token)
        XCTAssertEqual(second.completionCount, 1, "Same token must not increment completion count again")

        // Different token: must increment.
        let third = store.recordCompletion(token: UUID())
        XCTAssertEqual(third.completionCount, 2, "Different token should increment completion count")
    }

    func testFocusTokenExpiresOnDayChange() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 8, day: 15)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate }
        )

        let token = UUID()
        _ = store.recordFocusStarted(token: token)
        XCTAssertEqual(store.loadToday().focusCount, 1)

        // Move to next day; same token should NOT deduplicate across days.
        currentDate = makeDate(year: 2026, month: 8, day: 16)
        let nextDay = store.recordFocusStarted(token: token)
        XCTAssertEqual(nextDay.focusCount, 1, "Same token on new day should count as a new event")
    }

    func testNilTokenNeverDeduplicates() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let date = makeDate(year: 2026, month: 8, day: 15)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { date }
        )

        // Without a token, every call increments.
        _ = store.recordFocusStarted()
        _ = store.recordFocusStarted()
        _ = store.recordCompletion()
        _ = store.recordCompletion()

        let stats = store.loadToday()
        XCTAssertEqual(stats.focusCount, 2)
        XCTAssertEqual(stats.completionCount, 2)
    }

    func testCombinedSnapshotStoreUsesTheSameDefaultsAsDailyStats() {
        let defaults = makeDefaults()
        let store = DailyStatsStore(userDefaults: defaults)
        let combinedStore = store.makeCombinedSnapshotStore()
        let petSnapshot = TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
            )
        let activitySnapshot = GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil
            )

        let combinedUpdate = combinedStore.updatePetSlice(
            petSnapshot,
            fallbackActivitySnapshot: activitySnapshot
        )
        let combinedSnapshot = try! XCTUnwrap(combinedUpdate.snapshot)
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot),
            TinyBuddyCombinedSnapshotStore.encode(combinedSnapshot)
        )
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
