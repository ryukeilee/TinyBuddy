import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

/// Thread-safe mutable box for the session provider used by controller tests.
/// Also counts provider reads so tests can observe how many queries actually
/// reached the service.
private final class SessionProviderBox: @unchecked Sendable {
    var value: [FocusSession]
    var providerCallCount = 0

    init(_ value: [FocusSession]) {
        self.value = value
    }
}

/// Controller-level coverage for pagination consistency: deduplication and
/// re-sorting when data changes between pages, nil-page recovery (never stuck
/// in `.loading`), debounced update coalescing, and restart-on-invalidation.
@MainActor
final class HistoryQueryControllerTests: XCTestCase {
    private let alpha = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
    private let beta = FocusProjectContext(key: "repo.beta", displayName: "Beta")
    private let gamma = FocusProjectContext(key: "repo.gamma", displayName: "Gamma")

    // MARK: - Helpers

    private func makeController(box: SessionProviderBox) -> HistoryQueryController {
        let service = FocusSessionQueryService(sessionProvider: { [box] in
            box.providerCallCount += 1
            return box.value
        })
        return HistoryQueryController(queryService: service)
    }

    private func makeSession(
        id: UUID,
        project: FocusProjectContext,
        startedAt: Date,
        dayIdentifier: String = "2026-07-20"
    ) -> FocusSession {
        FocusSession(
            id: id,
            project: project,
            dayIdentifier: dayIdentifier,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600),
            status: .ended,
            lastUserActivityAt: startedAt.addingTimeInterval(600),
            lastStateChangeAt: startedAt.addingTimeInterval(600)
        )
    }

    /// Creates `count` ended sessions with strictly descending `startedAt`
    /// (index 0 newest) and deterministic ids, cycling through three projects.
    private func makeSessions(count: Int = 100) -> [FocusSession] {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let projects = [alpha, beta, gamma]
        return (0 ..< count).map { i in
            let start = base.addingTimeInterval(TimeInterval(count - i) * 60)
            let id = UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012x", i + 1)
            )!
            return makeSession(id: id, project: projects[i % 3], startedAt: start)
        }
    }

    private func newestSession(olderThan sessions: [FocusSession]) -> FocusSession {
        let newest = sessions[0].startedAt.addingTimeInterval(60)
        return makeSession(
            id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            project: beta,
            startedAt: newest
        )
    }

    private func assertCanonicallyOrdered(
        _ sessions: [FocusSession],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for i in 1 ..< sessions.count {
            let prev = sessions[i - 1]
            let cur = sessions[i]
            if cur.startedAt > prev.startedAt {
                XCTFail("Order jump at index \(i)", file: file, line: line)
            } else if cur.startedAt == prev.startedAt,
                      cur.id.uuidString < prev.id.uuidString {
                XCTFail("Tie-break order jump at index \(i)", file: file, line: line)
            }
        }
    }

    // MARK: - Basic Pagination

    func testRefreshLoadsFirstPage() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        await controller.refresh()

        guard case .loaded(let page) = controller.loadState else {
            return XCTFail("expected .loaded, got \(controller.loadState)")
        }
        XCTAssertEqual(controller.allSessions.count, 50)
        XCTAssertEqual(page.sessions.count, 50)
        XCTAssertTrue(page.hasMore)
        XCTAssertNotNil(page.nextCursor)
        assertCanonicallyOrdered(controller.allSessions)
    }

    func testLoadMoreStaticDataHasNoDuplicatesOrGaps() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        await controller.refresh()
        await controller.loadMore()

        XCTAssertEqual(controller.allSessions.count, 100)
        XCTAssertEqual(Set(controller.allSessions.map(\.id)).count, 100)
        assertCanonicallyOrdered(controller.allSessions)
        guard case .loaded(let page) = controller.loadState else {
            return XCTFail("expected .loaded, got \(controller.loadState)")
        }
        XCTAssertFalse(page.hasMore)
    }

    // MARK: - Mutation Between Pages

    /// Data changes between page loads without invalidating the query: the
    /// controller must still deduplicate by id and restore canonical order so
    /// no duplicate rows or order jumps appear.
    func testMutationBetweenPagesNoDuplicatesNoOrderJump() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        await controller.refresh()
        XCTAssertEqual(controller.allSessions.count, 50)

        // Mutate the provider between pages: delete one session, move another
        // (same id, older startedAt) into the second page's range, and insert
        // a brand-new session at the front. No version bump.
        var mutated = box.value
        mutated.remove(at: 24)
        var moved = mutated[19]
        moved.startedAt = mutated[48].startedAt.addingTimeInterval(-30)
        mutated[19] = moved
        mutated.insert(newestSession(olderThan: box.value), at: 0)
        box.value = mutated

        await controller.loadMore()

        // Naive append would hold 100 rows with the moved session duplicated;
        // deduplication must bring it back to 99 unique sessions.
        XCTAssertEqual(controller.allSessions.count, 99)
        XCTAssertEqual(Set(controller.allSessions.map(\.id)).count, 99)
        XCTAssertEqual(
            controller.allSessions.filter { $0.id == moved.id }.count,
            1,
            "The moved session must appear exactly once"
        )
        assertCanonicallyOrdered(controller.allSessions)
    }

    /// An invalidation (version bump) while mid-pagination must restart from
    /// the first page with fresh data — no duplicates, no missing inserted
    /// sessions, no stale deleted rows, and never a stuck `.loading` state.
    func testLoadMoreRestartsAfterInvalidation() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        await controller.refresh()
        XCTAssertEqual(controller.allSessions.count, 50)

        // Several edits invalidated the query (version 3) while this list was
        // mid-pagination and mutated the data underneath it.
        let deleted = box.value[24]
        let newest = newestSession(olderThan: box.value)
        box.value.remove(at: 24)
        box.value.insert(newest, at: 0)
        await controller.notifyChanges([])
        await controller.notifyChanges([])
        await controller.notifyChanges([])

        await controller.loadMore()

        // The stale cursor returns nil; the controller restarts pagination.
        guard case .loaded = controller.loadState else {
            return XCTFail("expected .loaded, got \(controller.loadState)")
        }
        XCTAssertEqual(controller.allSessions.count, 50)
        XCTAssertTrue(
            controller.allSessions.contains { $0.id == newest.id },
            "The inserted session must appear after restart"
        )
        XCTAssertFalse(
            controller.allSessions.contains { $0.id == deleted.id },
            "The deleted session must not linger after restart"
        )
        assertCanonicallyOrdered(controller.allSessions)
    }

    /// When all sessions disappear between pages, the cursor key is gone and
    /// the service signals a broken continuation; the controller must restart
    /// to an empty loaded state instead of freezing the loading indicator.
    func testLoadMoreRestartsWhenCursorDisappears() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        await controller.refresh()
        XCTAssertEqual(controller.allSessions.count, 50)

        box.value.removeAll()

        await controller.loadMore()

        guard case .loaded = controller.loadState else {
            return XCTFail("expected .loaded, got \(controller.loadState)")
        }
        XCTAssertTrue(controller.allSessions.isEmpty)
    }

    // MARK: - Nil-Page Recovery

    /// When the service version is already ahead of the controller's next
    /// operation ID, `refresh()` must retry with a fresh ID instead of
    /// freezing in `.loading`.
    func testRefreshRecoversFromNilPage() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        // Version 2 with no controller operations yet: the first execute is
        // guaranteed to return nil.
        await controller.notifyChanges([])
        await controller.notifyChanges([])

        await controller.refresh()

        guard case .loaded(let page) = controller.loadState else {
            return XCTFail("expected .loaded, got \(controller.loadState)")
        }
        XCTAssertEqual(controller.allSessions.count, 50)
        XCTAssertEqual(page.sessions.count, 50)
    }

    /// When the version keeps racing ahead of the retry budget, `refresh()`
    /// must surface `.failure` (making the error view's retry button
    /// reachable) rather than staying `.loading` forever — and a later
    /// refresh must recover.
    func testRefreshFailsAfterExhaustedRetries() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        // Version 4 stays ahead of all three retry attempts (op IDs 1…3).
        await controller.notifyChanges([])
        await controller.notifyChanges([])
        await controller.notifyChanges([])
        await controller.notifyChanges([])

        await controller.refresh()

        guard case .failure(let message) = controller.loadState else {
            return XCTFail("expected .failure, got \(controller.loadState)")
        }
        XCTAssertFalse(message.isEmpty)

        // A later refresh claims a fresh operation ID and succeeds.
        await controller.refresh()
        guard case .loaded = controller.loadState else {
            return XCTFail("expected .loaded after retry, got \(controller.loadState)")
        }
        XCTAssertEqual(controller.allSessions.count, 50)
    }

    // MARK: - Debounced Updates

    /// Rapid `updateQuery` calls must coalesce: only the newest call issues a
    /// query after the debounce wait; stale continuations drop out without
    /// redundant full-table filter/sort work.
    func testDebounceOnlyLatestUpdateIssuesQuery() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        let first = Task {
            await controller.updateQuery(
                FocusSessionQuery(keyword: "alpha"),
                debounceSeconds: 0.15
            )
        }
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task {
            await controller.updateQuery(
                FocusSessionQuery(keyword: "beta"),
                debounceSeconds: 0.15
            )
        }
        await first.value
        await second.value

        // Exactly one query reached the service.
        XCTAssertEqual(box.providerCallCount, 1)
        guard case .loaded = controller.loadState else {
            return XCTFail("expected .loaded, got \(controller.loadState)")
        }
        XCTAssertFalse(controller.allSessions.isEmpty)
        XCTAssertTrue(
            controller.allSessions.allSatisfy { $0.project.key.contains("beta") },
            "Only the newest query's filter may be applied"
        )
        assertCanonicallyOrdered(controller.allSessions)
    }

    // MARK: - Reload

    /// The primitive used by the snapshot-synchronization reload wiring: a
    /// reload must reflect provider mutations immediately.
    func testReloadReflectsProviderMutations() async {
        let box = SessionProviderBox(makeSessions())
        let controller = makeController(box: box)

        await controller.refresh()
        XCTAssertEqual(controller.allSessions.count, 50)

        let newest = newestSession(olderThan: box.value)
        box.value.insert(newest, at: 0)

        await controller.reload()

        guard case .loaded = controller.loadState else {
            return XCTFail("expected .loaded, got \(controller.loadState)")
        }
        XCTAssertEqual(controller.allSessions.count, 50)
        XCTAssertEqual(controller.allSessions.first?.id, newest.id)
        assertCanonicallyOrdered(controller.allSessions)
    }

    // MARK: - Date Filter Validation

    func testHistoryDateFilterRejectsInvalidFormatsDatesAndRanges() {
        XCTAssertEqual(
            HistoryDateFilterValidator.validate(FocusSessionQuery(dayStart: "2026-7-20")),
            .failure(.invalidFormat(.start))
        )
        XCTAssertEqual(
            HistoryDateFilterValidator.validate(FocusSessionQuery(dayStart: "2026-13-01")),
            .failure(.invalidDate(.start))
        )
        XCTAssertEqual(
            HistoryDateFilterValidator.validate(FocusSessionQuery(dayEnd: "2026-02-30")),
            .failure(.invalidDate(.end))
        )
        XCTAssertEqual(
            HistoryDateFilterValidator.validate(FocusSessionQuery(dayEnd: "2026-07-20 ")),
            .failure(.invalidFormat(.end))
        )
        XCTAssertEqual(
            HistoryDateFilterValidator.validate(
                FocusSessionQuery(dayStart: "2026-07-21", dayEnd: "2026-07-20")
            ),
            .failure(.reversedRange)
        )
    }

    func testHistoryDateFilterAcceptsLeapDaysOnlyInLeapYears() {
        XCTAssertEqual(
            HistoryDateFilterValidator.validate(FocusSessionQuery(dayStart: "2024-02-29")),
            .success(FocusSessionQuery(dayStart: "2024-02-29"))
        )
        XCTAssertEqual(
            HistoryDateFilterValidator.validate(FocusSessionQuery(dayStart: "2025-02-29")),
            .failure(.invalidDate(.start))
        )
    }

    func testValidatedHistoryDateFilterUsesInclusiveAndSingleBoundaries() async {
        let days = (18 ... 22).map { String(format: "2026-07-%02d", $0) }
        let sessions = days.enumerated().map { index, day in
            makeSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                project: alpha,
                startedAt: Date(timeIntervalSinceReferenceDate: 2_000_000 + Double(index) * 60),
                dayIdentifier: day
            )
        }
        let controller = makeController(box: SessionProviderBox(sessions))
        await controller.refresh()

        let startResult = await controller.updateQuery(
            validatingDateFilter: FocusSessionQuery(dayStart: "2026-07-20")
        )
        XCTAssertNil(startResult)
        XCTAssertEqual(
            controller.allSessions.map(\.dayIdentifier).sorted(),
            ["2026-07-20", "2026-07-21", "2026-07-22"]
        )

        let endResult = await controller.updateQuery(
            validatingDateFilter: FocusSessionQuery(dayEnd: "2026-07-20")
        )
        XCTAssertNil(endResult)
        XCTAssertEqual(
            controller.allSessions.map(\.dayIdentifier).sorted(),
            ["2026-07-18", "2026-07-19", "2026-07-20"]
        )

        let closedRangeResult = await controller.updateQuery(
            validatingDateFilter: FocusSessionQuery(
                dayStart: "2026-07-19",
                dayEnd: "2026-07-21"
            )
        )
        XCTAssertNil(closedRangeResult)
        XCTAssertEqual(
            controller.allSessions.map(\.dayIdentifier).sorted(),
            ["2026-07-19", "2026-07-20", "2026-07-21"]
        )
    }

    func testInvalidHistoryDateFilterPreservesTheActiveQueryAndResults() async {
        let days = ["2026-07-19", "2026-07-20", "2026-07-21"]
        let sessions = days.enumerated().map { index, day in
            makeSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                project: alpha,
                startedAt: Date(timeIntervalSinceReferenceDate: 3_000_000 + Double(index) * 60),
                dayIdentifier: day
            )
        }
        let box = SessionProviderBox(sessions)
        let controller = makeController(box: box)
        await controller.refresh()
        let validResult = await controller.updateQuery(
            validatingDateFilter: FocusSessionQuery(dayStart: "2026-07-20")
        )
        XCTAssertNil(validResult)

        let previousQuery = controller.query
        let previousIDs = controller.allSessions.map(\.id)
        let providerReads = box.providerCallCount
        let monthError = await controller.updateQuery(
            validatingDateFilter: FocusSessionQuery(dayStart: "2026-13-01")
        )
        XCTAssertEqual(monthError, .invalidDate(.start))
        XCTAssertEqual(controller.query, previousQuery)
        XCTAssertEqual(controller.allSessions.map(\.id), previousIDs)

        let reverseError = await controller.updateQuery(
            validatingDateFilter: FocusSessionQuery(
                dayStart: "2026-07-21",
                dayEnd: "2026-07-20"
            )
        )
        XCTAssertEqual(reverseError, .reversedRange)
        XCTAssertEqual(controller.query, previousQuery)
        XCTAssertEqual(controller.allSessions.map(\.id), previousIDs)
        XCTAssertEqual(box.providerCallCount, providerReads)
    }

    func testClearDateFilterRemovesBoundsAndReloadsAllMatchingSessions() async {
        let days = ["2026-07-19", "2026-07-20", "2026-07-21"]
        let sessions = days.enumerated().map { index, day in
            makeSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                project: alpha,
                startedAt: Date(timeIntervalSinceReferenceDate: 4_000_000 + Double(index) * 60),
                dayIdentifier: day
            )
        }
        let controller = makeController(box: SessionProviderBox(sessions))
        await controller.updateQuery(
            validatingDateFilter: FocusSessionQuery(dayStart: "2026-07-20", dayEnd: "2026-07-20")
        )
        XCTAssertEqual(controller.allSessions.map(\.dayIdentifier), ["2026-07-20"])

        await controller.clearDateFilter(in: controller.query)

        XCTAssertNil(controller.query.dayStart)
        XCTAssertNil(controller.query.dayEnd)
        XCTAssertEqual(controller.allSessions.map(\.dayIdentifier).sorted(), days)
    }

    func testDayDrillDownRequiresReliableReferencesAndValidDate() {
        func day(_ state: FocusHistoryDayState, _ ids: [UUID]?, date: String = "2026-07-20") -> FocusHistoryDay {
            FocusHistoryDay(
                dayIdentifier: date, state: state, focusDuration: nil,
                completedSessionCount: nil, goalMinutes: nil,
                goalCompletionRate: nil, isGoalMet: nil, contributingSessionIDs: ids
            )
        }
        XCTAssertEqual(FocusHistoryDayDrillDownPolicy.dayIdentifier(for: day(.sessions, [UUID()])), "2026-07-20")
        XCTAssertEqual(FocusHistoryDayDrillDownPolicy.dayIdentifier(for: day(.noSessions, [])), "2026-07-20")
        XCTAssertNil(FocusHistoryDayDrillDownPolicy.dayIdentifier(for: day(.unknown, [UUID()])))
        XCTAssertNil(FocusHistoryDayDrillDownPolicy.dayIdentifier(for: day(.sessions, nil)))
        XCTAssertNil(FocusHistoryDayDrillDownPolicy.dayIdentifier(for: day(.sessions, [])))
        XCTAssertNil(FocusHistoryDayDrillDownPolicy.dayIdentifier(for: day(.noSessions, nil)))
        XCTAssertNil(FocusHistoryDayDrillDownPolicy.dayIdentifier(for: day(.sessions, [UUID()], date: "2026-02-30")))
    }

    func testSingleDaySwitchSupersedesPendingQueryAndRetainsOtherFilters() async {
        let sessions = ["2026-07-19", "2026-07-20"].flatMap { day in
            [alpha, beta].map { project in
                makeSession(id: UUID(), project: project, startedAt: Date(timeIntervalSinceReferenceDate: 100), dayIdentifier: day)
            }
        }
        let controller = makeController(box: SessionProviderBox(sessions))
        var query = FocusSessionQuery(dayStart: "2026-07-19", dayEnd: "2026-07-19", projectKey: alpha.key, status: .ended, keyword: "Alpha")
        let oldQuery = query
        let pending = Task { await controller.updateQuery(oldQuery, debounceSeconds: 0.15) }
        await Task.yield()
        query.dayStart = "2026-07-20"
        query.dayEnd = "2026-07-20"
        let error = await controller.updateQuery(validatingDateFilter: query)
        await pending.value
        XCTAssertNil(error)
        XCTAssertEqual(controller.query, query)
        XCTAssertEqual(controller.allSessions.map(\.dayIdentifier), ["2026-07-20"])
        await controller.clearDateFilter(in: controller.query)
        XCTAssertEqual(controller.query.projectKey, alpha.key)
        XCTAssertEqual(controller.query.status, .ended)
        XCTAssertEqual(controller.query.keyword, "Alpha")
        XCTAssertEqual(controller.allSessions.map(\.dayIdentifier).sorted(), ["2026-07-19", "2026-07-20"])
    }

    func testPresetBoundsRespectLocalDaysWeeksAndCalendarArithmetic() throws {
        let cases: [(String, String, Int, String, String, String, String)] = [
            ("2026-01-01T01:00:00Z", "America/Los_Angeles", 2, "2025-12-31", "2025-12-29", "2026-01-04", "2025-12-25"),
            ("2026-01-31T16:30:00Z", "Asia/Shanghai", 1, "2026-02-01", "2026-02-01", "2026-02-07", "2026-01-26"),
            ("2026-03-10T07:30:00Z", "America/Los_Angeles", 2, "2026-03-10", "2026-03-09", "2026-03-15", "2026-03-04"),
            ("2024-03-01T12:00:00Z", "Asia/Shanghai", 2, "2024-03-01", "2024-02-26", "2024-03-03", "2024-02-24")
        ]
        for (instant, zone, firstWeekday, today, weekStart, weekEnd, sevenStart) in cases {
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: instant))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            calendar.firstWeekday = firstWeekday
            for (preset, expectedStart, expectedEnd) in [
                (HistoryDateFilterPreset.today, today, today),
                (.thisWeek, weekStart, weekEnd),
                (.lastSevenDays, sevenStart, today)
            ] {
                let bounds = try XCTUnwrap(preset.bounds(now: now, calendar: calendar))
                XCTAssertEqual(bounds.start, expectedStart)
                XCTAssertEqual(bounds.end, expectedEnd)
                let query = FocusSessionQuery(dayStart: bounds.start, dayEnd: bounds.end)
                XCTAssertEqual(HistoryDateFilterValidator.validate(query), .success(query))
            }
        }
    }

    func testPresetsCustomDrillDownAndClearShareQueryAndRetainOtherFilters() async throws {
        let days = ["2025-12-25", "2025-12-29", "2025-12-31", "2026-01-01", "2026-01-04", "2026-01-05"]
        let sessions = days.flatMap { day in
            [alpha, beta].map { project in
                makeSession(id: UUID(), project: project, startedAt: Date(), dayIdentifier: day)
            }
        }
        let controller = makeController(box: SessionProviderBox(sessions))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        calendar.firstWeekday = 2
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z"))
        var query = FocusSessionQuery(projectKey: alpha.key, status: .ended, keyword: "Alpha")
        let pending = Task { await controller.updateQuery(FocusSessionQuery(keyword: "Beta"), debounceSeconds: 0.15) }
        await Task.yield()
        for (preset, expected) in [
            (HistoryDateFilterPreset.today, ["2025-12-31"]),
            (.thisWeek, ["2025-12-29", "2025-12-31", "2026-01-01", "2026-01-04"]),
            (.lastSevenDays, ["2025-12-25", "2025-12-29", "2025-12-31"])
        ] {
            let bounds = try XCTUnwrap(preset.bounds(now: now, calendar: calendar))
            query.dayStart = bounds.start
            query.dayEnd = bounds.end
            let error = await controller.updateQuery(validatingDateFilter: query)
            XCTAssertNil(error)
            XCTAssertEqual(controller.query, query)
            XCTAssertEqual(controller.allSessions.map(\.dayIdentifier).sorted(), expected)
        }
        await pending.value
        XCTAssertEqual(controller.query, query)
        for (start, end, expected) in [
            ("2026-01-01", "2026-01-04", ["2026-01-01", "2026-01-04"]),
            ("2025-12-29", "2025-12-29", ["2025-12-29"])
        ] {
            query.dayStart = start
            query.dayEnd = end
            let error = await controller.updateQuery(validatingDateFilter: query)
            XCTAssertNil(error)
            XCTAssertEqual(controller.allSessions.map(\.dayIdentifier).sorted(), expected)
        }
        await controller.clearDateFilter(in: query)
        query.dayStart = nil
        query.dayEnd = nil
        XCTAssertEqual(controller.query, query)
        XCTAssertEqual(controller.allSessions.map(\.dayIdentifier).sorted(), days)
    }

    // MARK: - View Wiring

    /// Guards the view-level wiring (following the repository's source-level
    /// consistency-test convention): both history views reload the shared
    /// controller when the committed snapshot is republished, the list replays
    /// its own toolbar filters on appear (no `.ended` leak from the review
    /// view), and project options refresh whenever the loaded set changes.
    func testHistoryListViewWiringReloadsOnSnapshotSynchronization() throws {
        let list = try source("Sources/TinyBuddy/FocusHistoryListView.swift")
        let review = try source("Sources/TinyBuddy/FocusSessionReviewView.swift")
        let summary = try source("Sources/TinyBuddy/FocusHistoryView.swift")
        XCTAssertTrue(summary.contains("FocusHistoryDayDrillDownPolicy.dayIdentifier(for: day)"))
        XCTAssertTrue(summary.contains("showSessionList = true"))
        XCTAssertTrue(summary.contains("FocusHistoryListView(controller: controller, daySelection: selectedDay)"))
        XCTAssertTrue(list.contains(".task(id: daySelection?.requestID)"))
        XCTAssertTrue(list.contains("appliedDayRequestID != daySelection.requestID"))
        XCTAssertTrue(list.contains("dayStartInput = daySelection.dayIdentifier"))
        XCTAssertTrue(list.contains("dayEndInput = daySelection.dayIdentifier"))

        XCTAssertTrue(list.contains(".focusSessionSnapshotSynchronizationDidFinish"))
        XCTAssertTrue(list.contains("await controller.reload()"))
        XCTAssertTrue(list.contains("await loadProjectOptions()"))
        XCTAssertTrue(review.contains(".focusSessionSnapshotSynchronizationDidFinish"))
        XCTAssertTrue(review.contains("await historyController.reload()"))

        // The list replays its own toolbar filters on appear so the shared
        // controller's query cannot leak across views.
        XCTAssertTrue(list.contains("updateQuery(makeQuery(), debounceSeconds: 0)"))

        // Project options refresh when pagination or reload changes the set.
        XCTAssertTrue(list.contains("onChange(of: controller.allSessions.count)"))

        // Date submissions use the controller's validated path; failed input
        // stays visible, while Clear resets the draft and committed bounds.
        XCTAssertTrue(list.contains("validatingDateFilter: proposedQuery"))
        XCTAssertTrue(list.contains("ForEach(HistoryDateFilterPreset.allCases, id: \\.self)"))
        XCTAssertTrue(list.contains("dayStartInput = bounds.start"))
        XCTAssertTrue(list.contains("dayEndInput = bounds.end"))
        XCTAssertTrue(list.contains("applyDateFilter()"))
        XCTAssertTrue(list.contains("if let dateFilterError"))
        XCTAssertTrue(list.contains("Text(dateFilterError.message)"))
        XCTAssertTrue(list.contains("clearDateFilter(in: makeQuery())"))
        let clearButton = try XCTUnwrap(list.range(of: "Button(\"清除\")"))
        let applyButton = try XCTUnwrap(
            list.range(of: "Button(\"应用\")", range: clearButton.upperBound ..< list.endIndex)
        )
        let clearAction = String(list[clearButton.lowerBound ..< applyButton.lowerBound])
        XCTAssertTrue(clearAction.contains("dayStartInput = \"\""))
        XCTAssertTrue(clearAction.contains("dayEndInput = \"\""))
        XCTAssertTrue(clearAction.contains("dateFilterError = nil"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
