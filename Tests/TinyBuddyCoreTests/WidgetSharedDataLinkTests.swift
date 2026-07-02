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
        GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        ).saveTodayCount(3)
        GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        ).saveTodayCount(4)
        GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        ).saveTodayProjectName("TinyBuddy")

        let widgetStore = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let widgetSnapshot = widgetStore.loadSnapshot()
        let smallPresentation = TinyBuddyWidgetPresentation(snapshot: widgetSnapshot)
        let mediumPresentation = TinyBuddyWidgetPresentation(
            snapshot: widgetSnapshot,
            focusCountOverride: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today }
            ).loadTodayCount(),
            completionCountOverride: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today }
            ).loadTodayCount(),
            recentProjectName: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today }
            ).loadTodayProjectName(),
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(widgetSnapshot.status, .completedOnce)
        XCTAssertEqual(widgetSnapshot.stats.focusCount, 2)
        XCTAssertEqual(widgetSnapshot.stats.completionCount, 1)
        XCTAssertEqual(smallPresentation.expression, "★ᴗ★")
        XCTAssertEqual(smallPresentation.statusTitle, "完成一次")
        XCTAssertEqual(smallPresentation.focusCount, 2)
        XCTAssertEqual(smallPresentation.completionCount, 1)
        XCTAssertEqual(mediumPresentation.focusCount, 3)
        XCTAssertEqual(mediumPresentation.completionCount, 4)
        XCTAssertEqual(mediumPresentation.statusTitle, "活跃")
        XCTAssertEqual(mediumPresentation.statusDisplayTitle, "活跃 · TinyBuddy")
    }

    func testWidgetPresentationCanOverrideFocusAndCompletionCountWithGitCounts() {
        let snapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 6,
            completionCountOverride: 9,
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.focusCount, 6)
        XCTAssertEqual(presentation.completionCount, 9)
        XCTAssertEqual(presentation.statusTitle, "活跃")
    }

    func testWidgetPresentationUsesZeroWhenGitCountsAreUnavailable() {
        let snapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )
        let gitTodayFocusBlockCount: Int? = nil
        let gitTodayCommitCount: Int? = nil

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: gitTodayFocusBlockCount ?? 0,
            completionCountOverride: gitTodayCommitCount ?? 0,
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.focusCount, 0)
        XCTAssertEqual(presentation.completionCount, 0)
        XCTAssertEqual(presentation.statusTitle, "待机")
    }

    func testWidgetPresentationDefaultsToSnapshotStatusTitle() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 6,
            completionCountOverride: 9
        )

        XCTAssertEqual(presentation.statusTitle, "完成一次")
    }

    func testWidgetPresentationMapsGitTodayActivityStatusTitle() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        XCTAssertEqual(
            makeGitActivityPresentation(snapshot: snapshot, focusCount: 0, completionCount: 0).statusTitle,
            "待机"
        )
        XCTAssertEqual(
            makeGitActivityPresentation(snapshot: snapshot, focusCount: 3, completionCount: 0).statusTitle,
            "专注中"
        )
        XCTAssertEqual(
            makeGitActivityPresentation(snapshot: snapshot, focusCount: 0, completionCount: 4).statusTitle,
            "已完成"
        )
        XCTAssertEqual(
            makeGitActivityPresentation(snapshot: snapshot, focusCount: 5, completionCount: 6).statusTitle,
            "活跃"
        )
    }

    func testWidgetPresentationAppendsRecentProjectNameToStatusDisplayTitle() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 5,
            completionCountOverride: 6,
            recentProjectName: "TinyBuddy",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.statusTitle, "活跃")
        XCTAssertEqual(presentation.statusDisplayTitle, "活跃 · TinyBuddy")
    }

    func testWidgetPresentationKeepsOriginalStatusDisplayWhenProjectNameIsUnavailable() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 3,
            completionCountOverride: 0,
            recentProjectName: "  ",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.statusTitle, "专注中")
        XCTAssertEqual(presentation.statusDisplayTitle, "专注中")
    }

    private func makeGitActivityPresentation(
        snapshot: TinyBuddySnapshot,
        focusCount: Int,
        completionCount: Int
    ) -> TinyBuddyWidgetPresentation {
        TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: focusCount,
            completionCountOverride: completionCount,
            statusTitleSource: .gitTodayActivity
        )
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
