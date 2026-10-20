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

/// Thread-safe provider that records how often it was read. An accepted query
/// request reads the provider's array exactly once, whatever its query shape.
final class CountingSessionProvider: @unchecked Sendable {
    let snapshot: [FocusSession]
    private let lock = NSLock()
    private var calls = 0

    init(_ snapshot: [FocusSession]) { self.snapshot = snapshot }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func provide() -> [FocusSession] {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return snapshot
    }
}

/// Every ordering of `items`, so a test can prove a result does not depend on
/// provider order. Only used with the small fixtures in this file.
private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    var results: [[T]] = []
    for index in items.indices {
        var rest = items
        let head = rest.remove(at: index)
        for tail in permutations(rest) {
            results.append([head] + tail)
        }
    }
    return results
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

    /// Project summaries keep the documented newest-name rule, and two
    /// historical contexts of one project that share a timestamp are named by
    /// the row the display order considers newest, which for equal timestamps
    /// is the smallest `id.uuidString` (`testTieBreakerUUID` pins that display
    /// order). The fixture's ids differ in their last hex digit (`…0009` vs
    /// `…000a`), so the assertion depends on the tie-break and not on provider
    /// order.
    func testProjectSummaryTieBreakMatchesPerRowResolution() async throws {
        let shared = Date(timeIntervalSinceReferenceDate: 970_000_000)
        let winningID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000009"))
        let losingID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000a"))
        XCTAssertLessThan(winningID.uuidString, losingID.uuidString)
        let rows: [FocusSession] = [
            session(
                project: FocusProjectContext(key: "repo.alpha", displayName: "Winner By Uuid Order"),
                day: "2026-07-20",
                start: shared,
                end: shared,
                id: winningID
            ),
            session(
                project: FocusProjectContext(key: "canonical", displayName: "Loser By Uuid Order"),
                day: "2026-07-19",
                start: shared,
                end: shared,
                id: losingID
            )
        ]
        let resolver: @Sendable (FocusProjectContext) -> FocusProjectContext = { context in
            FocusProjectContext(key: "project.alpha", displayName: context.displayName)
        }
        let service = FocusSessionQueryService(sessionProvider: { rows }, projectResolver: resolver)

        let projectsResult = await service.projects(version: 0)
        let projects = try XCTUnwrap(projectsResult)
        // Both contexts resolve to the same canonical key, so the tied rows
        // collapse into one summary named by the smallest uuidString.
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.key, "project.alpha")
        XCTAssertEqual(projects.first?.displayName, "Winner By Uuid Order")
        XCTAssertEqual(counterFreeRowCount(rows, resolver: resolver), projects.count)
        XCTAssertEqual(
            projects.sorted { $0.key < $1.key },
            referenceProjectSummaries(rows, resolver: resolver)
        )

        // The winner must not be "whichever row came last": the same rows in
        // the opposite provider order still produce the identical summary.
        let reversedProvider = Array(rows.reversed())
        let reversedService = FocusSessionQueryService(
            sessionProvider: { reversedProvider },
            projectResolver: resolver
        )
        let reversedResult = await reversedService.projects(version: 0)
        XCTAssertEqual(reversedResult, projects)
    }

    /// Same-key rows sharing one timestamp must always be summarised by the row
    /// the display order considers newest, whatever order the provider returns
    /// them in. The four fixture ids sit on hex-digit boundaries (last byte
    /// 09/0a and 90/a0) where a byte-wise comparison and a string comparison
    /// could disagree if either side changed.
    func testProjectSummaryTieBreakMatchesUUIDStringOrdering() async throws {
        let shared = Date(timeIntervalSinceReferenceDate: 971_000_000)
        let uuids = [
            "00000000-0000-0000-0000-000000000009",
            "00000000-0000-0000-0000-00000000000a",
            "00000000-0000-0000-0000-000000000090",
            "00000000-0000-0000-0000-0000000000a0"
        ].compactMap { UUID(uuidString: $0) }
        XCTAssertEqual(uuids.count, 4, "fixture ids must parse")
        XCTAssertEqual(Set(uuids).count, uuids.count, "fixture ids must be unique")

        let rows = uuids.enumerated().map { index, id in
            session(
                project: FocusProjectContext(key: "repo.\(index)", displayName: "Row \(index)"),
                day: "2026-07-20",
                start: shared,
                end: shared,
                id: id
            )
        }
        let resolver: @Sendable (FocusProjectContext) -> FocusProjectContext = { context in
            FocusProjectContext(key: "project.alpha", displayName: context.displayName)
        }
        let expectedNameByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.project.displayName) })
        // Display order puts the smallest `id.uuidString` first among rows with
        // equal timestamps, and `projects()` names the project after that row.
        let winningID = try XCTUnwrap(uuids.min { $0.uuidString < $1.uuidString })
        let winningName = try XCTUnwrap(expectedNameByID[winningID])

        var testedOrders = 0
        for order in permutations(Array(rows.indices)) {
            testedOrders += 1
            let reordered = order.map { rows[$0] }
            let service = FocusSessionQueryService(
                sessionProvider: { reordered },
                projectResolver: resolver
            )
            let projectsResult = await service.projects(version: 0)
            let projects = try XCTUnwrap(projectsResult)
            XCTAssertEqual(projects.count, 1, "order \(order) must collapse to one summary")
            XCTAssertEqual(projects.first?.key, "project.alpha", "order \(order)")
            XCTAssertEqual(
                projects.first?.displayName,
                winningName,
                "order \(order) must name the row with the smallest uuidString"
            )
        }
        XCTAssertEqual(testedOrders, 24, "every ordering of four rows must be checked")
    }

    /// `projects(version:)` must agree with the naive per-row reference for
    /// every grouping and tie-break combination: three legacy contexts per
    /// project, three rows tied at each project's maximum timestamp, and a
    /// provider order that is neither chronological nor grouped by project.
    ///
    /// The fixture is built so both pinned rules are observable: every
    /// canonical key is fed by three distinct display names, the tie that
    /// decides each summary happens at that key's maximum `startedAt`, and at
    /// least one key is won by a row that is neither the first nor the last row
    /// the provider returns for it. The self-checks below fail the test if a
    /// later edit erodes any of those properties.
    func testProjectSummariesMatchPerRowReference() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 972_000_000)
        let rows: [FocusSession] = try (0 ..< 60).map { index in
            let projectIndex = index % 4
            // `aliasIndex` varies independently of `projectIndex` (mod 3 vs
            // mod 4), so each canonical project is fed by three distinct input
            // contexts. Rows `p`, `p + 4` and `p + 8` of every project share
            // that project's maximum `startedAt`, so the three names compete on
            // the uuid tie-break and the winner stays observable in the summary.
            let aliasIndex = index % 3
            let startedAt: Date
            if [0, 4, 8].contains(index - projectIndex) {
                startedAt = base.addingTimeInterval(100_000 + Double(projectIndex) * 900)
            } else {
                startedAt = base.addingTimeInterval(Double(index) * 900)
            }
            return session(
                project: FocusProjectContext(
                    key: "legacy.\(projectIndex).\(aliasIndex)",
                    displayName: "Legacy \(projectIndex)-\(aliasIndex)"
                ),
                day: "2026-07-20",
                start: startedAt,
                end: startedAt,
                // Deterministic, zero-padded ids so the winner of each tie is
                // fixed and the order matches `uuidString` ordering.
                id: try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
            )
        }
        // Interleave newest and oldest, so the provider order is neither
        // display order nor a single sorted run.
        var providerRows: [FocusSession] = []
        providerRows.reserveCapacity(rows.count)
        var lower = 0
        var upper = rows.count - 1
        while lower <= upper {
            providerRows.append(rows[upper])
            if lower != upper { providerRows.append(rows[lower]) }
            lower += 1
            upper -= 1
        }
        XCTAssertEqual(Set(providerRows.map(\.id)).count, rows.count, "fixture rows must be unique")

        let resolver: @Sendable (FocusProjectContext) -> FocusProjectContext = { context in
            let projectIndex = context.key.split(separator: ".")[1]
            return FocusProjectContext(key: "project.\(projectIndex)", displayName: context.displayName)
        }
        let snapshot = providerRows
        let service = FocusSessionQueryService(sessionProvider: { snapshot }, projectResolver: resolver)

        // Fixture self-checks. They guard the properties the equivalence
        // assertion below needs: without them an edit that collapsed the aliases
        // or moved the tied rows off the maximum timestamp would let the test
        // keep passing while testing nothing about the newest-name or tie-break
        // rules.
        let rowsByKey = Dictionary(grouping: snapshot) { resolver($0.project).key }
        for (key, keyRows) in rowsByKey {
            let names = Set(keyRows.map { resolver($0.project).displayName })
            XCTAssertGreaterThanOrEqual(
                names.count,
                2,
                "canonical key \(key) must be fed by at least two input contexts, otherwise the newest-name rule is unobservable"
            )
            let maxStartedAt = try XCTUnwrap(keyRows.map(\.startedAt).max())
            XCTAssertGreaterThanOrEqual(
                keyRows.filter { $0.startedAt == maxStartedAt }.count,
                2,
                "canonical key \(key) must tie on its maximum startedAt, otherwise the id tie-break never decides the summary"
            )
        }
        var firstRowByKey: [String: FocusSession] = [:]
        var lastRowByKey: [String: FocusSession] = [:]
        for row in snapshot {
            let key = resolver(row.project).key
            if firstRowByKey[key] == nil { firstRowByKey[key] = row }
            lastRowByKey[key] = row
        }
        let referenceWinners = referenceProjectSummaryWinners(snapshot, resolver: resolver)
        XCTAssertTrue(
            referenceWinners.contains { entry in
                firstRowByKey[entry.key].map { $0.id != entry.value.id } ?? false
            },
            "at least one key must be won by a row other than its first provider row, otherwise a \"first row wins\" shortcut would still pass"
        )
        XCTAssertTrue(
            referenceWinners.contains { entry in
                lastRowByKey[entry.key].map { $0.project.displayName != entry.value.project.displayName } ?? false
            },
            "at least one key must be won by a name other than its last provider row's, otherwise a \"last row wins\" shortcut would still pass"
        )

        let projectsResult = await service.projects(version: 0)
        let projects = try XCTUnwrap(projectsResult)
        XCTAssertEqual(projects.count, 4)
        XCTAssertEqual(
            projects.sorted { $0.key < $1.key },
            referenceProjectSummaries(snapshot, resolver: resolver)
        )
    }

    /// Naive, non-memoised reference for the project-summary rule: group rows by
    /// their resolved key, keep the newest `startedAt` and, on a tie, the row
    /// the display order treats as newest — the one with the smallest
    /// `id.uuidString` (`DisplayOrderKey.precedes` sorts ascending ids first, so
    /// a smaller id reads as newer). The result is sorted by key so callers can
    /// compare it with the service's display-name ordering without assuming the
    /// two orders coincide.
    private func referenceProjectSummaries(
        _ rows: [FocusSession],
        resolver: (FocusProjectContext) -> FocusProjectContext
    ) -> [FocusProjectContext] {
        referenceProjectSummaryWinners(rows, resolver: resolver)
            .values.map(\.project)
            .sorted { $0.key < $1.key }
    }

    /// Same rule as `referenceProjectSummaries`, but keeps the winning row's id
    /// so a caller can assert which row produced each summary.
    private func referenceProjectSummaryWinners(
        _ rows: [FocusSession],
        resolver: (FocusProjectContext) -> FocusProjectContext
    ) -> [String: (startedAt: Date, id: UUID, project: FocusProjectContext)] {
        var newest: [String: (startedAt: Date, id: UUID, project: FocusProjectContext)] = [:]
        for row in rows {
            let project = resolver(row.project)
            if let previous = newest[project.key],
               previous.startedAt > row.startedAt
                || (previous.startedAt == row.startedAt
                    && previous.id.uuidString < row.id.uuidString) { continue }
            newest[project.key] = (row.startedAt, row.id, project)
        }
        return newest
    }

    /// Walking the snapshot backwards must not change what a query returns:
    /// the same rows supplied in append order (oldest first, which is how
    /// `FocusSessionEngine` stores them) and in display order (newest first)
    /// must produce the same pages, row contents, page sizes, `hasMore` flags,
    /// cursors and counts.
    ///
    /// Two fixtures: one whose tie groups are already in id order (so the
    /// backwards walk emits an almost fully sorted run) and one whose tie groups
    /// are in reverse id order (so the sort has to move rows). Both must page
    /// identically, which is what makes the reversed walk a pure cost change.
    func testAppendAndDisplayOrderProviderInputProduceIdenticalPages() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 973_000_000)
        // Three tie groups of four rows; `reverseTies` flips the id order inside
        // the newer two groups.
        func fixture(reverseTies: Bool) -> [FocusSession] {
            var rows: [FocusSession] = []
            for group in 0 ..< 3 {
                let startedAt = base.addingTimeInterval(Double(group) * 1_800)
                for slot in 0 ..< 4 {
                    let id = UUID(uuidString: String(
                        format: "00000000-0000-0000-0000-%012d",
                        group * 10 + (reverseTies && group > 0 ? 3 - slot : slot)
                    ))!
                    rows.append(session(
                        project: FocusProjectContext(key: "repo.alpha", displayName: "Alpha"),
                        day: "2026-07-20",
                        start: startedAt,
                        end: startedAt.addingTimeInterval(60),
                        id: id
                    ))
                }
            }
            return rows
        }

        /// Pages the fixture at a page size below the row count, so every tie
        /// group must also be split across a page boundary. Whole pages are
        /// returned, so page metadata is compared too.
        func traverse(_ rows: [FocusSession]) async throws -> [FocusSessionQueryPage] {
            let service = FocusSessionQueryService(sessionProvider: { rows })
            var pages: [FocusSessionQueryPage] = []
            var cursor: FocusSessionCursor?
            // Bounded: 12 rows at 5 per page is at most 3 pages. The bound stops
            // the loop even if the service never reports exhaustion, so a broken
            // cursor fails the assertions below instead of hanging the suite.
            for _ in 0 ..< 4 {
                let result = await service.execute(
                    query: FocusSessionQuery(),
                    cursor: cursor,
                    limit: 5,
                    version: 0
                )
                let page = try XCTUnwrap(result)
                pages.append(page)
                XCTAssertEqual(page.totalEstimatedCount, rows.count)
                guard page.hasMore else { return pages }
                let next = try XCTUnwrap(page.nextCursor, "hasMore must carry a cursor")
                cursor = next
            }
            return pages
        }

        for reverseTies in [false, true] {
            let appendOrdered = fixture(reverseTies: reverseTies)
            let displayOrdered = appendOrdered.sorted { a, b in
                a.startedAt != b.startedAt
                    ? a.startedAt > b.startedAt
                    : a.id.uuidString < b.id.uuidString
            }
            XCTAssertEqual(Set(appendOrdered.map(\.id)).count, appendOrdered.count, "fixture ids must be unique")

            let fromAppendOrder = try await traverse(appendOrdered)
            let fromDisplayOrder = try await traverse(displayOrdered)
            // Whole pages: rows, order, `hasMore`, `nextCursor` and the total.
            XCTAssertEqual(
                fromAppendOrder,
                fromDisplayOrder,
                "append-order input (reverseTies: \(reverseTies)) must page identically to display-order input"
            )
            XCTAssertEqual(fromAppendOrder.map { $0.sessions.count }, [5, 5, 2], "page sizes")
            XCTAssertEqual(fromAppendOrder.map(\.hasMore), [true, true, false], "hasMore flags")
            XCTAssertNil(fromAppendOrder.last?.nextCursor, "the last page carries no cursor")
            XCTAssertTrue(fromAppendOrder.dropLast().allSatisfy { $0.nextCursor != nil })
            XCTAssertEqual(fromDisplayOrder.flatMap(\.sessions), displayOrdered, "every row, once, in display order")
        }
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

    /// One request reads the provider exactly once and never mutates the array
    /// it was handed: the pre-key implementation sorted a copy-on-write copy of
    /// the returned array, and the key implementation indexes that same
    /// snapshot, so both must leave the caller's array untouched.
    func testExecuteReadsProviderOnceAndLeavesSnapshotUnchanged() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let rows = [
            session(project: alpha, day: "2026-07-20", start: start,
                    end: start.addingTimeInterval(600), status: .ended),
            session(project: beta, day: "2026-07-20", start: start.addingTimeInterval(60),
                    status: .active),
            session(project: gamma, day: "2026-07-20", start: start.addingTimeInterval(120),
                    end: start.addingTimeInterval(720), status: .ended),
            session(project: alpha, day: "2026-07-20", start: start.addingTimeInterval(180),
                    end: start.addingTimeInterval(780), status: .ended)
        ]
        let snapshotBefore = rows
        let provider = CountingSessionProvider(rows)
        let service = FocusSessionQueryService(sessionProvider: { provider.provide() })

        let query = FocusSessionQuery(status: .ended)
        let pageResult = await service.execute(query: query, cursor: nil, limit: 2, version: 0)
        let page = try XCTUnwrap(pageResult)
        XCTAssertEqual(provider.count, 1, "execute must read the provider exactly once")

        let estimated = await service.estimatedCount(query: query)
        XCTAssertEqual(estimated, 3)
        XCTAssertEqual(provider.count, 2, "estimatedCount must read the provider exactly once")

        // The row that matches no filter stays where the caller put it, and
        // every field of every row survives the query unchanged.
        XCTAssertEqual(provider.snapshot.count, snapshotBefore.count)
        for (actual, expected) in zip(provider.snapshot, snapshotBefore) {
            XCTAssertEqual(actual.id, expected.id)
            XCTAssertEqual(actual.project, expected.project)
            XCTAssertEqual(actual.dayIdentifier, expected.dayIdentifier)
            XCTAssertEqual(actual.startedAt, expected.startedAt)
            XCTAssertEqual(actual.endedAt, expected.endedAt)
            XCTAssertEqual(actual.status, expected.status)
            XCTAssertEqual(actual.lastUserActivityAt, expected.lastUserActivityAt)
            XCTAssertEqual(actual.lastStateChangeAt, expected.lastStateChangeAt)
            XCTAssertEqual(actual.pausedTotal, expected.pausedTotal)
            XCTAssertEqual(actual.currentPauseStartedAt, expected.currentPauseStartedAt)
            XCTAssertEqual(actual.isManuallyConfirmed, expected.isManuallyConfirmed)
            XCTAssertEqual(actual.manualRevision, expected.manualRevision)
            XCTAssertEqual(actual.decisionEvents, expected.decisionEvents)
            XCTAssertEqual(actual.mode, expected.mode)
            XCTAssertEqual(actual.ruleVersion, expected.ruleVersion)
        }
        XCTAssertEqual(provider.snapshot, snapshotBefore, "the provider array must be unchanged")

        // The page is the matching subset in display order, and every row
        // equals the provider array value at its key's index.
        let matchingIndexes = rows.indices
            .filter { rows[$0].status == .ended }
            .sorted { rows[$0].startedAt > rows[$1].startedAt }
        XCTAssertEqual(page.sessions, matchingIndexes.prefix(2).map { provider.snapshot[$0] })
        XCTAssertEqual(page.sessions.map(\.project), [alpha, gamma])
        XCTAssertTrue(page.hasMore)
    }

    /// Rows may share both sort components (startedAt and id) while differing in
    /// every other field. They have no order of their own, so the frozen rule is
    /// the one the previous implementation produced: the row that comes first in
    /// the provider snapshot wins, whatever order the provider is in. The
    /// service reads the snapshot backwards, so this is what the row index in the
    /// sort key is for.
    func testDuplicateSortKeysKeepProviderOrder() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let sharedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000ac"))
        let names = ["Alpha", "Beta", "Gamma", "Delta"]
        let rows = names.map { name in
            session(
                project: FocusProjectContext(key: "repo.\(name)", displayName: name),
                day: "2026-07-20",
                start: start,
                end: start,
                id: sharedID
            )
        }
        // Same provider order and its reverse, so a rule that depended on the
        // walk direction instead of the snapshot would disagree with itself.
        // Both directions are listed explicitly, so the two iterations cannot
        // collapse to the same sequence through type inference.
        for snapshot in [rows, Array(rows.reversed())] {
            let service = makeService(sessions: snapshot)
            let pageResult = await service.execute(
                query: FocusSessionQuery(),
                cursor: nil,
                limit: snapshot.count,
                version: 0
            )
            let page = try XCTUnwrap(pageResult)
            XCTAssertEqual(
                page.sessions.map(\.project.displayName),
                snapshot.map(\.project.displayName),
                "rows with identical sort keys must keep provider order"
            )
            XCTAssertFalse(page.hasMore)
        }
    }

    /// Two rows may share the exact same sort key (startedAt and id). The cursor
    /// rule is "strictly after the cursor key", so the page holding one of them
    /// reports `hasMore`, and the next request returns `nil`: pagination does
    /// not promise per-row access to rows whose sort key equals the cursor's.
    func testDuplicateSortKeysFollowTheStrictlyAfterCursorRule() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let sharedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000ab"))
        let rows = [
            session(project: alpha, day: "2026-07-20", start: start, id: sharedID),
            session(project: beta, day: "2026-07-20", start: start, id: sharedID)
        ]
        let service = makeService(sessions: rows)

        let firstResult = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 1,
            version: 0
        )
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.sessions.first?.project, alpha, "the earlier row wins when both sort components match")
        XCTAssertTrue(first.hasMore)
        let next = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(next.lastStartedAt, start)
        XCTAssertEqual(next.lastID, sharedID)

        let secondResult = await service.execute(
            query: FocusSessionQuery(),
            cursor: next,
            limit: 1,
            version: 0
        )
        XCTAssertNil(secondResult, "no row sorts strictly after an identical sort key")
    }

    /// The display-order tie-break compares `UUID`s byte-wise, which must stay
    /// equivalent to the documented `id.uuidString` ascending order. The sampled
    /// ids cover the first-byte boundaries (00/0a/0f/10/9f/a0/f0/ff) where a
    /// byte-wise and a string-wise comparison would disagree if either side
    /// changed, plus mid-string (third group 00ff/0100, fourth group 0001) and
    /// trailing (last group 0100) byte boundaries; the walk then asserts the
    /// cursor's `id` comparison reaches the same order one row at a time.
    func testDisplayOrderTieBreakMatchesUUIDStringOrdering() async throws {
        let start = try date("2026-07-20T10:00:00Z")
        let uuids = [
            "00000000-0000-0000-0000-000000000000",
            "00000000-0000-0000-0000-000000000001",
            "0a000000-0000-0000-0000-000000000000",
            "0f000000-0000-0000-0000-000000000000",
            "10000000-0000-0000-0000-000000000000",
            "9f000000-0000-0000-0000-000000000000",
            "a0000000-0000-0000-0000-000000000000",
            "f0000000-0000-0000-0000-000000000000",
            // Mid-string and trailing byte boundaries: the comparison must keep
            // ordering by nibble value beyond the first byte.
            "00000000-0000-0100-0000-000000000000",
            "00000000-0000-00ff-0000-000000000000",
            "00000000-0000-0000-0001-000000000000",
            "00000000-0000-0000-0000-000000000100",
            "ffffffff-ffff-ffff-ffff-ffffffffffff",
        ].compactMap { UUID(uuidString: $0) }
        XCTAssertEqual(uuids.count, 13, "fixture ids must parse")
        XCTAssertEqual(Set(uuids).count, uuids.count, "fixture ids must be unique")

        // A fixed index permutation, so the provider order is neither
        // ascending nor descending and holds every row exactly once.
        let providerOrder = [7, 0, 4, 8, 2, 6, 1, 3, 5, 12, 9, 11, 10].map { uuids[$0] }
        XCTAssertEqual(Set(providerOrder), Set(uuids), "permutation must keep every row")
        XCTAssertEqual(providerOrder.count, uuids.count, "permutation must keep every row once")
        let rows = providerOrder.map {
            session(project: alpha, day: "2026-07-20", start: start, id: $0)
        }
        let service = makeService(sessions: rows)

        let expected = uuids.sorted { $0.uuidString < $1.uuidString }
        let result = await service.execute(
            query: FocusSessionQuery(),
            cursor: nil,
            limit: 100,
            version: 0
        )
        let page = try XCTUnwrap(result)
        XCTAssertEqual(page.sessions.map(\.id), expected)
        XCTAssertFalse(page.hasMore)

        // One row per page must visit the same order without gaps or repeats.
        var visited: [UUID] = []
        var hasMoreFlags: [Bool] = []
        var cursor: FocusSessionCursor?
        for _ in 0 ..< uuids.count {
            let singleResult = await service.execute(
                query: FocusSessionQuery(),
                cursor: cursor,
                limit: 1,
                version: 0
            )
            let single = try XCTUnwrap(singleResult)
            XCTAssertEqual(single.sessions.count, 1)
            visited.append(single.sessions[0].id)
            hasMoreFlags.append(single.hasMore)
            if single.hasMore {
                XCTAssertNotNil(single.nextCursor)
            } else {
                XCTAssertNil(single.nextCursor)
            }
            cursor = single.nextCursor
        }
        XCTAssertEqual(visited, expected)
        XCTAssertEqual(Set(visited).count, expected.count)
        XCTAssertEqual(
            hasMoreFlags,
            Array(repeating: true, count: uuids.count - 1) + [false]
        )
        XCTAssertNil(cursor)
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
