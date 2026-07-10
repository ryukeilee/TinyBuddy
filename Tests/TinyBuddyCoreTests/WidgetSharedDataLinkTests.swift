import XCTest
@testable import TinyBuddyCore

final class WidgetSharedDataLinkTests: XCTestCase {
    func testNegativeActivityRevisionIsRejectedWithoutChangingTrustedSnapshot() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })
        let petSnapshot = TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0))
        let trusted = store.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13, recentProjectName: "Trusted"),
            activityRevision: 200,
            fallbackSnapshot: petSnapshot
        )
        let legacy = GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "Invalid")

        let activityResult = store.updateActivitySlice(legacy, activityRevision: -1, fallbackSnapshot: petSnapshot)
        let petResult = store.updatePetSlice(
            petSnapshot,
            fallbackActivitySnapshot: legacy,
            fallbackActivityRevision: -1
        )

        XCTAssertEqual(activityResult.outcome, .rejectedInvalidActivityRevision)
        XCTAssertEqual(petResult.outcome, .rejectedInvalidActivityRevision)
        XCTAssertFalse(activityResult.didPersist)
        XCTAssertFalse(petResult.didPersist)
        XCTAssertEqual(store.load(), trusted.snapshot)
    }

    func testConcurrentCallsKeepTheirOwnUpdateResults() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })
        let petSnapshot = TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0))
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [TinyBuddyCombinedSnapshotStore.UpdateResult] = []

        group.enter()
        DispatchQueue.global().async {
            let result = store.updateActivitySlice(
                GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13),
                activityRevision: 200,
                fallbackSnapshot: petSnapshot
            )
            lock.lock()
            results.append(result)
            lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let result = store.updateActivitySlice(
                GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2),
                activityRevision: -1,
                fallbackSnapshot: petSnapshot
            )
            lock.lock()
            results.append(result)
            lock.unlock()
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.map(\.outcome).sorted { "\($0)" < "\($1)" }, [.rejectedInvalidActivityRevision, .saved])
        XCTAssertEqual(results.filter(\.didPersist).count, 1)
    }

    func testCrossDayRevisionExhaustionKeepsAppAndWidgetReadersOnPersistedSnapshot() {
        let defaults = makeDefaults()
        let trusted = TinyBuddyCombinedSnapshot(
            revision: Int64.max,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13),
            activityRevision: 200
        )
        defaults.set(TinyBuddyCombinedSnapshotStore.encode(trusted), forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        let appStore = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })
        let widgetStore = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })

        let result = appStore.updatePetSlice(
            TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0)),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(result.outcome, .revisionExhausted)
        XCTAssertFalse(result.didPersist)
        XCTAssertEqual(result.snapshot, trusted)
        XCTAssertEqual(appStore.load(), trusted)
        XCTAssertEqual(widgetStore.load(), trusted)
    }

    func testActivitySliceRejectsLegacyActivityWhenCombinedHasNewerTrustedRevision() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
        )
        let trustedB = GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13, recentProjectName: "B")
        let legacyA = GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "A")

        _ = store.updateActivitySlice(trustedB, activityRevision: 200, fallbackSnapshot: petSnapshot)
        let result = store.updateActivitySlice(legacyA, activityRevision: nil, fallbackSnapshot: petSnapshot)

        XCTAssertEqual(result.snapshot?.activitySnapshot, trustedB)
        XCTAssertEqual(result.snapshot?.activityRevision, 200)
        XCTAssertEqual(result.outcome, .rejectedStaleActivity)
        XCTAssertFalse(result.didPersist)
    }

    func testRevisionExhaustionDoesNotOverwriteTrustedSnapshot() {
        let defaults = makeDefaults()
        let trusted = TinyBuddyCombinedSnapshot(
            revision: Int64.max,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13),
            activityRevision: 200
        )
        defaults.set(TinyBuddyCombinedSnapshotStore.encode(trusted), forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        let store = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })

        let result = store.updatePetSlice(
            TinyBuddySnapshot(status: .focusing, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 1, completionCount: 0)),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(result.snapshot, trusted)
        XCTAssertEqual(store.load(), trusted)
        XCTAssertEqual(result.outcome, .revisionExhausted)
        XCTAssertFalse(result.didPersist)
    }

    func testInvalidOrZeroRevisionCounterStartsAtOne() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })
        defaults.set(-1, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)

        let first = store.updatePetSlice(
            TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(first.snapshot?.revision, 1)
        XCTAssertEqual(first.outcome, .saved)
        XCTAssertTrue(first.didPersist)
        defaults.set(0, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)
        let second = store.updatePetSlice(
            TinyBuddySnapshot(status: .focusing, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 1, completionCount: 0)),
            fallbackActivitySnapshot: nil
        )
        XCTAssertEqual(second.snapshot?.revision, 2)
    }

    func testPetSlicePrefersNewerTrustedActivityWhenCoordinatorCannotPublish() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )
        let activityA = GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "A")
        let activityB = GitTodayActivitySnapshot(focusBlockCount: 3, commitCount: 5, recentProjectName: "B")

        _ = store.updateActivitySlice(
            activityA,
            activityRevision: 100,
            fallbackSnapshot: petSnapshot
        )
        _ = store.updatePetSlice(
            petSnapshot,
            fallbackActivitySnapshot: activityB,
            fallbackActivityRevision: 200
        )

        XCTAssertEqual(store.load()?.activitySnapshot, activityB)
        XCTAssertEqual(store.load()?.activityRevision, 200)
    }

    func testCrossDayUpdateKeepsCombinedRevisionMonotonic() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let oldDaySnapshot = TinyBuddyCombinedSnapshot(
            revision: 40,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(
                status: .focusing,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 1, completionCount: 0)
            ),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 2, commitCount: 3),
            activityRevision: 100
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encode(oldDaySnapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )
        let newDaySnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0)
        )

        let updated = store.updatePetSlice(
            newDaySnapshot,
            fallbackActivitySnapshot: nil,
            fallbackActivityRevision: nil
        )

        XCTAssertEqual(updated.snapshot?.revision, 41)
        XCTAssertEqual(store.load(), updated.snapshot)
        XCTAssertEqual(updated.snapshot?.dayIdentifier, "2026-07-02")
    }

    func testSameRevisionCandidatesPreferDirectCombinedSnapshot() {
        let defaults = makeDefaults()
        let direct = TinyBuddyCombinedSnapshot(
            revision: 7,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 1),
            activityRevision: 10
        )
        let cached = TinyBuddyCombinedSnapshot(
            revision: 7,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 9, commitCount: 9),
            activityRevision: 20
        )
        defaults.set(TinyBuddyCombinedSnapshotStore.encode(direct), forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: {
                [TinyBuddyCombinedSnapshotStore.Key.snapshot: TinyBuddyCombinedSnapshotStore.encode(cached)]
            },
            fallbackDefaults: nil
        )

        XCTAssertEqual(store.load(), direct)
    }

    func testDelayedPetSlicePreservesNewerActivitySlice() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let staleActivity = GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 2,
            recentProjectName: "Old Project"
        )
        let newerActivity = GitTodayActivitySnapshot(
            focusBlockCount: 7,
            commitCount: 11,
            recentProjectName: "New Project"
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        _ = store.updateActivitySlice(newerActivity, activityRevision: 100, fallbackSnapshot: petSnapshot)
        _ = store.updatePetSlice(
            petSnapshot,
            fallbackActivitySnapshot: staleActivity,
            fallbackActivityRevision: 50
        )

        XCTAssertEqual(store.load()?.activitySnapshot, newerActivity)
        XCTAssertEqual(store.load()?.snapshot, petSnapshot)
        XCTAssertEqual(store.load()?.revision, 2)
    }

    func testConcurrentSliceWritersUseDeterministicRevisionsWithoutLosingEitherSlice() {
        let defaults = makeDefaults()
        let firstStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let secondStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 3, completionCount: 1)
        )
        let activitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: 5,
            commitCount: 8,
            recentProjectName: "TinyBuddy"
        )
        let group = DispatchGroup()

        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                _ = firstStore.updatePetSlice(petSnapshot, fallbackActivitySnapshot: nil)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                _ = secondStore.updateActivitySlice(activitySnapshot, fallbackSnapshot: petSnapshot)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(firstStore.load()?.snapshot, petSnapshot)
        XCTAssertEqual(firstStore.load()?.activitySnapshot, activitySnapshot)
        XCTAssertEqual(firstStore.load()?.revision, 40)
    }

    func testAppAndWidgetReadTheSameNewestCombinedSnapshot() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let newerSnapshot = TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
            )
        let newerActivity = GitTodayActivitySnapshot(
                focusBlockCount: 7,
                commitCount: 11,
                recentProjectName: "TinyBuddy"
            )

        _ = store.updateActivitySlice(newerActivity, fallbackSnapshot: newerSnapshot)
        _ = store.updatePetSlice(newerSnapshot, fallbackActivitySnapshot: nil)

        let appSnapshot = try? XCTUnwrap(store.load())
        let widgetSnapshot = try? XCTUnwrap(store.load())
        XCTAssertEqual(appSnapshot?.snapshot, newerSnapshot)
        XCTAssertEqual(appSnapshot?.activitySnapshot, newerActivity)
        XCTAssertEqual(widgetSnapshot, appSnapshot)
    }

    func testCombinedSnapshotPreservesUnavailableActivity() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let snapshot = TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
            )
        let activitySnapshot = GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            )

        _ = store.updatePetSlice(snapshot, fallbackActivitySnapshot: activitySnapshot)
        XCTAssertEqual(store.load()?.snapshot, snapshot)
        XCTAssertEqual(store.load()?.activitySnapshot, activitySnapshot)
    }

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

    func testWidgetSnapshotDoesNotCarryYesterdayStatusIntoToday() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 1)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate }
        )
        let session = PetSession(store: store)

        session.select(.focusing)
        currentDate = makeDate(year: 2026, month: 7, day: 2)

        let widgetSnapshot = store.loadSnapshot()
        let presentation = TinyBuddyWidgetPresentation(
            snapshot: widgetSnapshot,
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            )
        )

        XCTAssertEqual(widgetSnapshot.status, .idle)
        XCTAssertEqual(widgetSnapshot.stats, DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0))
        XCTAssertEqual(presentation.statusTitle, "待机")
        XCTAssertEqual(presentation.displayState, .idle)
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
