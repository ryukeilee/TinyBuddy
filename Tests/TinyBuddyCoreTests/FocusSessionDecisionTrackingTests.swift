import XCTest
@testable import TinyBuddyCore

final class FocusSessionDecisionTrackingTests: XCTestCase {
    private let projectA = FocusProjectContext(key: "repo/a", displayName: "Project A")
    private let projectB = FocusProjectContext(key: "repo/b", displayName: "Project B")
    private let start = Date(timeIntervalSinceReferenceDate: 2_000_000)

    func testAutomaticLifecycleRecordsUserIdleResumeAndLockReasons() throws {
        let (engine, clock, _) = makeEngine()

        XCTAssertEqual(engine.userActivity(in: projectA, at: start), .saved)
        clock.advance(by: 120)
        XCTAssertEqual(engine.idleDetected(at: clock.now), .saved)
        clock.advance(by: 30)
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)
        clock.advance(by: 10)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)

        let events = try XCTUnwrap(engine.allSessions.first?.decisionEvents)
        XCTAssertEqual(events.map(\.kind), [.started, .paused, .resumed, .ended])
        XCTAssertEqual(events.map(\.reason), [.userActivity, .idle, .userActivity, .lockScreen])
        XCTAssertEqual(Set(events.map(\.source)), [.automatic])
    }

    func testGitActivityAndProjectSwitchRemainDistinguishable() async throws {
        let (engine, clock, _) = makeEngine()
        let eventStart = start
        let firstProject = projectA
        let secondProject = projectB
        let coordinator = await MainActor.run {
            FocusSessionCoordinator(
                engine: engine,
                clock: clock,
                gitProjectResolver: { key, name in
                    FocusProjectContext(key: key, displayName: name)
                }
            )
        }

        await MainActor.run {
            coordinator.reportForegroundApp(
                bundleID: "com.apple.dt.Xcode",
                displayName: "Xcode",
                isCodeEditor: true,
                at: eventStart
            )
            coordinator.reportGitActivity(
                repoKey: firstProject.key,
                displayName: firstProject.displayName,
                automated: false,
                at: eventStart
            )
        }
        clock.advance(by: 20)
        await MainActor.run {
            coordinator.reportForegroundApp(
                bundleID: secondProject.key,
                displayName: secondProject.displayName,
                isCodeEditor: false,
                at: clock.now
            )
        }
        clock.advance(by: 5)
        await MainActor.run { coordinator.reportUserInput(at: clock.now) }

        let sessions = engine.allSessions.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].decisionEvents?.first?.reason, .gitActivity)
        XCTAssertEqual(sessions[0].decisionEvents?.last?.reason, .projectSwitch)
        XCTAssertEqual(sessions[1].decisionEvents?.first?.reason, .userActivity)
    }

    func testSleepAndAutomaticTerminationRecordTheirOwnEndReasons() throws {
        let (engine, clock, _) = makeEngine()
        engine.userActivity(in: projectA, at: start)
        clock.advance(by: 10)
        engine.systemSleep(at: clock.now)
        XCTAssertEqual(engine.allSessions[0].decisionEvents?.last?.reason, .systemSleep)

        clock.advance(by: 10)
        engine.userActivity(in: projectA, at: clock.now)
        clock.advance(by: 10)
        engine.appWillTerminate(at: clock.now)
        XCTAssertEqual(engine.allSessions[1].decisionEvents?.last?.reason, .appTermination)
    }

    func testDayBoundaryAndCrashRecoveryExplainAutomaticEndingWithoutBackfill() throws {
        let (engine, clock, store) = makeEngine()
        engine.userActivity(in: projectA, at: start)
        clock.advance(by: 10)
        engine.timeChanged(at: clock.now, dayIdentifier: "2001-01-25")
        XCTAssertEqual(engine.allSessions[0].decisionEvents?.last?.reason, .dayBoundary)

        clock.advance(by: 10)
        engine.userActivity(in: projectA, at: clock.now)
        let openLastChange = try XCTUnwrap(engine.allSessions.last?.lastStateChangeAt)
        clock.advance(by: 3_600)
        let restarted = FocusSessionEngine(
            clock: clock,
            persisting: store,
            dayIdentifier: { _ in "2001-01-25" }
        )
        XCTAssertEqual(restarted.allSessions.last?.endedAt, openLastChange)
        XCTAssertEqual(restarted.allSessions.last?.decisionEvents?.last?.reason, .crashRecovery)
    }

    func testConfirmationAndCorrectionAreDistinctAndCorrectionWins() throws {
        let (engine, clock, _) = makeEngine()
        engine.userActivity(in: projectA, at: start)
        clock.advance(by: 30)
        engine.lockScreen(at: clock.now)
        let id = try XCTUnwrap(engine.allSessions.first?.id)

        guard case .saved = engine.confirmSession(id: id) else {
            return XCTFail("Expected confirmation")
        }
        XCTAssertEqual(engine.allSessions[0].decisionAuthority, .userConfirmed)
        XCTAssertEqual(engine.allSessions[0].decisionEvents?.last?.kind, .confirmed)

        guard case .saved = engine.editSession(id: id, project: projectB) else {
            return XCTFail("Expected correction")
        }
        XCTAssertEqual(engine.allSessions[0].decisionAuthority, .manualCorrection)
        XCTAssertEqual(engine.allSessions[0].decisionEvents?.last?.kind, .projectChanged)

        clock.advance(by: 10)
        engine.userActivity(in: projectA, at: clock.now)
        XCTAssertEqual(engine.allSessions.first(where: { $0.id == id })?.project, projectB)
        XCTAssertEqual(engine.allSessions.first(where: { $0.id == id })?.decisionAuthority, .manualCorrection)
    }

    func testSplitMergeDeleteAndUndoKeepUniqueDecisionChainAndDerivedStatistics() throws {
        let (engine, clock, _) = makeEngine()
        engine.userActivity(in: projectA, at: start)
        clock.advance(by: 60)
        engine.lockScreen(at: clock.now)
        let id = try XCTUnwrap(engine.allSessions.first?.id)

        guard case .saved = engine.splitSession(id: id, at: start.addingTimeInterval(20)) else {
            return XCTFail("Expected split")
        }
        assertUniqueDecisionIDs(engine.allSessions)
        XCTAssertEqual(engine.derivedSnapshot().completedSessionCount, 2)
        XCTAssertEqual(
            engine.focusHistoryPublication()?.snapshot.recentDays.last?.contributingSessionIDs?.count,
            2
        )
        XCTAssertTrue(engine.allSessions.allSatisfy { $0.decisionAuthority == .manualCorrection })
        let splitRows = engine.allSessions.sorted { $0.startedAt < $1.startedAt }
        XCTAssertTrue(splitRows[0].decisionEvents?.contains(where: {
            $0.kind == .ended && $0.reason == .manualSplit
        }) == true)
        XCTAssertTrue(splitRows[1].decisionEvents?.contains(where: {
            $0.kind == .started && $0.reason == .manualSplit
        }) == true)

        guard case .saved = engine.mergeSessions(ids: engine.allSessions.map(\.id)) else {
            return XCTFail("Expected merge")
        }
        assertUniqueDecisionIDs(engine.allSessions)
        XCTAssertEqual(engine.derivedSnapshot().completedSessionCount, 1)
        XCTAssertEqual(engine.allSessions[0].decisionEvents?.last?.kind, .merged)

        guard case .saved = engine.deleteSession(id: id) else {
            return XCTFail("Expected delete")
        }
        XCTAssertEqual(engine.derivedSnapshot().completedSessionCount, 0)
        XCTAssertEqual(
            engine.focusHistoryPublication()?.snapshot.recentDays.last?.contributingSessionIDs,
            []
        )
        guard case .saved = engine.undoLastEdit() else {
            return XCTFail("Expected undo")
        }
        assertUniqueDecisionIDs(engine.allSessions)
        XCTAssertEqual(engine.derivedSnapshot().completedSessionCount, 1)
        XCTAssertEqual(
            engine.focusHistoryPublication()?.snapshot.recentDays.last?.contributingSessionIDs,
            [id]
        )
        XCTAssertEqual(engine.allSessions[0].decisionEvents?.last?.kind, .undo)
    }

    func testLegacySessionDoesNotInventMissingSourceAndCorrectionOnlyAddsProvableEvent() throws {
        let legacyJSON = """
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "project":{"key":"legacy","displayName":"Legacy"},
          "dayIdentifier":"2001-01-24",
          "startedAt":1000,
          "endedAt":1060,
          "status":"ended",
          "lastUserActivityAt":1000,
          "lastStateChangeAt":1060,
          "pausedTotal":0,
          "isManuallyConfirmed":false
        }
        """
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(FocusSession.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.decisionEvents)
        XCTAssertNil(legacy.decisionAuthority)

        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1_100))
        let store = MemoryStore()
        store.stored = [legacy]
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            dayIdentifier: { _ in "2001-01-24" }
        )
        guard case .saved = engine.editSession(id: legacy.id, project: projectB) else {
            return XCTFail("Expected legacy correction")
        }
        let events = try XCTUnwrap(engine.allSessions[0].decisionEvents)
        XCTAssertEqual(events.map(\.kind), [.projectChanged])
        XCTAssertFalse(events.contains(where: { $0.kind == .started }))
    }

    func testDecisionEventEncodingContainsOnlyMinimalEnumeratedFields() throws {
        let event = FocusSessionDecisionEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            at: start,
            kind: .started,
            reason: .gitActivity,
            source: .automatic
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["id", "at", "kind", "reason", "source"])
        XCTAssertNil(object["path"])
        XCTAssertNil(object["repositoryURL"])
        XCTAssertNil(object["commitMessage"])
        XCTAssertNil(object["keyboardContent"])
    }

    func testAutomaticProjectResolutionCannotOverrideManualReassignment() throws {
        let clock = FakeClock(start)
        let store = MemoryStore()
        let redirected = FocusProjectContext(key: "registry/redirect", displayName: "Redirected")
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            dayIdentifier: { _ in "2001-01-24" },
            projectContextResolver: { _ in redirected }
        )
        engine.userActivity(in: projectA, at: start)
        clock.advance(by: 30)
        engine.lockScreen(at: clock.now)
        let id = try XCTUnwrap(engine.allSessions.first?.id)

        XCTAssertEqual(engine.projectDurationsToday(), [redirected.key: 30])
        guard case .saved = engine.editSession(id: id, project: projectB) else {
            return XCTFail("Expected manual reassignment")
        }

        XCTAssertEqual(engine.projectDurationsToday(), [projectB.key: 30])
        let projects = try XCTUnwrap(engine.focusHistoryPublication()?.snapshot.currentWeek.projectDistribution)
        XCTAssertEqual(projects.map(\.displayName), [projectB.displayName])
        XCTAssertEqual(projects.first?.contributingSessionIDs, [id])
    }

    private func makeEngine() -> (FocusSessionEngine, FakeClock, MemoryStore) {
        let clock = FakeClock(start)
        let store = MemoryStore()
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            dayIdentifier: { _ in "2001-01-24" }
        )
        return (engine, clock, store)
    }

    private func assertUniqueDecisionIDs(
        _ sessions: [FocusSession],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ids = sessions.compactMap(\.decisionEvents).flatMap { $0 }.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, file: file, line: line)
    }
}
