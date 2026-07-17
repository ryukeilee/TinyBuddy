import XCTest
@testable import TinyBuddyCore

final class TimeReliabilityStoreTests: XCTestCase {
    func testMidnightAdvancesOnceAndClockRollbackPreservesNewestValidStats() {
        let defaults = makeDefaults()
        var now = makeDate(year: 2026, month: 7, day: 1, hour: 23, minute: 59)
        let environment = makeEnvironment(now: { now })
        let store = DailyStatsStore(userDefaults: defaults, timeEnvironment: environment)

        XCTAssertEqual(store.recordFocusStarted().focusCount, 1)
        XCTAssertEqual(store.recordCompletion().completionCount, 1)

        now = makeDate(year: 2026, month: 7, day: 2, hour: 0, minute: 0)
        XCTAssertEqual(
            store.loadToday(),
            DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0)
        )
        XCTAssertEqual(store.recordFocusStarted().focusCount, 1)

        now = makeDate(year: 2026, month: 7, day: 1, hour: 22, minute: 0)
        XCTAssertEqual(
            store.loadToday(),
            DailyStats(dayIdentifier: "2026-07-02", focusCount: 1, completionCount: 0)
        )
        XCTAssertEqual(store.recordCompletion().completionCount, 0)

        now = makeDate(year: 2026, month: 7, day: 2, hour: 0, minute: 1)
        XCTAssertEqual(store.loadToday().focusCount, 1)
    }

    func testWestwardTimeZoneChangeDoesNotPersistDateRollback() throws {
        let defaults = makeDefaults()
        let instant = makeDate(year: 2026, month: 7, day: 2, hour: 1, minute: 0)
        var timeZone = utc
        let environment = TinyBuddyTimeEnvironment(capture: {
            self.makeContext(now: instant, timeZone: timeZone)
        })
        let store = DailyStatsStore(userDefaults: defaults, timeEnvironment: environment)

        XCTAssertEqual(store.recordCompletion().dayIdentifier, "2026-07-02")
        timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        XCTAssertEqual(
            store.loadToday(),
            DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 1)
        )
        XCTAssertEqual(defaults.string(forKey: "tinybuddy.dailyStats.dayIdentifier"), "2026-07-02")
    }

    func testTrustedSnapshotFiltersDayBeforeChoosingHighestRevision() throws {
        let direct = makeDefaults()
        let today = trustedSnapshot(revision: 10, day: "2026-07-02", commits: 4)
        let future = trustedSnapshot(revision: 999, day: "2026-07-03", commits: 99)
        direct.set(
            GitTodayActivityTrustedSnapshotStore.encode(future),
            forKey: GitTodayActivityTrustedSnapshotStore.Key.snapshot
        )
        let store = GitTodayActivityTrustedSnapshotStore(
            userDefaults: direct,
            sharedPreferencesProvider: {
                [GitTodayActivityTrustedSnapshotStore.Key.snapshot:
                    GitTodayActivityTrustedSnapshotStore.encode(today)]
            }
        )

        let loaded = try XCTUnwrap(store.load(dayIdentifier: "2026-07-02"))
        XCTAssertEqual(loaded.revision, 10)
        XCTAssertEqual(loaded.activity.commitCount, 4)
    }

    func testTrustedSnapshotFiltersTimeScopeBeforeChoosingHighestRevision() throws {
        let direct = makeDefaults()
        let expectedScope = "scope-current"
        let staleScope = GitTodayActivityTrustedSnapshot(
            revision: 999,
            dayIdentifier: "2026-07-02",
            timeScopeIdentifier: "scope-stale",
            timeScopeToken: "old-token",
            activity: GitTodayActivitySnapshot(focusBlockCount: 99, commitCount: 99)
        )
        let currentScope = GitTodayActivityTrustedSnapshot(
            revision: 10,
            dayIdentifier: "2026-07-02",
            timeScopeIdentifier: expectedScope,
            timeScopeToken: "current-token",
            activity: GitTodayActivitySnapshot(focusBlockCount: 4, commitCount: 4)
        )
        direct.set(
            GitTodayActivityTrustedSnapshotStore.encode(staleScope),
            forKey: GitTodayActivityTrustedSnapshotStore.Key.snapshot
        )
        let store = GitTodayActivityTrustedSnapshotStore(
            userDefaults: direct,
            sharedPreferencesProvider: {
                [GitTodayActivityTrustedSnapshotStore.Key.snapshot:
                    GitTodayActivityTrustedSnapshotStore.encode(currentScope)]
            }
        )

        let loaded = try XCTUnwrap(store.load(
            dayIdentifier: "2026-07-02",
            timeScopeIdentifier: expectedScope,
            timeScopeToken: "current-token"
        ))
        XCTAssertEqual(loaded.revision, 10)
        XCTAssertEqual(loaded.timeScopeIdentifier, expectedScope)
        XCTAssertEqual(loaded.activity.commitCount, 4)
    }

    func testStaleScopeTokenCannotFallBackToSameDayDirectValues() throws {
        let defaults = makeDefaults()
        let now = makeDate(year: 2026, month: 7, day: 2, hour: 12, minute: 0)
        let environment = makeEnvironment(now: { now })
        let context = try XCTUnwrap(environment.capture())
        let focusStore = GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            timeEnvironment: environment,
            sharedFallbacksEnabled: false
        )
        let commitStore = GitTodayCommitCountStore(
            userDefaults: defaults,
            timeEnvironment: environment,
            sharedFallbacksEnabled: false
        )
        let recentStore = GitTodayRecentProjectStore(
            userDefaults: defaults,
            timeEnvironment: environment,
            sharedFallbacksEnabled: false
        )
        focusStore.saveTodayCount(99)
        commitStore.saveTodayCount(99)
        recentStore.saveTodayProjectName("Stale")
        defaults.set(
            GitTodayActivityTrustedSnapshotStore.encode(
                GitTodayActivityTrustedSnapshot(
                    revision: 7,
                    dayIdentifier: context.dayIdentifier,
                    timeScopeIdentifier: context.signature.portableScopeIdentifier,
                    timeScopeToken: "old-token",
                    activity: GitTodayActivitySnapshot(
                        focusBlockCount: 99,
                        commitCount: 99,
                        recentProjectName: "Stale"
                    )
                )
            ),
            forKey: GitTodayActivityTrustedSnapshotStore.Key.snapshot
        )
        TinyBuddyTimeScopeState.shared.replaceProcessToken("new-token")
        let activityStore = GitTodayActivityStore(
            trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil }
            ),
            focusBlockCountStore: focusStore,
            commitCountStore: commitStore,
            recentProjectStore: recentStore,
            timeEnvironment: environment
        )

        let read = activityStore.loadTodaySnapshotRead()
        XCTAssertNil(read.snapshot.focusBlockCount)
        XCTAssertNil(read.snapshot.commitCount)
        XCTAssertNil(read.snapshot.recentProjectName)
        XCTAssertNil(read.trustedRevision)
    }

    func testCombinedSnapshotFiltersDayBeforeChoosingHighestRevision() throws {
        let direct = makeDefaults()
        let today = combinedSnapshot(revision: 10, day: "2026-07-02", commits: 4)
        let future = combinedSnapshot(revision: 999, day: "2026-07-03", commits: 99)
        direct.set(
            TinyBuddyCombinedSnapshotStore.encode(future),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: direct,
            sharedPreferencesProvider: {
                [TinyBuddyCombinedSnapshotStore.Key.snapshot:
                    TinyBuddyCombinedSnapshotStore.encode(today)]
            },
            repairOnLoad: false
        )

        let read = store.readValidated(expectedDayIdentifier: "2026-07-02")
        XCTAssertEqual(try XCTUnwrap(read.snapshot).revision, 10)
        XCTAssertNil(read.observation)
    }

    func testReadOnlyDateFloorRetainsFutureSnapshotDuringRollbackButRejectsPreviousDay() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        let snapshot = combinedSnapshot(revision: 8, day: "2026-07-03", commits: 6)
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(snapshot.revision),
            forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
        )

        XCTAssertEqual(
            store.loadReadOnly(minimumDayIdentifier: "2026-07-02"),
            snapshot
        )
        XCTAssertNil(store.loadReadOnly(minimumDayIdentifier: "2026-07-04"))
        XCTAssertNil(store.loadReadOnly(minimumDayIdentifier: "not-a-day"))
    }

    func testSnapshotCodecsRejectMalformedAndImpossibleDays() {
        let trusted = GitTodayActivityTrustedSnapshot(
            revision: 1,
            dayIdentifier: "2026-02-30",
            activity: GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 1)
        )
        XCTAssertNil(
            GitTodayActivityTrustedSnapshotStore.decode(
                GitTodayActivityTrustedSnapshotStore.encode(trusted)
            )
        )

        let invalidCombined = combinedSnapshot(revision: 1, day: "2026-2-3", commits: 1)
        XCTAssertNil(
            TinyBuddyCombinedSnapshotStore.decode(
                TinyBuddyCombinedSnapshotStore.encode(invalidCombined)
            )
        )
    }

    private func trustedSnapshot(
        revision: Int64,
        day: String,
        commits: Int
    ) -> GitTodayActivityTrustedSnapshot {
        GitTodayActivityTrustedSnapshot(
            revision: revision,
            dayIdentifier: day,
            activity: GitTodayActivitySnapshot(
                focusBlockCount: commits,
                commitCount: commits,
                recentProjectName: "TinyBuddy"
            )
        )
    }

    private func combinedSnapshot(
        revision: Int64,
        day: String,
        commits: Int
    ) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: day,
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: day, focusCount: 1, completionCount: 1)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: commits,
                commitCount: commits,
                recentProjectName: "TinyBuddy"
            )
        )
    }

    private func makeEnvironment(now: @escaping () -> Date) -> TinyBuddyTimeEnvironment {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return TinyBuddyTimeEnvironment(calendar: calendar, dateProvider: now)
    }

    private func makeContext(now: Date, timeZone: TimeZone) -> TinyBuddyTimeContext? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return TinyBuddyTimeContext(
            now: now,
            timeZone: timeZone,
            locale: Locale(identifier: "en_US_POSIX"),
            sourceCalendar: calendar
        )
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: utc,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private var utc: TimeZone {
        TimeZone(secondsFromGMT: 0)!
    }

    private func makeDefaults() -> UserDefaults {
        let name = "TinyBuddyTimeReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
