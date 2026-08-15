import XCTest
@testable import TinyBuddyCore

// MARK: - Fakes

private final class RecognitionFakeClock: FocusClock, @unchecked Sendable {
    private var _now: Date
    var now: Date { _now }
    var monotonic: TimeInterval { _now.timeIntervalSinceReferenceDate }

    init(_ date: Date) {
        _now = date
    }

    func advance(by seconds: TimeInterval) {
        _now = _now.addingTimeInterval(seconds)
    }
}

private final class RecognitionMemoryStore: FocusSessionPersisting, @unchecked Sendable {
    var stored: [FocusSession]?
    var shouldFail = false

    func load() -> [FocusSession]? { stored }

    @discardableResult
    func save(_ sessions: [FocusSession]) -> Bool {
        guard !shouldFail else { return false }
        stored = sessions
        return true
    }
}

// MARK: - Shared fixtures

private let recT0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
private let recProjectA = FocusProjectContext(key: "repo/a", displayName: "Project A")
private let recProjectB = FocusProjectContext(key: "repo/b", displayName: "Project B")

private func recDayIdentifier(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func recMakeEngine(
    clock: RecognitionFakeClock,
    store: RecognitionMemoryStore,
    config: FocusSessionConfiguration = FocusSessionConfiguration(
        confirmationMinimumActiveDuration: 0
    )
) -> FocusSessionEngine {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return FocusSessionEngine(
        clock: clock,
        persisting: store,
        config: config,
        dayIdentifier: { recDayIdentifier(for: $0) },
        nextDayBoundary: { date in
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        }
    )
}

private func recDecision(
    at date: Date,
    kind: FocusSessionDecisionKind,
    reason: FocusSessionDecisionReason,
    source: FocusSessionDecisionSource = .automatic,
    explanation: String) -> FocusSessionDecisionExplanation {
    FocusSessionDecisionExplanation(
        at: date,
        kind: kind,
        reason: reason,
        source: source,
        confidence: .high,
        explanation: explanation
    )
}

// MARK: - Pure explainer tests

final class FocusRecognitionExplanationTests: XCTestCase {
    private func makeContext(
        gate: FocusSessionConfirmationGate = FocusSessionConfirmationGate(),
        confirmationCandidate: FocusProjectContext? = nil,
        minimumActiveDuration: TimeInterval = 120,
        currentProject: FocusProjectContext? = nil,
        currentSessionStatus: FocusSessionStatus? = nil,
        currentSessionMode: FocusMode? = nil,
        pendingSwitchCandidate: FocusProjectContext? = nil,
        mostRecentDecision: FocusSessionDecisionExplanation? = nil
    ) -> FocusRecognitionExplainer.Context {
        FocusRecognitionExplainer.Context(
            gate: gate,
            confirmationCandidate: confirmationCandidate,
            minimumActiveDuration: minimumActiveDuration,
            currentProject: currentProject,
            currentSessionStatus: currentSessionStatus,
            currentSessionMode: currentSessionMode,
            pendingSwitchCandidate: pendingSwitchCandidate,
            mostRecentDecision: mostRecentDecision
        )
    }

    /// The gate is accumulating activity for a candidate but has not yet
    /// confirmed: the explanation must say recognition is in progress and
    /// surface the gate's own accumulation, not a re-derived decision.
    func test_recognizing_when_gate_tracking_without_session() {
        var gate = FocusSessionConfirmationGate()
        XCTAssertFalse(gate.recordActivity(
            project: recProjectA,
            at: recT0,
            window: 300,
            minimumActiveDuration: 120
        ))

        let context = makeContext(
            gate: gate,
            confirmationCandidate: recProjectA,
            minimumActiveDuration: 120
        )
        let explanation = FocusRecognitionExplainer.makeExplanation(for: context)

        XCTAssertEqual(explanation.posture, .recognizing)
        XCTAssertEqual(explanation.title, "正在识别")
        XCTAssertTrue(explanation.detail.contains("Project A"))
        XCTAssertTrue(explanation.detail.contains("还需 120 秒"))
        XCTAssertNil(explanation.lastDecision)
    }

    /// Sustained activity reaches the minimum: the gate has confirmed, the
    /// engine session is open, and the explanation reflects the confirmation.
    func test_confirmed_when_session_open_and_active() {
        let context = makeContext(
            currentProject: recProjectA,
            currentSessionStatus: .active,
            currentSessionMode: .automatic,
            mostRecentDecision: recDecision(
                at: recT0,
                kind: .started,
                reason: .gitActivity,
                explanation: "检测到 Git 代码活动，开始专注会话"
            )
        )
        let explanation = FocusRecognitionExplainer.makeExplanation(for: context)

        XCTAssertEqual(explanation.posture, .confirmed)
        XCTAssertEqual(explanation.title, "已确认专注")
        XCTAssertTrue(explanation.detail.contains("Project A"))
        // The most recent key judgment is reused verbatim from the evidence.
        XCTAssertEqual(
            explanation.lastDecision?.explanation,
            "检测到 Git 代码活动，开始专注会话"
        )
    }

    /// A paused automatic session (no pending switch) is still confirmed
    /// focus — the pause is surfaced through the most recent decision.
    func test_confirmed_paused_without_pending_switch() {
        let context = makeContext(
            currentProject: recProjectA,
            currentSessionStatus: .paused,
            currentSessionMode: .automatic,
            mostRecentDecision: recDecision(
                at: recT0.addingTimeInterval(60),
                kind: .paused,
                reason: .idle,
                explanation: "用户停止活动超过阈值，自动暂停会话"
            )
        )
        let explanation = FocusRecognitionExplainer.makeExplanation(for: context)

        XCTAssertEqual(explanation.posture, .confirmed)
        XCTAssertEqual(explanation.title, "专注已暂停")
        XCTAssertTrue(explanation.detail.contains("Project A"))
        XCTAssertEqual(
            explanation.lastDecision?.reason,
            .idle
        )
    }

    /// A pending switch candidate while a session is open: the engine is
    /// waiting for sustained activity in the new project before switching.
    func test_switched_when_pending_candidate() {
        let context = makeContext(
            currentProject: recProjectA,
            currentSessionStatus: .paused,
            currentSessionMode: .automatic,
            pendingSwitchCandidate: recProjectB,
            mostRecentDecision: recDecision(
                at: recT0,
                kind: .paused,
                reason: .projectSwitch,
                explanation: "前段应用切换，等待确认新项目活动"
            )
        )
        let explanation = FocusRecognitionExplainer.makeExplanation(for: context)

        XCTAssertEqual(explanation.posture, .switched)
        XCTAssertEqual(explanation.title, "等待切换")
        XCTAssertTrue(explanation.detail.contains("Project B"))
        XCTAssertTrue(explanation.detail.contains("Project A"))
    }

    /// Nothing tracking and no session: the explanation explains why focus
    /// was not entered and reuses the last key judgment for context.
    func test_not_entered_when_nothing_tracking() {
        let context = makeContext(
            mostRecentDecision: recDecision(
                at: recT0,
                kind: .ended,
                reason: .idle,
                explanation: "空闲超时过长，自动结束会话"
            )
        )
        let explanation = FocusRecognitionExplainer.makeExplanation(for: context)

        XCTAssertEqual(explanation.posture, .notEntered)
        XCTAssertEqual(explanation.title, "未进入专注")
        XCTAssertEqual(
            explanation.lastDecision?.explanation,
            "空闲超时过长，自动结束会话"
        )
    }

    /// During a manual session, automatic recognition is suspended by design.
    func test_manual_session_suspends_automatic_recognition() {
        let context = makeContext(
            currentProject: recProjectA,
            currentSessionStatus: .active,
            currentSessionMode: .manual
        )
        let explanation = FocusRecognitionExplainer.makeExplanation(for: context)

        XCTAssertEqual(explanation.posture, .notEntered)
        XCTAssertEqual(explanation.title, "手动专注")
        XCTAssertTrue(explanation.detail.contains("自动识别已暂停"))
    }

    /// Same inputs always produce the same explanation (determinism).
    func test_deterministic_same_inputs_same_output() {
        var gate = FocusSessionConfirmationGate()
        _ = gate.recordActivity(
            project: recProjectA,
            at: recT0,
            window: 300,
            minimumActiveDuration: 120
        )
        let context = makeContext(
            gate: gate,
            confirmationCandidate: recProjectA,
            minimumActiveDuration: 120
        )
        let first = FocusRecognitionExplainer.makeExplanation(for: context)
        let second = FocusRecognitionExplainer.makeExplanation(for: context)
        XCTAssertEqual(first, second)
    }
}

// MARK: - Engine accessor integration tests

/// Drives the real engine through its public API and verifies the read-only
/// recognition state matches what the engine itself decided. The accessors
/// must mirror the engine's live state without duplicating any decision
/// logic in the presentation layer.
final class FocusRecognitionEngineStateTests: XCTestCase {
    func test_gate_snapshot_and_candidate_while_recognizing() {
        let clock = RecognitionFakeClock(recT0)
        let store = RecognitionMemoryStore()
        let config = FocusSessionConfiguration(
            confirmationWindow: 300,
            confirmationMinimumActiveDuration: 120
        )
        let engine = recMakeEngine(clock: clock, store: store, config: config)

        // Single event: gate starts tracking, nothing confirmed.
        XCTAssertEqual(engine.userActivity(in: recProjectA, at: recT0), .noChange)
        XCTAssertTrue(engine.confirmationGateSnapshot.isTracking)
        XCTAssertEqual(engine.confirmationGateSnapshot.trackedProjectKey, recProjectA.key)
        XCTAssertEqual(engine.confirmationCandidateProject, recProjectA)
        XCTAssertNil(engine.currentProject)
        XCTAssertNil(engine.currentSessionMode)

        // Accumulate inside the window but below the minimum.
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: recProjectA, at: clock.now), .noChange)
        XCTAssertEqual(engine.confirmationGateSnapshot.accumulatedActiveTime, 60, accuracy: 0.001)

        // Enough sustained activity: confirmed, session opens, gate resets.
        clock.advance(by: 60)
        XCTAssertEqual(engine.userActivity(in: recProjectA, at: clock.now), .saved)
        XCTAssertFalse(engine.confirmationGateSnapshot.isTracking)
        XCTAssertEqual(engine.currentProject, recProjectA)
        XCTAssertEqual(engine.currentSessionMode, .automatic)
        XCTAssertEqual(engine.currentSessionStatus, .active)
        XCTAssertEqual(engine.confirmationMinimumActiveDuration, 120)
    }

    func test_pending_switch_candidate_after_foreground_change() {
        let clock = RecognitionFakeClock(recT0)
        let store = RecognitionMemoryStore()
        let config = FocusSessionConfiguration(
            confirmationWindow: 300,
            confirmationMinimumActiveDuration: 0
        )
        let engine = recMakeEngine(clock: clock, store: store, config: config)

        // Project A starts immediately (gate disabled via zero minimum).
        XCTAssertEqual(engine.userActivity(in: recProjectA, at: recT0), .saved)
        clock.advance(by: 10)

        // Foreground change to B pauses A and registers a pending switch.
        XCTAssertEqual(engine.foregroundProjectChanged(to: recProjectB, at: clock.now), .saved)
        XCTAssertEqual(engine.pendingSwitchCandidateProject, recProjectB)
        XCTAssertEqual(engine.currentSessionStatus, .paused)
        XCTAssertEqual(engine.currentProject, recProjectA)
    }

    func test_most_recent_decision_from_evidence() {
        let clock = RecognitionFakeClock(recT0)
        let store = RecognitionMemoryStore()
        let config = FocusSessionConfiguration(
            confirmationWindow: 300,
            confirmationMinimumActiveDuration: 0
        )
        let engine = recMakeEngine(clock: clock, store: store, config: config)

        XCTAssertEqual(engine.userActivity(in: recProjectA, at: recT0), .saved)
        clock.advance(by: 30)
        XCTAssertEqual(engine.idleDetected(at: clock.now), .saved)

        // The newest decision in the evidence trail is the idle pause.
        let latest = engine.mostRecentDecisionExplanation
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.kind, .paused)
        XCTAssertEqual(latest?.reason, .idle)
        XCTAssertEqual(latest?.explanation, "用户停止活动超过阈值，自动暂停会话")
    }

    /// The explainer fed by the engine's own accessors must agree with the
    /// engine's live posture at each stage of the recognition lifecycle.
    func test_explainer_agrees_with_engine_lifecycle() {
        let clock = RecognitionFakeClock(recT0)
        let store = RecognitionMemoryStore()
        let config = FocusSessionConfiguration(
            confirmationWindow: 300,
            confirmationMinimumActiveDuration: 120
        )
        let engine = recMakeEngine(clock: clock, store: store, config: config)

        func explain() -> FocusRecognitionExplanation {
            FocusRecognitionExplainer.makeExplanation(for: FocusRecognitionExplainer.Context(
                gate: engine.confirmationGateSnapshot,
                confirmationCandidate: engine.confirmationCandidateProject,
                minimumActiveDuration: engine.confirmationMinimumActiveDuration,
                currentProject: engine.currentProject,
                currentSessionStatus: engine.currentSessionStatus,
                currentSessionMode: engine.currentSessionMode,
                pendingSwitchCandidate: engine.pendingSwitchCandidateProject,
                mostRecentDecision: engine.mostRecentDecisionExplanation
            ))
        }

        // Stage 1: recognizing.
        XCTAssertEqual(engine.userActivity(in: recProjectA, at: recT0), .noChange)
        XCTAssertEqual(explain().posture, .recognizing)

        // Stage 2: confirmed.
        clock.advance(by: 120)
        XCTAssertEqual(engine.userActivity(in: recProjectA, at: clock.now), .saved)
        XCTAssertEqual(explain().posture, .confirmed)
        XCTAssertEqual(explain().title, "已确认专注")

        // Stage 3: switched (pending candidate).
        clock.advance(by: 10)
        XCTAssertEqual(engine.foregroundProjectChanged(to: recProjectB, at: clock.now), .saved)
        XCTAssertEqual(explain().posture, .switched)

        // Stage 4: prolonged idle ends the paused session; nothing tracking.
        // 700s exceeds the default longAbsenceThreshold (600s).
        clock.advance(by: 700)
        XCTAssertEqual(engine.idleDetected(at: clock.now), .saved)
        XCTAssertNil(engine.currentProject)
        XCTAssertFalse(engine.confirmationGateSnapshot.isTracking)
        XCTAssertEqual(explain().posture, .notEntered)
        XCTAssertEqual(explain().lastDecision?.reason, .idle)
    }
}
