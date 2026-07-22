import Foundation

/// Outcome of a single engine event after validation and attempted persistence.
public enum FocusSessionUpdateOutcome: Equatable, Sendable {
    /// State changed and was persisted successfully.
    case saved
    /// No state changed; call was a no‑op.
    case noChange
    /// Mutation would have violated invariants; request was rejected and state is unchanged.
    case rejectedInvalid
    /// Mutation succeeded in memory but could not be persisted; last valid state is retained.
    case persistenceFailed
}

// MARK: - Engine

/// Thread‑safe focus session engine.  All public methods are `nonisolated` and
/// serialised by an internal `NSLock`.  The engine is `@unchecked Sendable`
/// because the lock provides mutual exclusion; access from multiple actors
/// requires care.
public final class FocusSessionEngine: @unchecked Sendable {
    // MARK: Dependencies
    private let clock: FocusClock
    private let persisting: FocusSessionPersisting
    private let config: FocusSessionConfiguration
    private let dayProvider: (Date) -> String
    private let nextDayBoundaryProvider: (Date) -> Date?
    private let historyGoalMinutesProvider: () -> Int
    private let historyActiveProjectKeysProvider: ([FocusSession]) -> Set<String>?
    private let projectContextResolver: @Sendable (FocusProjectContext) -> FocusProjectContext
    private let ruleVersionProvider: () -> FocusSessionRuleVersion?

    // MARK: State (protected by lock)
    private var lock: NSLock = .init()
    private var sessions: [FocusSession] = []
    /// Local‑day identifier for *now*.
    private var currentDay: String = ""
    /// Pending cross‑project switch (brief interruption candidate).
    private var pendingSwitch: PendingSwitch?
    private var lastEditUndo: [FocusSession]?
    private var committedRevision: Int64 = 0
    private var confirmedRevision: Int64 = 0
    /// Monotonic revision stored with the session archive. Unlike the manual
    /// revision, it advances for every durable authority-record mutation.
    private var archiveRevision: Int64 = 0
    private var archiveHistoryCompleteness: FocusSessionArchiveCompleteness = .complete
    /// Evidence records keyed by session ID. Persisted atomically with the
    /// session archive. Generated deterministically by the evidence engine.
    private var evidenceBySessionID: [UUID: FocusSessionEvidence] = [:]
    /// Monotonic revision of the evidence archive.
    private var evidenceArchiveRevision: Int64 = 0
    /// The only in-process history cache. It is updated by session deltas only
    /// after the matching archive write succeeds.
    private var historyCache = FocusHistoryAggregationCache()
    /// A corrupt archive remains unknown/partial rather than becoming a false
    /// all-zero history after the next successful live session write.
    private var historySource = FocusHistorySource(health: .available)
    /// Set by the primary app bridge. Called only after a journal commit.
    public var committedSnapshotHandler: (@Sendable (FocusSessionDerivedSnapshot) -> Void)?
    /// Set by the primary app bridge. This covers automatic completed sessions
    /// as well as manual edits, while the legacy current-day handler above
    /// remains for compatibility with the review journal tests.
    public var committedHistorySnapshotHandler: (@Sendable (FocusHistoryPublication) -> Void)?

    private struct PendingSwitch: Equatable {
        let fromSessionId: UUID
        let awayStartedAt: Date
        let candidate: FocusProjectContext
    }

    /// Deduplicates commands by token. The same token can only produce one state change;
    /// repeated calls with the same token return `.noChange`.
    private var lastManualCommandToken: UUID?
    private var lastManualCommandOutcome: FocusSessionUpdateOutcome = .noChange

    // MARK: Init

    /// - Parameters:
    ///   - clock: Source of truth for `now`.
    ///   - persisting: Persistence layer (e.g. `MemoryStore` in tests).
    ///   - config: Tunable thresholds.
    ///   - dayIdentifier: Maps a `Date` to its local‑day identifier string.
    public init(
        clock: FocusClock,
        persisting: FocusSessionPersisting,
        config: FocusSessionConfiguration = FocusSessionConfiguration(),
        dayIdentifier: @escaping (Date) -> String,
        nextDayBoundary: @escaping (Date) -> Date? = { date in
            let calendar = Calendar.current
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        },
        historyGoalMinutes: @escaping () -> Int = {
            FocusGoalConfiguration.default.dailyFocusGoalMinutes
        },
        historyActiveProjectKeys: @escaping ([FocusSession]) -> Set<String>? = { _ in
            nil
        },
        projectContextResolver: @escaping @Sendable (FocusProjectContext) -> FocusProjectContext = { $0 },
        ruleVersionProvider: @escaping () -> FocusSessionRuleVersion? = {
            FocusSessionRuleVersion.current
        }
    ) {
        let loaded = Self.loadInitialArchive(from: persisting)
        self.clock = clock
        self.persisting = persisting
        self.config = config
        self.dayProvider = dayIdentifier
        self.nextDayBoundaryProvider = nextDayBoundary
        self.historyGoalMinutesProvider = historyGoalMinutes
        self.historyActiveProjectKeysProvider = historyActiveProjectKeys
        self.projectContextResolver = projectContextResolver
        self.ruleVersionProvider = ruleVersionProvider
        let now = clock.now
        self.currentDay = dayProvider(now)
        self.sessions = loaded.sessions
        self.archiveRevision = loaded.revision
        self.archiveHistoryCompleteness = loaded.historyCompleteness
        self.historySource = loaded.source
        // Regenerate evidence if not present in the archive (backward compat
        // with v1 archives or stores like MemoryStore that don't archive evidence).
        var evidence = loaded.evidence
        if evidence.isEmpty {
            for session in loaded.sessions where session.decisionEvents?.isEmpty == false {
                let sessionEvents = session.decisionEvents ?? []
                let attributedViaGit = deriveAttributedViaGitActivity(from: session, events: sessionEvents)
                let redactedID = stableIdentifier(from: session.project.key)
                let input = FocusSessionEvidenceInput(
                    session: session,
                    attributedViaForegroundApp: !attributedViaGit,
                    attributedViaGitActivity: attributedViaGit,
                    redactedForegroundAppID: attributedViaGit ? nil : redactedID,
                    redactedRepoIdentifier: attributedViaGit ? redactedID : nil
                )
                if let ev = FocusSessionEvidenceEngine.generateEvidence(for: input) {
                    evidence[ev.sessionID] = ev
                }
            }
        }
        self.evidenceBySessionID = evidence
        self.evidenceArchiveRevision = loaded.revision
        self.historyCache = FocusHistoryAggregationCache(
            sessions: loaded.sessions,
            projectResolver: projectContextResolver
        )
        self.confirmedRevision = sessions.compactMap(\.manualRevision).max() ?? 0
        if reconcileOnLoad(now: now) {
            // A crash-recovered session must remain closed in memory even when
            // the immediate repair write fails. Reverting it to `beforeReconcile`
            // would let the first post-restart activity resume across the
            // offline interval and incorrectly count that gap. The unchanged
            // on-disk archive remains the recovery source; a later successful
            // mutation atomically persists this already-closed authority row.
            _ = persistAfterReconcile()
            historyCache = FocusHistoryAggregationCache(
                sessions: sessions,
                projectResolver: projectContextResolver
            )
        }
    }

    // MARK: - Public API

    /// User explicitly interacted with a project (keyboard / mouse / git activity).
    /// - `project == nil` means generic user input not attributable to any project.
    /// - During a manual session, automatic activity cannot switch projects or end
    ///   the session. Only un-pause (resume) of the same project is allowed.
    @discardableResult
    public func userActivity(
        in project: FocusProjectContext?,
        at date: Date,
        reason: FocusSessionDecisionReason = .userActivity
    ) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            // If a manual session is active, auto activity must not switch projects
            // or create parallel records. Only resume-if-paused is permitted.
            if let manualIdx = sessions.firstIndex(where: { $0.isOpen && $0.mode == .manual }) {
                if sessions[manualIdx].status == .paused {
                    resumeSession(at: manualIdx, at: when, reason: reason, into: &sessions)
                }
                sessions[manualIdx].lastUserActivityAt = when
                sessions[manualIdx].lastStateChangeAt = when
                return
            }

            guard let p = project else {
                handleGenericActivity(sessions: &sessions, when: when, reason: reason)
                return
            }
            guard let idx = sessions.firstIndex(where: \.isOpen) else {
                startSession(in: p, at: when, reason: reason, into: &sessions)
                return
            }
            let cur = sessions[idx]
            if cur.project == p {
                sameProjectActivity(idx: idx, sessions: &sessions, when: when, reason: reason)
            } else {
                differentProjectActivity(
                    idx: idx,
                    sessions: &sessions,
                    candidate: p,
                    when: when,
                    reason: reason
                )
            }
        }
    }

    /// The foreground app changed.  This only sets up a pending switch; a real
    /// session only begins when user activity is confirmed in the new project.
    /// During a manual session, foreground changes are ignored.
    @discardableResult
    public func foregroundProjectChanged(to project: FocusProjectContext?, at date: Date) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            // Block auto project switching during manual sessions.
            guard !sessions.contains(where: { $0.isOpen && $0.mode == .manual }) else { return }
            guard let p = project else { return }
            guard let idx = sessions.firstIndex(where: \.isOpen) else { return }
            let cur = sessions[idx]
            guard cur.project != p else { return }
            handleProjectArrival(sessions: &sessions, candidate: p, when: when)
        }
    }

    /// User idle detected (no input for `idleThreshold`).
    /// During a manual session, idle does not auto-pause — the user controls pause explicitly.
    @discardableResult
    public func idleDetected(at date: Date) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            guard let idx = sessions.firstIndex(where: \.isOpen),
                  sessions[idx].currentPauseStartedAt == nil else { return }
            // Manual sessions are not auto-paused by idle.
            guard sessions[idx].mode != .manual else { return }
            pauseSession(at: idx, at: when, reason: .idle, into: &sessions)
        }
    }

    @discardableResult
    public func lockScreen(at date: Date) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            guard let idx = sessions.firstIndex(where: \.isOpen) else {
                pendingSwitch = nil
                return
            }
            if sessions[idx].mode == .manual {
                // Manual sessions: pause on lock, user resumes later.
                if sessions[idx].currentPauseStartedAt == nil {
                    pauseSession(at: idx, at: when, reason: .lockScreen, into: &sessions)
                }
            } else {
                endSession(at: idx, endedAt: when, reason: .lockScreen, into: &sessions)
            }
            pendingSwitch = nil
        }
    }

    @discardableResult
    public func unlock(at date: Date) -> FocusSessionUpdateOutcome {
        _ = clampToNow(date)
        return apply { sessions in
            pendingSwitch = nil
        }
    }

    @discardableResult
    public func systemSleep(at date: Date) -> FocusSessionUpdateOutcome {
        finalizeOpen(at: date, reason: .systemSleep)
    }

    @discardableResult
    public func systemWake(at date: Date) -> FocusSessionUpdateOutcome {
        unlock(at: date)
    }

    /// Called when the wall‑clock time has jumped (manual change, NTP, DST, day boundary).
    @discardableResult
    public func timeChanged(at date: Date, dayIdentifier newDay: String) -> FocusSessionUpdateOutcome {
        let previousDay = currentDayIdentifier
        let when = clampToNow(date)
        let outcome = apply { sessions in
            guard newDay != currentDay else { return }
            // Day rolled: finalise any open session at its last known event (no backfill).
            if let idx = sessions.firstIndex(where: \.isOpen) {
                let lastKnown = sessions[idx].lastStateChangeAt
                endSession(
                    at: idx,
                    endedAt: min(lastKnown, when),
                    reason: .dayBoundary,
                    into: &sessions
                )
            }
            pendingSwitch = nil
            currentDay = newDay
        }
        // A new day/week changes the visible report even when there was no
        // open session to close. This is event-driven, never a background poll.
        if previousDay != newDay, outcome != .saved {
            republishFocusHistory()
        }
        return outcome
    }

    @discardableResult
    public func appWillTerminate(at date: Date) -> FocusSessionUpdateOutcome {
        finalizeOpen(at: date, reason: .appTermination)
    }

    @discardableResult
    public func crash(at date: Date) -> FocusSessionUpdateOutcome {
        finalizeOpen(at: date, reason: .crashRecovery)
    }

    // MARK: - Manual Focus Control (public API)

    /// The current manual-control state, derived from sessions protected by the lock.
    public var manualControlState: ManualFocusControlState {
        lock.lock(); defer { lock.unlock() }
        guard let idx = sessions.firstIndex(where: { $0.isOpen && $0.mode == .manual }) else {
            return .idle
        }
        let session = sessions[idx]
        let now = clock.now
        switch session.status {
        case .active:
            return .focusing(
                project: session.project,
                startedAt: session.startedAt,
                activeDuration: session.activeDuration(now: now)
            )
        case .paused:
            return .paused(
                project: session.project,
                startedAt: session.startedAt,
                pausedAt: session.currentPauseStartedAt ?? session.lastStateChangeAt,
                activeDuration: session.activeDuration(now: now)
            )
        case .ended:
            return .idle
        }
    }

    /// Start a manual focus session for `project`. If an automatic session is already
    /// active, it will be ended at the manual start time. If a manual session is
    /// already active for the same project, this is an idempotent no-op. If a manual
    /// session is active for a different project, the old one ends and a new one starts.
    /// `commandToken` enables idempotent deduplication: repeated calls with the same
    /// token produce only one state change.
    @discardableResult
    public func startManualFocus(
        project: FocusProjectContext,
        at date: Date,
        commandToken: UUID? = nil
    ) -> FocusSessionUpdateOutcome {
        guard !project.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !project.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejectedInvalid
        }
        let when = clampToNow(date)
        return applyWithToken(commandToken) { sessions in
            // If a manual session already exists for the same project, this is a no-op resume.
            if let idx = sessions.firstIndex(where: { $0.isOpen && $0.mode == .manual }) {
                if sessions[idx].project == project {
                    // Same project: resume if paused, otherwise no-op.
                    if sessions[idx].status == .paused {
                        resumeSession(at: idx, at: when, reason: .userActivity, into: &sessions)
                    }
                    return
                }
                // Different project manual session: end it first.
                endSession(at: idx, endedAt: when, reason: .projectSwitch, into: &sessions)
            }
            // If an automatic session is active, end it so manual takes priority.
            if let idx = sessions.firstIndex(where: { $0.isOpen && $0.mode == .automatic }) {
                endSession(at: idx, endedAt: when, reason: .projectSwitch, into: &sessions)
            }
            // Clear any pending auto switch — manual is now in control.
            pendingSwitch = nil
            // Start the new manual session.
            let session = FocusSession(
                project: project,
                dayIdentifier: currentDay,
                startedAt: when,
                status: .active,
                lastUserActivityAt: when,
                lastStateChangeAt: when,
                decisionEvents: [FocusSessionDecisionEvent(
                    at: when,
                    kind: .started,
                    reason: .userActivity,
                    source: .userConfirmed
                )],
                mode: .manual,
                ruleVersion: ruleVersionProvider()
            )
            sessions.append(session)
        }
    }

    /// Pause the current manual focus session. No-op if no manual session is active.
    @discardableResult
    public func pauseManualFocus(
        at date: Date,
        commandToken: UUID? = nil
    ) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return applyWithToken(commandToken) { sessions in
            guard let idx = sessions.firstIndex(where: { $0.isOpen && $0.mode == .manual }),
                  sessions[idx].status == .active else { return }
            pauseSession(at: idx, at: when, reason: .userActivity, into: &sessions)
        }
    }

    /// Resume the current paused manual focus session. No-op if no manual session is paused.
    @discardableResult
    public func resumeManualFocus(
        at date: Date,
        commandToken: UUID? = nil
    ) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return applyWithToken(commandToken) { sessions in
            guard let idx = sessions.firstIndex(where: { $0.isOpen && $0.mode == .manual }),
                  sessions[idx].status == .paused else { return }
            resumeSession(at: idx, at: when, reason: .userActivity, into: &sessions)
        }
    }

    /// End the current manual focus session. No-op if no manual session is active.
    /// After ending, automatic detection starts fresh from the next activity boundary.
    @discardableResult
    public func endManualFocus(
        at date: Date,
        commandToken: UUID? = nil
    ) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return applyWithToken(commandToken) { sessions in
            guard let idx = sessions.firstIndex(where: { $0.isOpen && $0.mode == .manual }) else { return }
            endSession(at: idx, endedAt: when, reason: .userActivity, into: &sessions)
            // Clear all pending automatic state so auto-detection starts clean.
            pendingSwitch = nil
        }
    }

    // MARK: - Aggregates (read‑only, thread‑safe)

    public var allSessions: [FocusSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions
    }

    public var currentDayIdentifier: String {
        lock.lock(); defer { lock.unlock() }
        return currentDay
    }

    public func sessionsForDay(_ identifier: String) -> [FocusSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.filter { $0.dayIdentifier == identifier }
    }

    public func focusDurationToday(now: Date? = nil) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let n = now ?? clock.now
        return sessions.filter { $0.dayIdentifier == currentDay }
            .reduce(0) { $0 + $1.activeDuration(now: n) }
    }

    public func projectDurationsToday(now: Date? = nil) -> [String: TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        let n = now ?? clock.now
        var result: [String: TimeInterval] = [:]
        for s in sessions where s.dayIdentifier == currentDay {
            let project = s.decisionAuthority == .manualCorrection
                ? s.project
                : projectContextResolver(s.project)
            result[project.key, default: 0] += s.activeDuration(now: n)
        }
        return result
    }

    /// Rebuilds only the derived identity view after a registry transaction.
    /// Raw session rows stay immutable, which makes a project merge reversible;
    /// the registry redirect atomically controls which stable project receives
    /// every historical contribution.
    public func refreshProjectIdentityPresentation() {
        lock.lock()
        historyCache = FocusHistoryAggregationCache(
            sessions: sessions,
            projectResolver: projectContextResolver
        )
        let publication = makeFocusHistoryPublication()
        lock.unlock()
        if let publication {
            committedHistorySnapshotHandler?(publication)
        }
    }

    public var currentProject: FocusProjectContext? {
        lock.lock(); defer { lock.unlock() }
        return sessions.first(where: \.isOpen)?.project
    }

    /// Returns the evidence record for a specific session, if available.
    public func evidence(for sessionID: UUID) -> FocusSessionEvidence? {
        lock.lock(); defer { lock.unlock() }
        return evidenceBySessionID[sessionID]
    }

    /// Returns all evidence records currently held by the engine.
    public var allEvidence: [UUID: FocusSessionEvidence] {
        lock.lock(); defer { lock.unlock() }
        return evidenceBySessionID
    }

    public func derivedSnapshot(now: Date? = nil) -> FocusSessionDerivedSnapshot {
        lock.lock(); defer { lock.unlock() }
        return makeDerivedSnapshot(sessions: sessions, now: now ?? clock.now)
    }

    /// Returns the cache-backed, revision-bound history view. All consumers
    /// must publish/read this value rather than scanning raw sessions again.
    public func focusHistoryPublication() -> FocusHistoryPublication? {
        lock.lock(); defer { lock.unlock() }
        return makeFocusHistoryPublication()
    }

    /// Re-emits the existing cache when a user explicitly opens the report or
    /// changes the focus target. It performs no discovery or session scan.
    public func republishFocusHistory() {
        lock.lock()
        let publication = makeFocusHistoryPublication()
        lock.unlock()
        if let publication {
            committedHistorySnapshotHandler?(publication)
        }
    }

    /// Updates an ended session by stable identifier. Crossing local-day
    /// boundaries is represented as adjacent day-local sessions; the first
    /// segment retains the original ID so a retry can never target another row.
    public func editSession(
        id: UUID,
        project: FocusProjectContext? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) -> FocusSessionEditResult {
        edit { working in
            guard let index = working.firstIndex(where: { $0.id == id }) else { return .sessionNotFound }
            guard !working[index].isOpen else { return .sessionIsActive }
            let resolvedProject = project ?? working[index].project
            guard !resolvedProject.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !resolvedProject.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalidProject }
            let start = startedAt ?? working[index].startedAt
            guard let end = endedAt ?? working[index].endedAt, end > start else { return .invalidTimeRange }
            guard end <= clock.now + config.dayBoundaryTolerance else { return .futureTime }
            guard config.maxSessionSpan.map({ end.timeIntervalSince(start) <= $0 }) ?? true else {
                return .invalidTimeRange
            }
            var source = working[index]
            let projectChanged = resolvedProject != source.project
            let timeChanged = start != source.startedAt || end != source.endedAt
            guard projectChanged || timeChanged else { return .invalidTimeRange }
            if projectChanged {
                appendDecision(
                    to: &source,
                    at: clock.now,
                    kind: .projectChanged,
                    reason: .manualCorrection,
                    source: .manualCorrection
                )
            }
            if timeChanged {
                appendDecision(
                    to: &source,
                    at: clock.now,
                    kind: .corrected,
                    reason: .manualCorrection,
                    source: .manualCorrection
                )
            }
            var replacement = splitForDayBoundaries(
                source: source, project: resolvedProject, start: start, end: end
            )
            guard !replacement.isEmpty else { return .crossDayBoundaryUnavailable }
            for replacementIndex in replacement.indices {
                if replacement[replacementIndex].startedAt != working[index].startedAt {
                    appendDecision(
                        to: &replacement[replacementIndex],
                        at: replacement[replacementIndex].startedAt,
                        kind: .started,
                        reason: .manualCorrection,
                        source: .manualCorrection
                    )
                }
                if replacement[replacementIndex].endedAt != working[index].endedAt,
                   let segmentEnd = replacement[replacementIndex].endedAt {
                    appendDecision(
                        to: &replacement[replacementIndex],
                        at: segmentEnd,
                        kind: .ended,
                        reason: .manualCorrection,
                        source: .manualCorrection
                    )
                }
            }
            working.remove(at: index)
            working.append(contentsOf: replacement)
            return nil
        }
    }

    public func deleteSession(id: UUID) -> FocusSessionEditResult {
        edit { working in
            guard let index = working.firstIndex(where: { $0.id == id }) else { return .sessionNotFound }
            guard !working[index].isOpen else { return .sessionIsActive }
            working.remove(at: index)
            return nil
        }
    }

    /// Records an explicit user confirmation without changing measured time or
    /// project attribution. Automatic processing cannot mutate ended rows, and
    /// the durable authority marker remains visible after restart.
    public func confirmSession(id: UUID) -> FocusSessionEditResult {
        edit { working in
            guard let index = working.firstIndex(where: { $0.id == id }) else {
                return .sessionNotFound
            }
            guard !working[index].isOpen else { return .sessionIsActive }
            guard working[index].decisionAuthority != .manualCorrection,
                  working[index].decisionAuthority != .userConfirmed else {
                return .alreadyConfirmed
            }
            working[index].isManuallyConfirmed = true
            appendDecision(
                to: &working[index],
                at: clock.now,
                kind: .confirmed,
                reason: .manualConfirmation,
                source: .userConfirmed
            )
            return nil
        }
    }

    /// Merges two or more adjacent ended sessions. The earliest selected ID is
    /// retained as the stable identity of the resulting record.
    public func mergeSessions(ids: [UUID], project: FocusProjectContext? = nil) -> FocusSessionEditResult {
        let selected = Array(Set(ids))
        guard selected.count >= 2 else { return .rejected(.insufficientSessionsToMerge) }
        return edit { working in
            let matches = working.filter { selected.contains($0.id) }.sorted { $0.startedAt < $1.startedAt }
            guard matches.count == selected.count else { return .sessionNotFound }
            guard !matches.contains(where: \.isOpen) else { return .sessionIsActive }
            guard let first = matches.first, let last = matches.last, let end = last.endedAt else { return .invalidTimeRange }
            let resolvedProject = project ?? first.project
            guard !resolvedProject.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !resolvedProject.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalidProject }
            for pair in zip(matches, matches.dropFirst()) where pair.0.endedAt != pair.1.startedAt {
                return .invalidTimeRange
            }
            working.removeAll { selected.contains($0.id) }
            var base = FocusSession(
                id: first.id, project: resolvedProject, dayIdentifier: dayProvider(first.startedAt),
                startedAt: first.startedAt, endedAt: end, status: .ended,
                lastUserActivityAt: end, lastStateChangeAt: end,
                pausedTotal: min(first.pausedTotal, end.timeIntervalSince(first.startedAt)),
                isManuallyConfirmed: true,
                decisionEvents: mergedDecisionEvents(matches)
            )
            appendDecision(
                to: &base,
                at: clock.now,
                kind: .merged,
                reason: .manualMerge,
                source: .manualCorrection
            )
            let replacements = splitForDayBoundaries(source: base, project: resolvedProject, start: base.startedAt, end: end)
            guard !replacements.isEmpty else { return .crossDayBoundaryUnavailable }
            working.append(contentsOf: replacements)
            return nil
        }
    }

    public func splitSession(id: UUID, at boundary: Date) -> FocusSessionEditResult {
        edit { working in
            guard let index = working.firstIndex(where: { $0.id == id }) else { return .sessionNotFound }
            let source = working[index]
            guard !source.isOpen else { return .sessionIsActive }
            guard let end = source.endedAt, boundary > source.startedAt, boundary < end else { return .splitOutsideSession }
            var first = FocusSession(id: source.id, project: source.project, dayIdentifier: dayProvider(source.startedAt), startedAt: source.startedAt, endedAt: boundary, status: .ended, lastUserActivityAt: boundary, lastStateChangeAt: boundary, pausedTotal: min(source.pausedTotal, boundary.timeIntervalSince(source.startedAt)), isManuallyConfirmed: true, decisionEvents: source.decisionEvents?.filter { $0.at < boundary })
            var second = FocusSession(project: source.project, dayIdentifier: dayProvider(boundary), startedAt: boundary, endedAt: end, status: .ended, lastUserActivityAt: end, lastStateChangeAt: end, pausedTotal: 0, isManuallyConfirmed: true, decisionEvents: source.decisionEvents?.filter { $0.at >= boundary })
            appendDecision(to: &first, at: boundary, kind: .ended, reason: .manualSplit, source: .manualCorrection)
            appendDecision(to: &second, at: boundary, kind: .started, reason: .manualSplit, source: .manualCorrection)
            appendDecision(to: &first, at: clock.now, kind: .split, reason: .manualSplit, source: .manualCorrection)
            appendDecision(to: &second, at: clock.now, kind: .split, reason: .manualSplit, source: .manualCorrection)
            working.remove(at: index)
            working.append(contentsOf: splitForDayBoundaries(source: first, project: first.project, start: first.startedAt, end: boundary))
            working.append(contentsOf: splitForDayBoundaries(source: second, project: second.project, start: boundary, end: end))
            return nil
        }
    }

    public func undoLastEdit() -> FocusSessionEditResult {
        lock.lock()
        guard let previous = lastEditUndo else { lock.unlock(); return .rejected(.nothingToUndo) }
        guard confirmedRevision < Int64.max, archiveRevision < Int64.max else {
            lock.unlock()
            return .rejected(.persistenceFailed)
        }
        let nextRevision = confirmedRevision + 1
        let nextArchiveRevision = archiveRevision + 1
        var restored = previous
        for index in restored.indices where !restored[index].isOpen {
            restored[index].isManuallyConfirmed = true
            appendDecision(
                to: &restored[index],
                at: clock.now,
                kind: .undo,
                reason: .undo,
                source: .manualCorrection
            )
        }
        markConfirmedSessions(in: &restored, revision: nextRevision)
        let evidence = generateEvidenceForSessions(restored)
        guard saveSessions(restored, revision: nextArchiveRevision, evidence: evidence) else {
            lock.unlock()
            return .rejected(.persistenceFailed)
        }
        let update = historyCache.apply(historyChanges(from: sessions, to: restored))
        recordTrustedHistoryDays(update.affectedDayIdentifiers)
        sessions = restored
        evidenceBySessionID = evidence
        evidenceArchiveRevision += 1
        lastEditUndo = nil
        committedRevision += 1
        confirmedRevision = nextRevision
        archiveRevision = nextArchiveRevision
        let snapshot = makeDerivedSnapshot(sessions: restored, now: clock.now)
        let history = update.affectedDayIdentifiers.isEmpty
            ? nil
            : makeFocusHistoryPublication()
        lock.unlock()
        committedSnapshotHandler?(snapshot)
        if let history {
            committedHistorySnapshotHandler?(history)
        }
        return .saved(replacedSessionIDs: restored.map(\.id), snapshot: snapshot)
    }
}

// MARK: - Private

private extension FocusSessionEngine {
    // MARK: Apply / Validate

    @discardableResult
    func apply(_ mutation: (inout [FocusSession]) -> Void) -> FocusSessionUpdateOutcome {
        lock.lock()
        let previous = sessions
        var working = sessions
        mutation(&working)
        guard validate(working) else {
            lock.unlock()
            return .rejectedInvalid
        }
        guard working != previous else {
            lock.unlock()
            return .noChange
        }
        guard archiveRevision < Int64.max else {
            lock.unlock()
            return .persistenceFailed
        }
        let nextArchiveRevision = archiveRevision + 1
        let nextEvidenceRevision = evidenceArchiveRevision + 1
        let evidence = generateEvidenceForSessions(working)
        guard saveSessions(working, revision: nextArchiveRevision, evidence: evidence) else {
            // Retain the prior session archive and history cache together.
            lock.unlock()
            return .persistenceFailed
        }
        let update = historyCache.apply(historyChanges(from: previous, to: working))
        recordTrustedHistoryDays(update.affectedDayIdentifiers)
        sessions = working
        evidenceBySessionID = evidence
        evidenceArchiveRevision = nextEvidenceRevision
        archiveRevision = nextArchiveRevision
        committedRevision += 1
        let history = update.affectedDayIdentifiers.isEmpty
            ? nil
            : makeFocusHistoryPublication()
        lock.unlock()
        if let history {
            committedHistorySnapshotHandler?(history)
        }
        return .saved
    }

    /// Token-based deduplication wrapper. If a non-nil token matches the last
    /// executed command, returns `.noChange` without mutating state.
    @discardableResult
    func applyWithToken(_ token: UUID?, _ mutation: (inout [FocusSession]) -> Void) -> FocusSessionUpdateOutcome {
        lock.lock()
        if let token, token == lastManualCommandToken {
            lock.unlock()
            return .noChange
        }
        lock.unlock()
        let outcome = apply(mutation)
        lock.lock()
        if let token {
            lastManualCommandToken = token
            lastManualCommandOutcome = outcome
        }
        lock.unlock()
        return outcome
    }

    func validate(_ list: [FocusSession]) -> Bool {
        // Unique identifiers.
        let ids = list.map(\.id)
        guard Set(ids).count == ids.count else { return false }
        let decisionIDs = list.compactMap(\.decisionEvents).flatMap { $0 }.map(\.id)
        guard Set(decisionIDs).count == decisionIDs.count else { return false }

        // At most one open session.
        guard list.filter(\.isOpen).count <= 1 else { return false }

        // Individual field invariants.
        for s in list {
            // No future startedAt beyond tolerance.
            if s.startedAt > clock.now + config.dayBoundaryTolerance { return false }
            // end >= start.
            if let end = s.endedAt, end < s.startedAt { return false }
            if s.isOpen && s.isManuallyConfirmed { return false }
            if let events = s.decisionEvents,
               events.contains(where: { !$0.at.timeIntervalSinceReferenceDate.isFinite }) {
                return false
            }
            // activeDuration must be non‑negative.
            if s.activeDuration(now: clock.now) < 0 { return false }
        }

        // Non‑overlapping sessions (contiguous allowed).
        let sorted = list.sorted { $0.startedAt < $1.startedAt }
        for i in 0 ..< sorted.count where i + 1 < sorted.count {
            let thisEnd = sorted[i].endedAt ?? Date.distantFuture
            if sorted[i + 1].startedAt < thisEnd { return false }
        }
        return true
    }

    func edit(_ mutation: (inout [FocusSession]) -> FocusSessionEditError?) -> FocusSessionEditResult {
        lock.lock()
        let previous = sessions
        var working = sessions
        if let error = mutation(&working) { lock.unlock(); return .rejected(error) }
        guard confirmedRevision < Int64.max, archiveRevision < Int64.max else {
            lock.unlock()
            return .rejected(.persistenceFailed)
        }
        let nextRevision = confirmedRevision + 1
        let nextArchiveRevision = archiveRevision + 1
        markConfirmedSessions(in: &working, revision: nextRevision)
        guard validate(working) else { lock.unlock(); return .rejected(.overlappingSession) }
        guard working != previous else { lock.unlock(); return .rejected(.invalidTimeRange) }
        let evidence = generateEvidenceForSessions(working)
        guard saveSessions(working, revision: nextArchiveRevision, evidence: evidence) else {
            lock.unlock()
            return .rejected(.persistenceFailed)
        }
        let update = historyCache.apply(historyChanges(from: previous, to: working))
        recordTrustedHistoryDays(update.affectedDayIdentifiers)
        sessions = working
        evidenceBySessionID = evidence
        evidenceArchiveRevision += 1
        lastEditUndo = previous
        pendingSwitch = nil
        committedRevision += 1
        confirmedRevision = nextRevision
        archiveRevision = nextArchiveRevision
        let snapshot = makeDerivedSnapshot(sessions: working, now: clock.now)
        let history = update.affectedDayIdentifiers.isEmpty
            ? nil
            : makeFocusHistoryPublication()
        lock.unlock()
        committedSnapshotHandler?(snapshot)
        if let history {
            committedHistorySnapshotHandler?(history)
        }
        return .saved(replacedSessionIDs: working.map(\.id), snapshot: snapshot)
    }

    func makeDerivedSnapshot(sessions: [FocusSession], now: Date) -> FocusSessionDerivedSnapshot {
        let todays = sessions.filter { $0.dayIdentifier == currentDay }
        var projects: [String: TimeInterval] = [:]
        for session in todays {
            // The shared presentation slice must never expose canonical project
            // identities (which may be filesystem paths). Display labels are
            // the only project grouping persisted outside the session journal.
            let label = session.project.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            projects[label, default: 0] += session.activeDuration(now: now)
        }
        return FocusSessionDerivedSnapshot(revision: confirmedRevision, dayIdentifier: currentDay, focusDuration: todays.reduce(0) { $0 + $1.activeDuration(now: now) }, projectDurations: projects, completedSessionCount: todays.filter { $0.status == .ended }.count)
    }

    func makeFocusHistoryPublication() -> FocusHistoryPublication? {
        guard TinyBuddyTimeContext.isValidDayIdentifier(currentDay) else {
            return nil
        }
        let goalMinutes = max(1, historyGoalMinutesProvider())
        let query = FocusHistoryQuery(
            referenceDayIdentifier: currentDay,
            source: historySource,
            activeProjectKeys: historyActiveProjectKeysProvider(sessions),
            defaultDailyGoalMinutes: goalMinutes
        )
        guard let snapshot = try? historyCache.snapshot(for: query) else {
            return nil
        }
        return FocusHistoryPublication(revision: archiveRevision, snapshot: snapshot)
    }

    static func loadInitialArchive(
        from persisting: FocusSessionPersisting
    ) -> (
        sessions: [FocusSession],
        revision: Int64,
        source: FocusHistorySource,
        historyCompleteness: FocusSessionArchiveCompleteness,
        evidence: [UUID: FocusSessionEvidence]
    ) {
        guard let archiveStore = persisting as? any FocusSessionArchivePersisting else {
            let sessions = persisting.load() ?? []
            guard FocusSessionArchive(sessions: sessions).isSemanticallyValid else {
                return (
                    sessions: [],
                    revision: 0,
                    source: FocusHistorySource(health: .unavailable),
                    historyCompleteness: .partialRecovery,
                    evidence: [:]
                )
            }
            return (
                sessions: sessions,
                revision: 0,
                source: FocusHistorySource(health: .available),
                historyCompleteness: .complete,
                evidence: [:]
            )
        }

        let result = archiveStore.loadArchive()
        if let archive = result.archive, archive.isSemanticallyValid {
            let evidence = archive.evidenceArchive?.evidenceBySessionID ?? [:]
            return (
                sessions: archive.sessions,
                revision: archive.revision,
                source: FocusHistorySource(
                    health: archive.historyCompleteness == .complete ? .available : .partial
                ),
                historyCompleteness: archive.historyCompleteness,
                evidence: evidence
            )
        }
        switch result.health {
        case .corrupt:
            return (
                sessions: [],
                revision: 0,
                source: FocusHistorySource(health: .unavailable),
                historyCompleteness: .partialRecovery,
                evidence: [:]
            )
        case .missing, .available, .recoveredFromBackup:
            return (
                sessions: [],
                revision: 0,
                source: FocusHistorySource(health: .available),
                historyCompleteness: .complete,
                evidence: [:]
            )
        }
    }

    func saveSessions(_ sessions: [FocusSession], revision: Int64, evidence: [UUID: FocusSessionEvidence]) -> Bool {
        guard revision >= 0 else { return false }
        if let archiveStore = persisting as? any FocusSessionArchivePersisting {
            let evidenceArchive = evidence.isEmpty ? nil : FocusSessionEvidenceArchive(
                revision: evidenceArchiveRevision,
                evidenceBySessionID: evidence
            )
            return archiveStore.saveArchive(
                FocusSessionArchive(
                    revision: revision,
                    sessions: sessions,
                    historyCompleteness: historySource.health == .available
                        ? archiveHistoryCompleteness
                        : .partialRecovery,
                    evidenceArchive: evidenceArchive
                )
            )
        }
        return persisting.save(sessions)
    }

    /// Generates deterministic evidence for all sessions that have decision events.
    /// This is called after every mutation to keep evidence in sync.
    ///
    /// Attribution context is derived from the session itself:
    ///   - If the session has any `.gitActivity` decision event, or the project key
    ///     is a repository path (contains "/"), it is attributed via Git activity.
    ///   - Manual sessions are never Git-attributed.
    ///   - Otherwise, it is attributed via foreground app detection.
    /// This ensures evidence always reflects the real attribution source, even when
    /// the coordinator's attribution policy (code editor + recent Git → Git project)
    /// is not explicitly recorded on individual decision events.
    func generateEvidenceForSessions(_ sessions: [FocusSession]) -> [UUID: FocusSessionEvidence] {
        var result: [UUID: FocusSessionEvidence] = [:]
        for session in sessions {
            guard let events = session.decisionEvents, !events.isEmpty else {
                // Legacy sessions without decision events get no evidence.
                continue
            }

            // Derive attribution context from session properties.
            let attributedViaGitActivity = deriveAttributedViaGitActivity(from: session, events: events)
            let attributedViaForegroundApp = !attributedViaGitActivity
            let redactedID = stableIdentifier(from: session.project.key)

            let input = FocusSessionEvidenceInput(
                session: session,
                attributedViaForegroundApp: attributedViaForegroundApp,
                attributedViaGitActivity: attributedViaGitActivity,
                redactedForegroundAppID: attributedViaForegroundApp ? redactedID : nil,
                redactedRepoIdentifier: attributedViaGitActivity ? redactedID : nil
            )
            if let evidence = FocusSessionEvidenceEngine.generateEvidence(for: input) {
                result[evidence.sessionID] = evidence
            }
        }
        return result
    }

    /// Derives whether a session was attributed via Git activity.
    /// - Manual sessions are never Git-attributed.
    /// - If any decision event has reason `.gitActivity`, the session is Git-attributed.
    /// - Otherwise, a project key containing "/" is a repository path (Git);
    ///   a key with only "." (bundle ID) is a foreground app.
    private func deriveAttributedViaGitActivity(
        from session: FocusSession,
        events: [FocusSessionDecisionEvent]
    ) -> Bool {
        // Manual sessions are always user-chosen, never Git-attributed.
        if session.mode == .manual { return false }
        // Explicit Git activity in the decision trail.
        if events.contains(where: { $0.reason == .gitActivity }) { return true }
        // Infer from project key pattern: repo paths contain "/".
        if session.project.key.contains("/") { return true }
        return false
    }

    func historyChanges(
        from previous: [FocusSession],
        to current: [FocusSession]
    ) -> [FocusHistorySessionChange] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return Set(previousByID.keys)
            .union(currentByID.keys)
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { id in
                let old = previousByID[id]
                let new = currentByID[id]
                guard old != new else { return nil }
                return FocusHistorySessionChange(previous: old, current: new)
            }
    }

    func recordTrustedHistoryDays(_ affectedDays: Set<String>) {
        guard !affectedDays.isEmpty else { return }
        switch historySource.health {
        case .available:
            return
        case .partial:
            historySource = FocusHistorySource(
                health: .partial,
                trustedDayIdentifiers: historySource.trustedDayIdentifiers.union(affectedDays)
            )
        case .unavailable:
            historySource = FocusHistorySource(
                health: .partial,
                trustedDayIdentifiers: affectedDays
            )
        }
    }

    func markConfirmedSessions(in sessions: inout [FocusSession], revision: Int64) {
        for index in sessions.indices where sessions[index].isManuallyConfirmed {
            sessions[index].manualRevision = revision
        }
    }

    func splitForDayBoundaries(source: FocusSession, project: FocusProjectContext, start: Date, end: Date) -> [FocusSession] {
        guard end > start else { return [] }
        var result: [FocusSession] = []
        var cursor = start
        var keepsOriginalID = true
        while cursor < end {
            guard let nextDay = nextDayBoundaryProvider(cursor) else { return [] }
            let segmentEnd = min(end, nextDay)
            guard segmentEnd > cursor else { return [] }
            let gross = end.timeIntervalSince(start)
            let segmentGross = segmentEnd.timeIntervalSince(cursor)
            let excluded = gross > 0 ? source.pausedTotal * segmentGross / gross : 0
            let segmentEvents = source.decisionEvents?.compactMap { event -> FocusSessionDecisionEvent? in
                let isLifecycleEvent = event.source == .automatic
                let isInsideSegment = event.at >= cursor
                    && (segmentEnd == end ? event.at <= segmentEnd : event.at < segmentEnd)
                guard !isLifecycleEvent || isInsideSegment else { return nil }
                guard !keepsOriginalID else { return event }
                return FocusSessionDecisionEvent(
                    at: event.at,
                    kind: event.kind,
                    reason: event.reason,
                    source: event.source
                )
            }
            result.append(FocusSession(id: keepsOriginalID ? source.id : UUID(), project: project, dayIdentifier: dayProvider(cursor), startedAt: cursor, endedAt: segmentEnd, status: .ended, lastUserActivityAt: segmentEnd, lastStateChangeAt: segmentEnd, pausedTotal: min(excluded, segmentGross), isManuallyConfirmed: true, decisionEvents: segmentEvents))
            keepsOriginalID = false
            cursor = segmentEnd
        }
        return result
    }

    // MARK: Helpers

    func clampToNow(_ date: Date) -> Date {
        min(date, clock.now)
    }

    func startSession(
        in project: FocusProjectContext,
        at when: Date,
        reason: FocusSessionDecisionReason,
        into sessions: inout [FocusSession],
        mode: FocusMode = .automatic
    ) {
        let session = FocusSession(
            project: project,
            dayIdentifier: currentDay,
            startedAt: when,
            status: .active,
            lastUserActivityAt: when,
            lastStateChangeAt: when,
            decisionEvents: [FocusSessionDecisionEvent(
                at: when,
                kind: .started,
                reason: reason,
                source: mode == .manual ? .userConfirmed : .automatic
            )],
            mode: mode,
            ruleVersion: ruleVersionProvider()
        )
        sessions.append(session)
    }

    func endSession(
        at index: Int,
        endedAt: Date,
        reason: FocusSessionDecisionReason,
        into sessions: inout [FocusSession]
    ) {
        guard index < sessions.count else { return }
        // Close any open pause first.
        if let pause = sessions[index].currentPauseStartedAt {
            sessions[index].pausedTotal += max(0, endedAt.timeIntervalSince(pause))
            sessions[index].currentPauseStartedAt = nil
        }
        sessions[index].endedAt = endedAt
        sessions[index].status = .ended
        sessions[index].lastStateChangeAt = endedAt
        appendDecision(
            to: &sessions[index],
            at: endedAt,
            kind: .ended,
            reason: reason,
            source: .automatic
        )
    }

    func pauseSession(
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
        appendDecision(
            to: &sessions[index],
            at: when,
            kind: .paused,
            reason: reason,
            source: .automatic
        )
    }

    func resumeSession(
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
            appendDecision(
                to: &sessions[index],
                at: when,
                kind: .resumed,
                reason: reason,
                source: .automatic
            )
        }
    }

    func appendDecision(
        to session: inout FocusSession,
        at date: Date,
        kind: FocusSessionDecisionKind,
        reason: FocusSessionDecisionReason,
        source: FocusSessionDecisionSource
    ) {
        var events = session.decisionEvents ?? []
        events.append(FocusSessionDecisionEvent(
            at: date,
            kind: kind,
            reason: reason,
            source: source
        ))
        session.decisionEvents = events
    }

    func mergedDecisionEvents(_ sessions: [FocusSession]) -> [FocusSessionDecisionEvent]? {
        let knownEvents = sessions.compactMap(\.decisionEvents).flatMap { $0 }
        guard !knownEvents.isEmpty else { return nil }
        return Dictionary(grouping: knownEvents, by: \.id)
            .compactMap { $0.value.first }
            .sorted {
                if $0.at != $1.at { return $0.at < $1.at }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    // MARK: Event logic

    func handleGenericActivity(
        sessions: inout [FocusSession],
        when: Date,
        reason: FocusSessionDecisionReason
    ) {
        guard let idx = sessions.firstIndex(where: \.isOpen) else { return }
        sessions[idx].lastUserActivityAt = when
        resumeSession(at: idx, at: when, reason: reason, into: &sessions)
    }

    func sameProjectActivity(
        idx: Int,
        sessions: inout [FocusSession],
        when: Date,
        reason: FocusSessionDecisionReason
    ) {
        resumeSession(at: idx, at: when, reason: reason, into: &sessions)
        sessions[idx].lastUserActivityAt = when
        sessions[idx].lastStateChangeAt = when
        // User returned to the original project — brief interruption merge.
        pendingSwitch = nil
    }

    func differentProjectActivity(
        idx: Int,
        sessions: inout [FocusSession],
        candidate: FocusProjectContext,
        when: Date,
        reason: FocusSessionDecisionReason
    ) {
        // User activity in a project different from the current session is a real
        // focus switch — end the current session and start the new one immediately.
        // If a pending switch exists, use its away timestamp as the boundary
        // so the away gap is never double-counted nor overlapped.
        let startAt: Date
        if let pending = pendingSwitch {
            startAt = pending.awayStartedAt
            pendingSwitch = nil
        } else {
            startAt = when
        }
        endSession(at: idx, endedAt: startAt, reason: .projectSwitch, into: &sessions)
        startSession(in: candidate, at: startAt, reason: reason, into: &sessions)
    }

    func handleProjectArrival(sessions: inout [FocusSession], candidate: FocusProjectContext, when: Date) {
        guard let idx = sessions.firstIndex(where: \.isOpen) else {
            startSession(in: candidate, at: when, reason: .projectSwitch, into: &sessions)
            return
        }
        let cur = sessions[idx]
        guard cur.project != candidate else { return }

        pendingSwitch = PendingSwitch(
            fromSessionId: cur.id,
            awayStartedAt: when,
            candidate: candidate
        )
        pauseSession(at: idx, at: when, reason: .projectSwitch, into: &sessions)
    }

    func commitPendingSwitch(sessions: inout [FocusSession], when: Date) {
        guard let pending = pendingSwitch else { return }
        if let idx = sessions.firstIndex(where: { $0.id == pending.fromSessionId && $0.isOpen }) {
            endSession(at: idx, endedAt: pending.awayStartedAt, reason: .projectSwitch, into: &sessions)
        }
        startSession(in: pending.candidate, at: pending.awayStartedAt, reason: .projectSwitch, into: &sessions)
        pendingSwitch = nil
    }

    func finalizeOpen(
        at date: Date,
        reason: FocusSessionDecisionReason
    ) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            if let idx = sessions.firstIndex(where: \.isOpen) {
                endSession(at: idx, endedAt: when, reason: reason, into: &sessions)
            }
            pendingSwitch = nil
        }
    }

    // MARK: Load / reconcile

    func reconcileOnLoad(now: Date) -> Bool {
        var changed = false
        // Any session left open by a crash must not backfill offline time.
        for i in 0 ..< sessions.count where sessions[i].isOpen {
            let end = min(sessions[i].lastStateChangeAt, now)
            if let pause = sessions[i].currentPauseStartedAt {
                sessions[i].pausedTotal += max(0, end.timeIntervalSince(pause))
                sessions[i].currentPauseStartedAt = nil
            }
            sessions[i].endedAt = end
            sessions[i].status = .ended
            sessions[i].lastStateChangeAt = end
            appendDecision(
                to: &sessions[i],
                at: end,
                kind: .ended,
                reason: .crashRecovery,
                source: .automatic
            )
            changed = true
        }
        currentDay = dayProvider(now)
        return changed
    }

    func persistAfterReconcile() -> Bool {
        guard !sessions.isEmpty else { return true }
        guard archiveRevision < Int64.max else { return false }
        let nextRevision = archiveRevision + 1
        let evidence = generateEvidenceForSessions(sessions)
        guard saveSessions(sessions, revision: nextRevision, evidence: evidence) else { return false }
        evidenceBySessionID = evidence
        evidenceArchiveRevision += 1
        archiveRevision = nextRevision
        committedRevision += 1
        return true
    }
}
