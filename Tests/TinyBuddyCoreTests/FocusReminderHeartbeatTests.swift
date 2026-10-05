import Foundation
import XCTest
@testable import TinyBuddyCore

/// Compares the indexed heartbeat with the retained, full-history evaluator.
/// Timing is opt-in; normal tests assert exact values and mutation semantics.
final class FocusReminderHeartbeatTests: XCTestCase {
    private let day = "2026-07-21"
    private let nextDay = "2026-07-22"
    private let now = Date(timeIntervalSince1970: 1_784_635_200)
    private let project = FocusProjectContext(key: "heartbeat-project", displayName: "Heartbeat")

    private func history(count: Int, sameDay: Bool) -> [FocusSession] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        // Bound the unrelated history aggregation setup to 100 rows per day;
        // setup is excluded from measurements of the periodic reminder read.
        let historicalDays = (0..<(count / 100 + 1)).map {
            formatter.string(from: now.addingTimeInterval(-Double($0 + 1) * 86_400))
        }
        return (0..<count).map { index in
            let dayOffset = sameDay ? 0 : index / 100 + 1
            let origin = now.addingTimeInterval(-20_000 - Double(dayOffset) * 86_400)
            let start = origin.addingTimeInterval(Double(sameDay ? index : index % 100) * 0.1)
            let end = start.addingTimeInterval(0.05)
            return FocusSession(
                project: project,
                dayIdentifier: sameDay ? day : historicalDays[index / 100],
                startedAt: start,
                endedAt: end,
                status: .ended,
                lastUserActivityAt: end,
                lastStateChangeAt: end
            )
        }
    }

    private func makeEngine(_ sessions: [FocusSession] = []) -> (FocusSessionEngine, FakeClock, MemoryStore) {
        let clock = FakeClock(now)
        let store = MemoryStore()
        store.stored = sessions
        let identifier = day
        let engine = FocusSessionEngine(clock: clock, persisting: store, dayIdentifier: { _ in identifier })
        return (engine, clock, store)
    }

    @discardableResult
    private func assertEquivalent(
        _ engine: FocusSessionEngine,
        at date: Date,
        dayIdentifier: String? = nil,
        state: FocusReminderState? = nil,
        config: FocusGoalConfiguration = .default,
        quiet: Bool = false,
        dnd: Bool = false,
        canDeliver: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FocusReminderEvaluation {
        let identifier = dayIdentifier ?? day
        let reminderState = state ?? FocusReminderState(dayIdentifier: identifier)
        let metrics = engine.reminderMetrics(dayIdentifier: identifier, now: date)
        let sessions = engine.allSessions
        let open = sessions.first(where: \.isOpen)
        XCTAssertEqual(metrics.totalFocusDuration,
                       sessions.filter { $0.dayIdentifier == identifier }.reduce(0) { $0 + $1.activeDuration(now: date) },
                       accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(metrics.openSessionID, open?.id, file: file, line: line)
        XCTAssertEqual(metrics.openSessionIsActive, open?.status == .active, file: file, line: line)
        XCTAssertEqual(metrics.openSessionIsPaused, open?.currentPauseStartedAt != nil, file: file, line: line)
        XCTAssertEqual(metrics.continuousFocusDuration, open?.continuousActiveDuration(now: date) ?? 0,
                       accuracy: 0.000_001, file: file, line: line)
        let old = FocusReminderEngine.evaluate(allSessions: sessions, config: config, state: reminderState,
                                              now: date, dayIdentifier: identifier, isInQuietHours: quiet,
                                              isSystemDND: dnd, canDeliverNotifications: canDeliver)
        let indexed = FocusReminderEngine.evaluate(metrics: metrics, config: config, state: reminderState,
                                                  now: date, dayIdentifier: identifier, isInQuietHours: quiet,
                                                  isSystemDND: dnd, canDeliverNotifications: canDeliver)
        XCTAssertEqual(indexed, old, file: file, line: line)
        return indexed
    }

    func testMetricsRemainEquivalentThroughPauseResumeAndLongContinuousFocus() {
        let (engine, clock, _) = makeEngine(history(count: 1_000, sameDay: false))
        XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .saved)
        assertEquivalent(engine, at: clock.now)
        clock.advance(by: 3_000)
        let triggered = assertEquivalent(engine, at: clock.now)
        guard case .breakReminder = triggered.action else { return XCTFail("Expected threshold reminder") }
        XCTAssertEqual(engine.pauseManualFocus(at: clock.now), .saved)
        let paused = assertEquivalent(engine, at: clock.now, state: triggered.updatedState)
        XCTAssertTrue(paused.updatedState.triggeredBreakReminderSessionIDs.isEmpty)
        clock.advance(by: 3_600)
        assertEquivalent(engine, at: clock.now, state: paused.updatedState)
        XCTAssertEqual(engine.resumeManualFocus(at: clock.now), .saved)
        assertEquivalent(engine, at: clock.now, state: paused.updatedState)
        clock.advance(by: 3_000)
        assertEquivalent(engine, at: clock.now, state: paused.updatedState)
        clock.advance(by: 86_400)
        assertEquivalent(engine, at: clock.now)
        XCTAssertEqual(engine.endManualFocus(at: clock.now), .saved)
        assertEquivalent(engine, at: clock.now)
    }

    func testMetricsTrackEditsDeletesAndFailedPersistenceWithoutAdvancingAuthority() {
        let sessions = history(count: 2, sameDay: true)
        let (engine, clock, store) = makeEngine(sessions)
        assertEquivalent(engine, at: clock.now)
        let editedEnd = sessions[1].startedAt.addingTimeInterval(600)
        guard case .saved = engine.editSession(id: sessions[1].id, endedAt: editedEnd) else {
            return XCTFail("Expected edit to commit")
        }
        assertEquivalent(engine, at: clock.now)
        let beforeFailure = engine.reminderMetrics(dayIdentifier: day, now: clock.now)
        store.shouldFail = true
        guard case .rejected(.persistenceFailed) = engine.deleteSession(id: sessions[1].id) else {
            return XCTFail("Expected failed persistence")
        }
        XCTAssertEqual(engine.reminderMetrics(dayIdentifier: day, now: clock.now), beforeFailure)
        assertEquivalent(engine, at: clock.now)
        store.shouldFail = false
        guard case .saved = engine.deleteSession(id: sessions[1].id) else { return XCTFail("Expected delete to commit") }
        assertEquivalent(engine, at: clock.now)
        guard case .saved = engine.undoLastEdit() else { return XCTFail("Expected undo to commit") }
        assertEquivalent(engine, at: clock.now)
        store.shouldFail = true
        XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .persistenceFailed)
        assertEquivalent(engine, at: clock.now)
    }

    func testRestartReconciliationCachesClosedAuthorityEvenWhenRepairSaveFails() {
        let (engine, clock, store) = makeEngine()
        XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .saved)
        clock.advance(by: 600)
        XCTAssertEqual(engine.pauseManualFocus(at: clock.now), .saved)
        let beforeRestart = engine.reminderMetrics(dayIdentifier: day, now: clock.now)
        clock.advance(by: 3_600)
        store.shouldFail = true
        let identifier = day
        let restarted = FocusSessionEngine(clock: clock, persisting: store, dayIdentifier: { _ in identifier })
        let afterRestart = restarted.reminderMetrics(dayIdentifier: day, now: clock.now)
        XCTAssertNil(afterRestart.openSessionID)
        XCTAssertEqual(afterRestart.totalFocusDuration, beforeRestart.totalFocusDuration)
        assertEquivalent(restarted, at: clock.now)
        clock.advance(by: 3_600)
        XCTAssertEqual(restarted.reminderMetrics(dayIdentifier: day, now: clock.now), afterRestart)
        store.shouldFail = false
        XCTAssertEqual(restarted.startManualFocus(project: project, at: clock.now), .saved)
        assertEquivalent(restarted, at: clock.now)
    }

    func testDayRolloverPermissionAndSuppressionPreserveReminderGates() {
        let (engine, clock, _) = makeEngine()
        XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .saved)
        clock.advance(by: 3_000)
        var config = FocusGoalConfiguration()
        config.dailyFocusGoalMinutes = 40
        let suppressed = assertEquivalent(engine, at: clock.now, config: config, canDeliver: false)
        XCTAssertEqual(suppressed.action, .none)
        XCTAssertFalse(suppressed.updatedState.goalCompletedNotified)
        XCTAssertTrue(suppressed.updatedState.triggeredBreakReminderSessionIDs.isEmpty)
        assertEquivalent(engine, at: clock.now, config: config, quiet: true)
        assertEquivalent(engine, at: clock.now, config: config, dnd: true)
        let allowed = assertEquivalent(engine, at: clock.now, state: suppressed.updatedState, config: config)
        guard case .goalCompleted = allowed.action else { return XCTFail("Expected recovered goal reminder") }
        clock.advance(by: 300)
        assertEquivalent(engine, at: clock.now, state: allowed.updatedState, config: config)
        XCTAssertEqual(engine.timeChanged(at: clock.now, dayIdentifier: nextDay), .saved)
        let next = assertEquivalent(engine, at: clock.now, dayIdentifier: nextDay, state: allowed.updatedState, config: config)
        XCTAssertFalse(next.updatedState.goalCompletedNotified)
        XCTAssertTrue(next.updatedState.triggeredBreakReminderSessionIDs.isEmpty)
        // An arbitrary noncurrent day query must also preserve historical totals.
        assertEquivalent(engine, at: clock.now, dayIdentifier: day)
    }

    func testHeartbeatReadsNeitherHistoryNorDecisionEventArrays() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
        }
        let engineSource = try source("Sources/TinyBuddyCore/FocusSessionEngine.swift")
        let start = try XCTUnwrap(engineSource.range(of: "public func reminderMetrics("))
        let end = try XCTUnwrap(engineSource.range(of: "private func rebuildReminderCache()", range: start.upperBound..<engineSource.endIndex))
        let heartbeat = String(engineSource[start.lowerBound..<end.lowerBound])
        for forbidden in ["sessions.", " in sessions", "decisionEvents", "rebuildReminderCache(", "allSessions"] {
            XCTAssertFalse(heartbeat.contains(forbidden), "Heartbeat must use cached scalars: \(forbidden)")
        }
        let sustainedStart = try XCTUnwrap(engineSource.range(of: "public func reportSustainedActivity("))
        let sustainedApply = try XCTUnwrap(engineSource.range(of: "let result = applyLocked", range: sustainedStart.upperBound..<engineSource.endIndex))
        let sustainedGuard = String(engineSource[sustainedStart.lowerBound..<sustainedApply.lowerBound])
        XCTAssertTrue(sustainedGuard.contains("current = openReminderSession"))
        XCTAssertFalse(sustainedGuard.contains("sessions."))
        let idleStart = try XCTUnwrap(engineSource.range(of: "public func endPausedSessionAfterLongAbsence("))
        let idleApply = try XCTUnwrap(engineSource.range(of: "let result = applyLocked", range: idleStart.upperBound..<engineSource.endIndex))
        let idleGuard = String(engineSource[idleStart.lowerBound..<idleApply.lowerBound])
        XCTAssertTrue(idleGuard.contains("open = openReminderSession"))
        XCTAssertTrue(idleGuard.contains("return .noChange"))
        XCTAssertFalse(idleGuard.contains("sessions."))
        let bridge = try source("Sources/TinyBuddy/FocusSessionAppBridge.swift")
        XCTAssertFalse(bridge.contains("engine.allSessions"), "App heartbeat must not materialize the archive")
        XCTAssertTrue(bridge.contains("engine.reminderMetrics("))
        let coordinator = try source("Sources/TinyBuddy/FocusGoalCoordinator.swift")
        let evaluationStart = try XCTUnwrap(coordinator.range(of: "private func evaluateRemindersNow("))
        let evaluation = String(coordinator[evaluationStart.lowerBound...])
        XCTAssertTrue(evaluation.contains("metrics: input.metrics"))
        XCTAssertFalse(evaluation.contains("allSessions:"), "Periodic evaluation must use scalar metrics")

        for sameDay in [false, true] {
            let (engine, clock, store) = makeEngine(history(count: 10_000, sameDay: sameDay))
            let expected = engine.reminderMetrics(dayIdentifier: day, now: clock.now)
            let saves = store.saveCount
            let loads = store.loadCount
            for _ in 0..<1_000 {
                XCTAssertEqual(engine.reminderMetrics(dayIdentifier: day, now: clock.now), expected)
            }
            XCTAssertEqual(store.saveCount, saves)
            XCTAssertEqual(store.loadCount, loads)
            assertEquivalent(engine, at: clock.now)
        }
    }

    func testHeartbeatPerformanceBaseline() throws {
        guard ProcessInfo.processInfo.environment["TINYBUDDY_REMINDER_BENCHMARK"] == "1" else {
            throw XCTSkip("Set TINYBUDDY_REMINDER_BENCHMARK=1; use -c release for reproducible heartbeat timings")
        }
        let iterations = 100
        let config = FocusGoalConfiguration()
        let state = FocusReminderState(dayIdentifier: day)
        for sameDay in [false, true] {
            var indexedTimes: [Double] = []
            let counts = sameDay ? [100, 1_000, 10_000] : [100, 10_000, 100_000]
            for count in counts {
                let (engine, clock, _) = makeEngine(history(count: count, sameDay: sameDay))
                XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .saved)
                clock.advance(by: 3_000)
                assertEquivalent(engine, at: clock.now)
                var sink = 0
                func sample(indexed: Bool) -> Double {
                    var samples: [Double] = []
                    for _ in 0..<5 {
                        let start = DispatchTime.now().uptimeNanoseconds
                        for _ in 0..<iterations {
                            let result: FocusReminderEvaluation
                            if indexed {
                                result = FocusReminderEngine.evaluate(
                                    metrics: engine.reminderMetrics(dayIdentifier: day, now: clock.now),
                                    config: config, state: state, now: clock.now, dayIdentifier: day)
                            } else {
                                result = FocusReminderEngine.evaluate(allSessions: engine.allSessions, config: config,
                                                                      state: state, now: clock.now, dayIdentifier: day)
                            }
                            sink += result.updatedState.triggeredBreakReminderSessionIDs.count
                        }
                        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations))
                    }
                    return samples.sorted()[samples.count / 2]
                }
                _ = sample(indexed: true) // Warmup is outside reported samples.
                let legacy = sample(indexed: false)
                let indexed = sample(indexed: true)
                indexedTimes.append(indexed)
                print("REMINDER_HEARTBEAT_BENCHMARK same_day=\(sameDay) history=\(count) iterations=\(iterations) legacy_ns=\(legacy) indexed_ns=\(indexed) speedup=\(legacy / indexed) sink=\(sink)")
                if count == counts.last { XCTAssertGreaterThan(legacy / indexed, 10) }
            }
            // Broad relative bound tolerates scheduling noise but rejects a full-history scan.
            XCTAssertLessThan(indexedTimes[2] / indexedTimes[0], 20)
        }
    }
}
