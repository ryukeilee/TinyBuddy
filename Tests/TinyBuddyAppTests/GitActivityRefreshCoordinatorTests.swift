import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore
import Foundation

final class GitActivityRefreshCoordinatorTests: XCTestCase {
    func testRefreshSkipsScriptWhenNoGitScanRootsAreAuthorized() {
        let harness = makeHarness(authorizedRoots: [])

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 0)
        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .skipped,
                reason: "no authorized Git scan roots"
            )
        )
    }

    func testRefreshPassesAuthorizedGitScanRootsToScript() {
        let roots = [
            URL(fileURLWithPath: "/Authorized/TinyBuddy Projects/ProjectA"),
            URL(fileURLWithPath: "/Authorized/TinyBuddy Projects/ProjectB")
        ]
        let harness = makeHarness(authorizedRoots: roots)

        harness.performAndWaitForRefresh {
            harness.coordinator.handleDidBecomeActive()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.capturedRootPaths, roots.map(\.standardizedFileURL.path))
        XCTAssertEqual(harness.stopAccessCount, roots.count)
    }

    func testVisibleRefreshTriggersScriptAndWidgetReload() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.handleDidBecomeActive()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .succeeded
            )
        )
    }

    func testRefreshMirrorsGitActivitySnapshotToStandardDefaults() {
        withRestoredStandardDefaults(keys: mirroredGitActivityKeys) {
            let harness = makeHarness()
            harness.setActivitySnapshot(focusBlockCount: 4, commitCount: 7, recentProjectName: "  TinyBuddy  ")

            harness.performAndWaitForRefresh {
                harness.coordinator.handleDidBecomeActive()
            }

            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayFocusBlockCountStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: GitTodayFocusBlockCountStore.Key.count),
                4
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayCommitCountStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: GitTodayCommitCountStore.Key.count),
                7
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayRecentProjectStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayRecentProjectStore.Key.projectName),
                "TinyBuddy"
            )

            harness.setActivitySnapshot(focusBlockCount: nil, commitCount: nil, recentProjectName: nil)
            harness.performAndWaitForWidgetReloadCount(2) {
                harness.coordinator.handleReopen()
            }

            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayFocusBlockCountStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: GitTodayFocusBlockCountStore.Key.count),
                0
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayCommitCountStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: GitTodayCommitCountStore.Key.count),
                0
            )
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: GitTodayRecentProjectStore.Key.dayIdentifier),
                harness.currentDayIdentifier
            )
            XCTAssertNil(
                UserDefaults.standard.string(forKey: GitTodayRecentProjectStore.Key.projectName)
            )
        }
    }

    func testRefreshFailureRecordsFailedStatusWithSummarizedReason() {
        let harness = makeHarness()
        harness.setScriptRunnerHook { _ in
            struct ScriptFailure: LocalizedError {
                var errorDescription: String? {
                    "refresh script exited with status 1:\nfull stderr details"
                }
            }

            throw ScriptFailure()
        }

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 0)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .becameActive,
                outcome: .failed,
                reason: "refresh script exited with status 1:"
            )
        )
    }

    func testStartTriggersLaunchRefreshAndWidgetReload() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
    }

    func testReopenTriggersRefreshAndWidgetReload() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.handleReopen()
        }

        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)
    }

    func testDidWakeNotificationTriggersRefreshAndWidgetReload() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testScreensDidWakeNotificationTriggersRefreshAndWidgetReload() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.screensDidWakeNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testSessionDidBecomeActiveNotificationTriggersRefreshAndWidgetReload() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testWakeNotificationBurstQueuesAtMostOneFollowUpRefresh() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.performAndWaitForWidgetReloadCount(3) {
            harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
            harness.postWorkspaceNotification(named: NSWorkspace.screensDidWakeNotification)
            harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 3)
        XCTAssertEqual(harness.widgetReloadCount, 3)
    }

    func testWakeNotificationDuringRefreshQueuesOneFollowUpRefresh() {
        let harness = makeHarness()
        let allowWakeRefreshToFinish = DispatchSemaphore(value: 0)
        let queuedWakeNotificationPosted = expectation(description: "queued wake notification posted")

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }
        harness.setScriptRunnerHook { runCount in
            guard runCount == 2 else {
                return
            }

            DispatchQueue.main.async {
                harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
                queuedWakeNotificationPosted.fulfill()
            }
            allowWakeRefreshToFinish.wait()
        }

        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        wait(for: [queuedWakeNotificationPosted], timeout: 1.0)
        allowWakeRefreshToFinish.signal()
        harness.waitForWidgetReloadCount(3)

        XCTAssertEqual(harness.scriptRunCount, 3)
        XCTAssertEqual(harness.widgetReloadCount, 3)
    }

    func testWakeNotificationRetriesWhenFirstWakeRefreshCannotStart() {
        let harness = makeHarness()

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        harness.authorizedRoots = []
        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        harness.waitForNoRefresh()
        XCTAssertEqual(harness.scriptRunCount, 1)
        XCTAssertEqual(harness.widgetReloadCount, 1)

        harness.authorizedRoots = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")]
        harness.performAndWaitForWidgetReloadCount(2) {
            harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
        }

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 2)
    }

    func testFailedRefreshDoesNotOverwriteQueuedWakeRefreshStatus() {
        let harness = makeHarness()
        let queuedWakeNotificationPosted = expectation(description: "queued wake notification posted")

        harness.performAndWaitForRefresh {
            harness.coordinator.start()
        }

        harness.setScriptRunnerHook { runCount in
            guard runCount == 2 else {
                return
            }

            DispatchQueue.main.async {
                harness.authorizedRoots = []
                harness.postWorkspaceNotification(named: NSWorkspace.sessionDidBecomeActiveNotification)
                queuedWakeNotificationPosted.fulfill()
            }

            struct ScriptFailure: LocalizedError {
                var errorDescription: String? {
                    "refresh script exited with status 1"
                }
            }

            throw ScriptFailure()
        }

        harness.postWorkspaceNotification(named: NSWorkspace.didWakeNotification)
        wait(for: [queuedWakeNotificationPosted], timeout: 1.0)
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 2)
        XCTAssertEqual(harness.widgetReloadCount, 1)
        XCTAssertEqual(
            harness.lastRefreshStatus,
            GitActivityRefreshStatus(
                refreshedAt: harness.currentDate,
                trigger: .sessionDidBecomeActive,
                outcome: .skipped,
                reason: "no authorized Git scan roots"
            )
        )
    }

    private func makeHarness(
        authorizedRoots: [URL] = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")]
    ) -> RefreshHarness {
        RefreshHarness(testCase: self, authorizedRoots: authorizedRoots)
    }

    private var mirroredGitActivityKeys: [String] {
        [
            GitTodayFocusBlockCountStore.Key.dayIdentifier,
            GitTodayFocusBlockCountStore.Key.count,
            GitTodayCommitCountStore.Key.dayIdentifier,
            GitTodayCommitCountStore.Key.count,
            GitTodayRecentProjectStore.Key.dayIdentifier,
            GitTodayRecentProjectStore.Key.projectName
        ]
    }

    private func withRestoredStandardDefaults(
        keys: [String],
        operation: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let originalValues = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, defaults.object(forKey: key))
        })

        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.synchronize()

        defer {
            for key in keys {
                if let value = originalValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            defaults.synchronize()
        }

        operation()
    }
}

private final class RefreshHarness {
    private let testCase: XCTestCase
    private let state: State
    private let refreshExpectationQueue = DispatchQueue(label: "TinyBuddyTests.RefreshHarness")
    private let workspaceNotificationCenter = NotificationCenter()
    private var pendingRefreshExpectation: XCTestExpectation?
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let activityDefaults: UserDefaults
    private let calendar: Calendar

    let coordinator: GitActivityRefreshCoordinator

    init(testCase: XCTestCase, authorizedRoots: [URL]) {
        self.testCase = testCase
        self.state = State(currentDate: Self.makeDate(second: 0))
        self.state.authorizedRoots = authorizedRoots

        let defaults = UserDefaults(suiteName: "TinyBuddyAppTests.\(UUID().uuidString)")!
        self.activityDefaults = defaults
        self.refreshStatusStore = GitActivityRefreshStatusStore(userDefaults: defaults)
        let calendar = Self.makeCalendar()
        self.calendar = calendar
        let activityStore = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { Self.makeDate(second: 0) },
                sharedFallbacksEnabled: false
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { Self.makeDate(second: 0) },
                sharedFallbacksEnabled: false
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { Self.makeDate(second: 0) },
                sharedFallbacksEnabled: false
            )
        )

        self.coordinator = GitActivityRefreshCoordinator(
            activityStore: activityStore,
            refreshStatusStore: refreshStatusStore,
            refreshInterval: 300,
            minimumRefreshSpacing: 60,
            widgetReloader: { [weak testCase, state] in
                guard testCase != nil else {
                    return
                }

                state.widgetReloadCount += 1
                state.onWidgetReload?(state.widgetReloadCount)
            },
            scriptURLProvider: { URL(fileURLWithPath: "/tmp/tinybuddy-test-refresh.sh") },
            scriptRunner: { [state] _, rootURLs in
                state.scriptRunCount += 1
                state.capturedRootPaths = rootURLs.map(\.standardizedFileURL.path)
                try state.scriptRunnerHook?(state.scriptRunCount)
            },
            authorizedRootsProvider: { [state] in
                state.authorizedRoots.map { url in
                    ScopedGitScanRoot(url: url) {
                        state.stopAccessCount += 1
                    }
                }
            },
            dateProvider: { [state] in
                state.currentDate
            },
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        state.onWidgetReload = { [weak self] _ in
            self?.fulfillPendingRefreshExpectation()
        }
    }

    var scriptRunCount: Int { state.scriptRunCount }
    var widgetReloadCount: Int { state.widgetReloadCount }
    var capturedRootPaths: [String] { state.capturedRootPaths }
    var stopAccessCount: Int { state.stopAccessCount }
    var currentDate: Date { state.currentDate }
    var currentDayIdentifier: String { Self.dayIdentifier(for: currentDate, calendar: calendar) }
    var lastRefreshStatus: GitActivityRefreshStatus? { refreshStatusStore.load() }
    var authorizedRoots: [URL] {
        get { state.authorizedRoots }
        set { state.authorizedRoots = newValue }
    }

    func postWorkspaceNotification(named name: Notification.Name) {
        workspaceNotificationCenter.post(name: name, object: nil)
    }

    func setScriptRunnerHook(_ hook: @escaping (Int) throws -> Void) {
        state.scriptRunnerHook = hook
    }

    func setActivitySnapshot(
        focusBlockCount: Int?,
        commitCount: Int?,
        recentProjectName: String?
    ) {
        let focusStore = GitTodayFocusBlockCountStore(
            userDefaults: activityDefaults,
            calendar: calendar,
            dateProvider: { self.currentDate },
            sharedFallbacksEnabled: false
        )
        let commitStore = GitTodayCommitCountStore(
            userDefaults: activityDefaults,
            calendar: calendar,
            dateProvider: { self.currentDate },
            sharedFallbacksEnabled: false
        )
        let recentProjectStore = GitTodayRecentProjectStore(
            userDefaults: activityDefaults,
            calendar: calendar,
            dateProvider: { self.currentDate },
            sharedFallbacksEnabled: false
        )

        focusStore.saveTodayCount(focusBlockCount ?? 0)
        commitStore.saveTodayCount(commitCount ?? 0)
        recentProjectStore.saveTodayProjectName(recentProjectName)
    }

    func performAndWaitForRefresh(_ action: () -> Void) {
        performAndWaitForWidgetReloadCount(1, action: action)
    }

    func performAndWaitForWidgetReloadCount(_ expectedReloadCount: Int, action: () -> Void) {
        let expectation = testCase.expectation(description: "refresh completed")
        refreshExpectationQueue.sync {
            pendingRefreshExpectation = expectation
            state.expectedWidgetReloadCount = expectedReloadCount
            if state.widgetReloadCount >= expectedReloadCount {
                expectation.fulfill()
                pendingRefreshExpectation = nil
                state.expectedWidgetReloadCount = 0
            }
        }
        action()
        testCase.wait(for: [expectation], timeout: 1.0)
    }

    func waitForWidgetReloadCount(_ expectedReloadCount: Int) {
        let expectation = testCase.expectation(description: "refresh count \(expectedReloadCount)")
        refreshExpectationQueue.sync {
            pendingRefreshExpectation = expectation
            state.expectedWidgetReloadCount = expectedReloadCount
            if state.widgetReloadCount >= expectedReloadCount {
                expectation.fulfill()
                pendingRefreshExpectation = nil
                state.expectedWidgetReloadCount = 0
            }
        }
        testCase.wait(for: [expectation], timeout: 1.0)
    }

    func waitForNoRefresh() {
        let expectation = testCase.expectation(description: "no refresh completed")
        expectation.isInverted = true
        state.onWidgetReload = { _ in
            expectation.fulfill()
        }
        testCase.wait(for: [expectation], timeout: 0.2)
        state.onWidgetReload = { [weak self] _ in
            self?.fulfillPendingRefreshExpectation()
        }
    }

    private func fulfillPendingRefreshExpectation() {
        refreshExpectationQueue.sync {
            guard let expectation = pendingRefreshExpectation else {
                return
            }

            guard state.widgetReloadCount >= state.expectedWidgetReloadCount else {
                return
            }

            expectation.fulfill()
            pendingRefreshExpectation = nil
            state.expectedWidgetReloadCount = 0
        }
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func makeDate(second: Int) -> Date {
        var components = DateComponents()
        components.calendar = makeCalendar()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 7
        components.day = 2
        components.hour = 12
        components.minute = 0
        components.second = second
        return components.date!
    }

    private static func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private final class State {
        var currentDate: Date
        var authorizedRoots: [URL] = []
        var capturedRootPaths: [String] = []
        var scriptRunCount = 0
        var widgetReloadCount = 0
        var stopAccessCount = 0
        var expectedWidgetReloadCount = 0
        var onWidgetReload: ((Int) -> Void)?
        var scriptRunnerHook: ((Int) throws -> Void)?

        init(currentDate: Date) {
            self.currentDate = currentDate
        }
    }
}
