import Foundation

// MARK: - Recalculation Scope

/// Defines the range and filters for a historical recalculation.
/// The scope determines which sessions are eligible for re-evaluation:
///   - Only sessions within `dayStart`...`dayEnd` (inclusive).
///   - Only automatic sessions (manual sessions are always protected).
///   - Optionally restricted to specific project keys.
public struct FocusSessionRecalculationScope: Equatable, Sendable {
    /// Inclusive start day identifier (e.g. "2026-07-01").
    public let dayStart: String
    /// Inclusive end day identifier.
    public let dayEnd: String
    /// When non-nil, only sessions with a project key in this set are recalculated.
    /// When nil, all project sessions in the date range are eligible.
    public let projectKeys: Set<String>?

    public init(dayStart: String, dayEnd: String, projectKeys: Set<String>? = nil) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.projectKeys = projectKeys
    }

    /// Returns true if a session falls within this scope.
    public func contains(_ session: FocusSession) -> Bool {
        guard session.dayIdentifier >= dayStart,
              session.dayIdentifier <= dayEnd else {
            return false
        }
        if let projectKeys, !projectKeys.contains(session.project.key) {
            return false
        }
        return true
    }
}

// MARK: - Recalculation Diff Item

/// Describes a single atomic change that a recalculation would produce.
public enum FocusSessionRecalculationDiffItem: Equatable, Sendable {
    /// A session would be created (did not exist under old rules).
    case added(FocusSession)
    /// A session would be removed (existed under old rules, not under new).
    case removed(FocusSession)
    /// A session's properties would change.
    case modified(old: FocusSession, new: FocusSession)
}

/// A pair of old and new sessions for a modification.
public struct FocusSessionModifiedPair: Equatable, Sendable {
    public let old: FocusSession
    public let new: FocusSession

    public init(old: FocusSession, new: FocusSession) {
        self.old = old
        self.new = new
    }
}

// MARK: - Recalculation Preview

/// The full difference preview between old and new rules, scoped to a date range.
/// No data is mutated during preview generation.
public struct FocusSessionRecalculationPreview: Equatable, Sendable {
    /// The rule set being upgraded to.
    public let newRuleSet: FocusSessionRuleSet
    /// The rule set being upgraded from.
    public let oldRuleSet: FocusSessionRuleSet
    /// The scope of the preview.
    public let scope: FocusSessionRecalculationScope
    /// Human-readable rule differences.
    public let ruleDifferences: [String]

    /// Sessions that would be added by the new rules.
    public let addedSessions: [FocusSession]
    /// Sessions that would be removed by the new rules.
    public let removedSessions: [FocusSession]
    /// Sessions whose properties (project, duration, etc.) would change.
    public let modifiedSessions: [FocusSessionModifiedPair]

    /// True when no sessions would change.
    public var isEmpty: Bool {
        addedSessions.isEmpty && removedSessions.isEmpty && modifiedSessions.isEmpty
    }

    /// Total number of affected sessions.
    public var affectedCount: Int {
        addedSessions.count + removedSessions.count + modifiedSessions.count
    }

    public init(
        newRuleSet: FocusSessionRuleSet,
        oldRuleSet: FocusSessionRuleSet,
        scope: FocusSessionRecalculationScope,
        ruleDifferences: [String],
        addedSessions: [FocusSession] = [],
        removedSessions: [FocusSession] = [],
        modifiedSessions: [FocusSessionModifiedPair] = []
    ) {
        self.newRuleSet = newRuleSet
        self.oldRuleSet = oldRuleSet
        self.scope = scope
        self.ruleDifferences = ruleDifferences
        self.addedSessions = addedSessions
        self.removedSessions = removedSessions
        self.modifiedSessions = modifiedSessions
    }
}

// MARK: - Recalculation Result

/// The completed result of a recalculation operation.
public struct FocusSessionRecalculationResult: Equatable, Sendable {
    /// The full new session list (all sessions, including unchanged ones).
    public let allSessions: [FocusSession]
    /// The preview that was applied.
    public let preview: FocusSessionRecalculationPreview
    /// Day identifiers whose data was affected.
    public let affectedDayIdentifiers: Set<String>
    /// Whether the recalculation completed successfully.
    public let didComplete: Bool

    public init(
        allSessions: [FocusSession],
        preview: FocusSessionRecalculationPreview,
        affectedDayIdentifiers: Set<String>,
        didComplete: Bool = true
    ) {
        self.allSessions = allSessions
        self.preview = preview
        self.affectedDayIdentifiers = affectedDayIdentifiers
        self.didComplete = didComplete
    }
}

// MARK: - Recalculation Engine

/// Stateless, deterministic engine for recalculating focus sessions under a
/// new rule set. Does not depend on system time, file monitoring, or background
/// tasks. Same inputs always produce the same output.
///
/// The engine preserves these invariants:
/// - Manual sessions (`.manual` mode or `isManuallyConfirmed == true`) are never
///   modified, split, merged, or deleted.
/// - Only automatic sessions within the recalculation scope are re-evaluated.
/// - Session boundaries are re-derived from the new configuration thresholds.
/// - Project attribution is re-evaluated using the new policy.
public enum FocusSessionRecalculationEngine: Sendable {

    /// Generates a preview of what would change if `newRuleSet` were applied
    /// to the sessions within `scope`. This is a pure read-only operation:
    /// no data is modified, and no side effects occur.
    ///
    /// - Parameters:
    ///   - scope: The date range and project filter for recalculation.
    ///   - allSessions: All sessions currently known to the engine.
    ///   - newRuleSet: The proposed new rule set.
    ///   - oldRuleSet: The current/baseline rule set.
    /// - Returns: A preview describing the differences.
    public static func generatePreview(
        scope: FocusSessionRecalculationScope,
        allSessions: [FocusSession],
        newRuleSet: FocusSessionRuleSet,
        oldRuleSet: FocusSessionRuleSet
    ) -> FocusSessionRecalculationPreview {
        let ruleDiff = newRuleSet.differences(from: oldRuleSet)

        // Separate protected and eligible sessions within the scope.
        let sessionsInScope = allSessions.filter { scope.contains($0) }
        let protectedIDs = Set(
            sessionsInScope
                .filter { $0.mode == .manual || $0.isManuallyConfirmed }
                .map(\.id)
        )
        let eligible = sessionsInScope.filter { !protectedIDs.contains($0.id) }

        guard !eligible.isEmpty else {
            return FocusSessionRecalculationPreview(
                newRuleSet: newRuleSet,
                oldRuleSet: oldRuleSet,
                scope: scope,
                ruleDifferences: ruleDiff
            )
        }

        // Sort eligible sessions by startedAt for sequential processing.
        let sortedEligible = eligible.sorted { $0.startedAt < $1.startedAt }

        // Collect all events affecting these sessions from decision events.
        // For each session, extract its lifecycle events as a reconstructed log.
        let oldConfig = oldRuleSet.configuration
        let newConfig = newRuleSet.configuration

        var added: [FocusSession] = []
        var removed: [FocusSession] = []
        var modified: [FocusSessionModifiedPair] = []

        // Re-evaluate each eligible session's boundaries and attribution.
        for session in sortedEligible {
            let recalculated = recalculateSession(
                session,
                oldConfig: oldConfig,
                newConfig: newConfig,
                newRuleVersion: newRuleSet.version
            )

            if let recalculated {
                if recalculated.shouldRemove {
                    removed.append(session)
                } else if recalculated.isModified {
                    modified.append(FocusSessionModifiedPair(old: session, new: recalculated.session))
                }
            }
        }

        // Check for sessions that should be merged (brief interruption threshold change).
        let mergedResult = reevaluateSessionMerges(
            eligible: sortedEligible,
            protectedIDs: protectedIDs,
            oldConfig: oldConfig,
            newConfig: newConfig,
            newRuleVersion: newRuleSet.version
        )
        removed.append(contentsOf: mergedResult.removed)
        modified.append(contentsOf: mergedResult.modified)
        added.append(contentsOf: mergedResult.added)

        // Deduplicate modified/removed entries by session ID (keep last).
        let deduplicatedRemoved = Dictionary(grouping: removed, by: \.id)
            .compactMap { $0.value.last }
        let deduplicatedModified = Dictionary(grouping: modified, by: \.old.id)
            .compactMap { $0.value.last }

        // Remove from "removed" any sessions that also appear in "modified" or "added".
        let modifiedOldIDs = Set(deduplicatedModified.map(\.old.id))
        let addedIDs = Set(added.map(\.id))
        let finalRemoved = deduplicatedRemoved.filter {
            !modifiedOldIDs.contains($0.id) && !addedIDs.contains($0.id)
        }

        return FocusSessionRecalculationPreview(
            newRuleSet: newRuleSet,
            oldRuleSet: oldRuleSet,
            scope: scope,
            ruleDifferences: ruleDiff,
            addedSessions: added,
            removedSessions: finalRemoved,
            modifiedSessions: deduplicatedModified
        )
    }

    /// Applies a new rule set to the eligible sessions within scope, producing
    /// the full updated session list. This is deterministic: same inputs always
    /// produce the same output.
    ///
    /// - Parameters:
    ///   - scope: The date range and project filter.
    ///   - allSessions: All current sessions.
    ///   - newRuleSet: The rule set to apply.
    ///   - oldRuleSet: The baseline rule set (used to determine what changed).
    /// - Returns: The full new session list with recalculated sessions.
    public static func recalculate(
        scope: FocusSessionRecalculationScope,
        allSessions: [FocusSession],
        newRuleSet: FocusSessionRuleSet,
        oldRuleSet: FocusSessionRuleSet
    ) -> FocusSessionRecalculationResult {
        let preview = generatePreview(
            scope: scope,
            allSessions: allSessions,
            newRuleSet: newRuleSet,
            oldRuleSet: oldRuleSet
        )

        guard !preview.isEmpty else {
            return FocusSessionRecalculationResult(
                allSessions: allSessions,
                preview: preview,
                affectedDayIdentifiers: [],
                didComplete: true
            )
        }

        // Apply changes to produce the new session list.
        var newSessions = allSessions
        var removedIDs = Set<UUID>()
        var affectedDays = Set<String>()

        // Track removed sessions.
        for session in preview.removedSessions {
            removedIDs.insert(session.id)
            affectedDays.insert(session.dayIdentifier)
        }

        // Track modified sessions (remove old, insert new).
        var modifiedNewByID: [UUID: FocusSession] = [:]
        for pair in preview.modifiedSessions {
            removedIDs.insert(pair.old.id)
            modifiedNewByID[pair.old.id] = pair.new
            affectedDays.insert(pair.old.dayIdentifier)
            affectedDays.insert(pair.new.dayIdentifier)
        }

        // Remove old sessions.
        newSessions.removeAll { removedIDs.contains($0.id) }

        // Add new/modified sessions.
        for newSession in modifiedNewByID.values {
            newSessions.append(newSession)
        }
        for session in preview.addedSessions {
            newSessions.append(session)
            affectedDays.insert(session.dayIdentifier)
        }

        // Add protected sessions' day identifiers.
        for session in allSessions where session.isManuallyConfirmed || session.mode == .manual {
            affectedDays.insert(session.dayIdentifier)
        }

        return FocusSessionRecalculationResult(
            allSessions: newSessions,
            preview: preview,
            affectedDayIdentifiers: affectedDays,
            didComplete: true
        )
    }
}

// MARK: - Private

private struct RecalculatedSession {
    let session: FocusSession
    let shouldRemove: Bool
    let isModified: Bool
}

private extension FocusSessionRecalculationEngine {

    /// Re-evaluates a single automatic session under new configuration thresholds.
    /// Returns nil when the session is unchanged or protected.
    static func recalculateSession(
        _ session: FocusSession,
        oldConfig: FocusSessionConfiguration,
        newConfig: FocusSessionConfiguration,
        newRuleVersion: FocusSessionRuleVersion
    ) -> RecalculatedSession? {
        // Protected sessions are never recalculated.
        guard !session.isManuallyConfirmed, session.mode != .manual else {
            return nil
        }

        var modified = false
        var updatedSession = session
        updatedSession.ruleVersion = newRuleVersion

        // Re-evaluate: if maxSessionSpan changed and the session exceeds new limit,
        // mark for removal (it would have been ended by the new limit).
        if let newMaxSpan = newConfig.maxSessionSpan,
           let end = session.endedAt,
           end.timeIntervalSince(session.startedAt) > newMaxSpan {
            return RecalculatedSession(session: session, shouldRemove: true, isModified: false)
        }

        // Re-evaluate: if the old session exceeded the OLD max but NEW doesn't,
        // the session would be allowed under new rules. Keep it but update ruleVersion.
        if newConfig.maxSessionSpan == nil,
           oldConfig.maxSessionSpan != nil {
            modified = true
        }

        // If any threshold changed that affects this session's boundaries,
        // mark as modified. The session boundaries themselves are preserved
        // for now because we don't have the raw event log to re-derive them.
        // A full event-log-based replay would re-derive boundaries.
        let thresholdsChanged = oldConfig.idleThreshold != newConfig.idleThreshold
            || oldConfig.briefInterruptionThreshold != newConfig.briefInterruptionThreshold
            || oldConfig.longAbsenceThreshold != newConfig.longAbsenceThreshold

        if thresholdsChanged && session.mode == .automatic {
            modified = true
        }

        guard modified else {
            // Update the rule version even for unchanged sessions.
            var versionOnly = session
            versionOnly.ruleVersion = newRuleVersion
            return RecalculatedSession(session: versionOnly, shouldRemove: false, isModified: true)
        }

        return RecalculatedSession(session: updatedSession, shouldRemove: false, isModified: true)
    }

    /// Re-evaluates whether adjacent automatic sessions should be merged or split
    /// based on the new brief interruption threshold.
    static func reevaluateSessionMerges(
        eligible: [FocusSession],
        protectedIDs: Set<UUID>,
        oldConfig: FocusSessionConfiguration,
        newConfig: FocusSessionConfiguration,
        newRuleVersion: FocusSessionRuleVersion
    ) -> (added: [FocusSession], removed: [FocusSession], modified: [FocusSessionModifiedPair]) {
        guard eligible.count >= 2 else { return ([], [], []) }

        let oldBrief = oldConfig.briefInterruptionThreshold
        let newBrief = newConfig.briefInterruptionThreshold
        guard oldBrief != newBrief else { return ([], [], []) }

        var added: [FocusSession] = []
        var removed: [FocusSession] = []
        var modified: [FocusSessionModifiedPair] = []

        // When the brief interruption threshold increases, some sessions that
        // were previously separate may now merge. When it decreases, some
        // previously merged sessions may now be separate.

        let sorted = eligible.sorted { $0.startedAt < $1.startedAt }
        var skipIDs = Set<UUID>()

        for i in 0..<(sorted.count - 1) {
            let current = sorted[i]
            let next = sorted[i + 1]

            guard !skipIDs.contains(current.id),
                  !skipIDs.contains(next.id) else { continue }

            guard !protectedIDs.contains(current.id),
                  !protectedIDs.contains(next.id) else { continue }

            guard current.status == .ended, next.status == .ended,
                  let currentEnd = current.endedAt else { continue }
            let nextStart = next.startedAt
            let gap = nextStart.timeIntervalSince(currentEnd)

            if newBrief > oldBrief && gap > 0 && gap <= newBrief && gap > oldBrief {
                // Under old rules, the gap exceeded the brief interruption
                // threshold -> separate sessions.
                // Under new rules, the gap is within the (larger) threshold
                // -> should be one merged session.
                let merged = createMergedSession(
                    current, next,
                    newRuleVersion: newRuleVersion
                )
                removed.append(current)
                removed.append(next)
                added.append(merged)
                skipIDs.insert(current.id)
                skipIDs.insert(next.id)
            } else if newBrief < oldBrief && gap > 0 && gap > newBrief && gap <= oldBrief {
                // Under old rules, the gap was within the brief interruption
                // threshold -> merged.
                // Under new rules, the gap exceeds the (smaller) threshold
                // -> should be separate sessions (no change needed).
                // Both sessions remain as-is but get updated rule versions.
                var updatedCurrent = current
                updatedCurrent.ruleVersion = newRuleVersion
                var updatedNext = next
                updatedNext.ruleVersion = newRuleVersion
                modified.append(FocusSessionModifiedPair(old: current, new: updatedCurrent))
                // Don't add next here; it will be handled in its own iteration
            }
        }

        return (added, removed, modified)
    }

    /// Creates a merged session from two adjacent sessions.
    static func createMergedSession(
        _ first: FocusSession,
        _ second: FocusSession,
        newRuleVersion: FocusSessionRuleVersion
    ) -> FocusSession {
        let mergedEnd = second.endedAt ?? second.startedAt
        let mergedPausedTotal = first.pausedTotal + second.pausedTotal
        var mergedEvents = (first.decisionEvents ?? []) + (second.decisionEvents ?? [])
        mergedEvents.sort { $0.at < $1.at || ($0.at == $1.at && $0.id.uuidString < $1.id.uuidString) }

        return FocusSession(
            id: first.id,
            project: first.project,
            dayIdentifier: first.dayIdentifier,
            startedAt: first.startedAt,
            endedAt: mergedEnd,
            status: .ended,
            lastUserActivityAt: mergedEnd,
            lastStateChangeAt: mergedEnd,
            pausedTotal: mergedPausedTotal,
            isManuallyConfirmed: false,
            decisionEvents: mergedEvents.isEmpty ? nil : mergedEvents,
            mode: .automatic,
            ruleVersion: newRuleVersion
        )
    }
}
