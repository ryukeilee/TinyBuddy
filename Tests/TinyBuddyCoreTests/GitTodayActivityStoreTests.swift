import XCTest
@testable import TinyBuddyCore

final class GitTodayActivityStoreTests: XCTestCase {
    func testSharedPreferencesDictionaryReadsAppGroupGitValues() {
        let preferences = TinyBuddySharedData.loadAppGroupPreferencesDictionary()

        XCTAssertEqual(preferences?["tinybuddy.gitTodayFocusBlockCount.dayIdentifier"] as? String, "2026-07-04")
        XCTAssertEqual((preferences?["tinybuddy.gitTodayFocusBlockCount.count"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(preferences?["tinybuddy.gitTodayCommitCount.dayIdentifier"] as? String, "2026-07-04")
        XCTAssertEqual((preferences?["tinybuddy.gitTodayCommitCount.count"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(preferences?["tinybuddy.gitTodayRecentProject.projectName"] as? String, "TinyBuddy")
    }

    func testLoadsSnapshotFromBothStores() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 2)

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

        let store = GitTodayActivityStore(
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

        XCTAssertEqual(
            store.loadTodaySnapshot(),
            GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 4,
                recentProjectName: "TinyBuddy"
            )
        )
    }

    func testRefreshResultOnlyReportsChangeWhenSnapshotDiffers() {
        let store = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(userDefaults: makeDefaults(), sharedFallbacksEnabled: false),
            commitCountStore: GitTodayCommitCountStore(userDefaults: makeDefaults(), sharedFallbacksEnabled: false),
            recentProjectStore: GitTodayRecentProjectStore(userDefaults: makeDefaults(), sharedFallbacksEnabled: false)
        )

        let previousSnapshot = GitTodayActivitySnapshot(
            focusBlockCount: 2,
            commitCount: 5,
            recentProjectName: "TinyBuddy"
        )
        let unchangedSnapshot = GitTodayActivitySnapshot(
            focusBlockCount: 2,
            commitCount: 5,
            recentProjectName: "TinyBuddy"
        )
        let changedSnapshot = GitTodayActivitySnapshot(
            focusBlockCount: 2,
            commitCount: 5,
            recentProjectName: "TinyBuddyCore"
        )

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
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .didWake, didChange: false)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .screensDidWake, didChange: false)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .sessionDidBecomeActive, didChange: false)
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
