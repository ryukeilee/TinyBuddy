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
}
