import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

/// In-memory registry store so the benchmark exercises the real
/// `TinyBuddyProjectRegistry.resolve(projectKey:)` identity authority without
/// touching any file-backed user state.
private final class HistoryBenchmarkRegistryStore: TinyBuddyProjectRegistryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: TinyBuddyProjectRegistrySnapshot?

    init(_ snapshot: TinyBuddyProjectRegistrySnapshot) {
        self.snapshot = snapshot
    }

    func load() -> TinyBuddyProjectRegistrySnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    @discardableResult
    func save(_ snapshot: TinyBuddyProjectRegistrySnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
        return true
    }
}

/// Deterministic end-to-end history query workload.
///
/// The fixture mirrors the production wiring: a `FocusSessionQueryService`
/// whose provider is an in-memory session array and whose `projectResolver` is
/// the app's real registry projection, consumed through `HistoryQueryController`
/// with the production page size (50).
private struct HistoryBenchmarkFixture {
    let sessions: [FocusSession]
    let service: FocusSessionQueryService
    let keyword: String
    let dayStart: String
    let dayEnd: String
    let projectKey: String

    static let projectCount = 60
    static let pageSize = 50
    static let dayCount = 730

    /// - Parameters:
    ///   - sessionCount: Number of authoritative sessions.
    ///   - projectCount: Number of registered projects the rows resolve to.
    ///   - order: Provider array order. `chronological` matches production
    ///     (`FocusSessionEngine` appends each session when it starts, so the
    ///     array is oldest first) and is the default. `edited` adds the rows a
    ///     user edit re-appended at the end. `shuffled` is a fixed-seed
    ///     unsorted proxy for input that history rewrites have left out of
    ///     order.
    init(
        sessionCount: Int,
        projectCount: Int = projectCount,
        order: RowOrder = .chronological
    ) {
        let days = Self.recentDays(count: Self.dayCount)
        let newestDay = days[0]

        var sessions: [FocusSession] = []
        sessions.reserveCapacity(sessionCount)
        var ordinal = 0
        // Oldest day first: production session arrays are in append order.
        for dayIndex in stride(from: Self.dayCount - 1, through: 0, by: -1) {
            let day = days[dayIndex]
            let rowCount = Self.rowsInDay(index: dayIndex, sessionCount: sessionCount)
            for slot in 0 ..< rowCount {
                let projectIndex = (ordinal / 3) % projectCount
                // Legacy alias key: the registry must resolve it to a canonical
                // id, exactly like rows recorded before a project rename.
                let project = FocusProjectContext(
                    key: "repo.\(projectIndex)",
                    displayName: "Project \(projectIndex)"
                )
                let startedAt = day.start.addingTimeInterval(
                    (Double(slot) + 0.5) * 86_400 / Double(rowCount)
                )
                // Only the newest day can still be open, like a real archive:
                // one live session and one paused session at most.
                let status: FocusSessionStatus
                if slot == 0, dayIndex == 0 {
                    status = .active
                } else if slot == 1, dayIndex == 0 {
                    status = .paused
                } else {
                    status = .ended
                }
                let endedAt: Date? = status == .ended ? startedAt.addingTimeInterval(1_800) : nil
                let events: [FocusSessionDecisionEvent]? = ordinal % 2 == 0
                    ? [
                        FocusSessionDecisionEvent(
                            at: startedAt,
                            kind: .started,
                            reason: .userActivity,
                            source: .automatic
                        ),
                        FocusSessionDecisionEvent(
                            at: endedAt ?? startedAt.addingTimeInterval(1_800),
                            kind: .ended,
                            reason: .idle,
                            source: .automatic
                        )
                    ]
                    : nil
                sessions.append(FocusSession(
                    project: project,
                    dayIdentifier: day.identifier,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    status: status,
                    lastUserActivityAt: startedAt.addingTimeInterval(1_800),
                    lastStateChangeAt: endedAt ?? startedAt.addingTimeInterval(1_800),
                    decisionEvents: events
                ))
                ordinal += 1
            }
        }
        if order == .edited {
            // One in fifty rows was rewritten and re-appended at the end.
            var rewritten: [FocusSession] = []
            var untouched: [FocusSession] = []
            untouched.reserveCapacity(sessions.count)
            for (index, session) in sessions.enumerated() {
                if index % 50 == 49 {
                    rewritten.append(session)
                } else {
                    untouched.append(session)
                }
            }
            sessions = untouched + rewritten
        }
        if order == .shuffled {
            var random = DeterministicRandom(seedString: "TinyBuddyHistoryBenchmark")
            for index in stride(from: sessions.count - 1, through: 1, by: -1) {
                let swapIndex = Int(random.next() % UInt64(index + 1))
                sessions.swapAt(index, swapIndex)
            }
        }

        var projects: [TinyBuddyProject] = []
        projects.reserveCapacity(projectCount)
        for index in 0 ..< projectCount {
            projects.append(TinyBuddyProject(
                id: TinyBuddyProjectID(rawValue: "project.\(index)"),
                kind: .gitRepository,
                displayName: "Project \(index)",
                aliases: ["repo.\(index)"],
                state: .active
            ))
        }
        let registry = TinyBuddyProjectRegistry(
            store: HistoryBenchmarkRegistryStore(
                TinyBuddyProjectRegistrySnapshot(projects: projects)
            )
        )

        self.sessions = sessions
        let snapshot = sessions
        self.service = FocusSessionQueryService(
            sessionProvider: { snapshot },
            projectResolver: { context in
                guard let project = registry.resolve(projectKey: context.key) else { return context }
                return FocusProjectContext(key: project.id.rawValue, displayName: project.displayName)
            }
        )
        self.keyword = "project 1"
        // The most recent seven days of the dataset.
        self.dayStart = days[6].identifier
        self.dayEnd = newestDay.identifier
        self.projectKey = "project.1"
    }

    @MainActor
    func makeController() -> HistoryQueryController {
        HistoryQueryController(queryService: service)
    }

    enum RowOrder: String {
        /// Append-only order: `FocusSessionEngine` appends each session when it
        /// starts, so a history that was never rewritten is oldest first.
        case chronological
        /// Append-only order plus the rows an edit, split or merge re-appended
        /// at the end (`editSession`/`splitSession`/`mergeSessions` do
        /// `remove(at:)` + `append(contentsOf:)`, and `undoLastEdit` rebuilds the
        /// array), which is what a user-edited archive looks like. Rule
        /// recalculation would re-append in dictionary hash order instead, but
        /// its coordinator is not wired into the app target.
        case edited
        /// Fixed-seed shuffle: a proxy for how much unsorted input can cost, not a
        /// reachable archive layout and not a proven bound.
        case shuffled
    }

    /// Distributes `sessionCount` rows over the benchmark day count so every
    /// day is populated before any day gets a second row.
    private static func rowsInDay(index: Int, sessionCount: Int) -> Int {
        let base = sessionCount / dayCount
        let remainder = sessionCount % dayCount
        return base + (index < remainder ? 1 : 0)
    }

    /// The `count` most recent real Gregorian days ending at a fixed reference
    /// day, newest first, in UTC so day identifiers are machine independent.
    private static func recentDays(count: Int) -> [(identifier: String, start: Date)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard var date = calendar.date(from: DateComponents(year: 2_026, month: 7, day: 22)) else {
            preconditionFailure("fixed benchmark reference day must be constructible")
        }
        var days: [(identifier: String, start: Date)] = []
        days.reserveCapacity(count)
        for _ in 0 ..< count {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            let identifier = String(
                format: "%04d-%02d-%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
            days.append((identifier, date))
            date = calendar.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-86_400)
        }
        return days
    }
}

/// Release-mode performance harness for the history surfaces.
///
/// The scenarios are the user-visible operations: first page load, the review
/// view entry, scrolling to the end of the history, and each filter switch.
/// Measurements include the real query service (provider read, project
/// resolution, filtering, sorting), controller state publication, and
/// pagination accumulation.
///
/// Opt in with:
///
/// ```sh
/// TINYBUDDY_HISTORY_BENCHMARK=1 ./script/swiftpm.sh test -c release \
///   --filter HistoryQueryPerformanceTests/testHistoryQueryScenarioBaseline
/// ```
///
/// Sizes come from `TINYBUDDY_HISTORY_BENCHMARK_SIZES` (comma separated,
/// default `2000,8000,16000`); samples per scenario from
/// `TINYBUDDY_HISTORY_BENCHMARK_SAMPLES` (default 3, median reported).
/// Every scenario is warmed up once before its timed samples. Provider
/// array order defaults to production append order; set
/// `TINYBUDDY_HISTORY_BENCHMARK_ORDER=shuffled` for the unsorted proxy, or
/// `=edited` for a user-edited archive.
///
/// `lastPage` and `serviceFullPagination` are service-level measurements that
/// have no separate user-visible operation: one page near the end of the
/// result set, and the aggregate cost of every page without the controller's
/// accumulation.
///
/// `renderedListPagination` is the scroll-to-end path with the page storage held
/// across every append — the closest single-value stand-in for a rendered list,
/// which holds the page list and each page's rows while the next page is
/// appended. It is the scenario that detects a per-append copy of the whole
/// accumulated history, so `fullPagination` (which only binds the returned page)
/// and `serviceFullPagination` (which does not touch the controller) cannot
/// replace it.
final class HistoryQueryPerformanceTests: XCTestCase {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TINYBUDDY_HISTORY_BENCHMARK"] == "1"
    }

    private static var sizes: [Int] {
        let raw = ProcessInfo.processInfo.environment["TINYBUDDY_HISTORY_BENCHMARK_SIZES"] ?? "2000,8000,16000"
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parsed.isEmpty ? [2_000, 8_000, 16_000] : parsed
    }

    private static var samples: Int {
        Int(ProcessInfo.processInfo.environment["TINYBUDDY_HISTORY_BENCHMARK_SAMPLES"] ?? "") ?? 3
    }

    @MainActor
    func testHistoryQueryScenarioBaseline() async throws {
        try XCTSkipUnless(
            Self.isEnabled,
            "Set TINYBUDDY_HISTORY_BENCHMARK=1 to run the history query performance baseline."
        )

        let clock = ContinuousClock()

        func measure(_ body: () async -> Void) async -> Double {
            let start = clock.now
            await body()
            let duration = start.duration(to: clock.now).components
            return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
        }

        /// One untimed warm-up (first-touch allocation and cache growth) plus
        /// the configured number of timed samples; the median is reported.
        func medianMilliseconds(_ body: () async -> Void) async -> Double {
            await body()
            var values: [Double] = []
            values.reserveCapacity(Self.samples)
            for _ in 0 ..< Self.samples {
                values.append(await measure(body))
            }
            return values.sorted()[values.count / 2]
        }

        for size in Self.sizes {
            let rowOrder = HistoryBenchmarkFixture.RowOrder(
                rawValue: ProcessInfo.processInfo.environment["TINYBUDDY_HISTORY_BENCHMARK_ORDER"] ?? ""
            ) ?? .chronological
            let fixture = HistoryBenchmarkFixture(sessionCount: size, order: rowOrder)

            let refreshFirstPage = await medianMilliseconds {
                let controller = fixture.makeController()
                await controller.refresh()
            }

            let serviceProjects = await medianMilliseconds {
                _ = await fixture.service.projects(version: 0)
            }

            let serviceFilterOnly = await medianMilliseconds {
                _ = await fixture.service.estimatedCount(query: FocusSessionQuery(status: .ended))
            }

            let serviceFirstPage = await medianMilliseconds {
                _ = await fixture.service.execute(
                    query: FocusSessionQuery(),
                    cursor: nil,
                    limit: HistoryBenchmarkFixture.pageSize,
                    version: 0
                )
            }

            let fullPagination = await medianMilliseconds {
                let controller = fixture.makeController()
                await controller.refresh()
                while case .loaded(let page) = controller.loadState, page.hasMore {
                    await controller.loadMore()
                }
            }

            // Scrolling to the end with the page storage held across every
            // append. A rendered list holds the page list (its outer `ForEach`)
            // and each page's rows (the inner one) while the next page is
            // appended, so this value model — one retained page list, kept alive
            // through the mutation — is the closest single-value stand-in for it.
            // It is a stress model of the reader, not a measurement of SwiftUI's
            // row lifetimes, and it is the scenario that detects a per-append
            // copy of the whole accumulation: with a flat accumulated array the
            // reader's copy is every loaded row, with the chunked accumulation it
            // is one reference per page.
            let renderedListPagination = await medianMilliseconds {
                let controller = fixture.makeController()
                await controller.refresh()
                var rendered: [[FocusSession]] = []
                while controller.loadState.currentPage?.hasMore == true {
                    rendered = controller.sessionPages
                    await controller.loadMore()
                    // Keep the reader's copy alive across the append explicitly;
                    // the optimizer is otherwise free to end its lifetime at the
                    // call.
                    withExtendedLifetime(rendered) {}
                }
                // The value the reader held is the page list from before the last
                // append: it must not have been extended or mutated in place.
                XCTAssertLessThan(rendered.count, controller.sessionPages.count)
            }

            let keywordFilterSwitch = await medianMilliseconds {
                let controller = fixture.makeController()
                await controller.refresh()
                var query = FocusSessionQuery()
                query.keyword = fixture.keyword
                await controller.updateQuery(query, debounceSeconds: 0)
            }

            let dayRangeFilterSwitch = await medianMilliseconds {
                let controller = fixture.makeController()
                await controller.refresh()
                var query = FocusSessionQuery()
                query.dayStart = fixture.dayStart
                query.dayEnd = fixture.dayEnd
                await controller.updateQuery(query, debounceSeconds: 0)
            }

            let projectFilterSwitch = await medianMilliseconds {
                let controller = fixture.makeController()
                await controller.refresh()
                var query = FocusSessionQuery()
                query.projectKey = fixture.projectKey
                await controller.updateQuery(query, debounceSeconds: 0)
            }

            let statusFilterSwitch = await medianMilliseconds {
                let controller = fixture.makeController()
                await controller.refresh()
                var query = FocusSessionQuery()
                query.status = .ended
                await controller.updateQuery(query, debounceSeconds: 0)
            }

            // Review view entry: the default `.ended` filter applied to a
            // controller that has not loaded anything yet.
            let reviewViewLoad = await medianMilliseconds {
                let controller = fixture.makeController()
                var query = FocusSessionQuery()
                query.status = .ended
                await controller.updateQuery(query, debounceSeconds: 0)
            }

            // Scrolling to the end of the history: place the cursor one row
            // before the final page so exactly one page remains. The fixture's
            // own rows are ordered the way the service orders them (startedAt
            // descending, then uuidString ascending) to build a realistic
            // deep-page cursor; the timed body is a single service call.
            //
            // This scenario places the cursor one row before the final full
            // page, so it needs more rows than one page; a history that is not
            // longer than one page has no such cursor and reports 0 instead of
            // indexing off the start of `orderedRows`.
            let orderedRows = fixture.sessions.sorted { a, b in
                if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
                return a.id.uuidString < b.id.uuidString
            }
            let lastPage: Double
            if orderedRows.count > HistoryBenchmarkFixture.pageSize {
                let deepCursorRow = orderedRows[orderedRows.count - HistoryBenchmarkFixture.pageSize - 1]
                let deepCursor = FocusSessionCursor(
                    lastStartedAt: deepCursorRow.startedAt,
                    lastID: deepCursorRow.id
                )

                lastPage = await medianMilliseconds {
                    _ = await fixture.service.execute(
                        query: FocusSessionQuery(),
                        cursor: deepCursor,
                        limit: HistoryBenchmarkFixture.pageSize,
                        version: 0
                    )
                }

                let lastPageProbeResult = await fixture.service.execute(
                    query: FocusSessionQuery(),
                    cursor: deepCursor,
                    limit: HistoryBenchmarkFixture.pageSize,
                    version: 0
                )
                let lastPageProbe = try XCTUnwrap(lastPageProbeResult)
                XCTAssertEqual(lastPageProbe.sessions.count, HistoryBenchmarkFixture.pageSize)
                XCTAssertFalse(lastPageProbe.hasMore)
            } else {
                lastPage = 0
            }

            // Service-only traversal: the query service's aggregate cost over
            // every page, without the controller's accumulation and without
            // this harness's own loop state. The difference from
            // `renderedListPagination` is the controller's pagination
            // bookkeeping and scheduling plus `refresh()`.
            let serviceFullPagination = await medianMilliseconds {
                var cursor: FocusSessionCursor?
                var visited = 0
                while true {
                    guard let page = await fixture.service.execute(
                        query: FocusSessionQuery(),
                        cursor: cursor,
                        limit: HistoryBenchmarkFixture.pageSize,
                        version: 0
                    ) else { break }
                    visited += page.sessions.count
                    guard page.hasMore, let next = page.nextCursor else { break }
                    cursor = next
                }
                XCTAssertEqual(visited, size)
            }

            let report: [(String, Double)] = [
                ("refreshFirstPage", refreshFirstPage),
                ("serviceProjects", serviceProjects),
                ("serviceFilterOnly", serviceFilterOnly),
                ("serviceFirstPage", serviceFirstPage),
                ("serviceFullPagination", serviceFullPagination),
                ("fullPagination", fullPagination),
                ("keywordFilterSwitch", keywordFilterSwitch),
                ("dayRangeFilterSwitch", dayRangeFilterSwitch),
                ("projectFilterSwitch", projectFilterSwitch),
                ("statusFilterSwitch", statusFilterSwitch),
                ("reviewViewLoad", reviewViewLoad),
                ("renderedListPagination", renderedListPagination),
                ("lastPage", lastPage)
            ]
            for (scenario, value) in report {
                print("HISTORY_QUERY_BENCHMARK size=\(size) order=\(rowOrder.rawValue) scenario=\(scenario) milliseconds=\(String(format: "%.3f", value))")
            }
        }
    }
}
