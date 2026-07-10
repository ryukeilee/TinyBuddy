import AppKit
import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

@MainActor
final class PetViewModelTests: XCTestCase {
    func testInitLoadsHUDPresentationFromSharedGitActivityStores() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        store.saveStatus(.idle)
        let activityStore = makeActivityStore(defaults: defaults, calendar: calendar, today: today)
        GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(1)
        GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(2)
        GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayProjectName("TinyBuddy")

        let viewModel = PetViewModel(
            store: store,
            activityStore: activityStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter()
        )
        let expectedPresentation = TinyBuddyWidgetPresentation(
            snapshot: store.loadSnapshot(),
            focusCountOverride: 1,
            completionCountOverride: 2,
            recentProjectName: "TinyBuddy",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(viewModel.hudPresentation, expectedPresentation)
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 2)
        XCTAssertEqual(viewModel.hudPresentation.statusTitle, "活跃")
        XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, "活跃 · TinyBuddy")
        XCTAssertEqual(viewModel.displayState, .active)
        XCTAssertNil(viewModel.displayState.selectedStatus)
    }

    func testLoadsRefreshDiagnosticsFromStoreOnInit() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 9, minute: 8, second: 7)
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { refreshedAt }
        )
        refreshStatusStore.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .didWake,
                outcome: .failed,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .scriptLookup,
                    reason: .scriptMissing
                )
            )
        )

        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            refreshStatusStore: refreshStatusStore,
            notificationCenter: NotificationCenter()
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.badgeTitle, "失败")
        XCTAssertEqual(viewModel.refreshDiagnostics.summary, "系统唤醒触发 刷新失败")
        XCTAssertEqual(viewModel.refreshDiagnostics.detail, formattedDetail(for: refreshedAt))
        XCTAssertEqual(viewModel.refreshDiagnostics.reason, "刷新组件缺失，暂时无法读取 Git 活动。")
        XCTAssertNil(viewModel.refreshDiagnostics.actionTitle)
    }

    func testInitDoesNotShowRefreshDiagnosticsFromPreviousDay() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 4, hour: 9, minute: 0, second: 0)
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate }
        )
        refreshStatusStore.save(
            GitActivityRefreshStatus(
                refreshedAt: currentDate,
                trigger: .didWake,
                outcome: .failed,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .scriptLookup,
                    reason: .scriptMissing
                )
            )
        )
        currentDate = makeDate(year: 2026, month: 7, day: 5, hour: 8, minute: 0, second: 0)

        let viewModel = PetViewModel(
            store: DailyStatsStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { currentDate }
            ),
            refreshStatusStore: refreshStatusStore,
            notificationCenter: NotificationCenter()
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.badgeTitle, "未刷新")
        XCTAssertEqual(viewModel.refreshDiagnostics.summary, "等待首次 Git 刷新")
        XCTAssertNil(viewModel.refreshDiagnostics.reason)
        XCTAssertNil(viewModel.refreshDiagnostics.actionTitle)
    }

    func testRefreshDiagnosticsUpdateWhenRefreshStatusNotificationArrives() async {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 10, minute: 0, second: 0)
        let refreshStatusStore = GitActivityRefreshStatusStore(userDefaults: defaults)
        let notificationCenter = NotificationCenter()
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let activityStore = makeActivityStore(defaults: defaults, calendar: calendar, today: today)
        let combinedSnapshotStore = store.makeCombinedSnapshotStore()
        let viewModel = PetViewModel(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            notificationCenter: notificationCenter
        )
        _ = combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 3, commitCount: 1, recentProjectName: "Project B"),
            fallbackSnapshot: store.loadSnapshot()
        )
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 10, minute: 11, second: 12)
        let updatedStatus = GitActivityRefreshStatus(
            refreshedAt: refreshedAt,
            trigger: .timer,
            outcome: .skipped,
            reason: "minimum refresh spacing not reached"
        )

        notificationCenter.post(name: .gitActivityRefreshStatusDidChange, object: updatedStatus)

        let expectation = expectation(description: "refresh diagnostics and HUD updated")
        Task { @MainActor in
            while viewModel.refreshDiagnostics.summary != "定时器触发 刷新跳过"
                || viewModel.hudPresentation.focusCount != 3
                || viewModel.hudPresentation.completionCount != 1
            {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(viewModel.refreshDiagnostics.badgeTitle, "跳过")
        XCTAssertEqual(viewModel.refreshDiagnostics.detail, formattedDetail(for: refreshedAt))
        XCTAssertEqual(viewModel.refreshDiagnostics.reason, "刚刚刷新过，稍后会自动再次尝试。")
        XCTAssertNil(viewModel.refreshDiagnostics.actionTitle)
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 3)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.statusTitle, "活跃")
        XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, "活跃 · Project B")
        XCTAssertEqual(viewModel.displayState, .active)
    }

    func testRefreshDiagnosticsMapsUnauthorizedRootsReasonToChinese() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 12, minute: 13, second: 14)
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { refreshedAt }
        )
        refreshStatusStore.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .skipped,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .authorizationResolution,
                    reason: .authorizationRequired
                )
            )
        )

        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            refreshStatusStore: refreshStatusStore,
            notificationCenter: NotificationCenter()
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.summary, "等待 Git 目录授权")
        XCTAssertEqual(viewModel.refreshDiagnostics.reason, "还没有可用的 Git 目录授权，授权后即可恢复 Git 刷新。")
        XCTAssertEqual(viewModel.refreshDiagnostics.actionTitle, "重新授权 Git 目录")
    }

    func testRefreshDiagnosticsMapsInvalidSavedAuthorizationToRecoveryMessage() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 12, minute: 15, second: 16)
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { refreshedAt }
        )
        refreshStatusStore.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .skipped,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .authorizationResolution,
                    reason: .authorizationInvalid
                )
            )
        )

        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            refreshStatusStore: refreshStatusStore,
            notificationCenter: NotificationCenter()
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.summary, "Git 目录授权已失效")
        XCTAssertEqual(
            viewModel.refreshDiagnostics.reason,
            "之前授权的 Git 扫描目录已失效，可能已被移动、删除或系统权限失效，请重新授权。"
        )
        XCTAssertEqual(viewModel.refreshDiagnostics.actionTitle, "重新授权 Git 目录")
    }

    func testRequestGitScanAuthorizationPostsRecoveryNotification() {
        let notificationCenter = NotificationCenter()
        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: makeDefaults()),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: makeDefaults()),
            notificationCenter: notificationCenter
        )
        let expectation = expectation(description: "authorization request posted")
        let observer = notificationCenter.addObserver(
            forName: .gitScanRootAuthorizationRequested,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer {
            notificationCenter.removeObserver(observer)
        }

        viewModel.requestGitScanAuthorization()

        wait(for: [expectation], timeout: 1.0)
    }

    func testRecreatedViewModelRestoresUserSelectionAndDailyCounts() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 13, minute: 0, second: 0)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let firstViewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter()
        )

        firstViewModel.select(.focusing)
        firstViewModel.select(.completedOnce)

        let recreatedViewModel = PetViewModel(
            store: DailyStatsStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today }
            ),
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter()
        )

        XCTAssertEqual(recreatedViewModel.status, .completedOnce)
        XCTAssertEqual(recreatedViewModel.stats.focusCount, 1)
        XCTAssertEqual(recreatedViewModel.stats.completionCount, 1)
    }

    func testSelectedStatusDoesNotRegressToGitDerivedDisplayState() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 13, minute: 30, second: 0)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(2)
        GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(3)

        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter()
        )

        viewModel.select(.focusing)

        XCTAssertEqual(viewModel.displayState, .active)
        XCTAssertEqual(viewModel.selectedStatus, .focusing)
    }

    func testBecameActiveRestoresPersistedStateWithoutWaitingForGitRefresh() async {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 14, minute: 0, second: 0)
        let notificationCenter = NotificationCenter()
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(viewModel.status, .idle)

        store.saveStatus(.focusing)
        store.recordFocusStarted()
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        let expectation = expectation(description: "persisted state restored on foreground transition")
        Task { @MainActor in
            while viewModel.status != .focusing || viewModel.stats.focusCount != 1 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testSelectingStatusSkipsWidgetReloadWhenWidgetPresentationIsUnchanged() {
        let defaults = makeDefaults()
        var widgetReloadCount = 0
        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            widgetReloader: { widgetReloadCount += 1 }
        )

        viewModel.select(.focusing)

        XCTAssertEqual(widgetReloadCount, 0)
        XCTAssertEqual(viewModel.selectedStatus, .focusing)
    }

    func testBecameActiveSkipsWidgetReloadWhenPersistedStateIsUnchanged() async {
        let defaults = makeDefaults()
        let notificationCenter = NotificationCenter()
        var widgetReloadCount = 0
        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            widgetReloader: { widgetReloadCount += 1 }
        )

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(widgetReloadCount, 0)
        XCTAssertEqual(viewModel.status, .idle)
    }

    func testRepeatedForegroundNotificationsKeepStateSubscriptionAndWidgetReloadStable() async {
        let defaults = makeDefaults()
        let notificationCenter = NotificationCenter()
        var widgetReloadCount = 0
        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            widgetReloader: { widgetReloadCount += 1 }
        )

        XCTAssertEqual(viewModel.notificationObserverCount, 2)

        for _ in 0..<25 {
            notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(viewModel.notificationObserverCount, 2)
        XCTAssertEqual(widgetReloadCount, 0)
    }

    func testBecameActiveReloadsWidgetWhenPersistedPresentationChanged() async {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 14, minute: 0, second: 0)
        let notificationCenter = NotificationCenter()
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        var widgetReloadCount = 0
        let activityStore = makeActivityStore(defaults: defaults, calendar: calendar, today: today)
        let combinedSnapshotStore = store.makeCombinedSnapshotStore()
        let viewModel = PetViewModel(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            widgetReloader: { widgetReloadCount += 1 }
        )

        _ = combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 0),
            fallbackSnapshot: store.loadSnapshot()
        )
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        let expectation = expectation(description: "changed persisted presentation restored")
        Task { @MainActor in
            while viewModel.hudPresentation.focusCount != 1 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(widgetReloadCount, 1)
    }

    func testNewDefaultsInstanceRestoresStateAfterApplicationRestart() {
        let suiteName = "TinyBuddyPetViewModelRestartTests.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: suiteName)!
        firstDefaults.removePersistentDomain(forName: suiteName)
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 15, minute: 0, second: 0)
        let firstStore = DailyStatsStore(
            userDefaults: firstDefaults,
            calendar: calendar,
            dateProvider: { today }
        )
        firstStore.recordFocusStarted()
        firstStore.recordCompletion()
        firstStore.saveStatus(.completedOnce)
        firstDefaults.synchronize()

        let restartedDefaults = UserDefaults(suiteName: suiteName)!
        let restartedViewModel = PetViewModel(
            store: DailyStatsStore(
                userDefaults: restartedDefaults,
                calendar: calendar,
                dateProvider: { today }
            ),
            activityStore: makeActivityStore(
                defaults: restartedDefaults,
                calendar: calendar,
                today: today
            ),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: restartedDefaults),
            notificationCenter: NotificationCenter()
        )

        XCTAssertEqual(restartedViewModel.status, .completedOnce)
        XCTAssertEqual(restartedViewModel.stats.focusCount, 1)
        XCTAssertEqual(restartedViewModel.stats.completionCount, 1)
    }

    func testHUDPresentationAndDisplayStateMatchSharedWidgetSemanticsForAllGitActivityStates() {
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let cases: [(focus: Int?, completion: Int?, projectName: String?, statusTitle: String, displayState: PetViewModel.DisplayState)] = [
            (0, 0, nil, "待机", .idle),
            (2, 0, " Focus Repo ", "专注中", .focusing),
            (0, 3, "ShipIt", "已完成", .completed),
            (2, 3, "TinyBuddy", "活跃", .active)
        ]

        for testCase in cases {
            let defaults = makeDefaults()
            let store = DailyStatsStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today }
            )
            store.saveStatus(.completedOnce)
            let activityStore = makeActivityStore(defaults: defaults, calendar: calendar, today: today)

            if let focus = testCase.focus {
                GitTodayFocusBlockCountStore(
                    userDefaults: defaults,
                    calendar: calendar,
                    dateProvider: { today },
                    sharedFallbacksEnabled: false
                ).saveTodayCount(focus)
            }
            if let completion = testCase.completion {
                GitTodayCommitCountStore(
                    userDefaults: defaults,
                    calendar: calendar,
                    dateProvider: { today },
                    sharedFallbacksEnabled: false
                ).saveTodayCount(completion)
            }
            if let projectName = testCase.projectName {
                GitTodayRecentProjectStore(
                    userDefaults: defaults,
                    calendar: calendar,
                    dateProvider: { today },
                    sharedFallbacksEnabled: false
                ).saveTodayProjectName(projectName)
            }

            let viewModel = PetViewModel(
                store: store,
                activityStore: activityStore,
                refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
                notificationCenter: NotificationCenter()
            )
            let expectedPresentation = TinyBuddyWidgetPresentation(
                snapshot: store.loadSnapshot(),
                activitySnapshot: activityStore.loadTodaySnapshot()
            )

            XCTAssertEqual(viewModel.hudPresentation, expectedPresentation)
            XCTAssertEqual(viewModel.hudPresentation.statusTitle, testCase.statusTitle)
            XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, expectedPresentation.statusDisplayTitle)
            XCTAssertEqual(viewModel.displayState, testCase.displayState)
            XCTAssertEqual(
                viewModel.displayState.selectedStatus,
                expectedSelectedStatus(for: testCase.displayState)
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyPetViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeActivityStore(
        defaults: UserDefaults,
        calendar: Calendar,
        today: Date
    ) -> GitTodayActivityStore {
        GitTodayActivityStore(
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
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
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

    private func formattedDetail(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func expectedSelectedStatus(for displayState: PetViewModel.DisplayState) -> PetStatus? {
        switch displayState {
        case .idle:
            return .idle
        case .focusing:
            return .focusing
        case .completed:
            return .completedOnce
        case .active:
            return nil
        }
    }
}
