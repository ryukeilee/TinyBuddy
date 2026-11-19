import Foundation
import XCTest
@testable import TinyBuddyCore

private final class TransitionBenchmarkClock: FocusClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return instant
    }

    var monotonic: TimeInterval { now.timeIntervalSinceReferenceDate }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        instant = instant.addingTimeInterval(seconds)
    }
}

private final class TransitionBenchmarkStore: FocusSessionArchivePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var archive: FocusSessionArchive

    init(_ archive: FocusSessionArchive) { self.archive = archive }

    func load() -> [FocusSession]? { loadArchive().archive?.sessions }

    func loadArchive() -> FocusSessionArchiveLoadResult {
        lock.lock(); defer { lock.unlock() }
        return FocusSessionArchiveLoadResult(health: .available, archive: archive, format: .envelope)
    }

    @discardableResult
    func save(_ sessions: [FocusSession]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        archive = FocusSessionArchive(revision: archive.revision + 1, sessions: sessions)
        return true
    }

    @discardableResult
    func saveArchive(_ archive: FocusSessionArchive) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.archive = archive
        return true
    }
}

/// Opt-in regression benchmark for the focus-session commit path.
///
///   TINYBUDDY_FOCUS_TRANSITION_BENCHMARK=1 \
///   TINYBUDDY_FOCUS_TRANSITION_SIZES=666,2000,8000,16000 \
///     ./script/swiftpm.sh test -c release --filter FocusSessionTransitionPerformanceTests
///
/// Each size runs a warm-up cycle, then five start/pause/resume/end cycles in
/// one engine; the reported value is the median of those five per operation.
/// No absolute threshold is asserted: the same fixture measured on another
/// machine only supports a relative before/after comparison.
final class FocusSessionTransitionPerformanceTests: XCTestCase {
    private let day = "2026-11-19"
    private let project = FocusProjectContext(key: "/Users/example/repo", displayName: "repo")

    func testTransitionCommitBenchmark() throws {
        guard ProcessInfo.processInfo.environment["TINYBUDDY_FOCUS_TRANSITION_BENCHMARK"] == "1" else {
            throw XCTSkip(
                "Set TINYBUDDY_FOCUS_TRANSITION_BENCHMARK=1; use -c release for reproducible commit timings"
            )
        }
        let base = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!
        let rawSizes = ProcessInfo.processInfo.environment["TINYBUDDY_FOCUS_TRANSITION_SIZES"] ?? "666,2000,8000,16000"
        let sizes = rawSizes.split(separator: ",").compactMap { Int($0) }
        guard !sizes.isEmpty else { throw XCTSkip("no benchmark sizes") }

        for storeKind in ["memory", "file"] {
            for size in sizes {
                let history = makeHistory(count: size, base: base)
                XCTAssertTrue(
                    zip(history, history.dropFirst()).allSatisfy { $0.startedAt <= $1.startedAt },
                    "the benchmark fixture must be in production append order"
                )
                let archiveValue = FocusSessionArchive(revision: 1, sessions: history)
                var validationSamples: [Double] = []
                for _ in 0 ..< 4 {
                    let validationStart = ProcessInfo.processInfo.systemUptime
                    _ = archiveValue.isSemanticallyValid
                    validationSamples.append((ProcessInfo.processInfo.systemUptime - validationStart) * 1000)
                }
                let validationMedian = validationSamples.dropFirst().sorted()[1]
                print(
                    "FOCUS_TRANSITION_BENCHMARK store=\(storeKind) history=\(size) "
                    + "op=archive-validation median_ms=\(String(format: "%.3f", validationMedian))"
                )
                let store: FocusSessionArchivePersisting
                var fileURL: URL?
                if storeKind == "file" {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("focus-transition-benchmark-\(UUID().uuidString).json")
                    let fileStore = FocusSessionFileStore(fileURL: url)
                    XCTAssertTrue(fileStore.saveArchive(FocusSessionArchive(revision: 1, sessions: history)))
                    store = fileStore
                    fileURL = url
                } else {
                    store = TransitionBenchmarkStore(FocusSessionArchive(revision: 1, sessions: history))
                }
                let clock = TransitionBenchmarkClock(base)
                let engine = FocusSessionEngine(
                    clock: clock,
                    persisting: store,
                    config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
                    dayIdentifier: { _ in self.day }
                )

                var samples: [String: [Double]] = [:]
                for _ in 0 ..< 6 {
                    let cycle = measureCycle(engine: engine, clock: clock)
                    for (operation, duration) in cycle {
                        samples[operation, default: []].append(duration)
                    }
                }
                for operation in ["start", "pause", "resume", "end"] {
                    // Drop the first cycle, which warms the archive / caches.
                    let values = (samples[operation] ?? []).dropFirst().sorted()
                    XCTAssertFalse(values.isEmpty)
                    let median = values[values.count / 2]
                    print(
                        "FOCUS_TRANSITION_BENCHMARK store=\(storeKind) history=\(size) op=\(operation) "
                        + "median_ms=\(String(format: "%.3f", median))"
                    )
                }

                var noOpSamples: [Double] = []
                for _ in 0 ..< 5 {
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = engine.foregroundProjectChanged(to: project, at: clock.now)
                    noOpSamples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                let noOpMedian = noOpSamples.sorted()[noOpSamples.count / 2]
                print(
                    "FOCUS_TRANSITION_BENCHMARK store=\(storeKind) history=\(size) op=no-op "
                    + "median_ms=\(String(format: "%.4f", noOpMedian))"
                )

                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            }
        }
    }

    private func measureCycle(
        engine: FocusSessionEngine,
        clock: TransitionBenchmarkClock
    ) -> [(String, Double)] {
        var result: [(String, Double)] = []
        func measure(_ operation: String, _ body: () -> Void) {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            result.append((operation, (ProcessInfo.processInfo.systemUptime - start) * 1000))
        }
        measure("start") {
            engine.startManualFocus(project: project, at: clock.now)
            clock.advance(by: 120)
        }
        measure("pause") {
            engine.pauseManualFocus(at: clock.now)
            clock.advance(by: 60)
        }
        measure("resume") {
            engine.resumeManualFocus(at: clock.now)
            clock.advance(by: 120)
        }
        measure("end") {
            engine.endManualFocus(at: clock.now)
            clock.advance(by: 60)
        }
        return result
    }

    /// Production archives append sessions in start order; edits re-append a
    /// small minority. The fixture mirrors that shape so the overlap check and
    /// the ordered-diff fast paths see realistic input.
    private func makeHistory(count: Int, base: Date) -> [FocusSession] {
        var sessions: [FocusSession] = []
        sessions.reserveCapacity(count)
        let dayCount = (count + 5) / 6
        for index in 0 ..< count {
            let offset = dayCount - (index / 6)
            let start = base.addingTimeInterval(
                TimeInterval(-offset * 86_400 - 3_600 + (index % 6) * 3_600)
            )
            let end = start.addingTimeInterval(1_800)
            sessions.append(FocusSession(
                project: project,
                dayIdentifier: Self.dayIdentifier(for: start),
                startedAt: start,
                endedAt: end,
                status: .ended,
                lastUserActivityAt: end,
                lastStateChangeAt: end,
                decisionEvents: [
                    FocusSessionDecisionEvent(at: start, kind: .started, reason: .userActivity, source: .automatic),
                    FocusSessionDecisionEvent(at: end, kind: .ended, reason: .idle, source: .automatic)
                ],
                mode: .automatic,
                ruleVersion: FocusSessionRuleVersion.current
            ))
        }
        return sessions
    }

    private static func dayIdentifier(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
