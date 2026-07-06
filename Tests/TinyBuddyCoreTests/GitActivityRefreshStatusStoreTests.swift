import XCTest
@testable import TinyBuddyCore

final class GitActivityRefreshStatusStoreTests: XCTestCase {
    func testLoadsSavedRefreshStatus() {
        let defaults = makeDefaults()
        let store = GitActivityRefreshStatusStore(userDefaults: defaults)
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 12, minute: 34, second: 56)

        store.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .timer,
                outcome: .succeeded
            )
        )

        XCTAssertEqual(
            store.load(),
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .timer,
                outcome: .succeeded
            )
        )
    }

    func testSaveTrimsBlankReasonsAndLoadRequiresCompleteRecord() {
        let defaults = makeDefaults()
        let store = GitActivityRefreshStatusStore(userDefaults: defaults)
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)

        store.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .becameActive,
                outcome: .skipped,
                reason: "  \n  "
            )
        )

        XCTAssertEqual(
            store.load(),
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .becameActive,
                outcome: .skipped
            )
        )

        defaults.removeObject(forKey: GitActivityRefreshStatusStore.Key.outcome)
        XCTAssertNil(store.load())
    }

    func testSaveAndLoadMetrics() {
        let defaults = makeDefaults()
        let store = GitActivityRefreshStatusStore(userDefaults: defaults)
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 9, minute: 1, second: 2)

        store.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .succeeded,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 4321,
                    authorizedRootCount: 2,
                    repositoryCount: 7,
                    cacheHitCount: 4,
                    reflogUnchangedSkipCount: 3,
                    recomputedRepositoryCount: 4,
                    sharedDataWritten: true,
                    widgetReloaded: false,
                    reason: "cached refresh"
                )
            )
        )

        XCTAssertEqual(
            store.load(),
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .succeeded,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 4321,
                    authorizedRootCount: 2,
                    repositoryCount: 7,
                    cacheHitCount: 4,
                    reflogUnchangedSkipCount: 3,
                    recomputedRepositoryCount: 4,
                    sharedDataWritten: true,
                    widgetReloaded: false,
                    reason: "cached refresh"
                )
            )
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitActivityRefreshStatusStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}
