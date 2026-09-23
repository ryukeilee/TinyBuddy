import Foundation
import XCTest
@testable import TinyBuddyCore

private final class FocusHistoryTransitionSnapshotSink: @unchecked Sendable {
    private let lock = NSLock()
    private let store: TinyBuddyCombinedSnapshotStore
    private var persistenceOutcomes: [TinyBuddyCombinedSnapshotStore.UpdateResult] = []
    private var publications: [FocusHistoryPublication] = []

    init(store: TinyBuddyCombinedSnapshotStore) {
        self.store = store
    }

    func publish(_ publication: FocusHistoryPublication) {
        guard let day = publication.snapshot.recentDays.last?.dayIdentifier else { return }
        let result = store.updateFocusHistorySlice(
            publication,
            fallbackSnapshot: TinyBuddySnapshot(
                status: publication.isFocusSessionActive || publication.isFocusSessionPaused
                    ? .focusing
                    : .idle,
                stats: DailyStats(dayIdentifier: day, focusCount: 0, completionCount: 0)
            )
        )
        lock.lock(); defer { lock.unlock() }
        publications.append(publication)
        persistenceOutcomes.append(result)
    }

    var recorded: ([FocusHistoryPublication], [TinyBuddyCombinedSnapshotStore.UpdateResult]) {
        lock.lock(); defer { lock.unlock() }
        return (publications, persistenceOutcomes)
    }
}

final class FocusHistoryLiveDurationProjectionTests: XCTestCase {
    func testRunningAndPausedAnchorsProjectDayAndWeekAtReadTime() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = try makeSnapshot(day: "2025-06-03", duration: 600)
        let running = FocusHistoryPublication(
            revision: 1,
            snapshot: snapshot,
            isFocusSessionActive: true,
            liveDurationAnchor: FocusHistoryLiveDurationAnchor(
                dayIdentifier: "2025-06-03",
                accumulatedDuration: 600,
                capturedAt: start,
                isRunning: true
            )
        )
        let paused = FocusHistoryPublication(
            revision: 2,
            snapshot: snapshot,
            isFocusSessionPaused: true,
            liveDurationAnchor: FocusHistoryLiveDurationAnchor(
                dayIdentifier: "2025-06-03",
                accumulatedDuration: 600,
                capturedAt: start,
                isRunning: false
            )
        )
        let later = start.addingTimeInterval(120)

        XCTAssertEqual(running.currentDayDuration(at: later), 720)
        XCTAssertEqual(running.currentWeekDuration(at: later), 720)
        XCTAssertEqual(FocusHistoryDurationFormatter.text(for: running.currentDayDuration(at: later)), "0 小时 12 分")
        XCTAssertEqual(paused.currentDayDuration(at: later), 600)
        XCTAssertEqual(paused.currentWeekDuration(at: later), 600)
        XCTAssertEqual(FocusHistoryDurationFormatter.text(for: paused.currentDayDuration(at: later)), "0 小时 10 分")
    }

    func testLegacyPublicationStillUsesStoredDurationsWithoutAnAnchor() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = try makeSnapshot(day: "2025-06-03", duration: 600)
        let publication = FocusHistoryPublication(revision: 1, snapshot: snapshot)
        let later = start.addingTimeInterval(600)

        XCTAssertNil(publication.liveDurationAnchor)
        XCTAssertEqual(publication.currentDayDuration(at: later), 600)
        XCTAssertEqual(publication.currentWeekDuration(at: later), 600)
    }

    func testTransitionsPersistImmediatelyAndKeepAccumulatedDayDurationAcrossProjectSwitch() throws {
        let start = ISO8601DateFormatter().date(from: "2025-06-03T09:00:00Z")!
        let day = "2025-06-03"
        let nextDay = "2025-06-04"
        let clock = FakeClock(start)
        let sessionStore = MemoryStore()
        let defaultsName = "TinyBuddyLiveDurationTransitions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let combinedStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        let sink = FocusHistoryTransitionSnapshotSink(store: combinedStore)
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: sessionStore,
            dayIdentifier: { Self.dayIdentifier(for: $0) }
        )
        engine.committedHistorySnapshotHandler = { sink.publish($0) }

        XCTAssertEqual(
            engine.startManualFocus(project: FocusProjectContext(key: "project-a", displayName: "A"), at: start, commandToken: UUID()),
            .saved
        )
        XCTAssertEqual(sink.recorded.1.count, 1)
        XCTAssertTrue(sink.recorded.1[0].didPersist, "Start must commit the shared snapshot synchronously at the publication sink")
        XCTAssertTrue(try XCTUnwrap(engine.focusHistoryPublication()).isFocusSessionActive)

        clock.advance(by: 120)
        XCTAssertEqual(engine.pauseManualFocus(at: clock.now, commandToken: UUID()), .saved)
        XCTAssertEqual(sink.recorded.1.count, 2)
        let paused = try XCTUnwrap(engine.focusHistoryPublication())
        XCTAssertFalse(paused.isFocusSessionActive)
        XCTAssertTrue(paused.isFocusSessionPaused)
        XCTAssertEqual(paused.currentDayDuration(at: clock.now.addingTimeInterval(600)), 120)

        clock.advance(by: 600)
        XCTAssertEqual(engine.resumeManualFocus(at: clock.now, commandToken: UUID()), .saved)
        XCTAssertEqual(sink.recorded.1.count, 3)
        let resumed = try XCTUnwrap(engine.focusHistoryPublication())
        XCTAssertTrue(resumed.isFocusSessionActive)
        XCTAssertEqual(resumed.currentDayDuration(at: clock.now.addingTimeInterval(60)), 180)
        XCTAssertEqual(FocusHistoryDurationFormatter.text(for: resumed.currentDayDuration(at: clock.now.addingTimeInterval(60))), "0 小时 3 分")

        clock.advance(by: 60)
        XCTAssertEqual(
            engine.startManualFocus(project: FocusProjectContext(key: "project-b", displayName: "B"), at: clock.now, commandToken: UUID()),
            .saved
        )
        XCTAssertEqual(sink.recorded.1.count, 4)
        let switched = try XCTUnwrap(engine.focusHistoryPublication())
        XCTAssertEqual(switched.currentDayDuration(at: clock.now), 180)
        XCTAssertEqual(switched.currentDayDuration(at: clock.now.addingTimeInterval(60)), 240)
        XCTAssertEqual(switched.liveDurationAnchor?.accumulatedDuration, 0)

        clock.advance(by: 30)
        XCTAssertEqual(engine.endManualFocus(at: clock.now, commandToken: UUID()), .saved)
        XCTAssertEqual(sink.recorded.1.count, 5)
        let ended = try XCTUnwrap(engine.focusHistoryPublication())
        XCTAssertNil(ended.liveDurationAnchor)
        XCTAssertEqual(ended.currentDayDuration(at: clock.now), 210)

        clock.set(to: ISO8601DateFormatter().date(from: "2025-06-03T23:58:00Z")!)
        XCTAssertEqual(
            engine.startManualFocus(project: FocusProjectContext(key: "project-c", displayName: "C"), at: clock.now, commandToken: UUID()),
            .saved
        )
        XCTAssertEqual(sink.recorded.1.count, 6)
        clock.advance(by: 4 * 60)
        XCTAssertEqual(engine.timeChanged(at: clock.now, dayIdentifier: nextDay), .saved)
        XCTAssertEqual(sink.recorded.1.count, 7)

        let nextDayPublication = try XCTUnwrap(engine.focusHistoryPublication())
        XCTAssertEqual(engine.currentDayIdentifier, nextDay)
        XCTAssertEqual(nextDayPublication.snapshot.recentDays.last?.dayIdentifier, nextDay)
        XCTAssertNil(nextDayPublication.liveDurationAnchor)
        XCTAssertEqual(nextDayPublication.currentDayDuration(at: clock.now), 0)
        XCTAssertTrue(engine.sessionsForDay(day).allSatisfy { !$0.isOpen })
        XCTAssertTrue(engine.sessionsForDay(nextDay).isEmpty)
        XCTAssertTrue(sink.recorded.1.allSatisfy(\.didPersist), "Every semantic transition must immediately persist its combined snapshot")
        XCTAssertEqual(combinedStore.readValidated(expectedDayIdentifier: nextDay).snapshot?.focusHistoryPublication, nextDayPublication)
    }

    private func makeSnapshot(day: String, duration: TimeInterval) throws -> FocusHistorySnapshot {
        let query = FocusHistoryQuery(
            referenceDayIdentifier: day,
            source: FocusHistorySource(health: .available)
        )
        return try FocusHistoryAggregationCache().snapshot(for: query, now: nil)
            .replacingCurrentDayDuration(duration)
    }

    private static func dayIdentifier(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private extension FocusHistorySnapshot {
    func replacingCurrentDayDuration(_ duration: TimeInterval) -> FocusHistorySnapshot {
        let days = recentDays.map { day in
            guard day.dayIdentifier == recentDays.last?.dayIdentifier else { return day }
            return FocusHistoryDay(
                dayIdentifier: day.dayIdentifier,
                state: .sessions,
                focusDuration: duration,
                completedSessionCount: day.completedSessionCount,
                goalMinutes: day.goalMinutes,
                goalCompletionRate: day.goalCompletionRate,
                isGoalMet: day.isGoalMet,
                contributingSessionIDs: day.contributingSessionIDs
            )
        }
        let updatedWeek = FocusHistoryWeek(
            startDayIdentifier: currentWeek.startDayIdentifier,
            endDayIdentifier: currentWeek.endDayIdentifier,
            state: currentWeek.state,
            focusDuration: duration,
            completedSessionCount: currentWeek.completedSessionCount,
            goalCompletionRate: currentWeek.goalCompletionRate,
            goalMetDayCount: currentWeek.goalMetDayCount,
            configuredGoalDayCount: currentWeek.configuredGoalDayCount,
            projectDistribution: currentWeek.projectDistribution
        )
        return FocusHistorySnapshot(
            state: .available,
            sourceHealth: sourceHealth,
            recentDays: days,
            currentWeek: updatedWeek,
            currentGoalStreakDays: currentGoalStreakDays
        )
    }
}
