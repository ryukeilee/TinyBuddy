import Combine
import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

@MainActor
final class PetViewModelDisplayTransitionTests: XCTestCase {
    func testRepeatedIdenticalSnapshotAndStatusNotificationsDoNotPublishOrRecordConsumptionAgain() async throws {
        let fixture = makeFixture(activity: GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 2,
            recentProjectName: "Initial"
        ))
        let status = makeStatus(at: fixture.now, outcome: .succeeded)
        fixture.refreshStatusStore.save(status)
        _ = fixture.combinedSnapshotStore.updateActivitySlice(
            fixture.activity,
            fallbackSnapshot: fixture.store.loadSnapshot()
        )
        var consumptions: [TinyBuddyHUDSnapshotConsumption] = []
        let viewModel = fixture.makeViewModel(hudSnapshotConsumptionRecorder: { consumptions.append($0) })
        let committedSnapshot = try XCTUnwrap(fixture.combinedSnapshotStore.readValidated(
            expectedDayIdentifier: fixture.store.loadSnapshot().stats.dayIdentifier
        ).snapshot)
        var publicationCount = 0
        let publication = viewModel.objectWillChange.sink { publicationCount += 1 }
        defer { publication.cancel() }

        XCTAssertEqual(consumptions, [consumption(for: committedSnapshot)])

        fixture.notificationCenter.post(
            name: .gitActivitySnapshotDidChange,
            object: nil,
            userInfo: lifecycleUserInfo(generation: 1, sequence: 1)
        )
        await Task.yield()
        fixture.notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: status,
            userInfo: lifecycleUserInfo(generation: 1, sequence: 2)
        )
        await Task.yield()

        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(consumptions, [consumption(for: committedSnapshot)])
    }

    func testRefreshStartPreservesUsableDisplayStateAndDuplicateStartDoesNotPublish() async {
        let cases: [(activity: GitTodayActivitySnapshot, state: TinyBuddyDisplayState)] = [
            (GitTodayActivitySnapshot(focusBlockCount: 2, commitCount: 0), .focusing),
            (GitTodayActivitySnapshot(focusBlockCount: 0, commitCount: 3), .completedToday),
            (GitTodayActivitySnapshot(focusBlockCount: 0, commitCount: 0), .noActivity)
        ]

        for testCase in cases {
            let fixture = makeFixture(activity: testCase.activity)
            _ = fixture.combinedSnapshotStore.updateActivitySlice(
                testCase.activity,
                fallbackSnapshot: fixture.store.loadSnapshot()
            )
            let viewModel = fixture.makeViewModel()
            let initialPresentation = viewModel.displayPresentation
            var publicationCount = 0
            let publication = viewModel.objectWillChange.sink { publicationCount += 1 }

            fixture.notificationCenter.post(
                name: .gitActivityRefreshDidStart,
                object: nil,
                userInfo: lifecycleUserInfo(generation: 1, sequence: 1)
            )
            await Task.yield()

            XCTAssertEqual(viewModel.displayPresentation.state, testCase.state)
            XCTAssertTrue(viewModel.displayPresentation.isRefreshing)
            XCTAssertEqual(viewModel.displayPresentation.transitionIdentity, initialPresentation.transitionIdentity)
            XCTAssertEqual(viewModel.displayPresentation.title, initialPresentation.title)
            XCTAssertEqual(viewModel.displayPresentation.message, initialPresentation.message)
            XCTAssertEqual(viewModel.displayPresentation.dataDateText, initialPresentation.dataDateText)
            XCTAssertEqual(viewModel.displayPresentation.focusCount, initialPresentation.focusCount)
            XCTAssertEqual(viewModel.displayPresentation.completionCount, initialPresentation.completionCount)
            XCTAssertEqual(publicationCount, 1)

            fixture.notificationCenter.post(
                name: .gitActivityRefreshDidStart,
                object: nil,
                userInfo: lifecycleUserInfo(generation: 1, sequence: 2)
            )
            await Task.yield()

            XCTAssertEqual(publicationCount, 1)
            publication.cancel()
        }
    }

    func testOlderSequenceCannotOverrideNewerRefreshStatusTitleOrTime() async {
        let fixture = makeFixture(activity: GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 1
        ))
        _ = fixture.combinedSnapshotStore.updateActivitySlice(
            fixture.activity,
            fallbackSnapshot: fixture.store.loadSnapshot()
        )
        let oldStatus = makeStatus(at: fixture.now.addingTimeInterval(-60), outcome: .succeeded)
        fixture.refreshStatusStore.save(oldStatus)
        let viewModel = fixture.makeViewModel()
        let newStatus = makeStatus(at: fixture.now.addingTimeInterval(60), outcome: .failed)

        fixture.notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: newStatus,
            userInfo: lifecycleUserInfo(generation: 4, sequence: 3)
        )
        await Task.yield()
        let presentationAfterNewStatus = viewModel.displayPresentation

        fixture.notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: oldStatus,
            userInfo: lifecycleUserInfo(generation: 4, sequence: 2)
        )
        await Task.yield()

        XCTAssertEqual(presentationAfterNewStatus.title, "数据读取失败")
        XCTAssertEqual(viewModel.displayPresentation.title, presentationAfterNewStatus.title)
        XCTAssertEqual(viewModel.displayPresentation.dataDateText, presentationAfterNewStatus.dataDateText)
    }

    func testRapidNotificationsConvergeOnHighestSequenceAndNewestCommittedSnapshot() async throws {
        let fixture = makeFixture(activity: GitTodayActivitySnapshot(
            focusBlockCount: 0,
            commitCount: 0
        ))
        let viewModel = fixture.makeViewModel()
        let firstUpdate = fixture.combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 3, commitCount: 0, recentProjectName: "First"),
            activityRevision: 1,
            fallbackSnapshot: fixture.store.loadSnapshot()
        )
        XCTAssertTrue(firstUpdate.didPersist)
        fixture.notificationCenter.post(
            name: .gitActivitySnapshotDidChange,
            object: nil,
            userInfo: lifecycleUserInfo(generation: 8, sequence: 1)
        )

        let finalActivity = GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 4,
            recentProjectName: "Final"
        )
        let finalUpdate = fixture.combinedSnapshotStore.updateActivitySlice(
            finalActivity,
            activityRevision: 2,
            fallbackSnapshot: fixture.store.loadSnapshot()
        )
        let finalSnapshot = try XCTUnwrap(finalUpdate.snapshot)
        fixture.notificationCenter.post(
            name: .gitActivitySnapshotDidChange,
            object: nil,
            userInfo: lifecycleUserInfo(generation: 8, sequence: 3)
        )
        await Task.yield()

        fixture.notificationCenter.post(
            name: .gitActivitySnapshotDidChange,
            object: nil,
            userInfo: lifecycleUserInfo(generation: 8, sequence: 2)
        )
        await Task.yield()

        XCTAssertEqual(viewModel.displayPresentation.focusCount, 1)
        XCTAssertEqual(viewModel.displayPresentation.completionCount, 4)
        XCTAssertEqual(viewModel.displayPresentation.recentProjectName, "Final")
        XCTAssertEqual(viewModel.displayPresentation.state, .completedToday)
        XCTAssertEqual(viewModel.displayPresentation, TinyBuddyDisplayPresentation(
            snapshot: finalSnapshot.snapshot,
            activitySnapshot: finalSnapshot.activitySnapshot,
            locale: fixture.locale,
            timeZone: fixture.timeZone
        ))
    }

    func testRefreshStartSubsumesAnEarlierTimeEnvironmentReloadWhenTasksArriveOutOfOrder() async {
        let fixture = makeFixture(activity: GitTodayActivitySnapshot(
            focusBlockCount: 0,
            commitCount: 0
        ))
        let viewModel = fixture.makeViewModel()
        _ = fixture.combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(
                focusBlockCount: 2,
                commitCount: 5,
                recentProjectName: "Current Scope"
            ),
            activityRevision: 1,
            fallbackSnapshot: fixture.store.loadSnapshot()
        )

        fixture.notificationCenter.post(
            name: .gitActivityRefreshDidStart,
            object: nil,
            userInfo: lifecycleUserInfo(generation: 9, sequence: 2)
        )
        await Task.yield()
        fixture.notificationCenter.post(
            name: .tinyBuddyTimeEnvironmentDidChange,
            object: nil,
            userInfo: lifecycleUserInfo(generation: 9, sequence: 1)
        )
        await Task.yield()

        XCTAssertEqual(viewModel.displayPresentation.focusCount, 2)
        XCTAssertEqual(viewModel.displayPresentation.completionCount, 5)
        XCTAssertEqual(viewModel.displayPresentation.recentProjectName, "Current Scope")
        XCTAssertEqual(viewModel.displayPresentation.state, .completedToday)
        XCTAssertTrue(viewModel.displayPresentation.isRefreshing)
    }

    func testDisplayPresentationMatchesDirectWidgetPresentationForSameCommittedSnapshotAndStatus() async throws {
        let fixture = makeFixture(activity: GitTodayActivitySnapshot(
            focusBlockCount: 2,
            commitCount: 5,
            recentProjectName: "Widget Contract"
        ))
        let status = makeStatus(at: fixture.now, outcome: .partial)
        fixture.refreshStatusStore.save(status)
        _ = fixture.combinedSnapshotStore.updateActivitySlice(
            fixture.activity,
            fallbackSnapshot: fixture.store.loadSnapshot()
        )
        let viewModel = fixture.makeViewModel()
        let committedSnapshot = try XCTUnwrap(fixture.combinedSnapshotStore.readValidated(
            expectedDayIdentifier: fixture.store.loadSnapshot().stats.dayIdentifier
        ).snapshot)
        let widgetPresentation = TinyBuddyDisplayPresentation(
            snapshot: committedSnapshot.snapshot,
            activitySnapshot: committedSnapshot.activitySnapshot,
            refreshStatus: status,
            locale: fixture.locale,
            timeZone: fixture.timeZone
        )

        XCTAssertEqual(viewModel.displayPresentation, widgetPresentation)
    }

    func testOlderLifecycleGenerationResultCannotOverrideCurrentDisplay() async {
        let fixture = makeFixture(activity: GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 1
        ))
        _ = fixture.combinedSnapshotStore.updateActivitySlice(
            fixture.activity,
            fallbackSnapshot: fixture.store.loadSnapshot()
        )
        let viewModel = fixture.makeViewModel()
        let currentStatus = makeStatus(at: fixture.now.addingTimeInterval(60), outcome: .failed)
        let oldStatus = makeStatus(at: fixture.now.addingTimeInterval(120), outcome: .succeeded)

        fixture.notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: currentStatus,
            userInfo: lifecycleUserInfo(generation: 7, sequence: 1)
        )
        await Task.yield()
        let currentPresentation = viewModel.displayPresentation

        fixture.notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: oldStatus,
            userInfo: lifecycleUserInfo(generation: 6, sequence: 99)
        )
        await Task.yield()

        XCTAssertEqual(viewModel.displayPresentation.title, currentPresentation.title)
        XCTAssertEqual(viewModel.displayPresentation.dataDateText, currentPresentation.dataDateText)
        XCTAssertEqual(viewModel.displayPresentation.state, .readFailed)
    }

    func testNewerLifecycleGenerationAcceptsStatusAfterWallClockRollback() async {
        let fixture = makeFixture(activity: GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 1
        ))
        _ = fixture.combinedSnapshotStore.updateActivitySlice(
            fixture.activity,
            fallbackSnapshot: fixture.store.loadSnapshot()
        )
        let viewModel = fixture.makeViewModel()
        let futureStatus = makeStatus(at: fixture.now.addingTimeInterval(120), outcome: .failed)
        let rolledBackStatus = makeStatus(at: fixture.now.addingTimeInterval(60), outcome: .succeeded)
        let obsoleteStatus = makeStatus(at: fixture.now.addingTimeInterval(180), outcome: .failed)

        fixture.notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: futureStatus,
            userInfo: lifecycleUserInfo(generation: 10, sequence: 1)
        )
        await Task.yield()
        XCTAssertEqual(viewModel.displayPresentation.state, .readFailed)

        fixture.notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: rolledBackStatus,
            userInfo: lifecycleUserInfo(generation: 11, sequence: 1)
        )
        await Task.yield()

        XCTAssertEqual(viewModel.displayPresentation.state, .completedToday)
        XCTAssertEqual(viewModel.displayPresentation.dataDateText, "数据日期 07-18")
        XCTAssertFalse(viewModel.displayPresentation.isRefreshing)

        fixture.notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: obsoleteStatus,
            userInfo: lifecycleUserInfo(generation: 10, sequence: 99)
        )
        await Task.yield()

        XCTAssertEqual(viewModel.displayPresentation.state, .completedToday)
        XCTAssertEqual(viewModel.displayPresentation.dataDateText, "数据日期 07-18")
        XCTAssertFalse(viewModel.displayPresentation.isRefreshing)
    }

    func testWestwardDayRollbackMatchesWidgetStaleDisplayPolicy() async throws {
        let defaults = makeDefaults()
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "zh_CN")
        var now = makeDate(year: 2026, month: 7, day: 5, hour: 1, minute: 0, second: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        let timeEnvironment = TinyBuddyTimeEnvironment(
            calendar: calendar,
            dateProvider: { now }
        )
        let store = DailyStatsStore(
            userDefaults: defaults,
            timeEnvironment: timeEnvironment
        )
        _ = store.recordFocusStarted()
        _ = store.recordCompletion()
        let activityStore = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { now },
                sharedFallbacksEnabled: false
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { now },
                sharedFallbacksEnabled: false
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { now },
                sharedFallbacksEnabled: false
            ),
            timeEnvironment: timeEnvironment,
            timeScopeTokenProvider: { nil }
        )
        let combinedSnapshotStore = store.makeCombinedSnapshotStore()
        let futureActivity = GitTodayActivitySnapshot(
            focusBlockCount: 4,
            commitCount: 5,
            recentProjectName: "Future"
        )
        let update = combinedSnapshotStore.updateActivitySlice(
            futureActivity,
            fallbackSnapshot: store.loadSnapshot()
        )
        XCTAssertTrue(update.didPersist)
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            timeEnvironment: timeEnvironment
        )
        refreshStatusStore.save(makeStatus(at: now, outcome: .failed))
        let onboardingStore = TinyBuddyOnboardingStore(
            userDefaults: defaults,
            sharedDefaults: defaults
        )
        _ = onboardingStore.markCompleted()
        let notificationCenter = NotificationCenter()
        let viewModel = PetViewModel(
            onboardingStore: onboardingStore,
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            notificationCenter: notificationCenter,
            timeEnvironment: timeEnvironment,
            widgetReloader: {}
        )
        XCTAssertEqual(viewModel.displayPresentation.state, .readFailed)

        now = makeDate(year: 2026, month: 7, day: 4, hour: 23, minute: 0, second: 0)
        notificationCenter.post(
            name: .tinyBuddyTimeEnvironmentDidChange,
            object: nil,
            userInfo: lifecycleUserInfo(generation: 1, sequence: 1)
        )
        await Task.yield()
        let currentContext = try XCTUnwrap(timeEnvironment.capture())
        let retainedSnapshot = try XCTUnwrap(combinedSnapshotStore.loadReadOnly(
            minimumDayIdentifier: currentContext.dayIdentifier
        ))
        let widgetPresentation = TinyBuddyDisplayPresentation(
            snapshot: retainedSnapshot.snapshot,
            activitySnapshot: retainedSnapshot.activitySnapshot,
            refreshStatus: nil,
            dataAvailability: .stale,
            onboardingCompleted: true,
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(viewModel.displayPresentation, widgetPresentation)
        XCTAssertEqual(viewModel.displayPresentation.state, .stale)
        XCTAssertEqual(viewModel.displayPresentation.dataDateText, "数据日期 07-05")
        XCTAssertNil(viewModel.refreshDiagnostics.outcome)
    }

    private func makeFixture(
        activity: GitTodayActivitySnapshot
    ) -> Fixture {
        let defaults = makeDefaults()
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "zh_CN")
        let now = makeDate(year: 2026, month: 7, day: 18, hour: 9, minute: 8, second: 7)
        let timeEnvironment = TinyBuddyTimeEnvironment.fixed(
            now: now,
            timeZone: timeZone,
            locale: locale
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { now }
        )
        let onboardingStore = TinyBuddyOnboardingStore(userDefaults: defaults, sharedDefaults: defaults)
        _ = onboardingStore.markCompleted()
        return Fixture(
            now: now,
            timeZone: timeZone,
            locale: locale,
            activity: activity,
            store: store,
            activityStore: GitTodayActivityStore(
                focusBlockCountStore: GitTodayFocusBlockCountStore(
                    userDefaults: defaults,
                    calendar: calendar,
                    dateProvider: { now },
                    sharedFallbacksEnabled: false
                ),
                commitCountStore: GitTodayCommitCountStore(
                    userDefaults: defaults,
                    calendar: calendar,
                    dateProvider: { now },
                    sharedFallbacksEnabled: false
                ),
                recentProjectStore: GitTodayRecentProjectStore(
                    userDefaults: defaults,
                    calendar: calendar,
                    dateProvider: { now },
                    sharedFallbacksEnabled: false
                ),
                timeEnvironment: timeEnvironment,
                timeScopeTokenProvider: { nil }
            ),
            combinedSnapshotStore: store.makeCombinedSnapshotStore(),
            refreshStatusStore: GitActivityRefreshStatusStore(
                userDefaults: defaults,
                timeEnvironment: timeEnvironment
            ),
            notificationCenter: NotificationCenter(),
            timeEnvironment: timeEnvironment,
            onboardingStore: onboardingStore
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyPetViewModelDisplayTransitionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStatus(at date: Date, outcome: GitActivityRefreshOutcome) -> GitActivityRefreshStatus {
        GitActivityRefreshStatus(
            refreshedAt: date,
            trigger: .reopen,
            outcome: outcome,
            metrics: GitActivityRefreshMetrics(authorizedRootCount: 1, repositoryCount: 1)
        )
    }

    private func lifecycleUserInfo(generation: Int, sequence: Int) -> [AnyHashable: Any] {
        [
            TinyBuddyLifecycleNotification.generationKey: generation,
            TinyBuddyLifecycleNotification.sequenceKey: sequence
        ]
    }

    private func consumption(for snapshot: TinyBuddyCombinedSnapshot) -> TinyBuddyHUDSnapshotConsumption {
        TinyBuddyHUDSnapshotConsumption(
            schemaVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            revision: snapshot.revision,
            dayIdentifier: snapshot.dayIdentifier
        )
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
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }
}

@MainActor
private struct Fixture {
    let now: Date
    let timeZone: TimeZone
    let locale: Locale
    let activity: GitTodayActivitySnapshot
    let store: DailyStatsStore
    let activityStore: GitTodayActivityStore
    let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    let refreshStatusStore: GitActivityRefreshStatusStore
    let notificationCenter: NotificationCenter
    let timeEnvironment: TinyBuddyTimeEnvironment
    let onboardingStore: TinyBuddyOnboardingStore

    func makeViewModel(
        hudSnapshotConsumptionRecorder: @escaping (TinyBuddyHUDSnapshotConsumption) -> Void = { _ in }
    ) -> PetViewModel {
        PetViewModel(
            onboardingStore: onboardingStore,
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            notificationCenter: notificationCenter,
            timeEnvironment: timeEnvironment,
            widgetReloader: {},
            hudSnapshotConsumptionRecorder: hudSnapshotConsumptionRecorder
        )
    }
}
