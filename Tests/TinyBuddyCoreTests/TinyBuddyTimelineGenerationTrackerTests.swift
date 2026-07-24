import XCTest
@testable import TinyBuddyCore

final class TinyBuddyTimelineGenerationTrackerTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let defaultsSuiteName = "test.timeline.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
        userDefaults = nil
        super.tearDown()
    }

    func testCurrentGenerationWhenNoGenerationStored() {
        XCTAssertEqual(
            TinyBuddyTimelineGenerationTracker.currentGeneration(userDefaults: userDefaults),
            0,
            "Should return 0 when no generation has been recorded"
        )
    }

    func testAdvanceGenerationIncrementsFromZero() {
        let gen = TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        XCTAssertEqual(gen, 1, "First advance should return 1")
        XCTAssertEqual(
            TinyBuddyTimelineGenerationTracker.currentGeneration(userDefaults: userDefaults),
            1,
            "Stored generation should match returned value"
        )
    }

    func testAdvanceGenerationIsMonotonic() {
        let gen1 = TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        let gen2 = TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        let gen3 = TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)

        XCTAssertEqual(gen1, 1)
        XCTAssertEqual(gen2, 2)
        XCTAssertEqual(gen3, 3)
        XCTAssertEqual(
            TinyBuddyTimelineGenerationTracker.currentGeneration(userDefaults: userDefaults),
            3
        )
    }

    func testCurrentGenerationTimestampIsMonotonic() {
        let t1 = TinyBuddyTimelineGenerationTracker.currentGenerationTimestamp(
            userDefaults: userDefaults
        )
        XCTAssertEqual(t1, .distantPast, "Initial timestamp should be distantPast")

        TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        let t2 = TinyBuddyTimelineGenerationTracker.currentGenerationTimestamp(
            userDefaults: userDefaults
        )
        XCTAssertGreaterThan(t2, t1, "Timestamp should advance after first generation")
        XCTAssertGreaterThan(t2, .distantPast)

        Thread.sleep(forTimeInterval: 0.1)
        TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        let t3 = TinyBuddyTimelineGenerationTracker.currentGenerationTimestamp(
            userDefaults: userDefaults
        )
        XCTAssertGreaterThan(t3, t2, "Timestamp should advance on each generation")
    }

    func testIsSnapshotCurrentWhenNoGenerations() {
        XCTAssertTrue(
            TinyBuddyTimelineGenerationTracker.isSnapshotCurrent(
                snapshotGeneration: 0,
                userDefaults: userDefaults
            )
        )
    }

    func testIsSnapshotCurrentWithAdvancedGeneration() {
        TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        XCTAssertFalse(
            TinyBuddyTimelineGenerationTracker.isSnapshotCurrent(
                snapshotGeneration: 0,
                userDefaults: userDefaults
            )
        )
        XCTAssertTrue(
            TinyBuddyTimelineGenerationTracker.isSnapshotCurrent(
                snapshotGeneration: 1,
                userDefaults: userDefaults
            )
        )
        XCTAssertTrue(
            TinyBuddyTimelineGenerationTracker.isSnapshotCurrent(
                snapshotGeneration: 2,
                userDefaults: userDefaults
            )
        )
    }

    func testResetForTestingRemovesAllKeys() {
        TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)

        XCTAssertEqual(
            TinyBuddyTimelineGenerationTracker.currentGeneration(userDefaults: userDefaults),
            2
        )

        TinyBuddyTimelineGenerationTracker.resetForTesting(userDefaults: userDefaults)

        XCTAssertEqual(
            TinyBuddyTimelineGenerationTracker.currentGeneration(userDefaults: userDefaults),
            0
        )
        XCTAssertEqual(
            TinyBuddyTimelineGenerationTracker.currentGenerationTimestamp(userDefaults: userDefaults),
            .distantPast
        )
    }

    func testAdvanceGenerationStoresTimestamp() {
        let before = Date.timeIntervalSinceReferenceDate
        _ = TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        let after = Date.timeIntervalSinceReferenceDate

        let stored = TinyBuddyTimelineGenerationTracker.currentGenerationTimestamp(
            userDefaults: userDefaults
        )
        XCTAssertGreaterThanOrEqual(stored.timeIntervalSinceReferenceDate, before)
        XCTAssertLessThanOrEqual(stored.timeIntervalSinceReferenceDate, after)
    }

    func testMultipleAdvanceCallsAcrossSuites() {
        let otherDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)
        TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: otherDefaults)
        TinyBuddyTimelineGenerationTracker.advanceGeneration(userDefaults: userDefaults)

        XCTAssertEqual(
            TinyBuddyTimelineGenerationTracker.currentGeneration(userDefaults: userDefaults),
            3
        )
        XCTAssertEqual(
            TinyBuddyTimelineGenerationTracker.currentGeneration(userDefaults: otherDefaults),
            3
        )
    }
}
