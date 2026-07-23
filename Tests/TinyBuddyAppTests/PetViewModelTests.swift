import AppKit
import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

@MainActor
final class PetViewModelTests: XCTestCase {
    func testInitKeepsHUDOnPersistedCombinedSnapshotWhenRevisionCannotAdvance() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let petSnapshot = store.loadSnapshot()
        let persisted = TinyBuddyCombinedSnapshot(
            revision: Int64.max,
            dayIdentifier: petSnapshot.stats.dayIdentifier,
            snapshot: petSnapshot,
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 1,
                commitCount: 2,
                recentProjectName: "Persisted"
            ),
            activityRevision: 100
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encode(persisted),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )
        defaults.set(Int64.max, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)

        GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(9)
        GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(11)
        GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayProjectName("Uncommitted")

        let combinedStore = store.makeCombinedSnapshotStore()
        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: combinedStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
        )

        XCTAssertEqual(viewModel.hudPresentation.focusCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 2)
        XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, "今日完成 · Persisted")
        XCTAssertEqual(combinedStore.load(), persisted)
    }

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

        var widgetReloadCount = 0
        let viewModel = PetViewModel(
            store: store,
            activityStore: activityStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: { widgetReloadCount += 1 }
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
        XCTAssertEqual(viewModel.hudPresentation.statusTitle, "今日完成")
        XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, "今日完成 · TinyBuddy")
        XCTAssertEqual(viewModel.displayState, .active)
        XCTAssertNil(viewModel.displayState.selectedStatus)
        XCTAssertEqual(widgetReloadCount, 1)
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
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: refreshedAt)
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.badgeTitle, "失败")
        XCTAssertEqual(viewModel.refreshDiagnostics.summary, "系统唤醒触发 刷新失败")
        XCTAssertEqual(
            viewModel.refreshDiagnostics.detail,
            formattedDetail(for: refreshedAt, calendar: calendar)
        )
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
            notificationCenter: NotificationCenter(),
            timeEnvironment: TinyBuddyTimeEnvironment(
                calendar: calendar,
                dateProvider: { currentDate }
            )
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
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
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
            notificationCenter: notificationCenter,
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
        )
        _ = combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 3, commitCount: 1, recentProjectName: "Project B"),
            fallbackSnapshot: store.loadSnapshot()
        )
        let committedRevision = combinedSnapshotStore.load()?.revision
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
        XCTAssertEqual(
            viewModel.refreshDiagnostics.detail,
            formattedDetail(for: refreshedAt, calendar: calendar)
        )
        XCTAssertEqual(viewModel.refreshDiagnostics.reason, "刚刚刷新过，稍后会自动再次尝试。")
        XCTAssertNil(viewModel.refreshDiagnostics.actionTitle)
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 3)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.statusTitle, "今日完成")
        XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, "今日完成 · Project B")
        XCTAssertEqual(viewModel.displayState, .active)
        XCTAssertEqual(combinedSnapshotStore.load()?.revision, committedRevision)
    }

    func testCommittedActivityNotificationPublishesCompleteHUDImmediately() async {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 10, minute: 0, second: 0)
        let notificationCenter = NotificationCenter()
        let store = DailyStatsStore(userDefaults: defaults, calendar: calendar, dateProvider: { today })
        let activityStore = makeActivityStore(defaults: defaults, calendar: calendar, today: today)
        let combinedSnapshotStore = store.makeCombinedSnapshotStore()
        let viewModel = PetViewModel(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
        )
        _ = combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 5, commitCount: 8, recentProjectName: "TinyBuddy"),
            fallbackSnapshot: store.loadSnapshot()
        )
        let committedRevision = combinedSnapshotStore.load()?.revision

        notificationCenter.post(name: .gitActivitySnapshotDidChange, object: nil)

        let expectation = expectation(description: "HUD activity updated")
        Task { @MainActor in
            while viewModel.hudPresentation.focusCount != 5
                || viewModel.hudPresentation.completionCount != 8
                || viewModel.hudPresentation.statusDisplayTitle != "今日完成 · TinyBuddy"
            {
                await Task.yield()
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 5)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 8)
        XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, "今日完成 · TinyBuddy")
        XCTAssertEqual(combinedSnapshotStore.load()?.revision, committedRevision)
    }

    func testFailedRefreshStatusDoesNotRepublishUncommittedActivity() async {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 10, minute: 0, second: 0)
        let notificationCenter = NotificationCenter()
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let focusStore = GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        )
        let commitStore = GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        )
        focusStore.saveTodayCount(1)
        commitStore.saveTodayCount(2)
        let combinedSnapshotStore = store.makeCombinedSnapshotStore()
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            notificationCenter: notificationCenter,
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: {}
        )
        let committedRevision = combinedSnapshotStore.load()?.revision

        focusStore.saveTodayCount(9)
        commitStore.saveTodayCount(11)
        let failedStatus = GitActivityRefreshStatus(
            refreshedAt: today,
            trigger: .timer,
            outcome: .failed,
            diagnostic: GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .combinedSnapshotCommit,
                reason: .combinedSnapshotCommitFailed
            )
        )
        refreshStatusStore.save(failedStatus)
        notificationCenter.post(name: .gitActivityRefreshStatusDidChange, object: failedStatus)

        let expectation = expectation(description: "failed status applied without republishing")
        Task { @MainActor in
            while viewModel.refreshDiagnostics.outcome != .failed {
                await Task.yield()
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(viewModel.hudPresentation.focusCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 2)
        XCTAssertEqual(combinedSnapshotStore.load()?.revision, committedRevision)

        viewModel.select(.focusing)
        let selectedSnapshot = combinedSnapshotStore.loadReadOnly()
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 2)
        XCTAssertEqual(selectedSnapshot?.activitySnapshot.focusBlockCount, 1)
        XCTAssertEqual(selectedSnapshot?.activitySnapshot.commitCount, 2)
        XCTAssertEqual(selectedSnapshot?.snapshot.status, .focusing)

        store.saveStatus(.completedOnce)
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let restorationExpectation = self.expectation(
            description: "foreground restoration preserves committed activity"
        )
        Task { @MainActor in
            while viewModel.selectedStatus != .completedOnce {
                await Task.yield()
            }
            restorationExpectation.fulfill()
        }
        await fulfillment(of: [restorationExpectation], timeout: 1.0)

        let restoredSnapshot = combinedSnapshotStore.loadReadOnly()
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 2)
        XCTAssertEqual(restoredSnapshot?.activitySnapshot.focusBlockCount, 1)
        XCTAssertEqual(restoredSnapshot?.activitySnapshot.commitCount, 2)
        XCTAssertEqual(restoredSnapshot?.snapshot.status, .completedOnce)
    }

    func testFailedFirstCombinedCommitDoesNotExposeTrustedActivityToHUD() async {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 10, minute: 0, second: 0)
        let notificationCenter = NotificationCenter()
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
        ).saveTodayCount(9)
        GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(11)
        let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { _, _ in false },
            synchronizeWrites: {
                _ = defaults.synchronize()
                return true
            }
        )
        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
        )

        XCTAssertNil(combinedSnapshotStore.loadReadOnly())
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 0)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 0)

        notificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: GitActivityRefreshStatus(
                refreshedAt: today,
                trigger: .timer,
                outcome: .failed,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .combinedSnapshotCommit,
                    reason: .combinedSnapshotCommitFailed
                )
            )
        )
        let expectation = expectation(description: "failed status remains on committed-only HUD state")
        Task { @MainActor in
            while viewModel.refreshDiagnostics.outcome != .failed {
                await Task.yield()
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(viewModel.hudPresentation.focusCount, 0)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 0)
        XCTAssertNil(combinedSnapshotStore.loadReadOnly())
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
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: refreshedAt)
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.summary, "等待 Git 目录授权")
        XCTAssertEqual(viewModel.refreshDiagnostics.reason, "还没有可用的 Git 目录授权，授权后即可恢复 Git 刷新。")
        XCTAssertEqual(viewModel.refreshDiagnostics.actionTitle, "管理 Git 目录")
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
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: refreshedAt)
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.summary, "Git 目录授权已失效")
        XCTAssertEqual(
            viewModel.refreshDiagnostics.reason,
            "之前授权的 Git 扫描目录已失效，可能已被移动、删除或系统权限失效，请重新授权。"
        )
        XCTAssertEqual(viewModel.refreshDiagnostics.actionTitle, "管理 Git 目录")
    }

    func testRefreshDiagnosticsOffersGitDirectoryManagementForPartialRecovery() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 12, minute: 18, second: 19)
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { refreshedAt }
        )
        refreshStatusStore.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .partial,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .authorizationResolution,
                    reason: .partialRecovery
                )
            )
        )

        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            refreshStatusStore: refreshStatusStore,
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: refreshedAt)
        )

        XCTAssertEqual(viewModel.refreshDiagnostics.summary, "Git 活动已部分刷新")
        XCTAssertEqual(viewModel.refreshDiagnostics.actionTitle, "管理 Git 目录")
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

    func testAuthorizationFailureRemainsActionableDuringRefreshAndCanRecover() async {
        let defaults = makeDefaults()
        let onboardingDefaults = makeDefaults()
        let onboardingStore = TinyBuddyOnboardingStore(
            userDefaults: onboardingDefaults,
            sharedDefaults: defaults
        )
        onboardingStore.markCompleted()
        let notificationCenter = NotificationCenter()
        let refreshStatusStore = GitActivityRefreshStatusStore(userDefaults: defaults)
        let invalidStatus = GitActivityRefreshStatus(
            refreshedAt: Date(),
            trigger: .launch,
            outcome: .failed,
            diagnostic: GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .authorizationResolution,
                reason: .authorizationInvalid
            )
        )
        refreshStatusStore.save(invalidStatus)
        let statsStore = DailyStatsStore(userDefaults: defaults)
        let combinedSnapshotStore = statsStore.makeCombinedSnapshotStore()
        _ = combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 0, commitCount: 0, recentProjectName: nil),
            fallbackSnapshot: statsStore.loadSnapshot()
        )
        let viewModel = PetViewModel(
            onboardingStore: onboardingStore,
            store: statsStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(viewModel.gitActivityExperience.state, .authorizationInvalid)

        var repairRequestCount = 0
        let observer = notificationCenter.addObserver(
            forName: .gitScanRootAuthorizationRepairRequested,
            object: nil,
            queue: nil
        ) { _ in
            repairRequestCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }
        viewModel.performGitActivityAction()
        XCTAssertEqual(repairRequestCount, 1)

        notificationCenter.post(name: .gitActivityRefreshDidStart, object: nil)
        await Task.yield()
        XCTAssertEqual(viewModel.gitActivityExperience.state, .authorizationInvalid)

        let recoveredStatus = GitActivityRefreshStatus(
            refreshedAt: Date(),
            trigger: .reopen,
            outcome: .succeeded,
            metrics: GitActivityRefreshMetrics(authorizedRootCount: 1, repositoryCount: 1)
        )
        notificationCenter.post(name: .gitActivityRefreshStatusDidChange, object: recoveredStatus)
        await Task.yield()
        XCTAssertTrue(
            viewModel.gitActivityExperience.state == .noActivity
                || viewModel.gitActivityExperience.state == .ready
        )
        XCTAssertNotEqual(viewModel.gitActivityExperience.action, .reauthorize)
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
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
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
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
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
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
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
            notificationCenter: notificationCenter,
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
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

    func testSelectingStatusReloadsWidgetWhenFallbackSemanticStatusChanges() {
        let defaults = makeDefaults()
        var widgetReloadCount = 0
        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            activityStore: makeActivityStore(defaults: defaults),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            widgetReloader: { widgetReloadCount += 1 }
        )

        viewModel.select(.focusing)

        XCTAssertEqual(widgetReloadCount, 1)
        XCTAssertEqual(viewModel.selectedStatus, .focusing)
    }

    func testBecameActiveSkipsWidgetReloadWhenPersistedStateIsUnchanged() async {
        let defaults = makeDefaults()
        let notificationCenter = NotificationCenter()
        var widgetReloadCount = 0
        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults),
            activityStore: makeActivityStore(defaults: defaults),
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
            activityStore: makeActivityStore(defaults: defaults),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            widgetReloader: { widgetReloadCount += 1 }
        )

        XCTAssertEqual(viewModel.notificationObserverCount, 7)

        for _ in 0..<25 {
            notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(viewModel.notificationObserverCount, 7)
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
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
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

    func testBecameActiveReloadsWidgetOnceWhenAvailabilityFailsWithoutPersistence() async {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 14, minute: 0, second: 0)
        let notificationCenter = NotificationCenter()
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        var readFailure: TinyBuddySharedSnapshotReason?
        let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { readFailure }
        )
        var widgetReloadCount = 0
        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: { widgetReloadCount += 1 }
        )
        let initialReloadCount = widgetReloadCount

        readFailure = .appGroupUnavailable
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(viewModel.displayPresentation.state, .readFailed)
        XCTAssertEqual(widgetReloadCount, initialReloadCount + 1)

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(widgetReloadCount, initialReloadCount + 1)
    }

    func testInitialUnavailableDisplayReloadsCachedWidgetTimeline() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 14, minute: 0, second: 0)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { .appGroupUnavailable }
        )
        var widgetReloadCount = 0

        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: { widgetReloadCount += 1 }
        )

        XCTAssertEqual(viewModel.displayPresentation.state, .readFailed)
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
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
        )

        XCTAssertEqual(restartedViewModel.status, .completedOnce)
        XCTAssertEqual(restartedViewModel.stats.focusCount, 1)
        XCTAssertEqual(restartedViewModel.stats.completionCount, 1)
    }

    func testHUDPresentationAndDisplayStateMatchSharedWidgetSemanticsForAllGitActivityStates() {
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let cases: [(focus: Int?, completion: Int?, projectName: String?, statusTitle: String, displayState: PetViewModel.DisplayState)] = [
            (0, 0, nil, "今日无活动", .idle),
            (2, 0, " Focus Repo ", "专注中", .focusing),
            (0, 3, "ShipIt", "今日完成", .completed),
            (2, 3, "TinyBuddy", "今日完成", .active)
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
                notificationCenter: NotificationCenter(),
                timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today)
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

    func testCorruptCombinedSnapshotIsRebuiltOnceAndRecordsRedactedRecovery() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let store = DailyStatsStore(userDefaults: defaults, calendar: calendar, dateProvider: { today })
        let validSnapshot = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: store.loadSnapshot().stats.dayIdentifier,
            snapshot: store.loadSnapshot(),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 1,
                commitCount: 1,
                recentProjectName: "Redacted"
            )
        )
        let validPayload = TinyBuddyCombinedSnapshotStore.encodeV2(validSnapshot)
        let corruptedPayload = String(validPayload.dropLast()) + "x"
        defaults.set(corruptedPayload, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        defaults.set(corruptedPayload, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB)
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(1),
            forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
        )
        let recorder = TinyBuddySharedSnapshotDiagnosticRecorder()

        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: TinyBuddyCombinedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil }
            ),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: {},
            sharedSnapshotDiagnosticRecorder: recorder
        )

        XCTAssertEqual(recorder.latestSummary?.identifier, "tinybuddy.sharedSnapshot.snapshotRead.snapshotCorrupt")
        XCTAssertEqual(recorder.latestSummary?.recovery, .rebuilt)
        XCTAssertEqual(viewModel.hiddenSnapshotDiagnosticSummary?.attemptCount, 3)
        XCTAssertNotNil(store.makeCombinedSnapshotStore().readValidated(
            expectedDayIdentifier: store.loadSnapshot().stats.dayIdentifier
        ).snapshot)
    }

    func testRecoveredRedundantSnapshotIsRepairedOnceInTheApp() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let store = DailyStatsStore(userDefaults: defaults, calendar: calendar, dateProvider: { today })
        let snapshot = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: store.loadSnapshot().stats.dayIdentifier,
            snapshot: store.loadSnapshot(),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 1,
                commitCount: 1,
                recentProjectName: "Redacted"
            )
        )
        let corruptedPayload = String(TinyBuddyCombinedSnapshotStore.encodeV2(snapshot).dropLast()) + "x"
        defaults.set(corruptedPayload, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(snapshot.revision),
            forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
        )
        let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let recorder = TinyBuddySharedSnapshotDiagnosticRecorder()

        _ = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: {},
            sharedSnapshotDiagnosticRecorder: recorder
        )

        XCTAssertEqual(recorder.latestSummary?.reason, .snapshotCorrupt)
        XCTAssertEqual(recorder.latestSummary?.recovery, .rebuilt)
        XCTAssertNil(
            combinedSnapshotStore.readValidated(
                expectedDayIdentifier: store.loadSnapshot().stats.dayIdentifier
            ).observation
        )
    }

    func testStaleCombinedSnapshotIsRebuiltOnceBeforeDisplayingActivity() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let store = DailyStatsStore(userDefaults: defaults, calendar: calendar, dateProvider: { today })
        let staleDayIdentifier = "2026-07-03"
        let staleSnapshot = TinyBuddyCombinedSnapshot(
            revision: 1,
            dayIdentifier: staleDayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(
                    dayIdentifier: staleDayIdentifier,
                    focusCount: 8,
                    completionCount: 5
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 7,
                commitCount: 6,
                recentProjectName: "Stale"
            )
        )
        let stalePayload = TinyBuddyCombinedSnapshotStore.encodeV2(staleSnapshot)
        defaults.set(stalePayload, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        defaults.set(stalePayload, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB)
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(staleSnapshot.revision),
            forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
        )
        let recorder = TinyBuddySharedSnapshotDiagnosticRecorder()
        let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )

        _ = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: {},
            sharedSnapshotDiagnosticRecorder: recorder
        )

        XCTAssertEqual(recorder.latestSummary?.reason, .staleData)
        XCTAssertEqual(recorder.latestSummary?.recovery, .rebuilt)
        XCTAssertEqual(
            combinedSnapshotStore.readValidated(
                expectedDayIdentifier: store.loadSnapshot().stats.dayIdentifier
            ).snapshot?.dayIdentifier,
            store.loadSnapshot().stats.dayIdentifier
        )
    }

    func testVersionOrAccessFailureDoesNotWriteOrExposeGitActivity() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let store = DailyStatsStore(userDefaults: defaults, calendar: calendar, dateProvider: { today })
        var writeAttemptCount = 0
        let recorder = TinyBuddySharedSnapshotDiagnosticRecorder()
        let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { _, _ in
                writeAttemptCount += 1
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { .versionIncompatible }
        )

        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: {},
            sharedSnapshotDiagnosticRecorder: recorder
        )

        XCTAssertEqual(writeAttemptCount, 0)
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 0)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 0)
        XCTAssertEqual(recorder.latestSummary?.reason, .versionIncompatible)
        XCTAssertEqual(recorder.latestSummary?.recovery, .stopped)
    }

    func testWidgetReloadFailureRecordsStructuredHiddenSummary() {
        enum ReloadError: Error { case unavailable }

        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let recorder = TinyBuddySharedSnapshotDiagnosticRecorder()
        GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(1)
        _ = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults, calendar: calendar, dateProvider: { today }),
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: { throw ReloadError.unavailable },
            sharedSnapshotDiagnosticRecorder: recorder
        )

        XCTAssertEqual(recorder.latestSummary?.identifier, "tinybuddy.sharedSnapshot.timelineReload.timelineReloadFailed")
        XCTAssertEqual(recorder.latestSummary?.recovery, .stopped)
    }

    func testSharedSnapshotRecorderPublishesHiddenDiagnosticSummary() async {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let recorder = TinyBuddySharedSnapshotDiagnosticRecorder()
        let viewModel = PetViewModel(
            store: DailyStatsStore(userDefaults: defaults, calendar: calendar, dateProvider: { today }),
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: TinyBuddyCombinedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil }
            ),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            widgetReloader: {},
            sharedSnapshotDiagnosticRecorder: recorder
        )

        recorder.record(
            phase: .gitScan,
            reason: .gitScanFailed,
            recovery: .stopped
        )
        await Task.yield()

        XCTAssertEqual(viewModel.notificationObserverCount, 7)
        XCTAssertEqual(
            viewModel.hiddenSnapshotDiagnosticSummary?.identifier,
            "tinybuddy.sharedSnapshot.gitScan.gitScanFailed"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyPetViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeActivityStore(
        defaults: UserDefaults
    ) -> GitTodayActivityStore {
        makeActivityStore(
            defaults: defaults,
            calendar: .current,
            today: Date()
        )
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

    private func makeTimeEnvironment(calendar: Calendar, now: Date) -> TinyBuddyTimeEnvironment {
        TinyBuddyTimeEnvironment(calendar: calendar, dateProvider: { now })
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

    private func formattedDetail(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
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
