import XCTest
@testable import TinyBuddyCore

/// Tests that the widget display presentation handles every data scenario
/// without crashing or producing undefined visual states.
final class WidgetFallbackRenderingTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var store: TinyBuddyCombinedSnapshotStore!
    private let defaultsSuiteName = "test.fallback.\(UUID().uuidString)"
    private let dayIdentifier = "2026-07-24"
    private let staleDayIdentifier = "2026-07-23"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        store = TinyBuddyCombinedSnapshotStore(
            userDefaults: userDefaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil,
            repairOnLoad: false
        )
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        userDefaults = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSnapshot(dayIdentifier: String, focusCount: Int = 5, completionCount: Int = 3) -> TinyBuddySnapshot {
        TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: dayIdentifier, focusCount: focusCount, completionCount: completionCount)
        )
    }

    private func makeActivity(focusBlocks: Int? = nil, commits: Int? = nil, project: String? = nil) -> GitTodayActivitySnapshot {
        GitTodayActivitySnapshot(focusBlockCount: focusBlocks, commitCount: commits, recentProjectName: project)
    }

    private func verifyPresentation(
        _ presentation: TinyBuddyDisplayPresentation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(presentation.statusTitle.isEmpty, "statusTitle must not be empty", file: file, line: line)
        XCTAssertFalse(presentation.systemImage.isEmpty, "systemImage must not be empty", file: file, line: line)
        XCTAssertGreaterThanOrEqual(presentation.focusCount, 0, "focusCount must be >= 0", file: file, line: line)
        XCTAssertGreaterThanOrEqual(presentation.completionCount, 0, "completionCount must be >= 0", file: file, line: line)
        XCTAssertFalse(presentation.focusCountText.isEmpty, "focusCountText must not be empty", file: file, line: line)
        XCTAssertFalse(presentation.completionCountText.isEmpty, "completionCountText must not be empty", file: file, line: line)
    }

    // MARK: - Available data

    func testPresentationWhenDataIsAvailable() {
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: makeSnapshot(dayIdentifier: dayIdentifier, focusCount: 5, completionCount: 3),
            activitySnapshot: makeActivity(focusBlocks: 12, commits: 15, project: "TinyBuddy")
        )
        verifyPresentation(presentation)
        XCTAssertEqual(presentation.focusCount, 12, "focusCount should come from activity.focusBlockCount")
        XCTAssertEqual(presentation.completionCount, 15, "completionCount should come from activity.commitCount")
        XCTAssertNotNil(presentation.recentProjectName)
        XCTAssertNotNil(presentation.dataDateText)
    }

    // MARK: - Stale data

    func testPresentationWithStaleData() {
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: makeSnapshot(dayIdentifier: dayIdentifier),
            activitySnapshot: makeActivity(focusBlocks: 3, commits: 1, project: "OldProject"),
            refreshStatus: nil,
            dataAvailability: .stale,
            onboardingCompleted: true,
            locale: Locale(identifier: "zh_CN"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        verifyPresentation(presentation)
        XCTAssertNotNil(presentation.dataDateText)
    }

    // MARK: - Loading data

    func testPresentationWhenDataIsLoading() {
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: makeSnapshot(dayIdentifier: dayIdentifier),
            activitySnapshot: makeActivity(),
            refreshStatus: nil,
            dataAvailability: .loading,
            onboardingCompleted: true,
            locale: Locale(identifier: "zh_CN"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        verifyPresentation(presentation)
    }

    // MARK: - Failed data

    func testPresentationWhenDataIsFailed() {
        let reason = TinyBuddySharedSnapshotReason.snapshotCorrupt
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: makeSnapshot(dayIdentifier: dayIdentifier),
            activitySnapshot: makeActivity(),
            refreshStatus: nil,
            dataAvailability: .failed(reason),
            onboardingCompleted: true,
            locale: Locale(identifier: "zh_CN"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        verifyPresentation(presentation)
    }

    // MARK: - Neutral (empty) data

    func testPresentationWhenDataIsNeutral() {
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: makeSnapshot(dayIdentifier: dayIdentifier),
            activitySnapshot: makeActivity(focusBlocks: 0, commits: 0, project: nil)
        )
        verifyPresentation(presentation)
        XCTAssertEqual(presentation.focusCount, 0)
        XCTAssertEqual(presentation.completionCount, 0)
        XCTAssertNil(presentation.recentProjectName)
        XCTAssertEqual(presentation.focusCountText, "0")
        XCTAssertEqual(presentation.completionCountText, "0")
    }

    // MARK: - No snapshot at all (nil combined read)

    func testPresentationWhenNoSnapshotExists() {
        let read = store.readValidated()
        XCTAssertNil(read.snapshot)
        let dataAvailability = TinyBuddyDisplayDataAvailability(observation: read.observation, hasSnapshot: false)
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: dayIdentifier, focusCount: 0, completionCount: 0)),
            activitySnapshot: makeActivity(focusBlocks: nil, commits: nil),
            refreshStatus: nil,
            dataAvailability: dataAvailability,
            onboardingCompleted: true,
            locale: Locale(identifier: "zh_CN"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        verifyPresentation(presentation)
    }

    // MARK: - Large numbers via activity (focus blocks/commits)

    func testPresentationWithLargeNumbers() {
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: makeSnapshot(dayIdentifier: dayIdentifier),
            activitySnapshot: makeActivity(focusBlocks: 999, commits: 888, project: "VeryLongProjectNameThatCouldOverflowTheLayout")
        )
        verifyPresentation(presentation)
        XCTAssertEqual(presentation.focusCount, 999, "focusCount from activity.focusBlockCount")
        XCTAssertEqual(presentation.completionCount, 888, "completionCount from activity.commitCount")
        XCTAssertFalse(presentation.focusCountText.isEmpty)
        XCTAssertFalse(presentation.completionCountText.isEmpty)
    }

    // MARK: - Partial activity data

    func testPresentationWithPartialActivityData() {
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: makeSnapshot(dayIdentifier: dayIdentifier),
            activitySnapshot: makeActivity(focusBlocks: nil, commits: 3, project: nil)
        )
        verifyPresentation(presentation)
        // When focusBlockCount is nil, focusCount should be 0
        XCTAssertEqual(presentation.focusCount, 0)
        XCTAssertEqual(presentation.completionCount, 3)
        XCTAssertNil(presentation.recentProjectName)
    }

    // MARK: - Onboarding not completed

    func testPresentationWhenOnboardingNotCompleted() {
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: makeSnapshot(dayIdentifier: dayIdentifier),
            activitySnapshot: makeActivity(),
            refreshStatus: nil,
            dataAvailability: .available,
            onboardingCompleted: false,
            locale: Locale(identifier: "zh_CN"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        verifyPresentation(presentation)
    }

    // MARK: - Focusing state

    func testPresentationWhenStatusIsFocusing() {
        let activity = makeActivity(focusBlocks: 1, commits: 0)
        let presentation = TinyBuddyDisplayPresentation(
            snapshot: TinyBuddySnapshot(status: .focusing, stats: DailyStats(dayIdentifier: dayIdentifier, focusCount: 1, completionCount: 0)),
            activitySnapshot: activity
        )
        verifyPresentation(presentation)
        XCTAssertFalse(presentation.statusTitle.lowercased().contains("idle"), "Focusing status should not show idle title")
    }
}
