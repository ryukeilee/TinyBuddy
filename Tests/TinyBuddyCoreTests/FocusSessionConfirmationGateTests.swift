import XCTest
@testable import TinyBuddyCore

// MARK: - Helpers

private let gateT0 = Date(timeIntervalSinceReferenceDate: 3_000_000)
private let gateProjectA = FocusProjectContext(key: "repo/a", displayName: "Project A")
private let gateProjectB = FocusProjectContext(key: "repo/b", displayName: "Project B")

private func gateDayIdentifier(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

/// Default gate thresholds for these tests: 5-minute window, 2 minutes of
/// cumulative active time required to confirm.
private func gateConfig(
    confirmationWindow: TimeInterval = 300,
    confirmationMinimumActiveDuration: TimeInterval = 120
) -> FocusSessionConfiguration {
    FocusSessionConfiguration(
        confirmationWindow: confirmationWindow,
        confirmationMinimumActiveDuration: confirmationMinimumActiveDuration
    )
}

private func makeGateEngine(
    clock: FakeClock,
    store: MemoryStore,
    config: FocusSessionConfiguration = gateConfig()
) -> FocusSessionEngine {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return FocusSessionEngine(
        clock: clock,
        persisting: store,
        config: config,
        dayIdentifier: { gateDayIdentifier(for: $0) },
        nextDayBoundary: { date in
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        }
    )
}

/// Drives the real confirmation gate to confirmation for `project` by feeding
/// two activity events spanning the configured minimum active duration.
@discardableResult
private func confirmActivity(
    engine: FocusSessionEngine,
    in project: FocusProjectContext,
    startAt: Date,
    clock: FakeClock,
    config: FocusSessionConfiguration = gateConfig(),
    reason: FocusSessionDecisionReason = .userActivity
) -> FocusSessionUpdateOutcome {
    _ = engine.userActivity(in: project, at: startAt, reason: reason)
    clock.set(to: startAt.addingTimeInterval(config.confirmationMinimumActiveDuration))
    return engine.userActivity(in: project, at: clock.now, reason: reason)
}

// MARK: - Confirmation gate tests (contract: sustained activity required)

/// The confirmation gate tests live in the `FocusSessionEngineTests` class so
/// the focused `FocusSession(Engine|...)Tests` filter covers them. They drive
/// the real engine/coordinator with deterministic clocks and real thresholds.
extension FocusSessionEngineTests {

    // MARK: Enter gate (acceptance criterion 1)

    func testConfirmationGate_singleGitCommitDoesNotStartSession() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(
            engine.userActivity(in: gateProjectA, at: gateT0, reason: .gitActivity),
            .noChange
        )
        XCTAssertTrue(engine.allSessions.isEmpty)
        XCTAssertEqual(store.saveCount, 0, "Unconfirmed activity must not persist")
    }

    func testConfirmationGate_briefTypingDoesNotStartSession() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: gateT0), .noChange)
        clock.advance(by: 30) // brief burst, far below the 120s requirement
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        XCTAssertTrue(engine.allSessions.isEmpty)
    }

    func testConfirmationGate_foregroundChangeAloneDoesNotStartOrAccumulate() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(engine.foregroundProjectChanged(to: gateProjectA, at: gateT0), .noChange)
        XCTAssertTrue(engine.allSessions.isEmpty)

        // The foreground change must not have fed the gate: one activity event
        // afterwards is still not enough.
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        XCTAssertTrue(engine.allSessions.isEmpty)
    }

    func testConfirmationGate_sustainedActivityStartsSessionAtConfirmingEvent() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: gateT0), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        clock.advance(by: 60) // now 120s of cumulative activity within the window
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .saved)

        XCTAssertEqual(engine.allSessions.count, 1)
        let session = engine.allSessions[0]
        XCTAssertEqual(session.project, gateProjectA)
        XCTAssertTrue(session.isOpen)
        // The session starts at the confirming event, never at the first one:
        // pre-confirmation activity is not counted.
        XCTAssertEqual(session.startedAt, clock.now)
        XCTAssertEqual(session.activeDuration(now: clock.now), 0, accuracy: 0.001)
    }

    func testConfirmationGate_windowExpiryResetsAccumulation() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: gateT0), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)

        // Gap longer than the window discards the run.
        clock.advance(by: 300 + 10)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        XCTAssertTrue(engine.allSessions.isEmpty)
    }

    @MainActor
    func testConfirmationGate_sustainedGitActivityProducesGitAttributedEvidence() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let config = gateConfig(confirmationMinimumActiveDuration: 60)
        let engine = makeGateEngine(clock: clock, store: store, config: config)
        let coordinator = FocusSessionCoordinator(
            engine: engine,
            policy: FocusAttributionPolicy(gitAttributionWindow: nil),
            clock: clock
        )

        coordinator.reportForegroundApp(
            bundleID: "com.apple.dt.Xcode",
            displayName: "Xcode",
            isCodeEditor: true,
            at: gateT0
        )
        coordinator.reportGitActivity(
            repoKey: "/Users/me/work/repoA",
            displayName: "Repo A",
            automated: false,
            at: gateT0
        )
        clock.advance(by: 60)
        coordinator.reportGitActivity(
            repoKey: "/Users/me/work/repoA",
            displayName: "Repo A",
            automated: false,
            at: clock.now
        )

        XCTAssertEqual(engine.allSessions.count, 1)
        let session = try! XCTUnwrap(engine.allSessions.first)
        XCTAssertEqual(session.project.key, "/Users/me/work/repoA")
        XCTAssertEqual(session.decisionEvents?.first?.reason, .gitActivity)
        XCTAssertEqual(session.ruleVersion, FocusSessionRuleVersion.current)

        let evidence = try! XCTUnwrap(engine.evidence(for: session.id))
        XCTAssertEqual(evidence.projectAttribution.source, .gitActivity)
        XCTAssertEqual(evidence.ruleVersion, FocusSessionRuleVersion.current)
        XCTAssertEqual(evidence.confidence, .high)
        XCTAssertEqual(
            evidence.projectAttribution.redactedIdentifier,
            stableIdentifier(from: session.project.key)
        )
        XCTAssertFalse(evidence.projectAttribution.explanation.contains("/Users/me/work"))
        let startedExplanation = try! XCTUnwrap(
            evidence.decisionExplanations.first { $0.kind == .started }
        )
        XCTAssertTrue(startedExplanation.explanation.contains("Git"))
    }

    func testConfirmationGate_sustainedActivityDoesNotCreateDuplicateSessions() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)
        XCTAssertEqual(engine.allSessions.count, 1)

        // Further same-project activity while the session is open refreshes it,
        // never duplicates it.
        clock.advance(by: 30)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions.count, 1)
    }

    func testConfirmationGate_stateIsInMemoryOnlyAcrossRestart() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: gateT0), .noChange)
        XCTAssertTrue(engine.allSessions.isEmpty)
        XCTAssertNil(store.stored, "Unconfirmed candidates must not be persisted")

        // A restarted engine starts with an empty gate: no phantom accumulation.
        let restarted = makeGateEngine(clock: clock, store: store)
        clock.advance(by: 60)
        XCTAssertEqual(restarted.userActivity(in: gateProjectA, at: clock.now), .noChange)
        XCTAssertTrue(restarted.allSessions.isEmpty)
    }

    // MARK: Exit gate (acceptance criterion 2)

    func testConfirmationGate_idlePauseThenLongAbsenceEndsWithoutCountingIdle() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let config = FocusSessionConfiguration(
            idleThreshold: 30,
            longAbsenceThreshold: 120,
            confirmationWindow: 300,
            confirmationMinimumActiveDuration: 60
        )
        let engine = makeGateEngine(clock: clock, store: store, config: config)

        _ = confirmActivity(
            engine: engine, in: gateProjectA, startAt: gateT0, clock: clock, config: config
        )
        // Session confirmed and started at t0+60.
        clock.advance(by: 30)
        XCTAssertEqual(engine.idleDetected(at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions[0].status, .paused)

        // Long absence (≥ longAbsenceThreshold): the paused session ends at
        // the pause start; the idle interval never counts.
        clock.advance(by: 150)
        XCTAssertEqual(engine.endPausedSessionAfterLongAbsence(at: clock.now), .saved)
        let session = engine.allSessions[0]
        XCTAssertEqual(session.status, .ended)
        XCTAssertEqual(session.endedAt, gateT0.addingTimeInterval(90))
        XCTAssertEqual(session.activeDuration(now: clock.now), 30, accuracy: 0.001)
    }

    func testConfirmationGate_idleDetectedWhilePausedEndsAfterLongAbsence() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let config = FocusSessionConfiguration(
            idleThreshold: 30,
            longAbsenceThreshold: 120,
            confirmationWindow: 300,
            confirmationMinimumActiveDuration: 60
        )
        let engine = makeGateEngine(clock: clock, store: store, config: config)

        _ = confirmActivity(
            engine: engine, in: gateProjectA, startAt: gateT0, clock: clock, config: config
        )
        clock.advance(by: 30)
        XCTAssertEqual(engine.idleDetected(at: clock.now), .saved) // pause at t0+90

        clock.advance(by: 200)
        XCTAssertEqual(engine.idleDetected(at: clock.now), .saved) // ≥ long absence → end
        XCTAssertEqual(engine.allSessions[0].status, .ended)
        XCTAssertEqual(engine.allSessions[0].activeDuration(now: clock.now), 30, accuracy: 0.001)
    }

    func testConfirmationGate_singleActivityAfterEndDoesNotReviveSession() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)
        clock.advance(by: 30)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions[0].status, .ended)

        clock.advance(by: 60)
        XCTAssertEqual(engine.unlock(at: clock.now), .noChange)

        // A single event after the end must not revive the old session.
        clock.advance(by: 10)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
    }

    func testConfirmationGate_reentryRequiresFreshConfirmation() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)
        clock.advance(by: 30)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions.count, 1)

        clock.advance(by: 60)
        XCTAssertEqual(engine.unlock(at: clock.now), .noChange)

        // Re-entry must re-satisfy the confirmation condition from scratch.
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .saved)

        XCTAssertEqual(engine.allSessions.count, 2)
        XCTAssertTrue(engine.allSessions[1].isOpen)
    }

    // MARK: Misjudgment protection (acceptance criterion 3)

    func testConfirmationGate_projectSwitchResetsAccumulation_ABARoundTrip() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        // Fast A→B→A round trip: activity in B discards A's accumulation and
        // the return to A starts fresh, so no cross-project accumulation.
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: gateT0), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)

        XCTAssertTrue(engine.allSessions.isEmpty)
    }

    func testConfirmationGate_foregroundSwitchResetsAccumulation() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: gateT0), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        XCTAssertEqual(engine.foregroundProjectChanged(to: gateProjectB, at: clock.now), .noChange)

        // The switch discarded A's 60s; one more A event is not enough.
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        XCTAssertTrue(engine.allSessions.isEmpty)

        // Sustained activity afterwards confirms normally.
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions.count, 1)
    }

    @MainActor
    func testConfirmationGate_excludedProjectNeverGetsAutomaticFocus() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let config = gateConfig(confirmationMinimumActiveDuration: 60)
        let engine = makeGateEngine(clock: clock, store: store, config: config)
        let coordinator = FocusSessionCoordinator(
            engine: engine,
            policy: FocusAttributionPolicy(gitAttributionWindow: nil),
            clock: clock,
            exclusionGate: { context in
                context.key == "/Users/me/work/excluded"
            }
        )

        coordinator.reportForegroundApp(
            bundleID: "com.apple.dt.Xcode",
            displayName: "Xcode",
            isCodeEditor: true,
            at: gateT0
        )
        // Sustained activity in an excluded repository: never a session.
        coordinator.reportGitActivity(
            repoKey: "/Users/me/work/excluded", displayName: "Excluded", automated: false, at: gateT0
        )
        clock.advance(by: 60)
        coordinator.reportGitActivity(
            repoKey: "/Users/me/work/excluded", displayName: "Excluded", automated: false, at: clock.now
        )
        clock.advance(by: 60)
        coordinator.reportGitActivity(
            repoKey: "/Users/me/work/excluded", displayName: "Excluded", automated: false, at: clock.now
        )
        XCTAssertTrue(engine.allSessions.isEmpty)

        // The same gate then works for a non-excluded repository.
        clock.advance(by: 60)
        coordinator.reportGitActivity(
            repoKey: "/Users/me/work/ok", displayName: "OK", automated: false, at: clock.now
        )
        clock.advance(by: 60)
        coordinator.reportGitActivity(
            repoKey: "/Users/me/work/ok", displayName: "OK", automated: false, at: clock.now
        )
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].project.key, "/Users/me/work/ok")
    }

    func testConfirmationGate_singleActivityDoesNotSwitchOpenSession() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)
        XCTAssertEqual(engine.allSessions.count, 1)

        // A single activity in B must not switch: A pauses as a pending switch.
        clock.advance(by: 30)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].project, gateProjectA)
        XCTAssertEqual(engine.allSessions[0].status, .paused)
    }

    func testConfirmationGate_switchRequiresSustainedActivityInNewProject() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)
        // A confirmed at t0+120.

        // B activity: first event starts a pending switch, later events
        // accumulate; only sustained activity commits the switch at the first
        // event's boundary so the away gap never counts.
        clock.set(to: gateT0.addingTimeInterval(180))
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .saved)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .saved)

        XCTAssertEqual(engine.allSessions.count, 2)
        let a = engine.allSessions[0]
        let b = engine.allSessions[1]
        XCTAssertEqual(a.project, gateProjectA)
        XCTAssertEqual(a.status, .ended)
        XCTAssertEqual(a.endedAt, gateT0.addingTimeInterval(180))
        XCTAssertEqual(a.activeDuration(now: clock.now), 60, accuracy: 0.001)
        XCTAssertEqual(b.project, gateProjectB)
        XCTAssertTrue(b.isOpen)
        XCTAssertEqual(b.startedAt, gateT0.addingTimeInterval(180))
        XCTAssertEqual(b.activeDuration(now: clock.now), 120, accuracy: 0.001)
    }

    func testConfirmationGate_switchAttemptThenReturnDiscardsCandidateAccumulation() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)

        // Attempt B (not confirmed → A pauses, pending B).
        clock.set(to: gateT0.addingTimeInterval(180))
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .saved)
        // Return to A: brief interruption merge; B's accumulation is discarded.
        clock.advance(by: 20)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].status, .active)

        // A fresh single B event afterwards starts B's accumulation from zero.
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .saved)
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].project, gateProjectA)
    }

    // MARK: Manual priority (acceptance criterion 4)

    func testConfirmationGate_manualSessionImmuneToAutomaticActivity() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(engine.startManualFocus(project: gateProjectA, at: gateT0), .saved)

        // Sustained automatic activity in another project: zero effect on the
        // session (checkpoint timestamps update, which is a .saved mutation).
        clock.advance(by: 30)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .saved)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .saved)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .saved)
        XCTAssertEqual(engine.foregroundProjectChanged(to: gateProjectB, at: clock.now), .noChange)
        XCTAssertEqual(engine.idleDetected(at: clock.now), .noChange)

        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].mode, .manual)
        XCTAssertEqual(engine.allSessions[0].project, gateProjectA)
        XCTAssertEqual(engine.allSessions[0].status, .active)
    }

    func testConfirmationGate_startManualFocusTakesOverFromAutomaticSession() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)
        XCTAssertEqual(engine.allSessions[0].mode, .automatic)

        clock.advance(by: 30)
        XCTAssertEqual(engine.startManualFocus(project: gateProjectB, at: clock.now), .saved)

        XCTAssertEqual(engine.allSessions.count, 2)
        XCTAssertEqual(engine.allSessions[0].mode, .automatic)
        XCTAssertEqual(engine.allSessions[0].status, .ended)
        XCTAssertEqual(engine.allSessions[0].endedAt, clock.now)
        XCTAssertEqual(engine.allSessions[1].mode, .manual)
        XCTAssertEqual(engine.allSessions[1].status, .active)
        XCTAssertEqual(engine.allSessions[1].startedAt, clock.now)
    }

    func testConfirmationGate_pausedManualSessionUnaffectedByAutomaticActivity() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        XCTAssertEqual(engine.startManualFocus(project: gateProjectA, at: gateT0), .saved)
        clock.advance(by: 10)
        XCTAssertEqual(engine.pauseManualFocus(at: clock.now), .saved)

        // Automatic activity must neither resume nor end a paused manual session.
        clock.advance(by: 30)
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: clock.now), .noChange)
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: gateProjectB, at: clock.now), .noChange)

        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions[0].mode, .manual)
        XCTAssertEqual(engine.allSessions[0].status, .paused)
    }

    // MARK: Pure state machine

    func testConfirmationGate_pureStateMachineSemantics() {
        var gate = FocusSessionConfirmationGate()
        XCTAssertFalse(gate.isTracking)

        // Single event: tracks but never confirms with real thresholds.
        XCTAssertFalse(gate.recordActivity(project: gateProjectA, at: gateT0, window: 300, minimumActiveDuration: 120))
        XCTAssertTrue(gate.isTracking)
        XCTAssertEqual(gate.trackedProjectKey, gateProjectA.key)
        XCTAssertEqual(gate.accumulatedActiveTime, 0)

        // Same-project event inside the window accumulates the gap.
        XCTAssertFalse(gate.recordActivity(project: gateProjectA, at: gateT0.addingTimeInterval(60), window: 300, minimumActiveDuration: 120))
        XCTAssertEqual(gate.accumulatedActiveTime, 60, accuracy: 0.001)

        // A different project discards everything.
        XCTAssertFalse(gate.recordActivity(project: gateProjectB, at: gateT0.addingTimeInterval(90), window: 300, minimumActiveDuration: 120))
        XCTAssertEqual(gate.trackedProjectKey, gateProjectB.key)
        XCTAssertEqual(gate.accumulatedActiveTime, 0)

        // Window expiry restarts the run.
        XCTAssertFalse(gate.recordActivity(project: gateProjectB, at: gateT0.addingTimeInterval(100), window: 300, minimumActiveDuration: 120))
        XCTAssertEqual(gate.accumulatedActiveTime, 10, accuracy: 0.001)
        XCTAssertFalse(gate.recordActivity(project: gateProjectB, at: gateT0.addingTimeInterval(100 + 301), window: 300, minimumActiveDuration: 120))
        XCTAssertEqual(gate.accumulatedActiveTime, 0)

        // Accumulation reaching the threshold confirms; reset clears.
        XCTAssertTrue(gate.recordActivity(project: gateProjectB, at: gateT0.addingTimeInterval(100 + 301 + 120), window: 300, minimumActiveDuration: 120))
        gate.reset()
        XCTAssertFalse(gate.isTracking)
        XCTAssertEqual(gate.accumulatedActiveTime, 0)

        // minimumActiveDuration ≤ 0 confirms on the first event.
        var immediate = FocusSessionConfirmationGate()
        XCTAssertTrue(immediate.recordActivity(project: gateProjectA, at: gateT0, window: 300, minimumActiveDuration: 0))
    }

    // MARK: Production feed — periodic sustained-activity heartbeat

    /// The production idle poll reports sustained activity every poll while the
    /// user is active. Continuous typing without commits and without any
    /// idle→active transition must still confirm through the heartbeat, or
    /// automatic sessions would never start for typing-only work.
    func testConfirmationGate_heartbeatStartsSessionForContinuousTyping() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        // One transition event, then nothing but 15s heartbeats (the
        // production poll cadence) — no commits, no further transitions.
        XCTAssertEqual(engine.userActivity(in: gateProjectA, at: gateT0), .noChange)
        var outcome: FocusSessionUpdateOutcome = .noChange
        for _ in 1 ... 8 {
            clock.advance(by: 15)
            outcome = engine.reportSustainedActivity(in: gateProjectA, at: clock.now)
        }
        XCTAssertEqual(outcome, .saved)

        XCTAssertEqual(engine.allSessions.count, 1)
        let session = try! XCTUnwrap(engine.allSessions.first)
        XCTAssertTrue(session.isOpen)
        XCTAssertEqual(session.project, gateProjectA)
        // The session starts at the confirming heartbeat, never at the first event.
        XCTAssertEqual(session.startedAt, gateT0.addingTimeInterval(8 * 15))
        XCTAssertEqual(session.activeDuration(now: clock.now), 0, accuracy: 0.001)
    }

    /// The heartbeat must feed only the confirmation gate: for an already-open
    /// same-project session it is a pure no-op that never mutates state or
    /// writes (a live session accrues time without journal writes).
    func testConfirmationGate_heartbeatDoesNotMutateOrPersistOpenSession() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)
        let saveCountAfterConfirm = store.saveCount
        let sessionBefore = try! XCTUnwrap(engine.allSessions.first)

        clock.advance(by: 15)
        XCTAssertEqual(
            engine.reportSustainedActivity(in: gateProjectA, at: clock.now),
            .noChange
        )
        clock.advance(by: 15)
        XCTAssertEqual(
            engine.reportSustainedActivity(in: gateProjectA, at: clock.now),
            .noChange
        )

        let sessionAfter = try! XCTUnwrap(engine.allSessions.first)
        XCTAssertEqual(sessionAfter.startedAt, sessionBefore.startedAt)
        XCTAssertNil(sessionAfter.endedAt)
        XCTAssertEqual(
            store.saveCount,
            saveCountAfterConfirm,
            "Heartbeat must not persist for an open same-project session"
        )
    }

    /// Continuous typing in a new project (no idle transition, no commit) must
    /// confirm the pending switch through the heartbeat: the old session ends
    /// at the away boundary and the new one starts there.
    func testConfirmationGate_heartbeatConfirmsSwitchForContinuousTypingInNewProject() {
        let clock = FakeClock(gateT0)
        let store = MemoryStore()
        let engine = makeGateEngine(clock: clock, store: store)

        _ = confirmActivity(engine: engine, in: gateProjectA, startAt: gateT0, clock: clock)
        XCTAssertEqual(engine.allSessions.count, 1)

        // Foreground change to B sets up the pending switch; then only
        // heartbeats arrive — the user never goes idle and never commits.
        // The first heartbeat only starts tracking; 9 heartbeats add 8 gaps
        // of 15s = the 120s minimum active duration.
        let switchAt = clock.now
        engine.foregroundProjectChanged(to: gateProjectB, at: switchAt)
        var outcome: FocusSessionUpdateOutcome = .noChange
        for _ in 1 ... 9 {
            clock.advance(by: 15)
            outcome = engine.reportSustainedActivity(in: gateProjectB, at: clock.now)
        }
        XCTAssertEqual(outcome, .saved)

        XCTAssertEqual(engine.allSessions.count, 2)
        let aSession = try! XCTUnwrap(engine.allSessions.first { $0.project == gateProjectA })
        let bSession = try! XCTUnwrap(engine.allSessions.first { $0.project == gateProjectB })
        XCTAssertFalse(aSession.isOpen)
        XCTAssertEqual(aSession.endedAt, switchAt)
        XCTAssertEqual(aSession.activeDuration(now: clock.now), 0, accuracy: 0.001)
        XCTAssertTrue(bSession.isOpen)
        XCTAssertEqual(bSession.startedAt, switchAt)
        // The away interval (9 heartbeats × 15s) belongs to the arrival
        // project: the switch boundary is the away start, never double-counted.
        XCTAssertEqual(bSession.activeDuration(now: clock.now), 9 * 15, accuracy: 0.001)
    }
}
