import XCTest
@testable import TinyBuddyCore

final class GitTodayActivityStoreTests: XCTestCase {
    func testAppAndWidgetReadersUseSameAtomicTrustedSnapshot() {
        let defaults = makeDefaults()
        let trustedStore = GitTodayActivityTrustedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let expected = GitTodayActivityTrustedSnapshot(
            revision: 200,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(
                focusBlockCount: 7,
                commitCount: 11,
                recentProjectName: "TinyBuddy"
            )
        )
        XCTAssertTrue(trustedStore.save(expected))

        let appStore = makeActivityStore(defaults: defaults)
        let widgetStore = makeActivityStore(defaults: defaults)

        XCTAssertEqual(appStore.loadTodaySnapshot(), expected.activity)
        XCTAssertEqual(widgetStore.loadTodaySnapshot(), expected.activity)
    }

    func testOlderTrustedSnapshotCannotOverwriteNewerSnapshot() {
        let defaults = makeDefaults()
        let store = GitTodayActivityTrustedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let newer = GitTodayActivityTrustedSnapshot(
            revision: 300,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13, recentProjectName: "New")
        )
        let older = GitTodayActivityTrustedSnapshot(
            revision: 200,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "Old")
        )

        XCTAssertTrue(store.save(newer))
        XCTAssertFalse(store.save(older))
        XCTAssertEqual(store.load(), newer)
    }

    func testConflictingSnapshotWithSameRevisionCannotOverwriteCurrentSnapshot() {
        let defaults = makeDefaults()
        let store = GitTodayActivityTrustedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let current = GitTodayActivityTrustedSnapshot(
            revision: 300,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13, recentProjectName: "Current")
        )
        let conflicting = GitTodayActivityTrustedSnapshot(
            revision: 300,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "Conflicting")
        )

        XCTAssertTrue(store.save(current))
        XCTAssertFalse(store.save(conflicting))
        XCTAssertEqual(store.load(), current)
    }

    func testProductionReadersIgnoreDifferentPrivateFallbackSnapshots() {
        let sharedDefaults = makeDefaults()
        let appPrivateDefaults = makeDefaults()
        let widgetPrivateDefaults = makeDefaults()
        let shared = GitTodayActivityTrustedSnapshot(
            revision: 100,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 5, commitCount: 8, recentProjectName: "Shared")
        )
        let appPrivate = GitTodayActivityTrustedSnapshot(
            revision: 900,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 90, commitCount: 90, recentProjectName: "App Private")
        )
        let widgetPrivate = GitTodayActivityTrustedSnapshot(
            revision: 800,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 80, commitCount: 80, recentProjectName: "Widget Private")
        )
        sharedDefaults.set(
            GitTodayActivityTrustedSnapshotStore.encode(shared),
            forKey: GitTodayActivityTrustedSnapshotStore.Key.snapshot
        )
        appPrivateDefaults.set(
            GitTodayActivityTrustedSnapshotStore.encode(appPrivate),
            forKey: GitTodayActivityTrustedSnapshotStore.Key.snapshot
        )
        widgetPrivateDefaults.set(
            GitTodayActivityTrustedSnapshotStore.encode(widgetPrivate),
            forKey: GitTodayActivityTrustedSnapshotStore.Key.snapshot
        )

        let appReader = GitTodayActivityTrustedSnapshotStore(
            userDefaults: sharedDefaults,
            sharedPreferencesProvider: { nil }
        )
        let widgetReader = GitTodayActivityTrustedSnapshotStore(
            userDefaults: sharedDefaults,
            sharedPreferencesProvider: { nil }
        )

        XCTAssertEqual(appReader.load(), shared)
        XCTAssertEqual(widgetReader.load(), shared)
        XCTAssertEqual(
            GitTodayActivityTrustedSnapshotStore(
                userDefaults: sharedDefaults,
                sharedPreferencesProvider: { nil },
                fallbackDefaults: appPrivateDefaults
            ).load(),
            appPrivate
        )
        XCTAssertEqual(
            GitTodayActivityTrustedSnapshotStore(
                userDefaults: sharedDefaults,
                sharedPreferencesProvider: { nil },
                fallbackDefaults: widgetPrivateDefaults
            ).load(),
            widgetPrivate
        )
    }

    func testReaderChoosesNewestTrustedSnapshotAcrossCachedAndDirectSources() {
        let defaults = makeDefaults()
        let cached = GitTodayActivityTrustedSnapshot(
            revision: 100,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 1, recentProjectName: "Cached")
        )
        let direct = GitTodayActivityTrustedSnapshot(
            revision: 200,
            dayIdentifier: todayIdentifier(),
            activity: GitTodayActivitySnapshot(focusBlockCount: 2, commitCount: 3, recentProjectName: "Direct")
        )
        defaults.set(GitTodayActivityTrustedSnapshotStore.encode(cached), forKey: GitTodayActivityTrustedSnapshotStore.Key.snapshot)
        let store = GitTodayActivityTrustedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: {
                [GitTodayActivityTrustedSnapshotStore.Key.snapshot: GitTodayActivityTrustedSnapshotStore.encode(direct)]
            },
            fallbackDefaults: nil
        )

        XCTAssertEqual(store.load(), direct)
    }

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

    func testTrustedSnapshotUsesInjectedDayAndRestoresAfterCrossingMidnight() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 2)
        let trustedStore = GitTodayActivityTrustedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let activityStore = GitTodayActivityStore(
            trustedSnapshotStore: trustedStore,
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { currentDate },
                sharedFallbacksEnabled: false
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { currentDate },
                sharedFallbacksEnabled: false
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { currentDate },
                sharedFallbacksEnabled: false
            ),
            calendar: calendar,
            dateProvider: { currentDate }
        )

        XCTAssertTrue(trustedStore.save(GitTodayActivityTrustedSnapshot(
            revision: 1,
            dayIdentifier: "2026-07-02",
            activity: GitTodayActivitySnapshot(focusBlockCount: 7, commitCount: 11, recentProjectName: "TinyBuddy")
        )))
        XCTAssertEqual(
            activityStore.loadTodaySnapshot(),
            GitTodayActivitySnapshot(focusBlockCount: 7, commitCount: 11, recentProjectName: "TinyBuddy")
        )

        currentDate = makeDate(year: 2026, month: 7, day: 3)
        XCTAssertEqual(
            activityStore.loadTodaySnapshot(),
            GitTodayActivitySnapshot(focusBlockCount: nil, commitCount: nil, recentProjectName: nil)
        )

        XCTAssertTrue(trustedStore.save(GitTodayActivityTrustedSnapshot(
            revision: 2,
            dayIdentifier: "2026-07-03",
            activity: GitTodayActivitySnapshot(focusBlockCount: 2, commitCount: 3, recentProjectName: "TinyBuddyCore")
        )))
        XCTAssertEqual(
            activityStore.loadTodaySnapshot(),
            GitTodayActivitySnapshot(focusBlockCount: 2, commitCount: 3, recentProjectName: "TinyBuddyCore")
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

    private func makeActivityStore(defaults: UserDefaults) -> GitTodayActivityStore {
        GitTodayActivityStore(
            trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil },
                fallbackDefaults: nil
            ),
            focusBlockCountStore: GitTodayFocusBlockCountStore(userDefaults: defaults, sharedFallbacksEnabled: false),
            commitCountStore: GitTodayCommitCountStore(userDefaults: defaults, sharedFallbacksEnabled: false),
            recentProjectStore: GitTodayRecentProjectStore(userDefaults: defaults, sharedFallbacksEnabled: false)
        )
    }

    private func todayIdentifier() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
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
