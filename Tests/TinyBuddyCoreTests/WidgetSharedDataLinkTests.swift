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
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(3)
        GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(4)
        GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayProjectName("TinyBuddy")

        let widgetStore = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let activityStore = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            )
        )
        let widgetSnapshot = widgetStore.loadSnapshot()
        let activitySnapshot = activityStore.loadTodaySnapshot()
        let smallPresentation = TinyBuddyWidgetPresentation(
            snapshot: widgetSnapshot,
            activitySnapshot: activitySnapshot
        )
        let mediumPresentation = TinyBuddyWidgetPresentation(
            snapshot: widgetSnapshot,
            activitySnapshot: activitySnapshot
        )

        XCTAssertEqual(widgetSnapshot.status, .completedOnce)
        XCTAssertEqual(widgetSnapshot.stats.focusCount, 2)
        XCTAssertEqual(widgetSnapshot.stats.completionCount, 1)
        XCTAssertEqual(smallPresentation.expression, "★ᴗ★")
        XCTAssertEqual(smallPresentation.statusTitle, "活跃")
        XCTAssertEqual(smallPresentation.focusCount, 3)
        XCTAssertEqual(smallPresentation.completionCount, 4)
        XCTAssertEqual(smallPresentation.statusDisplayTitle, "活跃 · TinyBuddy")
        XCTAssertEqual(mediumPresentation.focusCount, 3)
        XCTAssertEqual(mediumPresentation.completionCount, 4)
        XCTAssertEqual(mediumPresentation.statusTitle, "活跃")
        XCTAssertEqual(mediumPresentation.statusDisplayTitle, "活跃 · TinyBuddy")
    }

    func testUnifiedWidgetPresentationDoesNotFallBackToSnapshotStatsForSmallFamily() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )
        let activitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: 8,
            commitCount: 13,
            recentProjectName: "TinyBuddy"
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )

        XCTAssertEqual(presentation.focusCount, 8)
        XCTAssertEqual(presentation.completionCount, 13)
        XCTAssertEqual(presentation.statusTitle, "活跃")
        XCTAssertEqual(presentation.statusDisplayTitle, "活跃 · TinyBuddy")
    }

    func testUnifiedWidgetPresentationUsesZeroWhenGitActivityCountsAreUnavailable() {
        let snapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )
        let activitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: nil,
            commitCount: nil,
            recentProjectName: nil
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )

        XCTAssertEqual(presentation.focusCount, 0)
        XCTAssertEqual(presentation.completionCount, 0)
        XCTAssertEqual(presentation.statusTitle, "待机")
        XCTAssertEqual(presentation.statusDisplayTitle, "待机")
        XCTAssertEqual(presentation.displayState, .idle)
        XCTAssertEqual(presentation.expression, "•ᴗ•")
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

    func testWidgetPresentationAppendsRecentProjectNameForFocusingStatus() {
        let snapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 1, completionCount: 0)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 3,
            completionCountOverride: 0,
            recentProjectName: "TinyBuddy",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.statusTitle, "专注中")
        XCTAssertEqual(presentation.statusDisplayTitle, "专注中 · TinyBuddy")
    }

    func testWidgetPresentationAppendsRecentProjectNameForCompletedStatus() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 0,
            completionCountOverride: 2,
            recentProjectName: "TinyBuddy",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.statusTitle, "已完成")
        XCTAssertEqual(presentation.statusDisplayTitle, "已完成 · TinyBuddy")
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

    func testWidgetPresentationUpdatesRecentProjectNameWhenTodayActiveProjectChanges() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 1)
        let recentProjectStore = GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        )
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        recentProjectStore.saveTodayProjectName("Project A")
        let firstPresentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 3,
            completionCountOverride: 1,
            recentProjectName: recentProjectStore.loadTodayProjectName(),
            statusTitleSource: .gitTodayActivity
        )

        recentProjectStore.saveTodayProjectName("Project B")
        let updatedPresentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 3,
            completionCountOverride: 1,
            recentProjectName: recentProjectStore.loadTodayProjectName(),
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(firstPresentation.statusDisplayTitle, "活跃 · Project A")
        XCTAssertEqual(updatedPresentation.statusDisplayTitle, "活跃 · Project B")
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
