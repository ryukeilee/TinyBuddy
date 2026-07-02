import XCTest
@testable import TinyBuddyCore

final class GitTodayActivityStoreTests: XCTestCase {
    func testLoadsSnapshotFromBothStores() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 2)

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

        let store = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today }
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today }
            )
        )

        XCTAssertEqual(
            store.loadTodaySnapshot(),
            GitTodayActivitySnapshot(focusBlockCount: 3, commitCount: 4)
        )
    }

    func testRefreshResultOnlyReportsChangeWhenSnapshotDiffers() {
        let store = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(userDefaults: makeDefaults()),
            commitCountStore: GitTodayCommitCountStore(userDefaults: makeDefaults())
        )

        let previousSnapshot = GitTodayActivitySnapshot(focusBlockCount: 2, commitCount: 5)
        let unchangedSnapshot = GitTodayActivitySnapshot(focusBlockCount: 2, commitCount: 5)
        let changedSnapshot = GitTodayActivitySnapshot(focusBlockCount: 3, commitCount: 5)

        XCTAssertFalse(
            store.makeRefreshResult(
                previousSnapshot: previousSnapshot,
                currentSnapshot: unchangedSnapshot
            ).didChange
        )
        XCTAssertTrue(
            store.makeRefreshResult(
                previousSnapshot: previousSnapshot,
                currentSnapshot: changedSnapshot
            ).didChange
        )
    }

    func testRefreshPolicyAlwaysReloadsForLaunchAndUserVisibleRefreshes() {
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .launch, didChange: false)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .becameActive, didChange: false)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .reopen, didChange: false)
        )
    }

    func testRefreshPolicyOnlyReloadsTimerWhenGitActivityActuallyChanged() {
        XCTAssertFalse(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .timer, didChange: false)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .timer, didChange: true)
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitTodayActivityStoreTests.\(UUID().uuidString)"
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
