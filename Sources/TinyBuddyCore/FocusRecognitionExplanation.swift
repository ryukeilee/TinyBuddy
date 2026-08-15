import Foundation

// MARK: - Recognition Posture

/// The live posture of automatic focus recognition, derived purely from the
/// confirmation gate's own state and the engine's current session. The
/// explainer never re-runs the recognition decision — this enum only classifies
/// state the engine already holds, so the gate stays the single authority.
public enum FocusRecognitionPosture: String, Equatable, Sendable {
    /// The confirmation gate is accumulating activity for a candidate project
    /// but has not yet confirmed it (recognizing).
    case recognizing
    /// An automatic session is open (active or paused).
    case confirmed
    /// A different project is accumulating activity while the current session
    /// waits for sustained activity to confirm the switch.
    case switched
    /// No candidate and no open session; explains why focus was not entered.
    case notEntered
}

// MARK: - Recognition Explanation

/// A short, readable explanation of the current automatic-focus recognition
/// posture. Pure presentation model: every field derives from the confirmation
/// gate's own live state and the engine's committed decision evidence.
///
/// It carries no repository path, commit content, remote URL, or raw input —
/// only the presentation-safe display names and the evidence engine's already
/// redacted explanation text.
public struct FocusRecognitionExplanation: Equatable, Sendable {
    /// The live posture of automatic focus recognition.
    public let posture: FocusRecognitionPosture
    /// Short headline, e.g. “正在识别”.
    public let title: String
    /// One-sentence explanation of the current posture.
    public let detail: String
    /// The most recent key judgment from the decision evidence, if any.
    /// Reused verbatim from the evidence engine; never re-derived here.
    public let lastDecision: FocusSessionDecisionExplanation?

    public init(
        posture: FocusRecognitionPosture,
        title: String,
        detail: String,
        lastDecision: FocusSessionDecisionExplanation?
    ) {
        self.posture = posture
        self.title = title
        self.detail = detail
        self.lastDecision = lastDecision
    }
}

// MARK: - Explainer

/// Pure, deterministic builder that turns live gate state + session state +
/// decision evidence into a `FocusRecognitionExplanation`. Same inputs always
/// produce the same output.
///
/// The explainer classifies state the engine already holds; it never computes
/// whether the gate *would* confirm, so the confirmation gate remains the only
/// authority over automatic focus decisions.
public enum FocusRecognitionExplainer: Sendable {
    /// Complete set of live state needed to explain recognition. All fields
    /// come from the engine's existing read-only surface.
    public struct Context: Equatable, Sendable {
        /// The confirmation gate's own live state.
        public let gate: FocusSessionConfirmationGate
        /// The project context of the candidate currently accumulating in the
        /// gate, if the gate is tracking. Display-name only in output.
        public let confirmationCandidate: FocusProjectContext?
        /// The confirmation threshold, read for display only.
        public let minimumActiveDuration: TimeInterval
        /// The currently open session's project, if any.
        public let currentProject: FocusProjectContext?
        /// The currently open session's status, if any.
        public let currentSessionStatus: FocusSessionStatus?
        /// The currently open session's mode, if any.
        public let currentSessionMode: FocusMode?
        /// The candidate of an in-flight automatic project switch, if any.
        public let pendingSwitchCandidate: FocusProjectContext?
        /// The most recent committed decision explanation across all evidence.
        public let mostRecentDecision: FocusSessionDecisionExplanation?

        public init(
            gate: FocusSessionConfirmationGate,
            confirmationCandidate: FocusProjectContext?,
            minimumActiveDuration: TimeInterval,
            currentProject: FocusProjectContext?,
            currentSessionStatus: FocusSessionStatus?,
            currentSessionMode: FocusMode?,
            pendingSwitchCandidate: FocusProjectContext?,
            mostRecentDecision: FocusSessionDecisionExplanation?
        ) {
            self.gate = gate
            self.confirmationCandidate = confirmationCandidate
            self.minimumActiveDuration = minimumActiveDuration
            self.currentProject = currentProject
            self.currentSessionStatus = currentSessionStatus
            self.currentSessionMode = currentSessionMode
            self.pendingSwitchCandidate = pendingSwitchCandidate
            self.mostRecentDecision = mostRecentDecision
        }
    }

    /// Builds the explanation for the given live context. Always returns a
    /// value: every posture has a readable reason.
    public static func makeExplanation(for context: Context) -> FocusRecognitionExplanation {
        // Manual session: automatic recognition is suspended by design.
        if context.currentSessionMode == .manual, let project = context.currentProject {
            return FocusRecognitionExplanation(
                posture: .notEntered,
                title: "手动专注",
                detail: "手动专注「\(project.displayName)」进行中，自动识别已暂停",
                lastDecision: context.mostRecentDecision
            )
        }

        // Open session: confirmation already happened (active or paused).
        if let project = context.currentProject {
            // A pending switch candidate means the engine is waiting for
            // sustained activity to confirm a project switch.
            if let candidate = context.pendingSwitchCandidate, candidate != project {
                return FocusRecognitionExplanation(
                    posture: .switched,
                    title: "等待切换",
                    detail: "检测到「\(candidate.displayName)」的活动，持续活动将确认从「\(project.displayName)」切换",
                    lastDecision: context.mostRecentDecision
                )
            }
            let paused = context.currentSessionStatus == .paused
            return FocusRecognitionExplanation(
                posture: .confirmed,
                title: paused ? "专注已暂停" : "已确认专注",
                detail: paused
                    ? "已确认专注「\(project.displayName)」，当前暂停"
                    : "已确认专注「\(project.displayName)」，正在累计时间",
                lastDecision: context.mostRecentDecision
            )
        }

        // No session: the gate decides whether recognition is in progress.
        if context.gate.isTracking, let candidate = context.confirmationCandidate {
            let accumulated = max(0, Int(context.gate.accumulatedActiveTime))
            let required = max(0, Int(context.minimumActiveDuration))
            let remaining = max(0, required - accumulated)
            let progressText = required > 0
                ? "已累计 \(accumulated) 秒，还需 \(remaining) 秒"
                : "已累计 \(accumulated) 秒"
            return FocusRecognitionExplanation(
                posture: .recognizing,
                title: "正在识别",
                detail: "检测到「\(candidate.displayName)」的活动，\(progressText)，达到条件后确认专注",
                lastDecision: context.mostRecentDecision
            )
        }

        return FocusRecognitionExplanation(
            posture: .notEntered,
            title: "未进入专注",
            detail: "未检测到持续活动，暂不进入自动专注",
            lastDecision: context.mostRecentDecision
        )
    }
}
