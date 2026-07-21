import Foundation

// MARK: - Unified Validator

/// Unified invariant validation across all TinyBuddy data domains.
/// Every method returns an array of violations; an empty array means the data
/// satisfies all known invariants for that domain.
public enum TinyBuddyDataValidator {

    // MARK: Focus Sessions

    /// Validates a collection of focus sessions for all known invariants.
    /// - Parameters:
    ///   - sessions: All sessions in the archive.
    ///   - now: Current date for duration/future checks.
    ///   - activeProjectKeys: Current set of known project keys (optional).
    /// - Returns: Detected violations, sorted by severity then kind.
    public static func validateFocusSessions(
        _ sessions: [FocusSession],
        now: Date = Date(),
        activeProjectKeys: Set<String>? = nil
    ) -> [TinyBuddyDataInvariantViolation] {
        var violations: [TinyBuddyDataInvariantViolation] = []

        // 1. Duplicate session IDs
        let idCounts = Dictionary(grouping: sessions, by: { $0.id })
        for (id, group) in idCounts where group.count > 1 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .duplicateSessionID(id),
                severity: .critical,
                description: "Duplicate session ID: \(id)",
                affectedIdentifiers: [id.uuidString],
                suggestedRepair: .isolated
            ))
        }

        // 2. Per-session structural invariants
        for session in sessions {
            violations += validateSessionStructural(session, now: now)
        }

        // 3. Time overlap between ended sessions in the same day
        let endedSessions = sessions.filter { $0.status == .ended && $0.endedAt != nil }
        let sorted = endedSessions.sorted { $0.startedAt < $1.startedAt }
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j]
                guard a.dayIdentifier == b.dayIdentifier else { continue }
                guard let aEnd = a.endedAt else { continue }
                if b.startedAt < aEnd {
                    violations.append(TinyBuddyDataInvariantViolation(
                        domain: .focusSession,
                        kind: .sessionTimeOverlap(sessionIDs: [a.id, b.id]),
                        severity: .error,
                        description: "Sessions \(a.id) and \(b.id) overlap in time",
                        affectedIdentifiers: [a.id.uuidString, b.id.uuidString],
                        suggestedRepair: .repaired
                    ))
                    break // one overlap violation per outer session
                }
            }
        }

        // 4. Stale project references
        if let activeKeys = activeProjectKeys {
            for session in sessions {
                if !activeKeys.isEmpty, !activeKeys.contains(session.project.key) {
                    violations.append(TinyBuddyDataInvariantViolation(
                        domain: .focusSession,
                        kind: .staleProjectReference(projectKey: session.project.key),
                        severity: .warning,
                        description: "Session \(session.id) references unknown project key",
                        affectedIdentifiers: [session.project.key],
                        suggestedRepair: .none
                    ))
                }
            }
        }

        return violations
    }

    /// Per-session structural checks.
    private static func validateSessionStructural(
        _ session: FocusSession,
        now: Date
    ) -> [TinyBuddyDataInvariantViolation] {
        var violations: [TinyBuddyDataInvariantViolation] = []

        // Day identifier
        if !TinyBuddyTimeContext.isValidDayIdentifier(session.dayIdentifier) {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .invalidDayIdentifier(sessionID: session.id, identifier: session.dayIdentifier),
                severity: .critical,
                description: "Invalid day identifier: \(session.dayIdentifier)",
                affectedIdentifiers: [session.id.uuidString],
                suggestedRepair: .isolated
            ))
        }

        // Empty project key/display
        if session.project.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .emptyProjectKey(sessionID: session.id),
                severity: .error,
                description: "Empty project key for session \(session.id)",
                affectedIdentifiers: [session.id.uuidString],
                suggestedRepair: .repaired
            ))
        }
        if session.project.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .sessionEmptyProjectDisplayName(sessionID: session.id),
                severity: .error,
                description: "Empty project display name for session \(session.id)",
                affectedIdentifiers: [session.id.uuidString],
                suggestedRepair: .repaired
            ))
        }

        // Finite date checks
        let finiteChecks: [(Date, String)] = [
            (session.startedAt, "startedAt"),
            (session.lastUserActivityAt, "lastUserActivityAt"),
            (session.lastStateChangeAt, "lastStateChangeAt")
        ]
        for (date, label) in finiteChecks {
            if !date.timeIntervalSinceReferenceDate.isFinite {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .unknown("non_finite_\(label)"),
                    severity: .critical,
                    description: "Non-finite \(label) for session \(session.id)",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .isolated
                ))
            }
        }

        // Future startedAt (within reasonable tolerance)
        let futureTolerance: TimeInterval = 3600 // 1 hour clock skew tolerance
        if session.startedAt.timeIntervalSince(now) > futureTolerance {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .futureStartedAt(sessionID: session.id, date: session.startedAt),
                severity: .error,
                description: "Session \(session.id) has future startedAt",
                affectedIdentifiers: [session.id.uuidString],
                suggestedRepair: .repaired
            ))
        }

        // lastUserActivityAt / lastStateChangeAt >= startedAt
        if session.lastUserActivityAt < session.startedAt {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .lastUserActivityBeforeStart(sessionID: session.id),
                severity: .error,
                description: "lastUserActivityAt before startedAt for session \(session.id)",
                affectedIdentifiers: [session.id.uuidString],
                suggestedRepair: .repaired
            ))
        }
        if session.lastStateChangeAt < session.startedAt {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .lastStateChangeBeforeStart(sessionID: session.id),
                severity: .error,
                description: "lastStateChangeAt before startedAt for session \(session.id)",
                affectedIdentifiers: [session.id.uuidString],
                suggestedRepair: .repaired
            ))
        }

        // pausedTotal
        if !session.pausedTotal.isFinite || session.pausedTotal < 0 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .pausedTotalExceedsGross(
                    sessionID: session.id,
                    pausedTotal: session.pausedTotal,
                    gross: 0
                ),
                severity: .error,
                description: "Invalid pausedTotal for session \(session.id): \(session.pausedTotal)",
                affectedIdentifiers: [session.id.uuidString],
                suggestedRepair: .repaired
            ))
        }

        // manualRevision
        if let rev = session.manualRevision, rev < 0 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .focusSession,
                kind: .manualRevisionNegative(sessionID: session.id, revision: rev),
                severity: .error,
                description: "Negative manualRevision for session \(session.id): \(rev)",
                affectedIdentifiers: [session.id.uuidString],
                suggestedRepair: .repaired
            ))
        }

        // Decision event duplicate IDs
        if let events = session.decisionEvents {
            let eventIDCounts = Dictionary(grouping: events, by: { $0.id })
            for (eventID, group) in eventIDCounts where group.count > 1 {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .decisionEventDuplicateID(sessionID: session.id, eventID: eventID),
                    severity: .warning,
                    description: "Duplicate decision event ID in session \(session.id)",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
            }
        }

        // Status-specific invariants
        switch session.status {
        case .ended:
            guard let end = session.endedAt else {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .statusEndedWithoutEndedAt(sessionID: session.id),
                    severity: .error,
                    description: "Status is .ended but endedAt is nil for session \(session.id)",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
                break
            }
            if session.currentPauseStartedAt != nil {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .currentPauseNotNilForEnded(sessionID: session.id),
                    severity: .error,
                    description: "Ended session \(session.id) has non-nil currentPauseStartedAt",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
            }
            // pausedTotal <= gross duration
            let gross = end.timeIntervalSince(session.startedAt)
            if session.pausedTotal > gross && gross >= 0 {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .pausedTotalExceedsGross(
                        sessionID: session.id,
                        pausedTotal: session.pausedTotal,
                        gross: gross
                    ),
                    severity: .error,
                    description: "pausedTotal exceeds gross duration for ended session \(session.id)",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
            }
            // lastUserActivityAt / lastStateChangeAt <= end
            if session.lastUserActivityAt > end {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .unknown("last_activity_after_end"),
                    severity: .warning,
                    description: "lastUserActivityAt after endedAt for session \(session.id)",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
            }

        case .active:
            if session.endedAt != nil {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .statusActiveWithEndedAt(sessionID: session.id),
                    severity: .error,
                    description: "Active session \(session.id) has non-nil endedAt",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
            }
            if session.currentPauseStartedAt != nil {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .currentPauseNotNilForActive(sessionID: session.id),
                    severity: .error,
                    description: "Active session \(session.id) has non-nil currentPauseStartedAt",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
            }

        case .paused:
            if session.endedAt != nil {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .statusActiveWithEndedAt(sessionID: session.id),
                    severity: .error,
                    description: "Paused session \(session.id) has non-nil endedAt",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
            }
            if session.currentPauseStartedAt == nil {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .focusSession,
                    kind: .unknown("paused_no_pause_start"),
                    severity: .error,
                    description: "Paused session \(session.id) has nil currentPauseStartedAt",
                    affectedIdentifiers: [session.id.uuidString],
                    suggestedRepair: .repaired
                ))
            }
        }

        return violations
    }

    // MARK: Project Registry

    /// Validates a project registry snapshot.
    public static func validateProjectRegistry(
        _ snapshot: TinyBuddyProjectRegistrySnapshot
    ) -> [TinyBuddyDataInvariantViolation] {
        var violations: [TinyBuddyDataInvariantViolation] = []

        guard snapshot.schemaVersion == TinyBuddyProjectRegistrySnapshot.currentSchemaVersion else {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .projectIdentity,
                kind: .snapshotSchemaVersionMismatch,
                severity: .critical,
                description: "Project registry schema version mismatch",
                suggestedRepair: .preserved
            ))
            return violations
        }

        // Duplicate project IDs
        let idCounts = Dictionary(grouping: snapshot.projects, by: { $0.id })
        for (id, group) in idCounts where group.count > 1 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .projectIdentity,
                kind: .duplicateProjectID(id),
                severity: .critical,
                description: "Duplicate project ID: \(id.rawValue)",
                affectedIdentifiers: [id.rawValue],
                suggestedRepair: .isolated
            ))
        }

        // Empty display names
        for project in snapshot.projects where project.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .projectIdentity,
                kind: .projectEmptyProjectDisplayName(projectID: project.id),
                severity: .error,
                description: "Empty display name for project \(project.id.rawValue)",
                affectedIdentifiers: [project.id.rawValue],
                suggestedRepair: .repaired
            ))
        }

        // Redirect cycle detection
        let allIDs = Set(snapshot.projects.map(\.id))
        for (source, target) in snapshot.redirects {
            if source == target {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .projectIdentity,
                    kind: .projectRegistryRedirectToSelf,
                    severity: .critical,
                    description: "Redirect from \(source.rawValue) to itself",
                    affectedIdentifiers: [source.rawValue],
                    suggestedRepair: .repaired
                ))
                continue
            }
            if !allIDs.contains(source) {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .projectIdentity,
                    kind: .projectRedirectSourceNotInRegistry(source: source),
                    severity: .error,
                    description: "Redirect source \(source.rawValue) not in registry",
                    affectedIdentifiers: [source.rawValue],
                    suggestedRepair: .repaired
                ))
            }
            if !allIDs.contains(target) {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .projectIdentity,
                    kind: .projectRedirectTargetNotInRegistry(target: target),
                    severity: .error,
                    description: "Redirect target \(target.rawValue) not in registry",
                    affectedIdentifiers: [target.rawValue],
                    suggestedRepair: .repaired
                ))
            }
        }

        // Cycle check via DFS
        var visited = Set<TinyBuddyProjectID>()
        for start in snapshot.redirects.keys {
            if visited.contains(start) { continue }
            var path = Set<TinyBuddyProjectID>()
            var cursor = start
            var hasCycle = false
            while let next = snapshot.redirects[cursor] {
                if !path.insert(cursor).inserted {
                    hasCycle = true
                    break
                }
                cursor = next
            }
            visited.formUnion(path)
            if hasCycle {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .projectIdentity,
                    kind: .projectRegistryRedirectCycle,
                    severity: .critical,
                    description: "Redirect cycle detected starting from \(start.rawValue)",
                    affectedIdentifiers: Array(path).map(\.rawValue),
                    suggestedRepair: .repaired
                ))
            }
        }

        return violations
    }

    // MARK: Config Snapshot

    /// Validates a config snapshot version consistency.
    public static func validateConfigSnapshot(
        config: TinyBuddyAppConfig,
        previousVersion: Int64?,
        previousPlayload: [String: Any]?
    ) -> [TinyBuddyDataInvariantViolation] {
        var violations: [TinyBuddyDataInvariantViolation] = []

        guard previousVersion != nil else { return violations }

        if config.configVersion < previousVersion! {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .configSnapshot,
                kind: .configVersionRegression(
                    previous: previousVersion!,
                    current: config.configVersion
                ),
                severity: .critical,
                description: "Config version regression: \(previousVersion!) -> \(config.configVersion)",
                suggestedRepair: .preserved
            ))
        }

        return violations
    }

    // MARK: Combined Snapshot

    /// Validates a combined snapshot for cross-slice consistency.
    public static func validateCombinedSnapshot(
        _ snapshot: TinyBuddyCombinedSnapshot
    ) -> [TinyBuddyDataInvariantViolation] {
        var violations: [TinyBuddyDataInvariantViolation] = []

        // Revision non-negative
        if snapshot.revision < 0 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .sharedSnapshot,
                kind: .snapshotRevisionRegression(
                    previous: snapshot.revision,
                    current: snapshot.revision
                ),
                severity: .critical,
                description: "Negative snapshot revision: \(snapshot.revision)",
                suggestedRepair: .preserved
            ))
        }

        // Day identifier validity
        if !TinyBuddyTimeContext.isValidDayIdentifier(snapshot.dayIdentifier) {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .sharedSnapshot,
                kind: .snapshotDayIdentifierMismatch(
                    expected: snapshot.dayIdentifier,
                    actual: snapshot.snapshot.stats.dayIdentifier
                ),
                severity: .critical,
                description: "Invalid day identifier in combined snapshot",
                suggestedRepair: .preserved
            ))
        }

        // Day identifier consistency across sub-slices
        if snapshot.snapshot.stats.dayIdentifier != snapshot.dayIdentifier {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .sharedSnapshot,
                kind: .snapshotDayIdentifierMismatch(
                    expected: snapshot.dayIdentifier,
                    actual: snapshot.snapshot.stats.dayIdentifier
                ),
                severity: .error,
                description: "Snapshot day identifier mismatch: main='\(snapshot.dayIdentifier)' stats='\(snapshot.snapshot.stats.dayIdentifier)'",
                suggestedRepair: .repaired
            ))
        }

        // Focus session snapshot day consistency
        if let focus = snapshot.focusSessionSnapshot {
            if focus.dayIdentifier != snapshot.dayIdentifier {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .sharedSnapshot,
                    kind: .snapshotFocusSessionDayMismatch(
                        snapshotDay: snapshot.dayIdentifier,
                        focusDay: focus.dayIdentifier
                    ),
                    severity: .error,
                    description: "Focus session snapshot day mismatch",
                    suggestedRepair: .repaired
                ))
            }
            // focusDuration >= 0 is already enforced by normalization
        }

        // Focus history publication day consistency
        if let history = snapshot.focusHistoryPublication {
            let lastDay = history.snapshot.recentDays.last?.dayIdentifier ?? ""
            if lastDay != snapshot.dayIdentifier {
                violations.append(TinyBuddyDataInvariantViolation(
                    domain: .sharedSnapshot,
                    kind: .snapshotHistoryDayMismatch(
                        snapshotDay: snapshot.dayIdentifier,
                        historyDay: lastDay
                    ),
                    severity: .warning,
                    description: "Focus history last day '\(lastDay)' != snapshot day '\(snapshot.dayIdentifier)'",
                    suggestedRepair: .none
                ))
            }
        }

        // Non-negative stats
        if snapshot.snapshot.stats.focusCount < 0 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .dailyStats,
                kind: .focusCountNegative(
                    dayIdentifier: snapshot.dayIdentifier,
                    count: snapshot.snapshot.stats.focusCount
                ),
                severity: .error,
                description: "Negative focusCount in combined snapshot: \(snapshot.snapshot.stats.focusCount)",
                suggestedRepair: .repaired
            ))
        }
        if snapshot.snapshot.stats.completionCount < 0 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .dailyStats,
                kind: .completionCountNegative(
                    dayIdentifier: snapshot.dayIdentifier,
                    count: snapshot.snapshot.stats.completionCount
                ),
                severity: .error,
                description: "Negative completionCount in combined snapshot: \(snapshot.snapshot.stats.completionCount)",
                suggestedRepair: .repaired
            ))
        }

        return violations
    }

    // MARK: DailyStats

    /// Validates daily stats for invariants.
    public static func validateDailyStats(
        _ stats: DailyStats,
        previousStats: DailyStats? = nil
    ) -> [TinyBuddyDataInvariantViolation] {
        var violations: [TinyBuddyDataInvariantViolation] = []

        if !TinyBuddyTimeContext.isValidDayIdentifier(stats.dayIdentifier) {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .dailyStats,
                kind: .unknown("invalid_day_identifier"),
                severity: .error,
                description: "Invalid day identifier: \(stats.dayIdentifier)",
                suggestedRepair: .none
            ))
        }

        if stats.focusCount < 0 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .dailyStats,
                kind: .focusCountNegative(dayIdentifier: stats.dayIdentifier, count: stats.focusCount),
                severity: .error,
                description: "Negative focusCount: \(stats.focusCount)",
                suggestedRepair: .repaired
            ))
        }

        if stats.completionCount < 0 {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .dailyStats,
                kind: .completionCountNegative(dayIdentifier: stats.dayIdentifier, count: stats.completionCount),
                severity: .error,
                description: "Negative completionCount: \(stats.completionCount)",
                suggestedRepair: .repaired
            ))
        }

        if let prev = previousStats, prev.dayIdentifier > stats.dayIdentifier {
            violations.append(TinyBuddyDataInvariantViolation(
                domain: .dailyStats,
                kind: .dayIdentifierRollback(previous: prev.dayIdentifier, current: stats.dayIdentifier),
                severity: .error,
                description: "Day identifier rollback: '\(prev.dayIdentifier)' -> '\(stats.dayIdentifier)'",
                suggestedRepair: .preserved
            ))
        }

        return violations
    }
}
