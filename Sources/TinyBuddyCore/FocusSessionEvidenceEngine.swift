import Foundation

// MARK: - Evidence Input

/// Deterministic input to the evidence engine. This is the complete set of
/// information used to produce attribution evidence for a single session.
/// Same inputs always produce the same evidence.
public struct FocusSessionEvidenceInput: Equatable, Sendable {
    /// The session to generate evidence for.
    public let session: FocusSession
    /// Whether the project was attributed via foreground app.
    public let attributedViaForegroundApp: Bool
    /// Whether the project was attributed via Git activity.
    public let attributedViaGitActivity: Bool
    /// The bundle ID of the foreground app at the time (redacted to stable ID).
    public let redactedForegroundAppID: String?
    /// The stable repo identifier if Git-attributed.
    public let redactedRepoIdentifier: String?

    public init(
        session: FocusSession,
        attributedViaForegroundApp: Bool,
        attributedViaGitActivity: Bool,
        redactedForegroundAppID: String? = nil,
        redactedRepoIdentifier: String? = nil
    ) {
        self.session = session
        self.attributedViaForegroundApp = attributedViaForegroundApp
        self.attributedViaGitActivity = attributedViaGitActivity
        self.redactedForegroundAppID = redactedForegroundAppID
        self.redactedRepoIdentifier = redactedRepoIdentifier
    }
}

// MARK: - Evidence Engine

/// Stateless, deterministic evidence engine. Produces `FocusSessionEvidence`
/// from `FocusSessionEvidenceInput`. Same inputs always produce the same
/// output; no randomness, no system state, no mutable caches.
///
/// The engine operates purely on the decision events already recorded in the
/// session. It does NOT re-run attribution logic — it explains what happened.
public enum FocusSessionEvidenceEngine: Sendable {
    /// Generates evidence for a single session.
    /// - Parameter input: Deterministic input describing the session and context.
    /// - Returns: `FocusSessionEvidence` or `nil` if the session has no
    ///   decision events (legacy record).
    public static func generateEvidence(for input: FocusSessionEvidenceInput) -> FocusSessionEvidence? {
        let session = input.session
        guard let events = session.decisionEvents, !events.isEmpty else {
            // Legacy session with no decision trail. Return nil so the caller
            // can fall back to a generic "historical" explanation.
            return nil
        }

        // Determine attribution source and confidence.
        let attributionSource: FocusSessionAttributionSource
        let confidence: FocusSessionEvidenceConfidence
        var caveat: String?

        if session.mode == .manual {
            // Manual session — the user explicitly chose this project.
            attributionSource = .manual
            confidence = .high
        } else if session.decisionAuthority == .manualCorrection {
            attributionSource = .manual
            confidence = .high
        } else if session.decisionAuthority == .userConfirmed {
            // User confirmed attribution — treat as high confidence.
            if input.attributedViaForegroundApp || input.attributedViaGitActivity {
                attributionSource = input.attributedViaGitActivity ? .gitActivity : .foregroundApp
            } else {
                attributionSource = .foregroundApp
            }
            confidence = .high
        } else if input.attributedViaGitActivity {
            attributionSource = .gitActivity
            // Git attribution without explicit confirmation is high confidence
            // because it directly ties to a known project.
            confidence = .high
        } else if input.attributedViaForegroundApp {
            attributionSource = .foregroundApp
            // Foreground app attribution depends on known editor mappings.
            // It's high confidence when the app is a known code editor.
            confidence = .high
        } else {
            // Cannot determine attribution source — mark as pending.
            attributionSource = .unknown
            confidence = .pending
            caveat = "无法确定项目归属来源（缺少前段应用和 Git 活动信息）"
        }

        // Determine the redacted identifier to surface.
        let effectiveRedactedID = input.redactedRepoIdentifier
            ?? input.redactedForegroundAppID
            ?? stableIdentifier(from: session.project.key)

        // Build project attribution.
        let projectExplanation = buildProjectExplanation(
            project: session.project,
            source: attributionSource,
            confidence: confidence,
            mode: session.mode,
            authority: session.decisionAuthority,
            caveat: caveat
        )

        let projectAttribution = FocusSessionProjectAttribution(
            displayName: session.project.displayName,
            source: attributionSource,
            confidence: confidence,
            redactedIdentifier: effectiveRedactedID,
            explanation: projectExplanation,
            caveat: caveat
        )

        // Build decision explanations.
        let decisionExplanations = buildDecisionExplanations(from: events)

        return FocusSessionEvidence(
            sessionID: session.id,
            createdAt: session.lastStateChangeAt,
            ruleVersion: .current,
            confidence: confidence,
            projectAttribution: projectAttribution,
            decisionExplanations: decisionExplanations
        )
    }

    /// Generates evidence for a group of sessions (used during archive loading).
    /// Sessions without decision events are skipped.
    public static func generateEvidenceBatch(
        for inputs: [FocusSessionEvidenceInput]
    ) -> [UUID: FocusSessionEvidence] {
        var result: [UUID: FocusSessionEvidence] = [:]
        for input in inputs {
            guard let evidence = generateEvidence(for: input) else { continue }
            result[evidence.sessionID] = evidence
        }
        return result
    }

    /// Updates evidence after an edit, merge, split, or undo.
    /// Preserves manual correction authority and adjusts confidence.
    public static func updateEvidence(
        for session: FocusSession,
        previousEvidence: FocusSessionEvidence?,
        isManualEdit: Bool
    ) -> FocusSessionEvidence? {
        guard let events = session.decisionEvents, !events.isEmpty else { return nil }

        // Preserve existing evidence fields where possible.
        let baseConfidence: FocusSessionEvidenceConfidence
        let baseSource: FocusSessionAttributionSource
        let baseExplanation: String
        var caveat: String?

        if isManualEdit || session.decisionAuthority == .manualCorrection {
            baseConfidence = .high
            baseSource = .manual
            baseExplanation = "用户手动修正，覆盖自动识别结果"
        } else if let prev = previousEvidence {
            baseConfidence = prev.confidence
            baseSource = prev.projectAttribution.source
            baseExplanation = prev.projectAttribution.explanation
            caveat = prev.projectAttribution.caveat
        } else {
            // Fresh evidence generation — derive from session properties
            // instead of hardcoding a default attribution source.
            let derivedAttributedViaGit = deriveAttributedViaGitActivity(from: session)
            let redactedID = stableIdentifier(from: session.project.key)
            let input = FocusSessionEvidenceInput(
                session: session,
                attributedViaForegroundApp: !derivedAttributedViaGit,
                attributedViaGitActivity: derivedAttributedViaGit,
                redactedForegroundAppID: derivedAttributedViaGit ? nil : redactedID,
                redactedRepoIdentifier: derivedAttributedViaGit ? redactedID : nil
            )
            if let fresh = generateEvidence(for: input) {
                return fresh
            }
            return nil
        }

        let effectiveRedactedID = previousEvidence?.projectAttribution.redactedIdentifier
            ?? stableIdentifier(from: session.project.key)

        let decisionExplanations = buildDecisionExplanations(from: events)

        return FocusSessionEvidence(
            sessionID: session.id,
            createdAt: Date(),
            ruleVersion: .current,
            confidence: baseConfidence,
            projectAttribution: FocusSessionProjectAttribution(
                displayName: session.project.displayName,
                source: baseSource,
                confidence: baseConfidence,
                redactedIdentifier: effectiveRedactedID,
                explanation: baseExplanation,
                caveat: caveat
            ),
            decisionExplanations: decisionExplanations
        )
    }

    // MARK: - Private Helpers

    /// Deterministic project explanation based on available evidence.
    private static func buildProjectExplanation(
        project: FocusProjectContext,
        source: FocusSessionAttributionSource,
        confidence: FocusSessionEvidenceConfidence,
        mode: FocusMode,
        authority: FocusSessionDecisionSource?,
        caveat: String?
    ) -> String {
        switch (source, mode, authority) {
        case (.manual, _, _):
            return "用户明确选择了项目“\(project.displayName)”"
        case (_, _, .manualCorrection?):
            return "用户手动修正为项目“\(project.displayName)”"
        case (_, _, .userConfirmed?):
            return "用户确认归属于项目“\(project.displayName)”"
        case (.gitActivity, .automatic, _):
            return "检测到 Git 活动，归属到项目“\(project.displayName)”"
        case (.foregroundApp, .automatic, _):
            return "前段应用关联到项目“\(project.displayName)”"
        case (.unknown, .automatic, _):
            return "默认关联到项目“\(project.displayName)”"
        default:
            return "归属到项目“\(project.displayName)”"
        }
    }

    /// Build deterministic explanations for each decision event.
    private static func buildDecisionExplanations(
        from events: [FocusSessionDecisionEvent]
    ) -> [FocusSessionDecisionExplanation] {
        events.sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id.uuidString < rhs.id.uuidString
        }.map { event in
            FocusSessionDecisionExplanation(
                id: event.id,
                at: event.at,
                kind: event.kind,
                reason: event.reason,
                source: event.source,
                confidence: confidenceFor(event: event),
                explanation: explanationFor(event: event)
            )
        }
    }

    /// Derives whether a session was attributed via Git activity.
    /// Uses the same logic as `FocusSessionEngine.deriveAttributedViaGitActivity`.
    private static func deriveAttributedViaGitActivity(from session: FocusSession) -> Bool {
        // Manual sessions are always user-chosen, never Git-attributed.
        if session.mode == .manual { return false }
        // Explicit Git activity in the decision trail.
        if let events = session.decisionEvents,
           events.contains(where: { $0.reason == .gitActivity }) {
            return true
        }
        // Infer from project key pattern: repo paths contain "/".
        if session.project.key.contains("/") { return true }
        return false
    }

    /// Deterministic confidence for a single decision event.
    private static func confidenceFor(event: FocusSessionDecisionEvent) -> FocusSessionEvidenceConfidence {
        switch event.source {
        case .manualCorrection:
            return .high
        case .userConfirmed:
            return .high
        case .automatic:
            // Automatic decisions are high confidence when the reason is clear.
            switch event.reason {
            case .userActivity, .gitActivity, .lockScreen,
                 .systemSleep, .dayBoundary, .appTermination, .crashRecovery:
                return .high
            case .idle:
                return .high
            case .projectSwitch:
                return .high
            case .manualConfirmation, .manualCorrection, .manualSplit, .manualMerge, .undo:
                return .high
            }
        }
    }

    /// Deterministic explanation text for a decision event.
    /// Never contains raw input, paths, commit content, or remote URLs.
    private static func explanationFor(event: FocusSessionDecisionEvent) -> String {
        let sourceTag: String
        switch event.source {
        case .automatic: sourceTag = "自动"
        case .userConfirmed: sourceTag = "用户确认"
        case .manualCorrection: sourceTag = "手动修正"
        }

        switch (event.kind, event.reason) {
        case (.started, .userActivity):
            return "自动检测到用户活动，开始专注会话"
        case (.started, .gitActivity):
            return "检测到 Git 代码活动，开始专注会话"
        case (.started, .manualSplit):
            return "手动拆分会话，开始新分段"
        case (.started, .manualCorrection):
            return "手动修正创建了新会话分段"
        case (.paused, .idle):
            return "用户停止活动超过阈值，自动暂停会话"
        case (.paused, .lockScreen):
            return "屏幕锁定，自动暂停会话"
        case (.paused, .projectSwitch):
            return "前段应用切换，等待确认新项目活动"
        case (.paused, .systemSleep):
            return "系统休眠，自动暂停会话"
        case (.resumed, .userActivity):
            return "检测到用户活动，恢复专注会话"
        case (.resumed, .gitActivity):
            return "检测到 Git 活动，恢复专注会话"
        case (.ended, .idle):
            return "空闲超时过长，自动结束会话"
        case (.ended, .lockScreen):
            return "屏幕锁定，自动结束会话"
        case (.ended, .systemSleep):
            return "系统休眠，自动结束会话"
        case (.ended, .projectSwitch):
            return "切换到其他项目，结束当前会话"
        case (.ended, .dayBoundary):
            return "本地日期变更，自动结束会话"
        case (.ended, .appTermination):
            return "应用退出，自动结束会话"
        case (.ended, .crashRecovery):
            return "异常退出后安全收尾，自动结束会话"
        case (.ended, .manualCorrection):
            return "手动修正导致会话结束"
        case (.ended, .manualSplit):
            return "手动拆分导致本分段结束"
        case (.projectChanged, .manualCorrection):
            return "用户手动变更项目归属"
        case (.confirmed, .manualConfirmation):
            return "用户确认该记录归属正确"
        case (.corrected, .manualCorrection):
            return "用户手动修正记录时间"
        case (.split, .manualSplit):
            return "用户手动拆分会话"
        case (.merged, .manualMerge):
            return "用户手动合并多个会话"
        case (.undo, .undo):
            return "用户撤销上次编辑操作"
        default:
            return "\(sourceTag)触发：\(reasonLabel(event.reason))"
        }
    }

    private static func reasonLabel(_ reason: FocusSessionDecisionReason) -> String {
        switch reason {
        case .userActivity: return "用户活动"
        case .gitActivity: return "Git 活动"
        case .idle: return "空闲"
        case .lockScreen: return "锁屏"
        case .systemSleep: return "系统休眠"
        case .projectSwitch: return "项目切换"
        case .dayBoundary: return "日期变更"
        case .appTermination: return "应用退出"
        case .crashRecovery: return "崩溃恢复"
        case .manualConfirmation: return "用户确认"
        case .manualCorrection: return "手动修正"
        case .manualSplit: return "手动拆分"
        case .manualMerge: return "手动合并"
        case .undo: return "撤销"
        }
    }
}

// MARK: - Stable Identifier Utility

/// Derives a stable, redacted identifier from a project key.
/// If the key looks like a bundle ID, returns it as-is (bundle IDs are not sensitive).
/// If it looks like a path, computes an irreversible SHA-256 prefix.
/// Never returns the raw path.
func stableIdentifier(from projectKey: String) -> String {
    // Bundle IDs contain dots but no slashes — they're safe to surface.
    if projectKey.contains(".") && !projectKey.contains("/") {
        return projectKey
    }
    // Path-like: compute stable hash.
    return TinyBuddyStableRepoIdentifier(path: projectKey).value
}
