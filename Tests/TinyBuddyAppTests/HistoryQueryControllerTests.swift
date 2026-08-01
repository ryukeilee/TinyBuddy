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
        startedAt: Date
    ) -> FocusSession {
        FocusSession(
            id: id,
            project: project,
            dayIdentifier: "2026-07-20",
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

    // MARK: - View Wiring

    /// Guards the view-level wiring (following the repository's source-level
    /// consistency-test convention): both history views reload the shared
    /// controller when the committed snapshot is republished, the list replays
    /// its own toolbar filters on appear (no `.ended` leak from the review
    /// view), and project options refresh whenever the loaded set changes.
    func testHistoryListViewWiringReloadsOnSnapshotSynchronization() throws {
        let list = try source("Sources/TinyBuddy/FocusHistoryListView.swift")
        let review = try source("Sources/TinyBuddy/FocusSessionReviewView.swift")

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
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
