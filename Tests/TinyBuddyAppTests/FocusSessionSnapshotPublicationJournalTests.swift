import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class FocusSessionSnapshotPublicationJournalTests: XCTestCase {
    func testPendingPublicationSurvivesRestartAndClearsOnlyMatchingSnapshot() {
        let suiteName = "TinyBuddyAppTests.FocusSessionJournal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = FocusSessionDerivedSnapshot(
            revision: 12,
            dayIdentifier: "2026-07-21",
            focusDuration: 900,
            projectDurations: ["Project": 900],
            completedSessionCount: 1
        )
        let journal = FocusSessionSnapshotPublicationJournal(defaults: defaults)
        XCTAssertTrue(journal.stage(snapshot))

        let restarted = FocusSessionSnapshotPublicationJournal(defaults: defaults)
        XCTAssertEqual(restarted.pending, snapshot)
        let stale = FocusSessionDerivedSnapshot(
            revision: 11,
            dayIdentifier: snapshot.dayIdentifier,
            focusDuration: snapshot.focusDuration,
            projectDurations: snapshot.projectDurations,
            completedSessionCount: snapshot.completedSessionCount
        )
        XCTAssertFalse(restarted.clear(expected: stale))
        XCTAssertEqual(restarted.pending, snapshot)
        XCTAssertTrue(restarted.clear(expected: snapshot))
        XCTAssertNil(restarted.pending)
    }

    func testHistoryPublicationPreservesNewerRevisionAcrossDelayedCallbackAndRestart() {
        let suiteName = "TinyBuddyAppTests.FocusHistoryJournal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let older = historyPublication(revision: 7, goalMinutes: 60)
        let newer = historyPublication(revision: 8, goalMinutes: 60)
        let refreshedGoal = historyPublication(revision: 8, goalMinutes: 90)
        let journal = FocusSessionSnapshotPublicationJournal(defaults: defaults)

        XCTAssertEqual(journal.stage(newer), .staged)
        XCTAssertEqual(journal.stage(older), .rejectedStale)
        XCTAssertEqual(journal.pendingHistory, newer)

        // A configuration refresh shares the same session-archive revision,
        // so it is allowed to replace an equal-revision pending publication.
        XCTAssertEqual(journal.stage(refreshedGoal), .staged)
        let restarted = FocusSessionSnapshotPublicationJournal(defaults: defaults)
        XCTAssertEqual(restarted.pendingHistory, refreshedGoal)
        XCTAssertFalse(restarted.clear(expected: newer))
        XCTAssertTrue(restarted.clear(expected: refreshedGoal))
        XCTAssertNil(restarted.pendingHistory)
    }

    private func historyPublication(
        revision: Int64,
        goalMinutes: Int
    ) -> FocusHistoryPublication {
        let day = FocusHistoryDay(
            dayIdentifier: "2026-07-21",
            state: .sessions,
            focusDuration: 3_600,
            completedSessionCount: 1,
            goalMinutes: goalMinutes,
            goalCompletionRate: min(1, 60.0 / Double(goalMinutes)),
            isGoalMet: goalMinutes <= 60
        )
        return FocusHistoryPublication(
            revision: revision,
            snapshot: FocusHistorySnapshot(
                state: .available,
                sourceHealth: .available,
                recentDays: [day],
                currentWeek: FocusHistoryWeek(
                    startDayIdentifier: "2026-07-21",
                    endDayIdentifier: "2026-07-21",
                    state: .available,
                    focusDuration: 3_600,
                    completedSessionCount: 1,
                    goalCompletionRate: day.goalCompletionRate,
                    goalMetDayCount: day.isGoalMet == true ? 1 : 0,
                    configuredGoalDayCount: 1,
                    projectDistribution: []
                ),
                currentGoalStreakDays: day.isGoalMet == true ? 1 : 0
            )
        )
    }
}
