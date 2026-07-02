import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class GitActivityRefreshCoordinatorTests: XCTestCase {
    func testRefreshSkipsScriptWhenNoGitScanRootsAreAuthorized() {
        let harness = makeHarness(authorizedRoots: [])

        harness.coordinator.handleDidBecomeActive()
        harness.waitForNoRefresh()

        XCTAssertEqual(harness.scriptRunCount, 0)
        XCTAssertEqual(harness.widgetReloadCount, 0)
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

    private func makeHarness(
        authorizedRoots: [URL] = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")]
    ) -> RefreshHarness {
        RefreshHarness(testCase: self, authorizedRoots: authorizedRoots)
    }
}

private final class RefreshHarness {
    private let testCase: XCTestCase
    private let state: State
    private let refreshExpectationQueue = DispatchQueue(label: "TinyBuddyTests.RefreshHarness")
    private var pendingRefreshExpectation: XCTestExpectation?

    let coordinator: GitActivityRefreshCoordinator

    init(testCase: XCTestCase, authorizedRoots: [URL]) {
        self.testCase = testCase
        self.state = State(currentDate: Self.makeDate(second: 0))
        self.state.authorizedRoots = authorizedRoots

        let defaults = UserDefaults(suiteName: "TinyBuddyAppTests.\(UUID().uuidString)")!
        let calendar = Self.makeCalendar()
        let activityStore = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { Self.makeDate(second: 0) }
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { Self.makeDate(second: 0) }
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { Self.makeDate(second: 0) }
            )
        )

        self.coordinator = GitActivityRefreshCoordinator(
            activityStore: activityStore,
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
            }
        )
        state.onWidgetReload = { [weak self] _ in
            self?.fulfillPendingRefreshExpectation()
        }
    }

    var scriptRunCount: Int { state.scriptRunCount }
    var widgetReloadCount: Int { state.widgetReloadCount }
    var capturedRootPaths: [String] { state.capturedRootPaths }
    var stopAccessCount: Int { state.stopAccessCount }

    func performAndWaitForRefresh(_ action: () -> Void) {
        let expectation = testCase.expectation(description: "refresh completed")
        refreshExpectationQueue.sync {
            pendingRefreshExpectation = expectation
        }
        action()
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
            pendingRefreshExpectation?.fulfill()
            pendingRefreshExpectation = nil
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

    private final class State {
        var currentDate: Date
        var authorizedRoots: [URL] = []
        var capturedRootPaths: [String] = []
        var scriptRunCount = 0
        var widgetReloadCount = 0
        var stopAccessCount = 0
        var onWidgetReload: ((Int) -> Void)?

        init(currentDate: Date) {
            self.currentDate = currentDate
        }
    }
}
