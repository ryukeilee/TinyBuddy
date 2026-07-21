import XCTest
@testable import TinyBuddyCore

final class FocusHistoryAggregationTests: XCTestCase {
    func testRecentAndISOWeekUsePersistedDayAndEndedElapsedDuration() throws {
        let project = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        let springForwardStart = try date("2026-03-08T09:30:00Z") // 01:30 PST
        let springForwardEnd = try date("2026-03-08T10:30:00Z") // 03:30 PDT, one elapsed hour
        let ended = session(project: project, day: "2026-03-08", start: springForwardStart, end: springForwardEnd)
        let active = FocusSession(
            project: project,
            dayIdentifier: "2026-03-08",
            startedAt: springForwardStart,
            status: .active,
            lastUserActivityAt: springForwardStart,
            lastStateChangeAt: springForwardStart
        )
        let cache = FocusHistoryAggregationCache(sessions: [ended, active])
        let snapshot = try cache.snapshot(for: query(reference: "2026-03-08", goals: ["2026-03-08": 30]))

        XCTAssertEqual(snapshot.currentWeek.startDayIdentifier, "2026-03-02")
        XCTAssertEqual(snapshot.currentWeek.endDayIdentifier, "2026-03-08")
        XCTAssertEqual(snapshot.currentWeek.focusDuration ?? -1, 3_600, accuracy: 0.001)
        XCTAssertEqual(snapshot.currentWeek.completedSessionCount, 1)
        XCTAssertEqual(snapshot.recentDays.last?.focusDuration ?? -1, 3_600, accuracy: 0.001)
        XCTAssertEqual(snapshot.recentDays.last?.isGoalMet, true)
    }

    func testTrustedNoSessionsIsZeroButPartialUnknownIsNil() throws {
        let cache = FocusHistoryAggregationCache()
        let available = try cache.snapshot(for: query(reference: "2026-07-21"))
        XCTAssertEqual(available.state, .noHistory)
        XCTAssertEqual(available.recentDays.last?.state, .noSessions)
        XCTAssertEqual(available.recentDays.last?.focusDuration, 0)
        XCTAssertEqual(available.currentWeek.focusDuration, 0)

        let partial = FocusHistorySource(health: .partial, trustedDayIdentifiers: ["2026-07-21"])
        let incomplete = try cache.snapshot(for: FocusHistoryQuery(
            referenceDayIdentifier: "2026-07-21",
            source: partial,
            activeProjectKeys: []
        ))
        XCTAssertEqual(incomplete.state, .partial)
        XCTAssertEqual(incomplete.recentDays.last?.state, .noSessions)
        XCTAssertEqual(incomplete.recentDays.first?.state, .unknown)
        XCTAssertNil(incomplete.recentDays.first?.focusDuration)
        XCTAssertEqual(incomplete.currentWeek.state, .partial)
        XCTAssertNil(incomplete.currentWeek.focusDuration)

        let unavailable = try cache.snapshot(for: FocusHistoryQuery(
            referenceDayIdentifier: "2026-07-21",
            source: FocusHistorySource(health: .unavailable),
            activeProjectKeys: []
        ))
        XCTAssertEqual(unavailable.state, .unknown)
        XCTAssertEqual(unavailable.recentDays.last?.state, .unknown)
        XCTAssertNil(unavailable.recentDays.last?.completedSessionCount)
    }

    func testIncrementalReplacementInvalidatesOldAndNewDaysWithoutRescanning() throws {
        let alpha = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        let beta = FocusProjectContext(key: "repo.beta", displayName: "Beta")
        let old = session(project: alpha, day: "2026-07-20", start: try date("2026-07-20T01:00:00Z"), end: try date("2026-07-20T01:20:00Z"))
        var cache = FocusHistoryAggregationCache(sessions: [old])
        var replacement = session(project: beta, day: "2026-07-21", start: try date("2026-07-21T01:00:00Z"), end: try date("2026-07-21T01:45:00Z"), id: old.id)
        replacement.isManuallyConfirmed = true

        let update = cache.replace(previous: old, current: replacement)
        XCTAssertEqual(update.affectedDayIdentifiers, ["2026-07-20", "2026-07-21"])
        let snapshot = try cache.snapshot(for: query(reference: "2026-07-21", activeKeys: ["repo.beta"]))
        XCTAssertEqual(snapshot.recentDays.dropLast().last?.focusDuration, 0)
        XCTAssertEqual(snapshot.recentDays.last?.focusDuration ?? -1, 2_700, accuracy: 0.001)
        XCTAssertEqual(snapshot.currentWeek.completedSessionCount, 1)
        XCTAssertEqual(snapshot.currentWeek.projectDistribution?.map(\.displayName), ["Beta"])
        XCTAssertEqual(snapshot.currentWeek.projectDistribution?.first?.isHistoricalArchive, false)
    }

    func testCurrentWeekStartsOnMondayAndExcludesFutureDays() throws {
        let project = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        let sunday = session(project: project, day: "2026-07-19", start: try date("2026-07-19T01:00:00Z"), end: try date("2026-07-19T02:00:00Z"))
        let monday = session(project: project, day: "2026-07-20", start: try date("2026-07-20T01:00:00Z"), end: try date("2026-07-20T01:30:00Z"))
        let cache = FocusHistoryAggregationCache(sessions: [sunday, monday])
        let snapshot = try cache.snapshot(for: query(reference: "2026-07-21"))

        XCTAssertEqual(snapshot.currentWeek.startDayIdentifier, "2026-07-20")
        XCTAssertEqual(snapshot.currentWeek.endDayIdentifier, "2026-07-21")
        XCTAssertEqual(snapshot.currentWeek.focusDuration ?? -1, 1_800, accuracy: 0.001)
        XCTAssertEqual(snapshot.currentWeek.completedSessionCount, 1)
        XCTAssertEqual(snapshot.recentDays.first?.dayIdentifier, "2026-07-15")
        XCTAssertEqual(snapshot.recentDays.last?.dayIdentifier, "2026-07-21")
    }

    func testCrossDaySegmentsConserveElapsedTimeAndCrossWeekBoundary() throws {
        let project = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        let sunday = session(
            project: project,
            day: "2026-07-19",
            start: try date("2026-07-19T23:50:00Z"),
            end: try date("2026-07-20T00:00:00Z")
        )
        let monday = session(
            project: project,
            day: "2026-07-20",
            start: try date("2026-07-20T00:00:00Z"),
            end: try date("2026-07-20T00:20:00Z")
        )
        let cache = FocusHistoryAggregationCache(sessions: [sunday, monday])
        let snapshot = try cache.snapshot(for: query(reference: "2026-07-20"))

        XCTAssertEqual(snapshot.recentDays.last?.focusDuration ?? -1, 1_200, accuracy: 0.001)
        XCTAssertEqual(snapshot.currentWeek.focusDuration ?? -1, 1_200, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.recentDays.suffix(2).compactMap(\.focusDuration).reduce(0, +),
            1_800,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.currentWeek.completedSessionCount, 1)
    }

    func testPersistedLocalDayDoesNotDriftWhenViewingTimeZoneChanges() throws {
        let project = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        // 01:00 UTC would be the prior civil date in Los Angeles, but the
        // session was confirmed under the persisted July-20 local-day label.
        let confirmed = session(
            project: project,
            day: "2026-07-20",
            start: try date("2026-07-20T01:00:00Z"),
            end: try date("2026-07-20T01:30:00Z")
        )
        let cache = FocusHistoryAggregationCache(sessions: [confirmed])
        let snapshot = try cache.snapshot(for: query(reference: "2026-07-20"))

        XCTAssertEqual(snapshot.recentDays.last?.dayIdentifier, "2026-07-20")
        XCTAssertEqual(snapshot.recentDays.last?.focusDuration ?? -1, 1_800, accuracy: 0.001)
        XCTAssertEqual(snapshot.currentWeek.completedSessionCount, 1)
    }

    func testSplitMergeAndDeleteOnlyInvalidateChangedDayAndPreserveOtherDays() throws {
        let project = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        let stable = session(
            project: project,
            day: "2026-07-19",
            start: try date("2026-07-19T01:00:00Z"),
            end: try date("2026-07-19T01:30:00Z")
        )
        let original = session(
            project: project,
            day: "2026-07-20",
            start: try date("2026-07-20T01:00:00Z"),
            end: try date("2026-07-20T02:00:00Z")
        )
        var first = session(
            project: project,
            day: "2026-07-20",
            start: try date("2026-07-20T01:00:00Z"),
            end: try date("2026-07-20T01:30:00Z"),
            id: original.id
        )
        let second = session(
            project: project,
            day: "2026-07-20",
            start: try date("2026-07-20T01:30:00Z"),
            end: try date("2026-07-20T02:00:00Z")
        )
        first.isManuallyConfirmed = true
        var cache = FocusHistoryAggregationCache(sessions: [stable, original])

        let split = cache.apply([
            FocusHistorySessionChange(previous: original, current: first),
            FocusHistorySessionChange(previous: nil, current: second)
        ])
        XCTAssertEqual(split.affectedDayIdentifiers, ["2026-07-20"])
        var snapshot = try cache.snapshot(for: query(reference: "2026-07-20"))
        XCTAssertEqual(snapshot.recentDays.last?.focusDuration ?? -1, 3_600, accuracy: 0.001)
        XCTAssertEqual(snapshot.recentDays.last?.completedSessionCount, 2)
        XCTAssertEqual(snapshot.recentDays.dropLast().last?.focusDuration ?? -1, 1_800, accuracy: 0.001)

        let delete = cache.replace(previous: second, current: nil)
        XCTAssertEqual(delete.affectedDayIdentifiers, ["2026-07-20"])
        snapshot = try cache.snapshot(for: query(reference: "2026-07-20"))
        XCTAssertEqual(snapshot.recentDays.last?.focusDuration ?? -1, 1_800, accuracy: 0.001)
        XCTAssertEqual(snapshot.recentDays.last?.completedSessionCount, 1)
        XCTAssertEqual(snapshot.recentDays.dropLast().last?.focusDuration ?? -1, 1_800, accuracy: 0.001)
    }

    func testProjectArchiveGoalsAndStreakBreakOnMissedDay() throws {
        let alpha = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        let deleted = FocusProjectContext(key: "repo.deleted", displayName: "Old Project")
        let monday = session(project: alpha, day: "2026-07-20", start: try date("2026-07-20T01:00:00Z"), end: try date("2026-07-20T01:40:00Z"))
        let tuesday = session(project: deleted, day: "2026-07-21", start: try date("2026-07-21T01:00:00Z"), end: try date("2026-07-21T01:20:00Z"))
        let cache = FocusHistoryAggregationCache(sessions: [monday, tuesday])
        let snapshot = try cache.snapshot(for: query(
            reference: "2026-07-21",
            goals: ["2026-07-20": 30, "2026-07-21": 30],
            activeKeys: ["repo.alpha"]
        ))

        XCTAssertEqual(snapshot.currentWeek.goalCompletionRate, 1)
        XCTAssertEqual(snapshot.currentWeek.goalMetDayCount, 1)
        XCTAssertEqual(snapshot.currentGoalStreakDays, 0)
        XCTAssertEqual(snapshot.currentWeek.projectDistribution?.count, 2)
        XCTAssertEqual(snapshot.currentWeek.projectDistribution?.first(where: { $0.displayName == "Old Project" })?.isHistoricalArchive, true)
    }

    func testProjectStatusIsUnknownWithoutAnAuthoritativeRegistry() throws {
        let project = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        let ended = session(
            project: project,
            day: "2026-07-21",
            start: try date("2026-07-21T01:00:00Z"),
            end: try date("2026-07-21T01:30:00Z")
        )
        let cache = FocusHistoryAggregationCache(sessions: [ended])
        let snapshot = try cache.snapshot(for: FocusHistoryQuery(
            referenceDayIdentifier: "2026-07-21",
            source: FocusHistorySource(health: .available)
        ))

        XCTAssertNil(snapshot.currentWeek.projectDistribution?.first?.isHistoricalArchive)
    }

    func testStreakIsUnknownWhenEarlierRequiredDayIsNotTrusted() throws {
        let project = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
        let session = session(project: project, day: "2026-07-21", start: try date("2026-07-21T01:00:00Z"), end: try date("2026-07-21T01:30:00Z"))
        let cache = FocusHistoryAggregationCache(sessions: [session])
        let source = FocusHistorySource(health: .partial, trustedDayIdentifiers: ["2026-07-21"])
        let snapshot = try cache.snapshot(for: FocusHistoryQuery(
            referenceDayIdentifier: "2026-07-21",
            dailyGoalMinutes: ["2026-07-21": 30],
            source: source,
            activeProjectKeys: []
        ))
        XCTAssertNil(snapshot.currentGoalStreakDays)
    }

    private func query(
        reference: String,
        goals: [String: Int] = [:],
        activeKeys: Set<String>? = nil
    ) -> FocusHistoryQuery {
        FocusHistoryQuery(
            referenceDayIdentifier: reference,
            dailyGoalMinutes: goals,
            source: FocusHistorySource(health: .available),
            activeProjectKeys: activeKeys
        )
    }

    private func session(
        project: FocusProjectContext,
        day: String,
        start: Date,
        end: Date,
        id: UUID = UUID()
    ) -> FocusSession {
        FocusSession(
            id: id,
            project: project,
            dayIdentifier: day,
            startedAt: start,
            endedAt: end,
            status: .ended,
            lastUserActivityAt: end,
            lastStateChangeAt: end
        )
    }

    private func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw FocusHistoryAggregationError.invalidDayIdentifier(value)
        }
        return date
    }
}
