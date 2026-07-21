import XCTest
@testable import TinyBuddyCore

final class TinyBuddyAppGroupPreferencesStoreTests: XCTestCase {
    func testAdapterUsesCurrentUserAnyHostSuiteDomainForEveryOperation() {
        var observedDomains: [TinyBuddyAppGroupPreferencesStore.Domain] = []
        let store = TinyBuddyAppGroupPreferencesStore(
            applicationIdentifier: "group.example.TinyBuddy",
            loadValues: { domain, _ in
                observedDomains.append(domain)
                return [:]
            },
            setValue: { domain, _, _ in
                observedDomains.append(domain)
            },
            synchronize: { domain in
                observedDomains.append(domain)
                return true
            }
        )

        _ = store.loadDictionary()
        XCTAssertTrue(store.writeValue("value", forKey: "key"))
        XCTAssertTrue(store.synchronize())

        let expectedDomain = TinyBuddyAppGroupPreferencesStore.Domain(
            applicationIdentifier: "group.example.TinyBuddy",
            userScope: .currentUser,
            hostScope: .anyHost
        )
        XCTAssertEqual(store.domain, expectedDomain)
        XCTAssertEqual(observedDomains, [expectedDomain, expectedDomain, expectedDomain])
    }

    func testExactDomainPublishesTodaySnapshotAfterYesterdayLegacyState() throws {
        let preferences = PreferencesValues()
        let yesterday = TinyBuddyCombinedSnapshot(
            revision: 86,
            dayIdentifier: "2026-07-13",
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-13",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 1,
                commitCount: 2,
                recentProjectName: "Yesterday"
            ),
            activityRevision: 1_783_887_950
        )
        preferences.values[TinyBuddyCombinedSnapshotStore.Key.snapshot] = TinyBuddyCombinedSnapshotStore.encode(yesterday)
        preferences.values[TinyBuddyCombinedSnapshotStore.Key.highestRevision] = yesterday.revision
        let preferencesStore = makePreferencesStore(values: preferences)
        let appStore = TinyBuddyCombinedSnapshotStore(
            preferencesStore: preferencesStore,
            sharedPreferencesProvider: { nil }
        )
        let todaySnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(
                dayIdentifier: "2026-07-14",
                focusCount: 0,
                completionCount: 0
            )
        )
        let todayActivity = GitTodayActivitySnapshot(
            focusBlockCount: 5,
            commitCount: 8,
            recentProjectName: "DevPulse"
        )

        let update = appStore.updateActivitySlice(
            todayActivity,
            activityRevision: 1_784_015_234,
            fallbackSnapshot: todaySnapshot
        )

        XCTAssertEqual(update.outcome, .saved)
        XCTAssertTrue(update.didPersist)
        let committed = try XCTUnwrap(update.snapshot)
        XCTAssertEqual(committed.revision, 87)
        XCTAssertEqual(committed.dayIdentifier, "2026-07-14")
        XCTAssertEqual(committed.activitySnapshot, todayActivity)
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decodeRevisionMarker(
                try XCTUnwrap(preferences.values[TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2] as? String)
            ),
            committed.revision
        )

        let widgetStore = TinyBuddyCombinedSnapshotStore(
            preferencesStore: preferencesStore,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertEqual(widgetStore.loadReadOnly(), committed)
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decode(
                try XCTUnwrap(preferences.values[TinyBuddyCombinedSnapshotStore.Key.snapshot] as? String)
            ),
            committed
        )
    }

    func testSetWithoutExactDomainReadbackFailsClosed() {
        let preferencesStore = TinyBuddyAppGroupPreferencesStore(
            applicationIdentifier: "group.example.TinyBuddy",
            loadValues: { _, _ in [:] },
            setValue: { _, _, _ in },
            synchronize: { _ in true }
        )
        let store = TinyBuddyCombinedSnapshotStore(
            preferencesStore: preferencesStore,
            sharedPreferencesProvider: { nil }
        )

        let update = store.updateActivitySlice(
            GitTodayActivitySnapshot(
                focusBlockCount: 5,
                commitCount: 8,
                recentProjectName: "DevPulse"
            ),
            activityRevision: 1_784_015_234,
            fallbackSnapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-14",
                    focusCount: 0,
                    completionCount: 0
                )
            )
        )

        XCTAssertEqual(update.outcome, .persistenceFailed)
        XCTAssertFalse(update.didPersist)
        XCTAssertNil(update.snapshot)
    }

    func testFocusSessionSliceRejectsDelayedOlderRevisionAndKeepsCommittedDurations() throws {
        let preferences = PreferencesValues()
        let store = TinyBuddyCombinedSnapshotStore(
            preferencesStore: makePreferencesStore(values: preferences),
            sharedPreferencesProvider: { nil }
        )
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 99, completionCount: 0)
        )
        let newest = FocusSessionDerivedSnapshot(
            revision: 9,
            dayIdentifier: "2026-07-20",
            focusDuration: 4_200,
            projectDurations: ["Project A": 4_200],
            completedSessionCount: 2
        )
        let older = FocusSessionDerivedSnapshot(
            revision: 8,
            dayIdentifier: "2026-07-20",
            focusDuration: 1_200,
            projectDurations: ["Project B": 1_200],
            completedSessionCount: 1
        )

        let first = store.updateFocusSessionSlice(newest, fallbackSnapshot: fallback)
        XCTAssertEqual(first.outcome, .saved)
        let delayed = store.updateFocusSessionSlice(older, fallbackSnapshot: fallback)
        XCTAssertEqual(delayed.outcome, .alreadyCurrent)
        XCTAssertFalse(delayed.didPersist)
        XCTAssertEqual(delayed.snapshot?.focusSessionSnapshot, newest)
        XCTAssertEqual(delayed.snapshot?.snapshot.stats.focusCount, newest.completedSessionCount)
        XCTAssertEqual(store.loadReadOnly()?.focusSessionSnapshot, newest)
        XCTAssertEqual(store.loadReadOnly()?.snapshot.stats.focusCount, newest.completedSessionCount)

        let activityRefresh = store.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 4, commitCount: 1, recentProjectName: "Project A"),
            activityRevision: 10,
            fallbackSnapshot: TinyBuddySnapshot(
                status: .focusing,
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 0, completionCount: 7)
            )
        )
        XCTAssertEqual(activityRefresh.outcome, .saved)
        XCTAssertEqual(activityRefresh.snapshot?.focusSessionSnapshot, newest)
        XCTAssertEqual(activityRefresh.snapshot?.snapshot.stats.focusCount, newest.completedSessionCount)
        XCTAssertEqual(activityRefresh.snapshot?.snapshot.stats.completionCount, 0)
    }

    private func makePreferencesStore(
        values: PreferencesValues
    ) -> TinyBuddyAppGroupPreferencesStore {
        TinyBuddyAppGroupPreferencesStore(
            applicationIdentifier: "group.example.TinyBuddy",
            loadValues: { _, keys in
                var result: [String: Any] = [:]
                for key in keys {
                    result[key] = values.values[key]
                }
                return result
            },
            setValue: { _, key, value in
                values.values[key] = value
            },
            synchronize: { _ in true }
        )
    }

    private final class PreferencesValues {
        var values: [String: Any] = [:]
    }
}
