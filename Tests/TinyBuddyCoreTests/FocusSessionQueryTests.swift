import XCTest
@testable import TinyBuddyCore

/// Thread-safe mutable box used by tests that need to mutate the
/// session provider's backing array.
final class SessionBox: @unchecked Sendable {
    var value: [FocusSession]
    init(_ value: [FocusSession]) { self.value = value }
}

/// Thread-safe resolver invocation counter. Project resolution walks the
/// registry identity graph, so the number of calls per query pass is the
/// algorithmic property behind the history load/pagination budget.
final class ResolverCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func record() {
        lock.lock(); defer { lock.unlock() }
        calls += 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        calls = 0
    }
}

final class FocusSessionQueryTests: XCTestCase {
    private let alpha = FocusProjectContext(key: "repo.alpha", displayName: "Alpha")
    private let beta = FocusProjectContext(key: "repo.beta", displayName: "Beta")
    private let gamma = FocusProjectContext(key: "repo.gamma", displayName: "Gamma")

    func testProjectSummariesUseNewestNameAndStableOrdering() async throws {
        let base = Date(timeIntervalSince1970: 100)
        let renamed = FocusProjectContext(key: alpha.key, displayName: "Same")
        let sameName = FocusProjectContext(key: beta.key, displayName: "Same")
        let rows = [
            session(project: alpha, day: "2020-01-01", start: base),
            session(project: renamed, day: "2026-07-20", start: base.addingTimeInterval(10)),
            session(project: sameName, day: "2026-07-20", start: base.addingTimeInterval(20))
        ]
        let service = makeService(sessions: rows.reversed())
        let projects = await service.projects(version: 0)
        XCTAssertEqual(projects, [renamed, sameName])
        await service.invalidateQueries()
        let stale = await service.projects(version: 0)
        XCTAssertNil(stale)
    }

    func testProjectRenameMergeAndUndoResolveSummariesAndQueriesTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TinyBuddyProjectRegistryFileStore(fileURL: directory.appendingPathComponent("registry.json"))
        let target = TinyBuddyProject(id: TinyBuddyProjectID(rawValue: "target"), kind: .manual,
                                     displayName: "Target", aliases: [alpha.key])
        let source = TinyBuddyProject(id: TinyBuddyProjectID(rawValue: "source"), kind: .manual,
                                     displayName: "Source", aliases: [beta.key])
        XCTAssertTrue(store.save(TinyBuddyProjectRegistrySnapshot(projects: [target, source])))
        let registry = TinyBuddyProjectRegistry(store: store)
        let rows = [session(project: alpha, day: "2026-07-20", start: Date(timeIntervalSince1970: 100)),
                    session(project: beta, day: "2020-01-01", start: Date(timeIntervalSince1970: 50))]
        let service = FocusSessionQueryService(sessionProvider: { rows }, projectResolver: { context in
            guard let project = registry.resolve(projectKey: context.key) else { return context }
            return FocusProjectContext(key: project.id.rawValue, displayName: project.displayName)
        })
        guard case .saved = registry.rename(id: target.id, displayName: "Renamed") else {
            return XCTFail("rename failed")
        }
        let renamed = FocusProjectContext(key: target.id.rawValue, displayName: "Renamed")
        let beforeMerge = await service.projects(version: 0)
        XCTAssertEqual(beforeMerge, [renamed, FocusProjectContext(key: source.id.rawValue, displayName: "Source")])
        let preview = try XCTUnwrap(registry.previewMerge(targetID: target.id, sourceIDs: [source.id],
                                                        sessions: rows, now: Date(timeIntervalSince1970: 200)))
        guard case .saved(_, let undo) = registry.merge(preview) else { return XCTFail("merge failed") }
        let merged = await service.projects(version: 0)
        XCTAssertEqual(merged, [renamed])
        let page = await service.execute(query: FocusSessionQuery(projectKey: target.id.rawValue, keyword: "Renamed"),
                                         cursor: nil, limit: 50, version: 0)
        XCTAssertEqual(page?.sessions.map(\.id), rows.map(\.id))
        XCTAssertTrue(page?.sessions.allSatisfy { $0.project == renamed } == true)
        let count = await service.estimatedCount(query: FocusSessionQuery(projectKey: target.id.rawValue))
        XCTAssertEqual(count, 2)
        guard case .saved = registry.undoMerge(undo) else { return XCTFail("undo failed") }
        let restored = await service.projects(version: 0)
        XCTAssertEqual(restored, beforeMerge)
    }

    // MARK: - Helpers

    private func makeService(
        sessions: [FocusSession]
    ) -> FocusSessionQueryService {
        FocusSessionQueryService(sessionProvider: { sessions })
    }

    /// Builds a service whose resolver records every invocation, over
    /// `sessionCount` sessions that share only `projectCount` distinct projects.
    private func makeCountingService(
        sessionCount: Int,
        projectCount: Int,
        counter: ResolverCallCounter
    ) -> FocusSessionQueryService {
        let sessions = (0 ..< sessionCount).map { index in
            let offset = TimeInterval(index) * 60
            let project = FocusProjectContext(
                key: "repo.\(index % projectCount)",
                displayName: "Project \(index % projectCount)"
            )
            return FocusSession(
                id: UUID(),
                project: project,
                dayIdentifier: "2026-07-20",
                startedAt: Date(timeIntervalSinceReferenceDate: offset),
                endedAt: Date(timeIntervalSinceReferenceDate: offset + 1_800),
                status: .ended,
                lastUserActivityAt: Date(timeIntervalSinceReferenceDate: offset + 1_800),
                lastStateChangeAt: Date(timeIntervalSinceReferenceDate: offset + 1_800)
            )
        }
        return FocusSessionQueryService(
            sessionProvider: { sessions },
            projectResolver: { context in
                counter.record()
                return FocusProjectContext(
                    key: "canonical.\(context.key)",
                    displayName: context.displayName
                )
            }
        )
    }

    // ======================================================================
    // MARK: - Resolution cost scaling
    // ======================================================================

    /// A filtered history query must consult the project resolver once per
    /// distinct project, not once per session. Before memoisation a 2,000-row
    /// history with five projects called the resolver 2,000 times per pass.
    func testFilteredQueryResolvesEachDistinctProjectOnce() async throws {
        let counter = ResolverCallCounter()
        let service = makeCountingService(sessionCount: 2_000, projectCount: 5, counter: counter)

        let page = await service.execute(
            query: FocusSessionQuery(keyword: "project"),
            cursor: nil,
            limit: 50,
            version: 0
        )
        XCTAssertEqual(page?.totalEstimatedCount, 2_000)
        XCTAssertEqual(page?.sessions.count, 50)
        XCTAssertLessThanOrEqual(counter.count, 10)

        counter.reset()
        let projects = await service.projects(version: 0)
        XCTAssertEqual(projects?.count, 5)
        XCTAssertLessThanOrEqual(counter.count, 10)
    }

    /// The returned first page bounds how many rows need a resolved identity:
    /// an unfiltered history page must not resolve the entire history. Before
    /// the page-slice path this was one resolution per session (2,000).
    func testUnfilteredPageResolvesOnlyVisibleRows() async throws {
        let counter = ResolverCallCounter()
        let service = makeCountingService(sessionCount: 2_000, projectCount: 500, counter: counter)

        let page = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 50,
            version: 0
        )
        XCTAssertEqual(page?.totalEstimatedCount, 2_000)
        XCTAssertEqual(page?.sessions.count, 50)
        XCTAssertLessThanOrEqual(counter.count, 50)
        // Every returned row still carries its resolved project identity.
        XCTAssertTrue(page?.sessions.allSatisfy { $0.project.key.hasPrefix("canonical.repo.") } ?? false)
    }

    /// Day/status-only filters constrain rows without consulting project
    /// identity at all; only the visible page is resolved.
    func testRowLocalFilterDoesNotResolveNonVisibleRows() async throws {
        let counter = ResolverCallCounter()
        let service = makeCountingService(sessionCount: 2_000, projectCount: 500, counter: counter)

        let page = await service.execute(
            query: FocusSessionQuery(status: .ended),
            cursor: nil,
            limit: 50,
            version: 0
        )
        XCTAssertEqual(page?.totalEstimatedCount, 2_000)
        XCTAssertEqual(page?.sessions.count, 50)
        XCTAssertLessThanOrEqual(counter.count, 50)
        XCTAssertTrue(page?.sessions.allSatisfy { $0.project.key.hasPrefix("canonical.repo.") } ?? false)
    }

    // ======================================================================
    // MARK: - Memoised path vs. per-row reference
    // ======================================================================

    /// Naive implementation of the documented query semantics: resolve every
    /// row, filter, sort, locate the cursor, and materialise one page. The
    /// cursor search is intentionally the same shape as the service's, so the
    /// differential comparison guards what the optimisation changed: which rows
    /// are returned, in which order, with which resolved project identity, and
    /// with which page metadata.
    private func referencePage(
        sessions: [FocusSession],
        query: FocusSessionQuery,
        cursor: FocusSessionCursor?,
        limit: Int,
        resolver: (FocusProjectContext) -> FocusProjectContext
    ) -> FocusSessionQueryPage? {
        var resolved: [FocusSession] = []
        for session in sessions {
            var row = session
            row.project = resolver(session.project)
            if let dayStart = query.dayStart, row.dayIdentifier < dayStart { continue }
            if let dayEnd = query.dayEnd, row.dayIdentifier > dayEnd { continue }
            if let status = query.status, row.status != status { continue }
            if let projectKey = query.projectKey, row.project.key != projectKey { continue }
            if let keyword = query.keyword, !keyword.isEmpty {
                let lowered = keyword.lowercased()
                guard row.project.displayName.lowercased().contains(lowered)
                    || row.project.key.lowercased().contains(lowered) else { continue }
            }
            resolved.append(row)
        }
        resolved.sort { a, b in
            if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            return a.id.uuidString < b.id.uuidString
        }

        let totalCount = resolved.count
        let startIndex: Int
        var cursorMissed = false
        if let cursor {
            var lowerBound = 0
            var upperBound = totalCount
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                let session = resolved[middle]
                let comesBeforeOrAtCursor = session.startedAt > cursor.lastStartedAt
                    || (session.startedAt == cursor.lastStartedAt
                        && session.id.uuidString <= cursor.lastID.uuidString)
                if comesBeforeOrAtCursor {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            if lowerBound < totalCount {
                startIndex = lowerBound
            } else {
                startIndex = totalCount
                cursorMissed = true
            }
        } else {
            startIndex = 0
        }

        guard startIndex < totalCount else {
            return cursorMissed ? nil : .empty
        }
        let endIndex = min(startIndex + limit, totalCount)
        let page = Array(resolved[startIndex ..< endIndex])
        let hasMore = endIndex < totalCount
        return FocusSessionQueryPage(
            sessions: page,
            nextCursor: hasMore
                ? FocusSessionCursor(lastStartedAt: page.last!.startedAt, lastID: page.last!.id)
                : nil,
            hasMore: hasMore,
            totalEstimatedCount: totalCount
        )
    }

    /// Every page the optimised service returns must equal the naive per-row
    /// reference: same rows, same order, same resolved project identity, same
    /// cursor and counts. Rows are emitted newest first with legacy alias keys
    /// so resolution is observable in the returned page.
    func testMemoisedQueryMatchesPerRowReferenceImplementation() async throws {
        let sessions: [FocusSession] = (0 ..< 240).map { index in
            let day = String(format: "2026-07-%02d", 1 + index / 20)
            let slot = index % 20
            // A block of identical timestamps straddles the 25-row page
            // boundary, so the uuid tie-break has to agree across pages.
            let sharedTimestamp = (30 ..< 60).contains(index)
            let startedAt = sharedTimestamp
                ? Date(timeIntervalSinceReferenceDate: 800_000_000 + 50 * 900)
                : Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) * 900)
            let isOpen = index % 61 == 0
            let isPaused = index % 47 == 0
            return FocusSession(
                id: UUID(),
                project: FocusProjectContext(key: "repo.\(index % 5)", displayName: "Legacy \(index % 5)"),
                dayIdentifier: day,
                startedAt: startedAt,
                endedAt: isOpen || isPaused ? nil : startedAt.addingTimeInterval(600),
                status: isOpen ? .active : (isPaused ? .paused : .ended),
                lastUserActivityAt: startedAt,
                lastStateChangeAt: startedAt,
                decisionEvents: slot.isMultiple(of: 3)
                    ? [FocusSessionDecisionEvent(at: startedAt, kind: .started, reason: .userActivity, source: .automatic)]
                    : nil
            )
        }
        // Duplicate-free permutation: newest and oldest interleaved, so the
        // provider order is neither display order nor a single sorted run.
        var providerRows: [FocusSession] = []
        providerRows.reserveCapacity(sessions.count)
        var lower = 0
        var upper = sessions.count - 1
        while lower <= upper {
            providerRows.append(sessions[upper])
            if lower != upper { providerRows.append(sessions[lower]) }
            lower += 1
            upper -= 1
        }
        XCTAssertEqual(Set(providerRows.map(\.id)).count, sessions.count, "fixture rows must be unique")

        let resolver: @Sendable (FocusProjectContext) -> FocusProjectContext = { context in
            guard let index = Int(context.key.dropFirst("repo.".count)) else { return context }
            return FocusProjectContext(key: "project.\(index)", displayName: "Project \(index)")
        }
        let providerSnapshot = providerRows
        let service = FocusSessionQueryService(
            sessionProvider: { providerSnapshot },
            projectResolver: resolver
        )

        let queries: [FocusSessionQuery] = [
            FocusSessionQuery(),
            FocusSessionQuery(dayStart: "2026-07-04", dayEnd: "2026-07-09"),
            FocusSessionQuery(status: .ended),
            FocusSessionQuery(status: .active),
            FocusSessionQuery(projectKey: "project.3"),
            FocusSessionQuery(keyword: "PROJECT 1"),
            FocusSessionQuery(keyword: "repo.2"),
            FocusSessionQuery(keyword: ""),
            FocusSessionQuery(
                dayStart: "2026-07-05",
                dayEnd: "2026-07-11",
                projectKey: "project.4",
                status: .ended,
                keyword: "project"
            )
        ]

        for query in queries {
            var cursor: FocusSessionCursor?
            var pages = 0
            var visited: [UUID] = []
            var reportedTotal: Int?
            // The fixture holds 240 rows, so an unbounded walk must end because
            // `hasMore` became false, not because a page cap was hit.
            while pages < 40 {
                let expected = referencePage(
                    sessions: providerRows,
                    query: query,
                    cursor: cursor,
                    limit: 25,
                    resolver: resolver
                )
                let actual = await service.execute(
                    query: query,
                    cursor: cursor,
                    limit: 25,
                    version: 0
                )
                XCTAssertEqual(
                    actual,
                    expected,
                    "page \(pages) diverged for query \(query) with cursor \(String(describing: cursor))"
                )
                let estimatedCount = await service.estimatedCount(query: query)
                XCTAssertEqual(
                    estimatedCount,
                    expected?.totalEstimatedCount ?? 0,
                    "estimated count diverged for query \(query)"
                )
                guard let page = actual else {
                    // Continuity break: pagination must restart, so the walk ends.
                    XCTFail("pagination lost continuity for query \(query) at page \(pages)")
                    break
                }
                reportedTotal = reportedTotal ?? page.totalEstimatedCount
                visited.append(contentsOf: page.sessions.map(\.id))
                guard page.hasMore, let next = page.nextCursor else { break }
                cursor = next
                pages += 1
            }
            // Walking every page visits each matching row exactly once and stops
            // on its own, independent of the shared cursor search shape.
            XCTAssertEqual(visited.count, reportedTotal ?? 0, "pagination must visit every matching row")
            XCTAssertEqual(Set(visited).count, visited.count, "pagination must not repeat a row")
            XCTAssertLessThan(pages, 40, "pagination must terminate by exhausting the result set")
        }
    }

    /// Rows sharing a timestamp across a page boundary must still be visited
    /// exactly once, in the documented uuid order.
    func testIdenticalTimestampsAcrossPageBoundaryVisitEveryRowOnce() async throws {
        let shared = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let rows: [FocusSession] = (0 ..< 40).map { index in
            FocusSession(
                project: FocusProjectContext(key: "repo.alpha", displayName: "Alpha"),
                dayIdentifier: "2026-07-20",
                startedAt: index < 12 ? shared : shared.addingTimeInterval(-Double(index)),
                endedAt: shared.addingTimeInterval(600),
                status: .ended,
                lastUserActivityAt: shared,
                lastStateChangeAt: shared
            )
        }
        let service = FocusSessionQueryService(sessionProvider: { rows })

        var visited: [UUID] = []
        var cursor: FocusSessionCursor?
        while true {
            let pageResult = await service.execute(
                query: FocusSessionQuery(),
                cursor: cursor,
                limit: 5,
                version: 0
            )
            let page = try XCTUnwrap(pageResult)
            visited.append(contentsOf: page.sessions.map(\.id))
            guard page.hasMore, let next = page.nextCursor else { break }
            cursor = next
        }
        XCTAssertEqual(visited.count, rows.count)
        XCTAssertEqual(Set(visited).count, rows.count, "tie rows must not repeat")
        // The 12 tied rows come first, ordered by uuidString ascending.
        let tiedIDs = rows.filter { $0.startedAt == shared }.map(\.id)
        XCTAssertEqual(Array(visited.prefix(12)), tiedIDs.sorted { $0.uuidString < $1.uuidString })
    }

    /// A deleted cursor row with surviving rows after it: the frozen behaviour
    /// is to continue from the next surviving row (no gap, no duplicate), not to
    /// restart from the first page.
    func testPaginationContinuesAfterCursorRowDeletion() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 950_000_000)
        let box = SessionBox((0 ..< 10).map { index in
            FocusSession(
                project: FocusProjectContext(key: "repo.alpha", displayName: "Alpha"),
                dayIdentifier: "2026-07-20",
                startedAt: base.addingTimeInterval(-Double(index) * 600),
                endedAt: base,
                status: .ended,
                lastUserActivityAt: base,
                lastStateChangeAt: base
            )
        })
        let rows = box.value
        let service = FocusSessionQueryService(sessionProvider: { box.value })

        // Page 1 is the three newest rows; the cursor points at the third.
        let firstPageResult = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 3,
            version: 0
        )
        let firstPage = try XCTUnwrap(firstPageResult)
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        XCTAssertEqual(firstPage.sessions.map(\.id), Array(rows.prefix(3).map(\.id)))

        // The cursor row (and the one before it) disappear between pages.
        box.value.removeAll { $0.id == rows[2].id || $0.id == rows[1].id }

        let secondPageResult = await service.execute(
            query: FocusSessionQuery(),
            cursor: cursor,
            limit: 3,
            version: 0
        )
        let secondPage = try XCTUnwrap(secondPageResult)
        XCTAssertEqual(secondPage.sessions.map(\.id), Array(rows[3 ..< 6].map(\.id)))
        XCTAssertEqual(secondPage.totalEstimatedCount, 8)
    }

    /// The memo fixes the first resolution of an exact input context for the
    /// duration of one call, so a single page cannot mix two identities of the
    /// same project. This pins the documented concurrent-registry-mutation
    /// boundary instead of leaving it implicit.
    func testSinglePageUsesOneIdentityPerInputContext() async throws {
        let counter = ResolverCallCounter()
        let base = Date(timeIntervalSinceReferenceDate: 960_000_000)
        let rows: [FocusSession] = (0 ..< 9).map { index in
            FocusSession(
                project: FocusProjectContext(key: "repo.alpha", displayName: "Alpha"),
                dayIdentifier: "2026-07-20",
                startedAt: base.addingTimeInterval(-Double(index) * 600),
                endedAt: base,
                status: .ended,
                lastUserActivityAt: base,
                lastStateChangeAt: base
            )
        }
        let service = FocusSessionQueryService(
            sessionProvider: { rows },
            projectResolver: { context in
                counter.record()
                // Simulates a registry that is renamed between two lookups.
                let name = counter.count == 1 ? "Before" : "After"
                return FocusProjectContext(key: context.key, displayName: name)
            }
        )
        let identityPageResult = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 9,
            version: 0
        )
        let page = try XCTUnwrap(identityPageResult)
        XCTAssertEqual(counter.count, 1, "one input context must resolve once per call")
        XCTAssertEqual(Set(page.sessions.map(\.project.displayName)), ["Before"])
    }

    /// Project summaries keep the documented newest-name and uuid tie-break rule
    /// when two historical contexts of one project share a timestamp.
    func testProjectSummaryTieBreakMatchesPerRowResolution() async throws {
        let shared = Date(timeIntervalSinceReferenceDate: 970_000_000)
        let older = shared.addingTimeInterval(-3_600)
        let rows: [FocusSession] = [
            FocusSession(
                project: FocusProjectContext(key: "repo.alpha", displayName: "Renamed Later"),
                dayIdentifier: "2026-07-20",
                startedAt: shared,
                endedAt: shared,
                status: .ended,
                lastUserActivityAt: shared,
                lastStateChangeAt: shared
            ),
            FocusSession(
                project: FocusProjectContext(key: "canonical", displayName: "Older Name"),
                dayIdentifier: "2026-07-19",
                startedAt: older,
                endedAt: older,
                status: .ended,
                lastUserActivityAt: older,
                lastStateChangeAt: older
            )
        ]
        let resolver: @Sendable (FocusProjectContext) -> FocusProjectContext = { context in
            FocusProjectContext(key: "project.alpha", displayName: context.displayName)
        }
        let service = FocusSessionQueryService(sessionProvider: { rows }, projectResolver: resolver)

        let projectsResult = await service.projects(version: 0)
        let projects = try XCTUnwrap(projectsResult)
        // Both contexts resolve to the same canonical key, so the newest row's
        // name is the only summary.
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.key, "project.alpha")
        XCTAssertEqual(projects.first?.displayName, "Renamed Later")
        XCTAssertEqual(counterFreeRowCount(rows, resolver: resolver), projects.count)
    }

    /// Number of distinct resolved identities, computed one row at a time.
    private func counterFreeRowCount(
        _ rows: [FocusSession],
        resolver: (FocusProjectContext) -> FocusProjectContext
    ) -> Int {
        Set(rows.map { resolver($0.project) }.map(\.key)).count
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

    func testCursorMissReturnsNilInsteadOfTruncating() async throws {
        let base = try date("2026-07-20T12:00:00Z")
        let sessions = makeOrderedSessions(count: 25, project: alpha, base: base)
        let box = SessionBox(sessions)
        let service = FocusSessionQueryService(sessionProvider: { box.value })

        let r1 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let page1 = try XCTUnwrap(r1)
        XCTAssertEqual(page1.sessions.count, 10)
        XCTAssertNotNil(page1.nextCursor)

        // Delete every session between pages without a version bump: the
        // cursor key no longer exists, so continuation is impossible.
        box.value.removeAll()

        // A cursor miss must signal a restart (nil) instead of returning an
        // empty page that silently truncates the remaining sessions.
        let r2 = await service.execute(
            query: FocusSessionQuery(),
            cursor: page1.nextCursor,
            limit: 10,
            version: 0
        )
        XCTAssertNil(r2)

        // A nil cursor still yields an empty page for an empty result set.
        let r3 = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 10,
            version: 0
        )
        let empty = try XCTUnwrap(r3)
        XCTAssertTrue(empty.sessions.isEmpty)
        XCTAssertFalse(empty.hasMore)
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

    func testNonPositiveLimitReturnsEmptyPageInsteadOfTrapping() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let service = makeService(sessions: [
            session(project: alpha, day: "2026-07-20", start: start)
        ])

        for limit in [0, -1, Int.min] {
            let result = await service.execute(
                query: FocusSessionQuery(),
                cursor: nil,
                limit: limit,
                version: 0
            )
            let page = try XCTUnwrap(result)
            XCTAssertTrue(page.sessions.isEmpty)
            XCTAssertFalse(page.hasMore)
            XCTAssertNil(page.nextCursor)
        }
    }

    func testMaximumLimitDoesNotOverflowPageBoundary() async throws {
        let base = try date("2026-07-20T12:00:00Z")
        let service = makeService(sessions: makeOrderedSessions(
            count: 3,
            project: alpha,
            base: base
        ))

        let result = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: Int.max,
            version: 0
        )
        let page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.count, 3)
        XCTAssertFalse(page.hasMore)
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
