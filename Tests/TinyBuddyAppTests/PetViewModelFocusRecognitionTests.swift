import AppKit
import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

// MARK: - Fakes

private final class RecognitionAppFakeClock: FocusClock, @unchecked Sendable {
    private var _now: Date
    var now: Date { _now }
    var monotonic: TimeInterval { _now.timeIntervalSinceReferenceDate }

    init(_ date: Date) {
        _now = date
    }

    func advance(by seconds: TimeInterval) {
        _now = _now.addingTimeInterval(seconds)
    }
}

private final class RecognitionAppMemoryStore: FocusSessionPersisting, @unchecked Sendable {
    private var data: [FocusSession] = []

    func load() -> [FocusSession]? { data }

    @discardableResult
    func save(_ sessions: [FocusSession]) -> Bool {
        data = sessions
        return true
    }
}

// MARK: - Harness

private struct RecognitionHarness {
    let viewModel: PetViewModel
    let engine: FocusSessionEngine
    let clock: RecognitionAppFakeClock
}

@MainActor
private func makeRecognitionHarness(
    confirmationMinimumActiveDuration: TimeInterval = 120
) -> RecognitionHarness {
    let suiteName = "TinyBuddyRecognitionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = Date(timeIntervalSinceReferenceDate: 2_000_000)
    let clock = RecognitionAppFakeClock(today)
    let store = DailyStatsStore(
        userDefaults: defaults,
        calendar: calendar,
        dateProvider: { today }
    )
    let engine = FocusSessionEngine(
        clock: clock,
        persisting: RecognitionAppMemoryStore(),
        config: FocusSessionConfiguration(
            confirmationWindow: 300,
            confirmationMinimumActiveDuration: confirmationMinimumActiveDuration
        ),
        dayIdentifier: { recDay(for: $0) },
        nextDayBoundary: { date in
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        }
    )
    let viewModel = PetViewModel(
        store: store,
        activityStore: GitTodayActivityStore(
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
        ),
        combinedSnapshotStore: store.makeCombinedSnapshotStore(),
        refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
        notificationCenter: NotificationCenter(),
        timeEnvironment: TinyBuddyTimeEnvironment(calendar: calendar, dateProvider: { today }),
        widgetReloader: {}
    )
    viewModel.setFocusSessionEngine(engine)
    return RecognitionHarness(viewModel: viewModel, engine: engine, clock: clock)
}

private func recDay(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

// MARK: - Tests

/// The HUD publishes the automatic-focus recognition explanation on demand,
/// derived from the engine's live gate state and committed decision evidence.
@MainActor
final class PetViewModelFocusRecognitionTests: XCTestCase {
    private let projectA = FocusProjectContext(key: "repo/a", displayName: "Project A")

    func testOnDemandRefreshPublishesRecognizingExplanation() {
        let harness = makeRecognitionHarness(confirmationMinimumActiveDuration: 120)
        XCTAssertNil(harness.viewModel.focusRecognitionExplanation)

        // One activity event: gate tracks, nothing confirmed yet.
        _ = harness.engine.userActivity(in: projectA, at: harness.clock.now)

        harness.viewModel.refreshFocusRecognitionExplanation()

        let explanation = harness.viewModel.focusRecognitionExplanation
        XCTAssertNotNil(explanation)
        XCTAssertEqual(explanation?.posture, .recognizing)
        XCTAssertEqual(explanation?.title, "正在识别")
        XCTAssertTrue(explanation?.detail.contains("Project A") ?? false)
    }

    func testOnDemandRefreshPublishesConfirmedExplanationAfterGateConfirms() {
        let harness = makeRecognitionHarness(confirmationMinimumActiveDuration: 120)

        _ = harness.engine.userActivity(in: projectA, at: harness.clock.now)
        harness.clock.advance(by: 60)
        _ = harness.engine.userActivity(in: projectA, at: harness.clock.now)
        harness.clock.advance(by: 60)
        _ = harness.engine.userActivity(in: projectA, at: harness.clock.now)

        harness.viewModel.refreshFocusRecognitionExplanation()

        let explanation = harness.viewModel.focusRecognitionExplanation
        XCTAssertEqual(explanation?.posture, .confirmed)
        XCTAssertEqual(explanation?.title, "已确认专注")
        XCTAssertTrue(explanation?.detail.contains("Project A") ?? false)
        // The most recent key judgment is the confirmation start.
        XCTAssertEqual(explanation?.lastDecision?.kind, .started)
    }

    func testRefreshClearsExplanationWhenEngineIsRemoved() {
        let harness = makeRecognitionHarness()
        harness.viewModel.refreshFocusRecognitionExplanation()
        XCTAssertEqual(harness.viewModel.focusRecognitionExplanation?.posture, .notEntered)

        harness.viewModel.setFocusSessionEngine(nil)
        harness.viewModel.refreshFocusRecognitionExplanation()
        XCTAssertNil(harness.viewModel.focusRecognitionExplanation)
    }

    /// The published explanation must never change engine behavior: the
    /// on-demand read leaves the gate and sessions untouched.
    func testOnDemandRefreshIsPureRead() {
        let harness = makeRecognitionHarness()
        _ = harness.engine.userActivity(in: projectA, at: harness.clock.now)
        let gateBefore = harness.engine.confirmationGateSnapshot
        let sessionsBefore = harness.engine.allSessions.count

        harness.viewModel.refreshFocusRecognitionExplanation()

        XCTAssertEqual(harness.engine.confirmationGateSnapshot, gateBefore)
        XCTAssertEqual(harness.engine.allSessions.count, sessionsBefore)
        XCTAssertEqual(harness.engine.currentProject, nil)
    }
}
