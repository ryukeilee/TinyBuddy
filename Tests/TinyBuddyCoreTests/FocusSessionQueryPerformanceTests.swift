import XCTest
@testable import TinyBuddyCore

final class FocusSessionQueryPerformanceTests: XCTestCase {

    // MARK: - Helpers

    /// Creates `count` sessions with varied dates and projects.
    /// Days cycle through 2026-07-01 … 2026-07-22 (22 unique days).
    /// Projects cycle through 20 unique keys (repo.0 … repo.19).
    /// `startedAt` decreases with index so sorting is non-trivial.
    private func makeSessions(count: Int) -> [FocusSession] {
        (0 ..< count).map { i in
            let projectIndex = i % 20
            let project = FocusProjectContext(
                key: "repo.\(projectIndex)",
                displayName: "Project \(projectIndex)"
            )
            let day = String(format: "2026-07-%02d", (i % 22) + 1)
            let startedAt = Date(timeIntervalSinceReferenceDate: Double(count - i) * 100)
            return FocusSession(
                project: project,
                dayIdentifier: day,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(600),
                status: .ended,
                lastUserActivityAt: startedAt.addingTimeInterval(600),
                lastStateChangeAt: startedAt.addingTimeInterval(600)
            )
        }
    }

    /// Creates a service backed by `count` deterministic sessions.
    private func makeService(count: Int) -> FocusSessionQueryService {
        let sessions = makeSessions(count: count)
        return FocusSessionQueryService(sessionProvider: { sessions })
    }

    /// Creates 100 sessions all sharing the exact same `startedAt` to
    /// exercise the UUID-based tie-breaking in sorting.
    private func makeIdenticalTimestampService() -> FocusSessionQueryService {
        let sameDate = Date(timeIntervalSinceReferenceDate: 100_000_000)
        let sessions = (0 ..< 100).map { i in
            FocusSession(
                project: FocusProjectContext(
                    key: "repo.\(i)",
                    displayName: "Project \(i)"
                ),
                dayIdentifier: "2026-07-01",
                startedAt: sameDate,
                endedAt: sameDate.addingTimeInterval(600),
                status: .ended,
                lastUserActivityAt: sameDate.addingTimeInterval(600),
                lastStateChangeAt: sameDate.addingTimeInterval(600)
            )
        }
        return FocusSessionQueryService(sessionProvider: { sessions })
    }

    // MARK: - Large Dataset Benchmarks

    /// Measures the time to load the first page of 50 from 10_000 sessions.
    /// Expected baseline: < 0.1 s.
    func testFirstPageLoadTime() throws {
        let service = makeService(count: 10_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            let exp = expectation(description: "firstPage")
            Task {
                let page = await service.execute(
                    query: FocusSessionQuery(),
                    cursor: nil,
                    limit: 50,
                    version: 0
                )
                XCTAssertNotNil(page)
                XCTAssertEqual(page?.sessions.count, 50)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10)
        }
    }

    /// Measures the time to page through all 10_000 sessions
    /// (100 pages of 100). Expected baseline: < 1.0 s.
    func testFullPaginationTime() throws {
        let service = makeService(count: 10_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let exp = expectation(description: "fullPagination")
            Task {
                var cursor: FocusSessionCursor?
                var total = 0
                while true {
                    guard let page = await service.execute(
                        query: FocusSessionQuery(),
                        cursor: cursor,
                        limit: 100,
                        version: 0
                    ) else {
                        XCTFail("unexpected nil page")
                        break
                    }
                    total += page.sessions.count
                    guard page.hasMore, let next = page.nextCursor else { break }
                    cursor = next
                }
                XCTAssertEqual(total, 10_000)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30)
        }
    }

    /// Measures the time to apply a day-range filter to 10_000 sessions.
    /// Expected baseline: < 0.05 s.
    func testFilterApplicationTime() throws {
        let service = makeService(count: 10_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            let exp = expectation(description: "filter")
            Task {
                let query = FocusSessionQuery(
                    dayStart: "2026-07-10",
                    dayEnd: "2026-07-15"
                )
                let page = await service.execute(
                    query: query,
                    cursor: nil,
                    limit: 50,
                    version: 0
                )
                XCTAssertNotNil(page)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10)
        }
    }

    /// Verifies that after `invalidateQueries()`, calls with old versions
    /// return `nil`, while a fresh call with the current version succeeds.
    /// The actor serialises calls, so overlapping queries cannot be in-flight
    /// concurrently; this test validates the version guard itself.
    func testConcurrentQueryCancellation() async throws {
        let service = makeService(count: 10_000)

        // 1. Run a first batch of queries at version 0 (succeeds).
        let v0Result = await service.execute(
            query: FocusSessionQuery(), cursor: nil, limit: 10, version: 0
        )
        XCTAssertNotNil(v0Result)
        XCTAssertEqual(v0Result?.sessions.count, 10)

        // 2. Invalidate — bumps internal version to 1.
        await service.invalidateQueries()

        // 3. Version 0 queries should now return nil.
        let staleResult = await service.execute(
            query: FocusSessionQuery(), cursor: nil, limit: 10, version: 0
        )
        XCTAssertNil(staleResult, "stale version 0 after invalidation should return nil")

        // 4. Version 1 queries should succeed.
        let freshResult = await service.execute(
            query: FocusSessionQuery(), cursor: nil, limit: 10, version: 1
        )
        XCTAssertNotNil(freshResult, "current version after invalidation should succeed")
        XCTAssertEqual(freshResult?.sessions.count, 10)
    }

    // MARK: - Memory Benchmarks

    /// Measures physical memory delta while paginating through 10_000
    /// sessions. The service uses a fresh `sessionProvider` closure each
    /// call and does not retain page arrays across invocations, so memory
    /// should remain stable.
    func testMemoryUsageDuringPagination() throws {
        let service = makeService(count: 10_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let exp = expectation(description: "memoryPagination")
            Task {
                var cursor: FocusSessionCursor?
                while true {
                    guard let page = await service.execute(
                        query: FocusSessionQuery(),
                        cursor: cursor,
                        limit: 100,
                        version: 0
                    ) else { break }
                    guard page.hasMore, let next = page.nextCursor else { break }
                    cursor = next
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30)
        }
    }

    // MARK: - Edge Case Performance

    /// Empty session provider: query must return an empty page instantly.
    func testEmptyDataset() throws {
        let service = FocusSessionQueryService(sessionProvider: { [] })
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            let exp = expectation(description: "emptyQuery")
            Task {
                let page = await service.execute(
                    query: FocusSessionQuery(),
                    cursor: nil,
                    limit: 50,
                    version: 0
                )
                XCTAssertNotNil(page)
                XCTAssertTrue(page!.sessions.isEmpty)
                XCTAssertNil(page!.nextCursor)
                XCTAssertFalse(page!.hasMore)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5)
        }
    }

    /// 50 sessions (fewer than the requested page size of 100):
    /// a single page holds all results.
    func testSinglePagePerformance() throws {
        let service = makeService(count: 50)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            let exp = expectation(description: "singlePage")
            Task {
                let page = await service.execute(
                    query: FocusSessionQuery(),
                    cursor: nil,
                    limit: 100,
                    version: 0
                )
                XCTAssertNotNil(page)
                XCTAssertEqual(page?.sessions.count, 50)
                XCTAssertFalse(page!.hasMore)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5)
        }
    }

    // MARK: - Sort Stability Under Load

    /// 100 sessions share the exact same `startedAt`, forcing the
    /// tie-breaking sort on `id.uuidString`. Runs 3 repeated queries
    /// and asserts the result order is identical each time.
    func testSortStabilityWithIdenticalTimestamps() throws {
        let service = makeIdenticalTimestampService()

        // Warm up / establish the canonical order.
        let warmExp = expectation(description: "warmUp")
        var canonicalIDs: [UUID]?
        Task {
            let page = await service.execute(
                query: FocusSessionQuery(),
                cursor: nil,
                limit: 200,
                version: 0
            )
            canonicalIDs = page!.sessions.map(\.id)
            warmExp.fulfill()
        }
        wait(for: [warmExp], timeout: 5)
        let expectedIDs = try XCTUnwrap(canonicalIDs)
        // Verify it's indeed sorted by uuidString ascending.
        let sorted = expectedIDs.sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(expectedIDs, sorted,
                       "tie-breaking must order by id.uuidString ascending")

        // Repeat the query twice more and verify identical ordering.
        for iteration in 0 ..< 2 {
            let exp = expectation(description: "sortStability_\(iteration)")
            Task {
                let page = await service.execute(
                    query: FocusSessionQuery(),
                    cursor: nil,
                    limit: 200,
                    version: 0
                )
                let ids = page!.sessions.map(\.id)
                XCTAssertEqual(ids, expectedIDs,
                               "sort order must be deterministic across queries")
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5)
        }
    }
}
