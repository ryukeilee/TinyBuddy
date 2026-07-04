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
        let refreshStatusStore = GitActivityRefreshStatusStore(userDefaults: defaults)
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 9, minute: 8, second: 7)
        refreshStatusStore.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .didWake,
                outcome: .failed,
                reason: "missing git refresh script"
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
        let viewModel = PetViewModel(
            store: store,
            activityStore: activityStore,
            refreshStatusStore: refreshStatusStore,
            notificationCenter: notificationCenter
        )
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
        ).saveTodayCount(1)
        GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayProjectName("Project B")
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
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 3)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.statusTitle, "活跃")
        XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, "活跃 · Project B")
        XCTAssertEqual(viewModel.displayState, .active)
    }

    func testRefreshDiagnosticsMapsUnauthorizedRootsReasonToChinese() {
        let defaults = makeDefaults()
        let refreshStatusStore = GitActivityRefreshStatusStore(userDefaults: defaults)
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 12, minute: 13, second: 14)
        refreshStatusStore.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .skipped,
                reason: "no authorized Git scan roots"
            )
        )

        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            refreshStatusStore: refreshStatusStore,
            notificationCenter: NotificationCenter()
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.reason, "还没有可用的 Git 目录授权，暂时无法刷新。")
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
