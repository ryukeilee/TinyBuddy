import XCTest
@testable import TinyBuddyCore

final class GitTodayActivityStoreTests: XCTestCase {
    func testSharedPreferencesDictionaryMatchesStoreReadSemantics() throws {
        guard let preferences = TinyBuddySharedData.loadAppGroupPreferencesDictionary() else {
            throw XCTSkip("App Group shared preferences plist is unavailable in this environment")
        }

        guard let dayIdentifier = preferences[GitTodayFocusBlockCountStore.Key.dayIdentifier] as? String,
              let today = makeDate(dayIdentifier: dayIdentifier) else {
            XCTFail("Expected a valid focus-block day identifier in shared preferences")
            return
        }

        XCTAssertEqual(
            preferences[GitTodayCommitCountStore.Key.dayIdentifier] as? String,
            dayIdentifier
        )

        if let recentProjectDayIdentifier = preferences[GitTodayRecentProjectStore.Key.dayIdentifier] as? String {
            XCTAssertEqual(recentProjectDayIdentifier, dayIdentifier)
        }

        let expectedFocusCount = normalizedInteger(
            preferences[GitTodayFocusBlockCountStore.Key.count]
        )
        let expectedCommitCount = normalizedInteger(
            preferences[GitTodayCommitCountStore.Key.count]
        )
        let expectedRecentProjectName = normalizedProjectName(
            preferences[GitTodayRecentProjectStore.Key.projectName]
        )

        XCTAssertNotNil(expectedFocusCount)
        XCTAssertNotNil(expectedCommitCount)

        let isolatedDefaults = makeDefaults()
        let calendar = makeCalendar()
        let store = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: isolatedDefaults,
                calendar: calendar,
                dateProvider: { today }
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: isolatedDefaults,
                calendar: calendar,
                dateProvider: { today }
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: isolatedDefaults,
                calendar: calendar,
                dateProvider: { today }
            )
        )

        XCTAssertEqual(
            store.loadTodaySnapshot(),
            GitTodayActivitySnapshot(
                focusBlockCount: expectedFocusCount,
                commitCount: expectedCommitCount,
                recentProjectName: expectedRecentProjectName
            )
        )
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

    func testRefreshPolicyOnlyReloadsWhenGitActivityActuallyChanged() {
        XCTAssertFalse(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .launch, didChange: false)
        )
        XCTAssertFalse(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .becameActive, didChange: false)
        )
        XCTAssertFalse(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .reopen, didChange: false)
        )
        XCTAssertFalse(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .didWake, didChange: false)
        )
        XCTAssertFalse(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .screensDidWake, didChange: false)
        )
        XCTAssertFalse(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .sessionDidBecomeActive, didChange: false)
        )
        XCTAssertFalse(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .timer, didChange: false)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .launch, didChange: true)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .becameActive, didChange: true)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .reopen, didChange: true)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .didWake, didChange: true)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .screensDidWake, didChange: true)
        )
        XCTAssertTrue(
            GitTodayActivityRefreshPolicy.shouldReloadWidget(for: .sessionDidBecomeActive, didChange: true)
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

    private func makeDate(dayIdentifier: String) -> Date? {
        let parts = dayIdentifier.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        return makeDate(year: year, month: month, day: day)
    }

    private func normalizedInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return max(0, number.intValue)
        }

        if let integer = value as? Int {
            return max(0, integer)
        }

        return nil
    }

    private func normalizedProjectName(_ value: Any?) -> String? {
        guard let projectName = value as? String else {
            return nil
        }

        let trimmedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProjectName.isEmpty else {
            return nil
        }

        return trimmedProjectName
    }
}
