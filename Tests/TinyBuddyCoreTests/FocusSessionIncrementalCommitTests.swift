import Foundation
import XCTest
@testable import TinyBuddyCore

/// Pins the incremental commit path to the literal "regenerate everything"
/// semantics it replaces. The perf benchmark below covers the latency; these
/// tests cover correctness after every commit shape.
final class FocusSessionIncrementalCommitTests: XCTestCase {
    private let day = "2026-11-19"
    private let project = FocusProjectContext(key: "/Users/example/repo", displayName: "repo")
    private lazy var base = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!

    private func makeHistory(count: Int) -> [FocusSession] {
        var sessions: [FocusSession] = []
        sessions.reserveCapacity(count)
        let dayCount = (count + 5) / 6
        for index in 0 ..< count {
            let offset = dayCount - (index / 6)
            let start = base.addingTimeInterval(
                TimeInterval(-offset * 86_400 - 3_600 + (index % 6) * 3_600)
            )
            let end = start.addingTimeInterval(1_800)
            let dayIdentifier = Self.dayIdentifier(for: start)
            sessions.append(FocusSession(
                project: project,
                dayIdentifier: dayIdentifier,
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

    private func makeEngine(history: [FocusSession], clock: FakeClock) -> (FocusSessionEngine, MemoryStore) {
        let store = MemoryStore()
        store.stored = history
        let identifier = day
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { _ in identifier }
        )
        return (engine, store)
    }

    private func referenceReminderMetrics(
        sessions: [FocusSession],
        dayIdentifier: String,
        now: Date
    ) -> (total: TimeInterval, open: FocusSession?) {
        let total = sessions
            .filter { $0.dayIdentifier == dayIdentifier }
            .reduce(0) { $0 + $1.activeDuration(now: now) }
        return (total, sessions.first(where: \.isOpen))
    }

    private func assertReminderMetricsMatchReference(
        _ engine: FocusSessionEngine,
        clock: FakeClock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reference = referenceReminderMetrics(
            sessions: engine.allSessions,
            dayIdentifier: day,
            now: clock.now
        )
        let metrics = engine.reminderMetrics(dayIdentifier: day, now: clock.now)
        XCTAssertEqual(metrics.totalFocusDuration, reference.total, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(metrics.openSessionID, reference.open?.id, file: file, line: line)
        XCTAssertEqual(metrics.openSessionIsActive, reference.open?.status == .active, file: file, line: line)
        XCTAssertEqual(
            metrics.openSessionIsPaused,
            reference.open?.currentPauseStartedAt != nil,
            file: file,
            line: line
        )
    }

    private func assertHistoryAggregationMatchesFullRebuild(
        _ engine: FocusSessionEngine,
        clock: FakeClock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cache = FocusHistoryAggregationCache(sessions: engine.allSessions)
        let query = FocusHistoryQuery(
            referenceDayIdentifier: engine.currentDayIdentifier,
            source: FocusHistorySource(health: .available),
            activeProjectKeys: nil,
            defaultDailyGoalMinutes: FocusGoalConfiguration.default.dailyFocusGoalMinutes
        )
        let expected = try cache.snapshot(for: query, now: clock.now)
        let publication = engine.focusHistoryPublication()
        XCTAssertEqual(publication?.snapshot, expected, file: file, line: line)
    }

    private func assertEvidenceMatchesFullRegeneration(
        _ engine: FocusSessionEngine,
        clock: FakeClock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // A second engine loaded with the same sessions and no evidence archive
        // regenerates every record from scratch; only the random evidence /
        // decision explanation identifiers may differ.
        // A reference engine reconciles any open session as crash recovery on
        // load, so this comparison only applies once the archive is closed.
        guard engine.allSessions.allSatisfy({ !$0.isOpen }) else { return }
        let (reference, _) = makeEngine(history: engine.allSessions, clock: clock)
        XCTAssertEqual(reference.allSessions, engine.allSessions, file: file, line: line)
        for session in engine.allSessions {
            let incremental = engine.evidence(for: session.id)
            let regenerated = reference.evidence(for: session.id)
            guard let incremental else {
                XCTAssertNil(regenerated, "missing evidence for \(session.id)", file: file, line: line)
                continue
            }
            guard let regenerated else {
                XCTFail("extra evidence for \(session.id)", file: file, line: line)
                continue
            }
            XCTAssertEqual(incremental.sessionID, regenerated.sessionID, file: file, line: line)
            XCTAssertEqual(incremental.createdAt, regenerated.createdAt, file: file, line: line)
            XCTAssertEqual(incremental.ruleVersion, regenerated.ruleVersion, file: file, line: line)
            XCTAssertEqual(incremental.confidence, regenerated.confidence, file: file, line: line)
            XCTAssertEqual(incremental.projectAttribution, regenerated.projectAttribution, file: file, line: line)
            XCTAssertEqual(
                incremental.decisionExplanations.map(Self.explanationSignature),
                regenerated.decisionExplanations.map(Self.explanationSignature),
                file: file,
                line: line
            )
        }
    }

    private static func explanationSignature(_ explanation: FocusSessionDecisionExplanation) -> String {
        "\(explanation.at.timeIntervalSinceReferenceDate)|\(explanation.kind.rawValue)|\(explanation.reason.rawValue)|\(explanation.source.rawValue)|\(explanation.confidence.rawValue)|\(explanation.explanation)"
    }

    func testIncrementalStateKeepsReminderHistoryAndEvidenceEqualToFullRebuild() throws {
        let clock = FakeClock(base)
        let (engine, _) = makeEngine(history: makeHistory(count: 120), clock: clock)

        XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .saved)
        assertReminderMetricsMatchReference(engine, clock: clock)
        try assertHistoryAggregationMatchesFullRebuild(engine, clock: clock)
        assertEvidenceMatchesFullRegeneration(engine, clock: clock)

        clock.advance(by: 600)
        XCTAssertEqual(engine.pauseManualFocus(at: clock.now), .saved)
        assertReminderMetricsMatchReference(engine, clock: clock)
        try assertHistoryAggregationMatchesFullRebuild(engine, clock: clock)
        assertEvidenceMatchesFullRegeneration(engine, clock: clock)

        clock.advance(by: 300)
        XCTAssertEqual(engine.resumeManualFocus(at: clock.now), .saved)
        assertReminderMetricsMatchReference(engine, clock: clock)
        try assertHistoryAggregationMatchesFullRebuild(engine, clock: clock)
        assertEvidenceMatchesFullRegeneration(engine, clock: clock)

        clock.advance(by: 600)
        XCTAssertEqual(engine.endManualFocus(at: clock.now), .saved)
        assertReminderMetricsMatchReference(engine, clock: clock)
        try assertHistoryAggregationMatchesFullRebuild(engine, clock: clock)
        assertEvidenceMatchesFullRegeneration(engine, clock: clock)

        let editable = try XCTUnwrap(engine.allSessions.dropLast().first)
        let correctedProject = FocusProjectContext(key: "/Users/example/other", displayName: "other")
        guard case .saved = engine.editSession(id: editable.id, project: correctedProject) else {
            return XCTFail("expected edit")
        }
        assertReminderMetricsMatchReference(engine, clock: clock)
        try assertHistoryAggregationMatchesFullRebuild(engine, clock: clock)
        assertEvidenceMatchesFullRegeneration(engine, clock: clock)

        guard case .saved = engine.deleteSession(id: editable.id) else {
            return XCTFail("expected delete")
        }
        assertReminderMetricsMatchReference(engine, clock: clock)
        try assertHistoryAggregationMatchesFullRebuild(engine, clock: clock)
        assertEvidenceMatchesFullRegeneration(engine, clock: clock)

        guard case .saved = engine.undoLastEdit() else {
            return XCTFail("expected undo")
        }
        assertReminderMetricsMatchReference(engine, clock: clock)
        try assertHistoryAggregationMatchesFullRebuild(engine, clock: clock)
        assertEvidenceMatchesFullRegeneration(engine, clock: clock)
    }

    func testNoOpReportsDoNotRepublishOrRewriteIncrementalState() {
        let clock = FakeClock(base)
        let (engine, _) = makeEngine(history: makeHistory(count: 200), clock: clock)

        let sessionsBefore = engine.allSessions
        let evidenceBefore = engine.allEvidence
        // No open session: both reports are semantic no-ops.
        XCTAssertEqual(engine.foregroundProjectChanged(to: project, at: clock.now), .noChange)
        XCTAssertEqual(engine.idleDetected(at: clock.now), .noChange)
        XCTAssertEqual(engine.allSessions, sessionsBefore)
        XCTAssertEqual(engine.allEvidence, evidenceBefore)

        // After a committed transition the same no-op path must stay a no-op.
        XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .saved)
        clock.advance(by: 60)
        XCTAssertEqual(engine.endManualFocus(at: clock.now), .saved)
        let committedSessions = engine.allSessions
        let committedEvidence = engine.allEvidence
        XCTAssertEqual(engine.foregroundProjectChanged(to: project, at: clock.now), .noChange)
        XCTAssertEqual(engine.allSessions, committedSessions)
        XCTAssertEqual(engine.allEvidence, committedEvidence)
    }

    func testIncompleteLoadedEvidenceIsHealedBeforeIncrementalCommits() throws {
        let history = makeHistory(count: 3)
        let clock = FakeClock(base)
        let seedEngine = makeEngine(history: history, clock: clock).0
        var partialEvidence = seedEngine.allEvidence
        let missingID = history[0].id
        partialEvidence.removeValue(forKey: missingID)
        XCTAssertFalse(partialEvidence.isEmpty)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-evidence-heal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fileStore = FocusSessionFileStore(fileURL: fileURL)
        XCTAssertTrue(fileStore.saveArchive(FocusSessionArchive(
            revision: 2,
            sessions: history,
            evidenceArchive: FocusSessionEvidenceArchive(
                revision: 1,
                evidenceBySessionID: partialEvidence
            )
        )))

        let engine = FocusSessionEngine(
            clock: clock,
            persisting: fileStore,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { _ in self.day }
        )
        // The missing unchanged session is repaired on load; incremental
        // commits must not leave it missing.
        XCTAssertNotNil(engine.evidence(for: missingID))
        XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .saved)
        clock.advance(by: 60)
        XCTAssertEqual(engine.endManualFocus(at: clock.now), .saved)
        XCTAssertNotNil(engine.evidence(for: missingID))
        assertEvidenceMatchesFullRegeneration(engine, clock: clock)
    }

    func testFailedCrashRecoveryWriteLeavesRegeneratedEvidenceInMemory() throws {
        let sessionStart = base.addingTimeInterval(-3_600)
        let openSession = FocusSession(
            project: project,
            dayIdentifier: day,
            startedAt: sessionStart,
            status: .active,
            lastUserActivityAt: sessionStart,
            lastStateChangeAt: sessionStart,
            decisionEvents: [
                FocusSessionDecisionEvent(
                    at: sessionStart,
                    kind: .started,
                    reason: .userActivity,
                    source: .automatic
                )
            ],
            mode: .automatic,
            ruleVersion: FocusSessionRuleVersion.current
        )
        let store = MemoryStore()
        store.stored = [openSession]
        store.shouldFail = true
        let clock = FakeClock(base)
        let identifier = day
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { _ in identifier }
        )

        let recovered = try XCTUnwrap(engine.allSessions.first)
        XCTAssertEqual(recovered.status, .ended)
        let evidence = try XCTUnwrap(engine.evidence(for: recovered.id))
        XCTAssertTrue(evidence.decisionExplanations.contains { $0.reason == .crashRecovery })
    }

    func testBackwardClockJumpRevalidatesCommittedStateOnNoOpReport() {
        let history = makeHistory(count: 1)
        let clock = FakeClock(base)
        let (engine, _) = makeEngine(history: history, clock: clock)
        XCTAssertEqual(engine.foregroundProjectChanged(to: project, at: clock.now), .noChange)

        // Move the wall clock before the archived session, beyond any
        // day-boundary tolerance. The cached validation result no longer
        // applies, so the same no-op report must be rejected as invalid.
        clock.set(to: history[0].startedAt.addingTimeInterval(-86_400))
        XCTAssertEqual(engine.foregroundProjectChanged(to: project, at: clock.now), .rejectedInvalid)
    }

    func testReminderTotalAfterDeletionMatchesArchiveOrderRecomputation() throws {
        let start = base.addingTimeInterval(-7_200)
        let first = FocusSession(
            project: project,
            dayIdentifier: day,
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            status: .ended,
            lastUserActivityAt: start.addingTimeInterval(3_600),
            lastStateChangeAt: start.addingTimeInterval(3_600),
            decisionEvents: [
                FocusSessionDecisionEvent(at: start, kind: .started, reason: .userActivity, source: .automatic),
                FocusSessionDecisionEvent(
                    at: start.addingTimeInterval(3_600),
                    kind: .ended,
                    reason: .idle,
                    source: .automatic
                )
            ],
            mode: .automatic,
            ruleVersion: FocusSessionRuleVersion.current
        )
        let secondStart = start.addingTimeInterval(4_000)
        let secondEnd = secondStart.addingTimeInterval(2_850.085225877114)
        let second = FocusSession(
            project: project,
            dayIdentifier: day,
            startedAt: secondStart,
            endedAt: secondEnd,
            status: .ended,
            lastUserActivityAt: secondEnd,
            lastStateChangeAt: secondEnd,
            decisionEvents: [
                FocusSessionDecisionEvent(at: secondStart, kind: .started, reason: .userActivity, source: .automatic),
                FocusSessionDecisionEvent(at: secondEnd, kind: .ended, reason: .idle, source: .automatic)
            ],
            mode: .automatic,
            ruleVersion: FocusSessionRuleVersion.current
        )
        let clock = FakeClock(base)
        let (engine, _) = makeEngine(history: [first, second], clock: clock)
        guard case .saved = engine.deleteSession(id: second.id) else {
            return XCTFail("expected delete")
        }

        let remaining = try XCTUnwrap(engine.allSessions.first)
        let expected = remaining.activeDuration(now: remaining.endedAt ?? remaining.startedAt)
        let metrics = engine.reminderMetrics(dayIdentifier: day, now: clock.now)
        XCTAssertEqual(metrics.totalFocusDuration, expected)
        XCTAssertEqual(metrics.totalFocusDuration, 3_600)
    }

    func testStaleLoadedEvidenceIsReconciledOnFirstSuccessfulCommit() throws {
        let session = makeHistory(count: 1)[0]
        let staleEvidence = FocusSessionEvidence(
            sessionID: session.id,
            createdAt: session.lastStateChangeAt,
            ruleVersion: .current,
            confidence: .high,
            projectAttribution: FocusSessionProjectAttribution(
                displayName: session.project.displayName,
                source: .foregroundApp,
                confidence: .high,
                redactedIdentifier: "stale",
                explanation: "stale explanation"
            ),
            decisionExplanations: []
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-stale-evidence-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fileStore = FocusSessionFileStore(fileURL: fileURL)
        XCTAssertTrue(fileStore.saveArchive(FocusSessionArchive(
            revision: 2,
            sessions: [session],
            evidenceArchive: FocusSessionEvidenceArchive(
                revision: 1,
                evidenceBySessionID: [session.id: staleEvidence]
            )
        )))

        let clock = FakeClock(base)
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: fileStore,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { _ in self.day }
        )
        // Matches the previous behavior: the loaded record is trusted until the
        // next durable commit.
        XCTAssertEqual(
            engine.evidence(for: session.id)?.projectAttribution.source,
            .foregroundApp
        )
        XCTAssertEqual(engine.startManualFocus(project: project, at: clock.now), .saved)
        clock.advance(by: 60)
        XCTAssertEqual(engine.endManualFocus(at: clock.now), .saved)
        // The first commit reconciles the whole archive once, so the unrelated
        // historical row is rebuilt with the current attribution rules.
        XCTAssertEqual(
            engine.evidence(for: session.id)?.projectAttribution.source,
            .gitActivity
        )
    }

    func testRepeatedProjectSwitchesKeepOpenReminderSession() {
        let clock = FakeClock(base)
        let (engine, _) = makeEngine(history: [], clock: clock)
        let projects = [
            project,
            FocusProjectContext(key: "/Users/example/other", displayName: "other"),
            FocusProjectContext(key: "com.example.editor", displayName: "editor")
        ]
        for step in 0 ..< 30 {
            clock.advance(by: 60)
            XCTAssertEqual(
                engine.startManualFocus(project: projects[step % projects.count], at: clock.now),
                .saved
            )
            let openSession = engine.allSessions.first(where: \.isOpen)
            XCTAssertNotNil(openSession)
            XCTAssertEqual(
                engine.reminderMetrics(dayIdentifier: day, now: clock.now).openSessionID,
                openSession?.id,
                "the reminder cache must keep the surviving open session after a project switch"
            )
        }
    }
}
