import XCTest
@testable import TinyBuddyCore

/// Thread-safe mutable box used by tests that need to mutate the
/// session provider's backing array.
final class SessionBox: @unchecked Sendable {
    var value: [FocusSession]
    init(_ value: [FocusSession]) { self.value = value }
}

final class FocusSessionQueryTests: XCTestCase {
    private let alpha = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
    private let beta = FocusProjectContext(key: "repo.beta", displayName: "Beta")
    private let gamma = FocusProjectContext(key: "repo.gamma", displayName: "Gamma")

    // MARK: - Helpers

    private func makeService(
        sessions: [FocusSession]
    ) -> FocusSessionQueryService {
        FocusSessionQueryService(sessionProvider: { sessions })
    }

    private func session(
        project: FocusProjectContext,
        day: String,
        start: Date,
        end: Date? = nil,
        status: FocusSessionStatus = .ended,
        id: UUID = UUID()
    ) -> FocusSession {
        FocusSession(
            id: id,
            project: project,
            dayIdentifier: day,
            startedAt: start,
            endedAt: end,
            status: status,
            lastUserActivityAt: end ?? start,
            lastStateChangeAt: end ?? start
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    /// Creates `count` sessions with unique `startedAt` times at one-minute
    /// intervals starting from the given base date.
    private func makeOrderedSessions(
        count: Int,
        project: FocusProjectContext,
        day: String = "2026-07-20",
        base: Date
    ) -> [FocusSession] {
        (0 ..< count).map { i in
            let start = base.addingTimeInterval(TimeInterval(i) * 60)
            return session(
                project: project,
                day: day,
                start: start
            )
        }
    }

    // ======================================================================
    // MARK: - Pagination
    // ======================================================================

    func testEmptyPage() async throws {
        let service = makeService(sessions: [])

        let result = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertTrue(page.sessions.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.totalEstimatedCount)
    }

    func testFirstPage() async throws {
        let base = try date("2026-07-20T12:00:00Z")
        let sessions = makeOrderedSessions(count: 25, project: alpha, base: base)
        let service = makeService(sessions: sessions)

        let result = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 10)
        XCTAssertTrue(page.hasMore)
        XCTAssertNotNil(page.nextCursor)
    }

    func testLastPage() async throws {
        let base = try date("2026-07-20T12:00:00Z")
        let sessions = makeOrderedSessions(count: 25, project: alpha, base: base)
        let service = makeService(sessions: sessions)

        let r1 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page1 = try XCTUnwrap(r1)

        let r2 = await service.execute(
            query: FocusSessionQuery(),
            cursor: page1.nextCursor,
            limit: 10,
            version: 0
        )
        let page2 = try XCTUnwrap(r2)

        let r3 = await service.execute(
            query: FocusSessionQuery(),
            cursor: page2.nextCursor,
            limit: 10,
            version: 0
        )
        let page3 = try XCTUnwrap(r3)

        XCTAssertEqual(page3.sessions.count, 5)
        XCTAssertFalse(page3.hasMore)
        XCTAssertNil(page3.nextCursor)
    }

    func testExactPageSize() async throws {
        let base = try date("2026-07-20T12:00:00Z")
        let sessions = makeOrderedSessions(count: 10, project: alpha, base: base)
        let service = makeService(sessions: sessions)

        let result = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 10)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func testCursorAdvances() async throws {
        let base = try date("2026-07-20T12:00:00Z")
        let sessions = makeOrderedSessions(count: 25, project: alpha, base: base)
        let service = makeService(sessions: sessions)

        let r1 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page1 = try XCTUnwrap(r1)
        let ids1 = Set(page1.sessions.map(\.id))
        XCTAssertEqual(ids1.count, 10)

        let r2 = await service.execute(
            query: FocusSessionQuery(),
            cursor: page1.nextCursor,
            limit: 10,
            version: 0
        )
        let page2 = try XCTUnwrap(r2)
        let ids2 = Set(page2.sessions.map(\.id))
        XCTAssertEqual(ids2.count, 10)
        XCTAssertTrue(ids1.isDisjoint(with: ids2), "Page 2 must not overlap page 1")

        let r3 = await service.execute(
            query: FocusSessionQuery(),
            cursor: page2.nextCursor,
            limit: 10,
            version: 0
        )
        let page3 = try XCTUnwrap(r3)
        let ids3 = Set(page3.sessions.map(\.id))
        XCTAssertEqual(ids3.count, 5)
        XCTAssertTrue(ids3.isDisjoint(with: ids1), "Page 3 must not overlap page 1")
        XCTAssertTrue(ids3.isDisjoint(with: ids2), "Page 3 must not overlap page 2")

        // Verify no gaps: all 25 ids collected
        let allIDs = ids1.union(ids2).union(ids3)
        XCTAssertEqual(allIDs.count, 25)
    }

    func testMultiplePagesAllItems() async throws {
        let base = try date("2026-07-20T12:00:00Z")
        let sessions = makeOrderedSessions(count: 25, project: alpha, base: base)
        let service = makeService(sessions: sessions)

        var allIDs = Set<UUID>()
        var cursor: FocusSessionCursor?
        var hasMore = true

        while hasMore {
            let result = await service.execute(
                query: FocusSessionQuery(),
                cursor: cursor,
                limit: 10,
                version: 0
            )
            let page = try XCTUnwrap(result)
            for s in page.sessions {
                allIDs.insert(s.id)
            }
            cursor = page.nextCursor
            hasMore = page.hasMore
        }

        XCTAssertEqual(allIDs.count, 25)
    }

    func testSingleSession() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let s = session(project: alpha, day: "2026-07-20", start: start)
        let service = makeService(sessions: [s])

        let result = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    // ======================================================================
    // MARK: - Filters
    // ======================================================================

    func testFilterByDayStart() async throws {
        let s1 = session(
            project: alpha, day: "2026-07-19",
            start: try date("2026-07-19T10:00:00Z")
        )
        let s2 = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z")
        )
        let s3 = session(
            project: alpha, day: "2026-07-21",
            start: try date("2026-07-21T10:00:00Z")
        )
        let service = makeService(sessions: [s1, s2, s3])

        let result = await service.execute(
            query: FocusSessionQuery(dayStart: "2026-07-20"),
            cursor: nil,
            limit: 100,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 2)
        XCTAssertEqual(
            Set(page.sessions.map(\.dayIdentifier)),
            ["2026-07-20", "2026-07-21"]
        )
    }

    func testFilterByDayEnd() async throws {
        let s1 = session(
            project: alpha, day: "2026-07-19",
            start: try date("2026-07-19T10:00:00Z")
        )
        let s2 = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z")
        )
        let s3 = session(
            project: alpha, day: "2026-07-21",
            start: try date("2026-07-21T10:00:00Z")
        )
        let service = makeService(sessions: [s1, s2, s3])

        let result = await service.execute(
            query: FocusSessionQuery(dayEnd: "2026-07-20"),
            cursor: nil,
            limit: 100,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 2)
        XCTAssertEqual(
            Set(page.sessions.map(\.dayIdentifier)),
            ["2026-07-19", "2026-07-20"]
        )
    }

    func testFilterByDayRange() async throws {
        let s1 = session(
            project: alpha, day: "2026-07-18",
            start: try date("2026-07-18T10:00:00Z")
        )
        let s2 = session(
            project: alpha, day: "2026-07-19",
            start: try date("2026-07-19T10:00:00Z")
        )
        let s3 = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z")
        )
        let s4 = session(
            project: alpha, day: "2026-07-21",
            start: try date("2026-07-21T10:00:00Z")
        )
        let s5 = session(
            project: alpha, day: "2026-07-22",
            start: try date("2026-07-22T10:00:00Z")
        )
        let service = makeService(sessions: [s1, s2, s3, s4, s5])

        let result = await service.execute(
            query: FocusSessionQuery(
                dayStart: "2026-07-19",
                dayEnd: "2026-07-21"
            ),
            cursor: nil,
            limit: 100,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 3)
        XCTAssertEqual(
            Set(page.sessions.map(\.dayIdentifier)),
            ["2026-07-19", "2026-07-20", "2026-07-21"]
        )
    }

    func testFilterByProjectKey() async throws {
        let s1 = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z")
        )
        let s2 = session(
            project: beta, day: "2026-07-20",
            start: try date("2026-07-20T11:00:00Z")
        )
        let s3 = session(
            project: gamma, day: "2026-07-20",
            start: try date("2026-07-20T12:00:00Z")
        )
        let service = makeService(sessions: [s1, s2, s3])

        let result = await service.execute(
            query: FocusSessionQuery(projectKey: "repo.beta"),
            cursor: nil,
            limit: 100,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].project.key, "repo.beta")
    }

    func testFilterByStatus() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let ended = session(
            project: alpha, day: "2026-07-20",
            start: start, status: .ended
        )
        let active = FocusSession(
            project: alpha,
            dayIdentifier: "2026-07-20",
            startedAt: try date("2026-07-20T11:00:00Z"),
            status: .active,
            lastUserActivityAt: try date("2026-07-20T11:00:00Z"),
            lastStateChangeAt: try date("2026-07-20T11:00:00Z")
        )
        let paused = FocusSession(
            project: alpha,
            dayIdentifier: "2026-07-20",
            startedAt: try date("2026-07-20T12:00:00Z"),
            status: .paused,
            lastUserActivityAt: try date("2026-07-20T12:00:00Z"),
            lastStateChangeAt: try date("2026-07-20T12:00:00Z")
        )
        let service = makeService(sessions: [ended, active, paused])

        var result = await service.execute(
            query: FocusSessionQuery(status: .ended),
            cursor: nil, limit: 100, version: 0
        )
        var page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].status, .ended)

        result = await service.execute(
            query: FocusSessionQuery(status: .active),
            cursor: nil, limit: 100, version: 0
        )
        page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].status, .active)

        result = await service.execute(
            query: FocusSessionQuery(status: .paused),
            cursor: nil, limit: 100, version: 0
        )
        page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].status, .paused)
    }

    func testFilterByKeyword() async throws {
        let s1 = session(
            project: FocusProjectContext(key: "repo.alpha", displayName: "Alpha Project"),
            day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z")
        )
        let s2 = session(
            project: FocusProjectContext(key: "repo.beta", displayName: "Beta App"),
            day: "2026-07-20",
            start: try date("2026-07-20T11:00:00Z")
        )
        let s3 = session(
            project: FocusProjectContext(key: "other.service", displayName: "Gamma"),
            day: "2026-07-20",
            start: try date("2026-07-20T12:00:00Z")
        )
        let service = makeService(sessions: [s1, s2, s3])

        // Match via displayName (case-insensitive)
        var result = await service.execute(
            query: FocusSessionQuery(keyword: "alpha"),
            cursor: nil, limit: 100, version: 0
        )
        var page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].id, s1.id)

        // Match via key (case-insensitive upper-case keyword)
        result = await service.execute(
            query: FocusSessionQuery(keyword: "BETA"),
            cursor: nil, limit: 100, version: 0
        )
        page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].id, s2.id)

        // Filter only by own displayName, not by sibling key
        result = await service.execute(
            query: FocusSessionQuery(keyword: "gamma"),
            cursor: nil, limit: 100, version: 0
        )
        page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].id, s3.id)
    }

    // ======================================================================
    // MARK: - Stale Query Prevention
    // ======================================================================

    func testStaleQueryReturnsNil() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let s = session(project: alpha, day: "2026-07-20", start: start)
        let service = makeService(sessions: [s])

        // Version 0 works initially
        let r0 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        XCTAssertNotNil(r0)

        await service.invalidateQueries()

        // Version 0 now stale → nil
        let rStale = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        XCTAssertNil(rStale)

        // Version 1 works
        let r1 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 1
        )
        XCTAssertNotNil(r1)
    }

    func testConsecutiveInvalidations() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let s = session(project: alpha, day: "2026-07-20", start: start)
        let service = makeService(sessions: [s])

        // Version 0 works
        let r0 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 0
        )
        XCTAssertNotNil(r0)

        await service.invalidateQueries() // version → 1

        // Version 0 stale, version 1 works
        let r0after = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 0
        )
        XCTAssertNil(r0after)
        let r1 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 1
        )
        XCTAssertNotNil(r1)

        await service.invalidateQueries() // version → 2

        // Version 1 stale, version 2 works
        let r1after = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 1
        )
        XCTAssertNil(r1after)
        let r2 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 2
        )
        XCTAssertNotNil(r2)
    }

    // ======================================================================
    // MARK: - Sort Stability
    // ======================================================================

    func testSortOrder() async throws {
        let sLate = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T12:00:00Z")
        )
        let sMid = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z")
        )
        let sEarly = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T08:00:00Z")
        )

        // Feed in unsorted order
        let service = makeService(sessions: [sMid, sEarly, sLate])

        let result = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 3)
        // Expected: late (12:00) → mid (10:00) → early (08:00)
        XCTAssertEqual(page.sessions[0].startedAt, sLate.startedAt)
        XCTAssertEqual(page.sessions[1].startedAt, sMid.startedAt)
        XCTAssertEqual(page.sessions[2].startedAt, sEarly.startedAt)
    }

    func testTieBreakerUUID() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
        let idC = UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!

        // Feed in unsorted UUID order: b, a, c
        let sB = session(project: alpha, day: "2026-07-20", start: start, id: idB)
        let sA = session(project: alpha, day: "2026-07-20", start: start, id: idA)
        let sC = session(project: alpha, day: "2026-07-20", start: start, id: idC)
        let service = makeService(sessions: [sB, sA, sC])

        let result = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sessions.count, 3)
        // UUID string ascending: a → b → c
        XCTAssertEqual(page.sessions[0].id, idA)
        XCTAssertEqual(page.sessions[1].id, idB)
        XCTAssertEqual(page.sessions[2].id, idC)
    }

    // ======================================================================
    // MARK: - Edit + Refresh
    // ======================================================================

    func testApplyChangesBumpsVersion() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let s = session(project: alpha, day: "2026-07-20", start: start)
        let service = makeService(sessions: [s])

        // Execute with version 0
        let r0 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 0
        )
        XCTAssertNotNil(r0)

        // applyChanges bumps the version
        await service.applyChanges([])

        // Version 0 now stale
        let r0after = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 0
        )
        XCTAssertNil(r0after)

        // Version 1 works
        let r1 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 1
        )
        XCTAssertNotNil(r1)
    }

    func testSessionChangesReflected() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let sA = session(project: alpha, day: "2026-07-20", start: start)

        // Use a SessionBox so the Sendable closure captures a class reference
        // instead of a mutable local variable.
        let box = SessionBox([sA])
        let service = FocusSessionQueryService(sessionProvider: { box.value })

        // Initial query sees only sA
        let r1 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 0
        )
        let page1 = try XCTUnwrap(r1)
        XCTAssertEqual(page1.sessions.count, 1)

        // Mutate the provider data and bump version
        let sB = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T11:00:00Z")
        )
        box.value.append(sB)
        await service.applyChanges([])

        // New query with bumped version sees both
        let r2 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 1
        )
        let page2 = try XCTUnwrap(r2)
        XCTAssertEqual(page2.sessions.count, 2)
    }

    // ======================================================================
    // MARK: - Edge Cases
    // ======================================================================

    func testEmptyKeywordFilter() async throws {
        let s = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z")
        )
        let service = makeService(sessions: [s])

        // Empty keyword should be treated as no filter
        let result = await service.execute(
            query: FocusSessionQuery(keyword: ""),
            cursor: nil, limit: 10, version: 0
        )
        let page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.count, 1)
    }

    func testKeywordWithNoMatch() async throws {
        let s = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z")
        )
        let service = makeService(sessions: [s])

        let result = await service.execute(
            query: FocusSessionQuery(keyword: "nonexistent"),
            cursor: nil, limit: 10, version: 0
        )
        let page = try XCTUnwrap(result)

        XCTAssertTrue(page.sessions.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
        XCTAssertNil(page.totalEstimatedCount)
    }

    func testAllFiltersCombined() async throws {
        let session1 = session(
            project: alpha, day: "2026-07-20",
            start: try date("2026-07-20T10:00:00Z"),
            status: .ended
        )
        // Fails dayEnd: day 22 > 21
        let session2 = session(
            project: alpha, day: "2026-07-22",
            start: try date("2026-07-22T10:00:00Z"),
            status: .ended
        )
        // Fails projectKey
        let session3 = session(
            project: beta, day: "2026-07-20",
            start: try date("2026-07-20T11:00:00Z"),
            status: .ended
        )
        // Fails status
        let session4 = FocusSession(
            project: alpha,
            dayIdentifier: "2026-07-20",
            startedAt: try date("2026-07-20T12:00:00Z"),
            status: .active,
            lastUserActivityAt: try date("2026-07-20T12:00:00Z"),
            lastStateChangeAt: try date("2026-07-20T12:00:00Z")
        )
        // Fails projectKey and keyword
        let session5 = session(
            project: gamma, day: "2026-07-20",
            start: try date("2026-07-20T13:00:00Z"),
            status: .ended
        )
        // Fails dayStart: day 18 < 19
        let session6 = session(
            project: alpha, day: "2026-07-18",
            start: try date("2026-07-18T10:00:00Z"),
            status: .ended
        )

        let service = makeService(sessions: [
            session1, session2, session3, session4, session5, session6,
        ])

        let query = FocusSessionQuery(
            dayStart: "2026-07-19",
            dayEnd: "2026-07-21",
            projectKey: "repo.alpha",
            status: .ended,
            keyword: "alpha"
        )

        let result = await service.execute(query: query, cursor: nil, limit: 100, version: 0)
        let page = try XCTUnwrap(result)

        // Only session1 passes all filters
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].id, session1.id)
    }

    func testEstimatedCount() async throws {
        let base = try date("2026-07-20T12:00:00Z")
        let sessions = makeOrderedSessions(count: 25, project: alpha, base: base)
        let service = makeService(sessions: sessions)

        // Unfiltered: totalEstimatedCount reflects full result set
        let r1 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil, limit: 10, version: 0
        )
        let page = try XCTUnwrap(r1)
        XCTAssertEqual(page.totalEstimatedCount, 25)

        // Filtered: project matches all 25
        let r2 = await service.execute(
            query: FocusSessionQuery(projectKey: "repo.alpha"),
            cursor: nil, limit: 10, version: 0
        )
        let filtered = try XCTUnwrap(r2)
        XCTAssertEqual(filtered.totalEstimatedCount, 25)

        // No match → returns .empty which has nil totalEstimatedCount
        let r3 = await service.execute(
            query: FocusSessionQuery(projectKey: "nonexistent"),
            cursor: nil, limit: 10, version: 0
        )
        let none = try XCTUnwrap(r3)
        XCTAssertTrue(none.sessions.isEmpty)
        XCTAssertNil(none.totalEstimatedCount)

        // estimatedCount async method returns filtered count
        let allCount = await service.estimatedCount(query: FocusSessionQuery())
        XCTAssertEqual(allCount, 25)

        let noneCount = await service.estimatedCount(
            query: FocusSessionQuery(projectKey: "nonexistent")
        )
        XCTAssertEqual(noneCount, 0)
    }
}
