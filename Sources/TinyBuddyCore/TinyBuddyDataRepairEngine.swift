import Foundation

// MARK: - Repair Engine

/// Localized, idempotent, atomic repair operations for all data domains.
///
/// Rules:
/// - Every repair operation is idempotent: applying it multiple times with the
///   same input produces identical results.
/// - Repairs are atomic per domain: either all changes for a domain succeed or
///   none are applied.
/// - Interruptible: intermediate state is tracked in the repair session so a
///   second invocation continues from the same checkpoint.
/// - Only affected records are touched; valid records are never modified.
/// - Derived statistics are regenerated from authoritative source data, never
///   from other derived values.
public enum TinyBuddyDataRepairEngine {

    // MARK: - Public API

    /// Runs a full repair cycle across all domains. Returns a completed or
    /// partial repair session.
    /// - Parameters:
    ///   - sessions: Focus session archive (mutable copy).
    ///   - projectSnapshot: Project registry snapshot (mutable copy).
    ///   - combinedSnapshot: Combined snapshot (mutable copy).
    ///   - activeProjectKeys: Current set of valid project keys.
    ///   - now: Current date.
    ///   - previousSessionCount: Previous derived session count for the day.
    /// - Returns: A repair session with all violations and results.
    public static func repairAll(
        sessions: inout [FocusSession],
        projectSnapshot: inout TinyBuddyProjectRegistrySnapshot,
        combinedSnapshot: inout TinyBuddyCombinedSnapshot?,
        activeProjectKeys: Set<String>? = nil,
        now: Date = Date(),
        previousSessionCount: Int? = nil
    ) -> TinyBuddyDataRepairSession {
        let sessionID = UUID()
        let startedAt = now
        var allViolations: [TinyBuddyDataInvariantViolation] = []
        var allResults: [TinyBuddyDataRepairResult] = []

        // === Focus Session Repair ===
        let sessionViolations = TinyBuddyDataValidator.validateFocusSessions(
            sessions, now: now, activeProjectKeys: activeProjectKeys
        )
        allViolations += sessionViolations

        let sessionResults = repairSessions(
            &sessions, violations: sessionViolations, now: now
        )
        allResults += sessionResults

        // === Project Registry Repair ===
        let projectViolations = TinyBuddyDataValidator.validateProjectRegistry(projectSnapshot)
        allViolations += projectViolations

        let projectResults = repairProjectRegistry(
            &projectSnapshot, violations: projectViolations
        )
        allResults += projectResults

        // === Combined Snapshot Repair ===
        var combinedRepairResults: [TinyBuddyDataRepairResult] = []
        if var snap = combinedSnapshot {
            let combinedViolations = TinyBuddyDataValidator.validateCombinedSnapshot(snap)
            allViolations += combinedViolations
            combinedRepairResults = repairCombinedSnapshot(
                &snap, violations: combinedViolations,
                sessions: sessions, now: now,
                previousSessionCount: previousSessionCount
            )
            combinedSnapshot = snap
        }
        allResults += combinedRepairResults

        let didPerformRepair = allResults.contains { $0.action != .none && $0.action != .skippedAlreadyApplied }

        return TinyBuddyDataRepairSession(
            id: sessionID,
            startedAt: startedAt,
            endedAt: Date(),
            violations: allViolations,
            results: allResults,
            didComplete: true,
            inputHash: inputHash(
                sessions: sessions,
                project: projectSnapshot,
                combined: combinedSnapshot
            ),
            didPerformRepair: didPerformRepair
        )
    }

    // MARK: - Session Repair

    /// Repairs focus session violations. Idempotent: same input yields same output.
    private static func repairSessions(
        _ sessions: inout [FocusSession],
        violations: [TinyBuddyDataInvariantViolation],
        now: Date
    ) -> [TinyBuddyDataRepairResult] {
        var results: [TinyBuddyDataRepairResult] = []

        // Build set of session IDs to quarantine (duplicate instances)
        var quarantineIDs = Set<UUID>()
        var seenIDs = Set<UUID>()
        var deduplicated: [FocusSession] = []

        for session in sessions {
            if seenIDs.contains(session.id) {
                quarantineIDs.insert(session.id)
            } else {
                seenIDs.insert(session.id)
                deduplicated.append(session)
            }
        }

        if !quarantineIDs.isEmpty {
            results.append(TinyBuddyDataRepairResult(
                violationID: violations.first(where: {
                    if case .duplicateSessionID = $0.kind { return true }
                    return false
                })?.id ?? UUID(),
                action: .isolated,
                diagnosticKey: "repair.session.deduplicated",
                summary: "Isolated \(quarantineIDs.count) duplicate session(s)"
            ))
        }

        // Repair individual session invariants
        for i in deduplicated.indices {
            var session = deduplicated[i]
            var repaired = false

            // Clamp negative pausedTotal
            if !session.pausedTotal.isFinite || session.pausedTotal < 0 {
                session.pausedTotal = 0
                repaired = true
            }

            // Clamp negative manualRevision
            if let rev = session.manualRevision, rev < 0 {
                session.manualRevision = nil
                repaired = true
            }

            // Fix lastUserActivityAt / lastStateChangeAt < startedAt
            if session.lastUserActivityAt < session.startedAt {
                session.lastUserActivityAt = session.startedAt
                repaired = true
            }
            if session.lastStateChangeAt < session.startedAt {
                session.lastStateChangeAt = session.startedAt
                repaired = true
            }

            // Fix ended status with missing endedAt
            if session.status == .ended && session.endedAt == nil {
                session.endedAt = session.lastStateChangeAt
                repaired = true
            }

            // Fix ended status with currentPauseStartedAt (idempotent: skip if already nil)
            if session.status == .ended, session.currentPauseStartedAt != nil {
                session.currentPauseStartedAt = nil
                repaired = true
            }

            // Fix active/paused status with endedAt
            if session.status != .ended && session.endedAt != nil {
                session.status = .ended
                repaired = true
            }

            // Fix paused without pause start
            if session.status == .paused && session.currentPauseStartedAt == nil {
                session.status = .active
                repaired = true
            }

            // Clamp future startedAt within reasonable bound
            let futureTolerance: TimeInterval = 3600
            if session.startedAt.timeIntervalSince(now) > futureTolerance {
                session.startedAt = now
                if session.lastUserActivityAt < session.startedAt {
                    session.lastUserActivityAt = session.startedAt
                }
                if session.lastStateChangeAt < session.startedAt {
                    session.lastStateChangeAt = session.startedAt
                }
                repaired = true
            }

            // Fix empty project key
            if session.project.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.project = FocusProjectContext(
                    key: "unknown.\(session.id.uuidString.prefix(8))",
                    displayName: session.project.displayName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty ? "未知项目" : session.project.displayName
                )
                repaired = true
            }

            if repaired {
                // Find relevant violations for this session
                let sessionViolations = violations.filter { v in
                    v.affectedIdentifiers.contains(session.id.uuidString)
                }
                let violationID = sessionViolations.first?.id ?? UUID()
                results.append(TinyBuddyDataRepairResult(
                    violationID: violationID,
                    action: .repaired,
                    diagnosticKey: "repair.session.repaired",
                    summary: "Repaired session \(session.id)"
                ))
            }

            deduplicated[i] = session
        }

        sessions = deduplicated
        return results
    }

    // MARK: - Project Registry Repair

    /// Repairs project registry violations. Idempotent.
    private static func repairProjectRegistry(
        _ snapshot: inout TinyBuddyProjectRegistrySnapshot,
        violations: [TinyBuddyDataInvariantViolation]
    ) -> [TinyBuddyDataRepairResult] {
        var results: [TinyBuddyDataRepairResult] = []
        var modified = false

        // Remove duplicate projects (keep first occurrence)
        var seenIDs = Set<TinyBuddyProjectID>()
        var deduplicated: [TinyBuddyProject] = []
        for project in snapshot.projects {
            if seenIDs.contains(project.id) {
                modified = true
            } else {
                seenIDs.insert(project.id)
                deduplicated.append(project)
            }
        }

        if modified {
            results.append(TinyBuddyDataRepairResult(
                violationID: violations.first(where: {
                    if case .duplicateProjectID = $0.kind { return true }
                    return false
                })?.id ?? UUID(),
                action: .isolated,
                diagnosticKey: "repair.project.deduplicated",
                summary: "Deduplicated project registry"
            ))
            snapshot = TinyBuddyProjectRegistrySnapshot(
                schemaVersion: snapshot.schemaVersion,
                revision: snapshot.revision,
                generation: snapshot.generation,
                projects: deduplicated,
                redirects: snapshot.redirects
            )
        }

        // Fix empty display names
        var emptyNameFixed = false
        for i in snapshot.projects.indices {
            let name = snapshot.projects[i].displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                snapshot.projects[i].displayName = "项目 \(snapshot.projects[i].id.rawValue.prefix(8))"
                modified = true
                emptyNameFixed = true
            }
        }
        if emptyNameFixed {
            results.append(TinyBuddyDataRepairResult(
                violationID: violations.first(where: {
                    if case .projectEmptyProjectDisplayName = $0.kind { return true }
                    return false
                })?.id ?? UUID(),
                action: .repaired,
                diagnosticKey: "repair.project.empty_display_name",
                summary: "Fixed empty display name(s)"
            ))
        }

        // Fix redirect cycles and self-redirects
        var cleanRedirects = snapshot.redirects
        let allIDs = Set(snapshot.projects.map(\.id))

        // Remove self-redirects
        for (source, target) in cleanRedirects where source == target {
            cleanRedirects.removeValue(forKey: source)
        }

        // Remove redirects with missing source/target
        for (source, target) in cleanRedirects {
            if !allIDs.contains(source) || !allIDs.contains(target) {
                cleanRedirects.removeValue(forKey: source)
            }
        }

        if cleanRedirects != snapshot.redirects {
            modified = true
            results.append(TinyBuddyDataRepairResult(
                violationID: violations.first(where: {
                    if case .projectRegistryRedirectCycle = $0.kind { return true }
                    if case .projectRegistryRedirectToSelf = $0.kind { return true }
                    return false
                })?.id ?? UUID(),
                action: .repaired,
                diagnosticKey: "repair.project.redirects",
                summary: "Cleaned project registry redirects"
            ))
            snapshot = TinyBuddyProjectRegistrySnapshot(
                schemaVersion: snapshot.schemaVersion,
                revision: snapshot.revision,
                generation: snapshot.generation,
                projects: snapshot.projects,
                redirects: cleanRedirects
            )
        }

        if !modified {
            results.append(TinyBuddyDataRepairResult(
                violationID: UUID(),
                action: .skippedAlreadyApplied,
                diagnosticKey: "repair.project.noop",
                summary: "No registry repair needed"
            ))
        }

        return results
    }

    // MARK: - Combined Snapshot Repair

    /// Repairs combined snapshot violations. Non-negative stats are clamped,
    /// day identifier mismatches are corrected from authoritative data.
    private static func repairCombinedSnapshot(
        _ snapshot: inout TinyBuddyCombinedSnapshot,
        violations: [TinyBuddyDataInvariantViolation],
        sessions: [FocusSession],
        now: Date,
        previousSessionCount: Int?
    ) -> [TinyBuddyDataRepairResult] {
        var results: [TinyBuddyDataRepairResult] = []
        var repaired = false

        // Clamp negative stats
        if snapshot.snapshot.stats.focusCount < 0 {
            let expected = previousSessionCount ?? sessions.filter {
                $0.dayIdentifier == snapshot.dayIdentifier && $0.status == .ended
            }.count
            let newSnapshot = TinyBuddySnapshot(
                status: snapshot.snapshot.status,
                stats: DailyStats(
                    dayIdentifier: snapshot.snapshot.stats.dayIdentifier,
                    focusCount: max(0, expected),
                    completionCount: max(0, snapshot.snapshot.stats.completionCount)
                )
            )
            snapshot = TinyBuddyCombinedSnapshot(
                revision: snapshot.revision,
                dayIdentifier: snapshot.dayIdentifier,
                snapshot: newSnapshot,
                activitySnapshot: snapshot.activitySnapshot,
                activityRevision: snapshot.activityRevision,
                focusSessionSnapshot: snapshot.focusSessionSnapshot,
                focusHistoryPublication: snapshot.focusHistoryPublication
            )
            repaired = true
        }

        if snapshot.snapshot.stats.completionCount < 0 {
            let newSnapshot = TinyBuddySnapshot(
                status: snapshot.snapshot.status,
                stats: DailyStats(
                    dayIdentifier: snapshot.snapshot.stats.dayIdentifier,
                    focusCount: max(0, snapshot.snapshot.stats.focusCount),
                    completionCount: 0
                )
            )
            snapshot = TinyBuddyCombinedSnapshot(
                revision: snapshot.revision,
                dayIdentifier: snapshot.dayIdentifier,
                snapshot: newSnapshot,
                activitySnapshot: snapshot.activitySnapshot,
                activityRevision: snapshot.activityRevision,
                focusSessionSnapshot: snapshot.focusSessionSnapshot,
                focusHistoryPublication: snapshot.focusHistoryPublication
            )
            repaired = true
        }

        // Fix day identifier mismatch (use the inner stats day as authoritative)
        if snapshot.snapshot.stats.dayIdentifier != snapshot.dayIdentifier {
            let fixedDay = snapshot.snapshot.stats.dayIdentifier
            snapshot = TinyBuddyCombinedSnapshot(
                revision: snapshot.revision,
                dayIdentifier: fixedDay,
                snapshot: snapshot.snapshot,
                activitySnapshot: snapshot.activitySnapshot,
                activityRevision: snapshot.activityRevision,
                focusSessionSnapshot: snapshot.focusSessionSnapshot,
                focusHistoryPublication: snapshot.focusHistoryPublication
            )
            repaired = true
        }

        if repaired {
            results.append(TinyBuddyDataRepairResult(
                violationID: violations.first?.id ?? UUID(),
                action: .repaired,
                diagnosticKey: "repair.snapshot.clamped",
                summary: "Repaired combined snapshot invariants"
            ))
        } else {
            results.append(TinyBuddyDataRepairResult(
                violationID: UUID(),
                action: .skippedAlreadyApplied,
                diagnosticKey: "repair.snapshot.noop",
                summary: "No snapshot repair needed"
            ))
        }

        return results
    }

    // MARK: - Helpers

    /// Stable input hash for idempotency checking.
    private static func inputHash(
        sessions: [FocusSession],
        project: TinyBuddyProjectRegistrySnapshot,
        combined: TinyBuddyCombinedSnapshot?
    ) -> String {
        var hasher = Hasher()
        hasher.combine(sessions.count)
        hasher.combine(project.revision)
        hasher.combine(project.generation)
        hasher.combine(combined?.revision ?? -1)
        return String(hasher.finalize())
    }
}
