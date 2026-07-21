import Foundation
import OSLog

// MARK: - Upgrade Phase

/// The current phase of a rule upgrade lifecycle.
public enum FocusSessionUpgradePhase: Equatable, Sendable {
    /// No upgrade in progress.
    case idle
    /// The upgrade coordinator has paused the engine; a snapshot is available.
    case paused(oldRuleSet: FocusSessionRuleSet)
    /// A preview has been computed and is ready for user review.
    case previewReady(preview: FocusSessionRecalculationPreview)
    /// The upgrade is being applied.
    case upgrading
    /// The upgrade completed successfully.
    case completed(newRuleSet: FocusSessionRuleSet)
    /// The upgrade was rolled back.
    case rolledBack(previousRuleSet: FocusSessionRuleSet)
    /// The upgrade failed with a reason.
    case failed(reason: String)
}

// MARK: - Upgrade Coordinator

/// Orchestrates the full lifecycle of a rule upgrade:
///   1. Pause the session engine.
///   2. Snapshot current state and save recovery metadata.
///   3. Generate a read-only preview.
///   4. Apply the new rules (with caller confirmation).
///   5. Atomic commit or complete rollback.
///
/// The coordinator is designed to be used from `@MainActor` and coordinates
/// with the `FocusSessionEngine` to ensure no concurrent writes during upgrade.
public final class FocusSessionUpgradeCoordinator: @unchecked Sendable {
    private let registry: FocusSessionRuleRegistry
    private let store: FocusSessionPersisting
    private let clock: FocusClock
    private let logger = Logger(subsystem: "local.tinybuddy", category: "FocusSessionUpgradeCoordinator")

    /// Callback invoked when the phase changes. Set by the app bridge.
    public var onPhaseChange: (@Sendable (FocusSessionUpgradePhase) -> Void)?

    /// Callback to pause/resume the session engine's auto-detection.
    /// Set by the app bridge. When set to `true`, the engine stops processing
    /// automatic events; when `false`, normal processing resumes.
    public var setEnginePaused: (@Sendable (Bool) -> Void)?

    /// Callback to apply a new set of sessions atomically.
    /// Returns true on success. Set by the app bridge.
    public var applySessionsAtomically: (@Sendable ([FocusSession], Int64) -> Bool)?

    /// Provides the current sessions and archive revision. Set by the app bridge.
    public var currentSessionProvider: (@Sendable () -> (sessions: [FocusSession], revision: Int64))?

    private let lock = NSLock()
    private var phase: FocusSessionUpgradePhase = .idle

    public init(
        registry: FocusSessionRuleRegistry = FocusSessionRuleRegistry(),
        store: FocusSessionPersisting,
        clock: FocusClock
    ) {
        self.registry = registry
        self.store = store
        self.clock = clock
    }

    /// The current phase of the upgrade lifecycle.
    public var currentPhase: FocusSessionUpgradePhase {
        lock.lock(); defer { lock.unlock() }
        return phase
    }

    // MARK: - Upgrade Lifecycle

    /// Begins the upgrade process. Pauses the engine, snapshots state, and
    /// computes a preview.
    ///
    /// - Parameters:
    ///   - newRuleSet: The new rule set to evaluate.
    ///   - scope: The date range to recalculate.
    /// - Returns: The preview, or nil if preparation failed.
    public func beginUpgrade(
        newRuleSet: FocusSessionRuleSet,
        scope: FocusSessionRecalculationScope
    ) -> FocusSessionRecalculationPreview? {
        lock.lock()
        guard case .idle = phase else {
            lock.unlock()
            logger.debug("Upgrade already in progress (phase=\(String(describing: self.phase)))")
            return nil
        }

        let oldRuleSet = registry.currentRuleSet

        // Pause the engine.
        phase = .paused(oldRuleSet: oldRuleSet)
        lock.unlock()
        notifyPhaseChange()

        setEnginePaused?(true)

        lock.lock()
        defer { lock.unlock() }

        guard let provider = currentSessionProvider else {
            phase = .failed(reason: "currentSessionProvider not configured")
            notifyPhaseChange()
            return nil
        }

        let (sessions, revision) = provider()

        // Generate the preview.
        let preview = FocusSessionRecalculationEngine.generatePreview(
            scope: scope,
            allSessions: sessions,
            newRuleSet: newRuleSet,
            oldRuleSet: oldRuleSet
        )

        // Save upgrade recovery state.
        let recoveryState = FocusSessionRuleRegistry.UpgradeRecoveryState(
            newRuleSet: newRuleSet,
            oldRuleSet: oldRuleSet,
            dayStart: scope.dayStart,
            dayEnd: scope.dayEnd,
            archiveRevision: revision
        )

        if !registry.saveUpgradeState(recoveryState) {
            phase = .failed(reason: "Failed to persist upgrade recovery state")
            notifyPhaseChange()
            return nil
        }

        phase = .previewReady(preview: preview)
        notifyPhaseChange()

        return preview
    }

    /// Confirms and applies the upgrade. Must be called after the user has
    /// reviewed the preview and decided to proceed.
    ///
    /// - Returns: The result of the upgrade, or nil if confirmation fails.
    public func confirmUpgrade() -> FocusSessionRecalculationResult? {
        lock.lock()
        guard case .previewReady(let preview) = phase else {
            lock.unlock()
            logger.debug("confirmUpgrade called but phase is \(String(describing: self.phase))")
            return nil
        }
        phase = .upgrading
        lock.unlock()
        notifyPhaseChange()

        // Execute the recalculation.
        guard let provider = currentSessionProvider else {
            failUpgrade(reason: "currentSessionProvider not configured")
            return nil
        }

        let (allSessions, _) = provider()
        let scope = preview.scope

        let result = FocusSessionRecalculationEngine.recalculate(
            scope: scope,
            allSessions: allSessions,
            newRuleSet: preview.newRuleSet,
            oldRuleSet: preview.oldRuleSet
        )

        guard result.didComplete else {
            failUpgrade(reason: "Recalculation failed")
            return nil
        }

        // Atomically apply the new sessions.
        guard let apply = applySessionsAtomically else {
            failUpgrade(reason: "applySessionsAtomically not configured")
            return nil
        }

        // Use the old archive revision + 1 for the new archive.
        let recovery = registry.loadUpgradeState()
        let newRevision = (recovery?.archiveRevision ?? 0) + 1

        guard apply(result.allSessions, newRevision) else {
            failUpgrade(reason: "Atomic session apply failed")
            return nil
        }

        // Register the new rule set.
        guard registry.registerNewRuleSet(preview.newRuleSet) else {
            // Session data is already committed, but rule registry failed.
            // This is a partial failure; the upgrade state will trigger
            // reconciliation on next launch.
            logger.error("Rule set registration failed after session apply")
            lock.lock()
            phase = .failed(reason: "Rule set registration failed")
            lock.unlock()
            notifyPhaseChange()
            return result
        }

        // Clear upgrade state.
        registry.clearUpgradeState()

        lock.lock()
        phase = .completed(newRuleSet: preview.newRuleSet)
        lock.unlock()
        notifyPhaseChange()

        // Resume the engine.
        setEnginePaused?(false)

        return result
    }

    /// Rolls back the upgrade. Restores the previous rule set and clears
    /// the upgrade state. Session data is not automatically reverted;
    /// the caller is responsible for restoring from backup.
    public func rollbackUpgrade() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard case .previewReady(let preview) = phase else {
            logger.debug("rollbackUpgrade called but phase is \(String(describing: self.phase))")
            return false
        }

        // Clear upgrade state.
        registry.clearUpgradeState()

        // Restore the old rule set as current.
        if !registry.rollbackToPrevious() {
            // Even if rollback fails in registry, the old rule set is still
            // available from the preview.
        }

        phase = .rolledBack(previousRuleSet: preview.oldRuleSet)
        notifyPhaseChange()

        // Resume the engine.
        setEnginePaused?(false)

        return true
    }

    /// Cancels the upgrade without applying changes. Resumes the engine.
    public func cancelUpgrade() {
        lock.lock()
        defer { lock.unlock() }

        registry.clearUpgradeState()
        phase = .idle
        notifyPhaseChange()
        setEnginePaused?(false)
    }

    /// Detects an incomplete upgrade at startup (based on persisted recovery
    /// state) and returns the recovery state so the caller can decide whether
    /// to roll forward or roll back.
    public func detectIncompleteUpgrade() -> FocusSessionRuleRegistry.UpgradeRecoveryState? {
        registry.loadUpgradeState()
    }

    /// Cleans up after detecting an incomplete upgrade at startup.
    /// Returns true if the upgrade should be rolled forward (re-applied),
    /// or false if it should be rolled back.
    public func resolveIncompleteUpgrade(rollForward: Bool) -> Bool {
        guard let state = registry.loadUpgradeState() else {
            return false
        }

        if rollForward {
            // Re-register the new rule set.
            guard registry.registerNewRuleSet(state.newRuleSet) else {
                return false
            }
        } else {
            // Roll back the registry.
            registry.rollbackToPrevious()
        }

        registry.clearUpgradeState()
        return true
    }

    // MARK: - Private

    private func failUpgrade(reason: String) {
        lock.lock()
        phase = .failed(reason: reason)
        lock.unlock()
        notifyPhaseChange()
        setEnginePaused?(false)
    }

    private func notifyPhaseChange() {
        lock.lock()
        let currentPhase = phase
        lock.unlock()
        onPhaseChange?(currentPhase)
    }
}

// MARK: - Event Log Replay Engine

/// Replays a sequence of raw input events through a rule set to produce
/// sessions deterministically. This is the pure "replay" counterpart to
/// the live `FocusSessionEngine`.
public enum FocusSessionEventLogReplayEngine: Sendable {

    /// Replays the given event log through the given rule set, producing
    /// a deterministic set of sessions.
    ///
    /// - Parameters:
    ///   - log: The ordered event log to replay.
    ///   - ruleSet: The rule set to apply.
    ///   - dayProvider: Maps dates to day identifiers.
    /// - Returns: The sessions produced by replaying events through the rules.
    public static func replay(
        log: FocusSessionEventLog,
        ruleSet: FocusSessionRuleSet,
        dayProvider: (Date) -> String
    ) -> [FocusSession] {
        let config = ruleSet.configuration
        let sorted = log.entries.sorted { $0.at < $1.at || ($0.at == $1.at && $0.id.uuidString < $1.id.uuidString) }
        var sessions: [FocusSession] = []
        var currentDay: String = ""
        var pendingSwitch: (fromSessionId: UUID, awayStartedAt: Date, candidate: FocusProjectContext)?

        for entry in sorted {
            let day = dayProvider(entry.at)

            // Handle day boundary changes.
            if entry.kind == .timeChanged, let newDay = entry.dayIdentifier {
                if newDay != currentDay {
                    // End any open session.
                    if let idx = sessions.firstIndex(where: \.isOpen) {
                        endSession(at: idx, endedAt: sessions[idx].lastStateChangeAt, reason: .dayBoundary, into: &sessions)
                    }
                    pendingSwitch = nil
                    currentDay = newDay
                }
                continue
            }

            // Initialize currentDay if empty.
            if currentDay.isEmpty {
                currentDay = day
            }

            // If we're in a new day from a previous event, handle day boundary.
            if day != currentDay {
                if let idx = sessions.firstIndex(where: \.isOpen) {
                    endSession(at: idx, endedAt: sessions[idx].lastStateChangeAt, reason: .dayBoundary, into: &sessions)
                }
                pendingSwitch = nil
                currentDay = day
            }

            switch entry.kind {
            case .userActivity:
                guard let key = entry.projectKey,
                      let displayName = entry.projectDisplayName else {
                    // Generic activity: only resume a paused session.
                    if let idx = sessions.firstIndex(where: { $0.isOpen && $0.status == .paused }) {
                        resumeSession(at: idx, at: entry.at, reason: .userActivity, into: &sessions)
                        sessions[idx].lastUserActivityAt = entry.at
                    }
                    continue
                }
                let project = FocusProjectContext(key: key, displayName: displayName)
                handleUserActivity(
                    project: project,
                    at: entry.at,
                    config: config,
                    day: day,
                    sessions: &sessions,
                    pendingSwitch: &pendingSwitch,
                    ruleVersion: ruleSet.version
                )

            case .foregroundProjectChanged:
                guard let key = entry.projectKey,
                      let displayName = entry.projectDisplayName else { continue }
                let project = FocusProjectContext(key: key, displayName: displayName)
                handleForegroundChange(
                    project: project,
                    at: entry.at,
                    config: config,
                    sessions: &sessions,
                    pendingSwitch: &pendingSwitch
                )

            case .idleDetected:
                if let idx = sessions.firstIndex(where: \.isOpen),
                   sessions[idx].currentPauseStartedAt == nil {
                    pauseSession(at: idx, at: entry.at, reason: .idle, into: &sessions)
                }

            case .lockScreen:
                if let idx = sessions.firstIndex(where: \.isOpen) {
                    if sessions[idx].currentPauseStartedAt == nil {
                        pauseSession(at: idx, at: entry.at, reason: .lockScreen, into: &sessions)
                    }
                }
                pendingSwitch = nil

            case .unlock:
                pendingSwitch = nil

            case .systemSleep:
                if let idx = sessions.firstIndex(where: \.isOpen) {
                    endSession(at: idx, endedAt: entry.at, reason: .systemSleep, into: &sessions)
                }
                pendingSwitch = nil

            case .systemWake:
                pendingSwitch = nil

            case .appWillTerminate, .crash:
                if let idx = sessions.firstIndex(where: \.isOpen) {
                    let reason: FocusSessionDecisionReason = entry.kind == .appWillTerminate ? .appTermination : .crashRecovery
                    endSession(at: idx, endedAt: entry.at, reason: reason, into: &sessions)
                }
                pendingSwitch = nil

            case .timeChanged:
                break // handled above
            }
        }

        return sessions
    }

    // MARK: - Private Helpers (mirrors FocusSessionEngine logic)

    private static func handleUserActivity(
        project: FocusProjectContext,
        at when: Date,
        config: FocusSessionConfiguration,
        day: String,
        sessions: inout [FocusSession],
        pendingSwitch: inout (fromSessionId: UUID, awayStartedAt: Date, candidate: FocusProjectContext)?,
        ruleVersion: FocusSessionRuleVersion
    ) {
        if let idx = sessions.firstIndex(where: \.isOpen) {
            let cur = sessions[idx]
            if cur.project == project {
                resumeSession(at: idx, at: when, reason: .userActivity, into: &sessions)
                sessions[idx].lastUserActivityAt = when
                sessions[idx].lastStateChangeAt = when
                pendingSwitch = nil
            } else {
                // Different project activity.
                let startAt: Date
                if let pending = pendingSwitch {
                    startAt = pending.awayStartedAt
                    pendingSwitch = nil
                } else {
                    startAt = when
                }
                endSession(at: idx, endedAt: startAt, reason: .projectSwitch, into: &sessions)
                startNewSession(project: project, at: startAt, day: day, reason: .userActivity, sessions: &sessions, ruleVersion: ruleVersion)
            }
        } else {
            startNewSession(project: project, at: when, day: day, reason: .userActivity, sessions: &sessions, ruleVersion: ruleVersion)
        }
    }

    private static func handleForegroundChange(
        project: FocusProjectContext,
        at when: Date,
        config: FocusSessionConfiguration,
        sessions: inout [FocusSession],
        pendingSwitch: inout (fromSessionId: UUID, awayStartedAt: Date, candidate: FocusProjectContext)?
    ) {
        guard let idx = sessions.firstIndex(where: \.isOpen) else {
            // No open session; foreground change alone does not start one.
            return
        }
        let cur = sessions[idx]
        guard cur.project != project else { return }

        pendingSwitch = (fromSessionId: cur.id, awayStartedAt: when, candidate: project)
        pauseSession(at: idx, at: when, reason: .projectSwitch, into: &sessions)
    }

    private static func startNewSession(
        project: FocusProjectContext,
        at when: Date,
        day: String,
        reason: FocusSessionDecisionReason,
        sessions: inout [FocusSession],
        ruleVersion: FocusSessionRuleVersion
    ) {
        let session = FocusSession(
            project: project,
            dayIdentifier: day,
            startedAt: when,
            status: .active,
            lastUserActivityAt: when,
            lastStateChangeAt: when,
            decisionEvents: [FocusSessionDecisionEvent(at: when, kind: .started, reason: reason, source: .automatic)],
            mode: .automatic,
            ruleVersion: ruleVersion
        )
        sessions.append(session)
    }

    private static func endSession(
        at index: Int,
        endedAt: Date,
        reason: FocusSessionDecisionReason,
        into sessions: inout [FocusSession]
    ) {
        guard index < sessions.count else { return }
        if let pause = sessions[index].currentPauseStartedAt {
            sessions[index].pausedTotal += max(0, endedAt.timeIntervalSince(pause))
            sessions[index].currentPauseStartedAt = nil
        }
        sessions[index].endedAt = endedAt
        sessions[index].status = .ended
        sessions[index].lastStateChangeAt = endedAt
        var events = sessions[index].decisionEvents ?? []
        events.append(FocusSessionDecisionEvent(at: endedAt, kind: .ended, reason: reason, source: .automatic))
        sessions[index].decisionEvents = events
    }

    private static func pauseSession(
        at index: Int,
        at when: Date,
        reason: FocusSessionDecisionReason,
        into sessions: inout [FocusSession]
    ) {
        guard index < sessions.count,
              sessions[index].currentPauseStartedAt == nil else { return }
        sessions[index].currentPauseStartedAt = when
        sessions[index].status = .paused
        sessions[index].lastStateChangeAt = when
        var events = sessions[index].decisionEvents ?? []
        events.append(FocusSessionDecisionEvent(at: when, kind: .paused, reason: reason, source: .automatic))
        sessions[index].decisionEvents = events
    }

    private static func resumeSession(
        at index: Int,
        at when: Date,
        reason: FocusSessionDecisionReason,
        into sessions: inout [FocusSession]
    ) {
        guard index < sessions.count else { return }
        let wasPaused = sessions[index].currentPauseStartedAt != nil
        if let pause = sessions[index].currentPauseStartedAt {
            sessions[index].pausedTotal += max(0, when.timeIntervalSince(pause))
            sessions[index].currentPauseStartedAt = nil
        }
        sessions[index].status = .active
        sessions[index].lastStateChangeAt = when
        if wasPaused {
            var events = sessions[index].decisionEvents ?? []
            events.append(FocusSessionDecisionEvent(at: when, kind: .resumed, reason: reason, source: .automatic))
            sessions[index].decisionEvents = events
        }
    }
}
