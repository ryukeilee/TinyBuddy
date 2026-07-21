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
    /// Set by the primary app bridge. Called only after a journal commit.
    public var committedSnapshotHandler: (@Sendable (FocusSessionDerivedSnapshot) -> Void)?

    private struct PendingSwitch: Equatable {
        let fromSessionId: UUID
        let awayStartedAt: Date
        let candidate: FocusProjectContext
    }

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
        }
    ) {
        self.clock = clock
        self.persisting = persisting
        self.config = config
        self.dayProvider = dayIdentifier
        self.nextDayBoundaryProvider = nextDayBoundary
        let now = clock.now
        self.currentDay = dayProvider(now)
        self.sessions = persisting.load() ?? []
        self.confirmedRevision = sessions.compactMap(\.manualRevision).max() ?? 0
        reconcileOnLoad(now: now)
        persistAfterReconcile()
    }

    // MARK: - Public API

    /// User explicitly interacted with a project (keyboard / mouse / git activity).
    /// - `project == nil` means generic user input not attributable to any project.
    @discardableResult
    public func userActivity(in project: FocusProjectContext?, at date: Date) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            guard let p = project else {
                handleGenericActivity(sessions: &sessions, when: when)
                return
            }
            guard let idx = sessions.firstIndex(where: \.isOpen) else {
                startSession(in: p, at: when, into: &sessions)
                return
            }
            let cur = sessions[idx]
            if cur.project == p {
                sameProjectActivity(idx: idx, sessions: &sessions, when: when)
            } else {
                differentProjectActivity(idx: idx, sessions: &sessions, candidate: p, when: when)
            }
        }
    }

    /// The foreground app changed.  This only sets up a pending switch; a real
    /// session only begins when user activity is confirmed in the new project.
    @discardableResult
    public func foregroundProjectChanged(to project: FocusProjectContext?, at date: Date) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            guard let p = project else { return }
            guard let idx = sessions.firstIndex(where: \.isOpen) else { return }
            let cur = sessions[idx]
            guard cur.project != p else { return }
            handleProjectArrival(sessions: &sessions, candidate: p, when: when)
        }
    }

    /// User idle detected (no input for `idleThreshold`).
    @discardableResult
    public func idleDetected(at date: Date) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            guard let idx = sessions.firstIndex(where: \.isOpen),
                  sessions[idx].currentPauseStartedAt == nil else { return }
            pauseSession(at: idx, at: when, into: &sessions)
        }
    }

    @discardableResult
    public func lockScreen(at date: Date) -> FocusSessionUpdateOutcome {
        finalizeOpen(at: date)
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
        finalizeOpen(at: date)
    }

    @discardableResult
    public func systemWake(at date: Date) -> FocusSessionUpdateOutcome {
        unlock(at: date)
    }

    /// Called when the wall‑clock time has jumped (manual change, NTP, DST, day boundary).
    @discardableResult
    public func timeChanged(at date: Date, dayIdentifier newDay: String) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            guard newDay != currentDay else { return }
            // Day rolled: finalise any open session at its last known event (no backfill).
            if let idx = sessions.firstIndex(where: \.isOpen) {
                let lastKnown = sessions[idx].lastStateChangeAt
                endSession(at: idx, endedAt: min(lastKnown, when), into: &sessions)
            }
            pendingSwitch = nil
            currentDay = newDay
        }
    }

    @discardableResult
    public func appWillTerminate(at date: Date) -> FocusSessionUpdateOutcome {
        finalizeOpen(at: date)
    }

    @discardableResult
    public func crash(at date: Date) -> FocusSessionUpdateOutcome {
        finalizeOpen(at: date)
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
            result[s.project.key, default: 0] += s.activeDuration(now: n)
        }
        return result
    }

    public var currentProject: FocusProjectContext? {
        lock.lock(); defer { lock.unlock() }
        return sessions.first(where: \.isOpen)?.project
    }

    public func derivedSnapshot(now: Date? = nil) -> FocusSessionDerivedSnapshot {
        lock.lock(); defer { lock.unlock() }
        return makeDerivedSnapshot(sessions: sessions, now: now ?? clock.now)
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
            let replacement = splitForDayBoundaries(
                source: working[index], project: resolvedProject, start: start, end: end
            )
            guard !replacement.isEmpty else { return .crossDayBoundaryUnavailable }
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
            let base = FocusSession(
                id: first.id, project: resolvedProject, dayIdentifier: dayProvider(first.startedAt),
                startedAt: first.startedAt, endedAt: end, status: .ended,
                lastUserActivityAt: end, lastStateChangeAt: end,
                pausedTotal: min(first.pausedTotal, end.timeIntervalSince(first.startedAt)),
                isManuallyConfirmed: true
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
            let first = FocusSession(id: source.id, project: source.project, dayIdentifier: dayProvider(source.startedAt), startedAt: source.startedAt, endedAt: boundary, status: .ended, lastUserActivityAt: boundary, lastStateChangeAt: boundary, pausedTotal: min(source.pausedTotal, boundary.timeIntervalSince(source.startedAt)), isManuallyConfirmed: true)
            let second = FocusSession(project: source.project, dayIdentifier: dayProvider(boundary), startedAt: boundary, endedAt: end, status: .ended, lastUserActivityAt: end, lastStateChangeAt: end, pausedTotal: 0, isManuallyConfirmed: true)
            working.remove(at: index)
            working.append(contentsOf: splitForDayBoundaries(source: first, project: first.project, start: first.startedAt, end: boundary))
            working.append(contentsOf: splitForDayBoundaries(source: second, project: second.project, start: boundary, end: end))
            return nil
        }
    }

    public func undoLastEdit() -> FocusSessionEditResult {
        lock.lock()
        guard let previous = lastEditUndo else { lock.unlock(); return .rejected(.nothingToUndo) }
        guard confirmedRevision < Int64.max else { lock.unlock(); return .rejected(.persistenceFailed) }
        let nextRevision = confirmedRevision + 1
        var restored = previous
        markConfirmedSessions(in: &restored, revision: nextRevision)
        guard persisting.save(restored) else { lock.unlock(); return .rejected(.persistenceFailed) }
        sessions = restored
        lastEditUndo = nil
        committedRevision += 1
        confirmedRevision = nextRevision
        let snapshot = makeDerivedSnapshot(sessions: restored, now: clock.now)
        lock.unlock()
        committedSnapshotHandler?(snapshot)
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
        if persisting.save(working) {
            sessions = working
            committedRevision += 1
            lock.unlock()
            return .saved
        } else {
            // Retain last valid state on persistence failure.
            lock.unlock()
            return .persistenceFailed
        }
    }

    func validate(_ list: [FocusSession]) -> Bool {
        // Unique identifiers.
        let ids = list.map(\.id)
        guard Set(ids).count == ids.count else { return false }

        // At most one open session.
        guard list.filter(\.isOpen).count <= 1 else { return false }

        // Individual field invariants.
        for s in list {
            // No future startedAt beyond tolerance.
            if s.startedAt > clock.now + config.dayBoundaryTolerance { return false }
            // end >= start.
            if let end = s.endedAt, end < s.startedAt { return false }
            if s.isOpen && s.isManuallyConfirmed { return false }
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
        guard confirmedRevision < Int64.max else { lock.unlock(); return .rejected(.persistenceFailed) }
        let nextRevision = confirmedRevision + 1
        markConfirmedSessions(in: &working, revision: nextRevision)
        guard validate(working) else { lock.unlock(); return .rejected(.overlappingSession) }
        guard working != previous else { lock.unlock(); return .rejected(.invalidTimeRange) }
        guard persisting.save(working) else { lock.unlock(); return .rejected(.persistenceFailed) }
        sessions = working
        lastEditUndo = previous
        pendingSwitch = nil
        committedRevision += 1
        confirmedRevision = nextRevision
        let snapshot = makeDerivedSnapshot(sessions: working, now: clock.now)
        lock.unlock()
        committedSnapshotHandler?(snapshot)
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
            result.append(FocusSession(id: keepsOriginalID ? source.id : UUID(), project: project, dayIdentifier: dayProvider(cursor), startedAt: cursor, endedAt: segmentEnd, status: .ended, lastUserActivityAt: segmentEnd, lastStateChangeAt: segmentEnd, pausedTotal: min(excluded, segmentGross), isManuallyConfirmed: true))
            keepsOriginalID = false
            cursor = segmentEnd
        }
        return result
    }

    // MARK: Helpers

    func clampToNow(_ date: Date) -> Date {
        min(date, clock.now)
    }

    func startSession(in project: FocusProjectContext, at when: Date, into sessions: inout [FocusSession]) {
        let session = FocusSession(
            project: project,
            dayIdentifier: currentDay,
            startedAt: when,
            status: .active,
            lastUserActivityAt: when,
            lastStateChangeAt: when
        )
        sessions.append(session)
    }

    func endSession(at index: Int, endedAt: Date, into sessions: inout [FocusSession]) {
        guard index < sessions.count else { return }
        // Close any open pause first.
        if let pause = sessions[index].currentPauseStartedAt {
            sessions[index].pausedTotal += max(0, endedAt.timeIntervalSince(pause))
            sessions[index].currentPauseStartedAt = nil
        }
        sessions[index].endedAt = endedAt
        sessions[index].status = .ended
        sessions[index].lastStateChangeAt = endedAt
    }

    func pauseSession(at index: Int, at when: Date, into sessions: inout [FocusSession]) {
        guard index < sessions.count,
              sessions[index].currentPauseStartedAt == nil else { return }
        sessions[index].currentPauseStartedAt = when
        sessions[index].status = .paused
        sessions[index].lastStateChangeAt = when
    }

    func resumeSession(at index: Int, at when: Date, into sessions: inout [FocusSession]) {
        guard index < sessions.count else { return }
        if let pause = sessions[index].currentPauseStartedAt {
            sessions[index].pausedTotal += max(0, when.timeIntervalSince(pause))
            sessions[index].currentPauseStartedAt = nil
        }
        sessions[index].status = .active
        sessions[index].lastStateChangeAt = when
    }

    // MARK: Event logic

    func handleGenericActivity(sessions: inout [FocusSession], when: Date) {
        guard let idx = sessions.firstIndex(where: \.isOpen) else { return }
        sessions[idx].lastUserActivityAt = when
        resumeSession(at: idx, at: when, into: &sessions)
    }

    func sameProjectActivity(idx: Int, sessions: inout [FocusSession], when: Date) {
        resumeSession(at: idx, at: when, into: &sessions)
        sessions[idx].lastUserActivityAt = when
        sessions[idx].lastStateChangeAt = when
        // User returned to the original project — brief interruption merge.
        pendingSwitch = nil
    }

    func differentProjectActivity(idx: Int, sessions: inout [FocusSession], candidate: FocusProjectContext, when: Date) {
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
        endSession(at: idx, endedAt: startAt, into: &sessions)
        startSession(in: candidate, at: startAt, into: &sessions)
    }

    func handleProjectArrival(sessions: inout [FocusSession], candidate: FocusProjectContext, when: Date) {
        guard let idx = sessions.firstIndex(where: \.isOpen) else {
            startSession(in: candidate, at: when, into: &sessions)
            return
        }
        let cur = sessions[idx]
        guard cur.project != candidate else { return }

        pendingSwitch = PendingSwitch(
            fromSessionId: cur.id,
            awayStartedAt: when,
            candidate: candidate
        )
        pauseSession(at: idx, at: when, into: &sessions)
    }

    func commitPendingSwitch(sessions: inout [FocusSession], when: Date) {
        guard let pending = pendingSwitch else { return }
        if let idx = sessions.firstIndex(where: { $0.id == pending.fromSessionId && $0.isOpen }) {
            endSession(at: idx, endedAt: pending.awayStartedAt, into: &sessions)
        }
        startSession(in: pending.candidate, at: pending.awayStartedAt, into: &sessions)
        pendingSwitch = nil
    }

    func finalizeOpen(at date: Date) -> FocusSessionUpdateOutcome {
        let when = clampToNow(date)
        return apply { sessions in
            if let idx = sessions.firstIndex(where: \.isOpen) {
                endSession(at: idx, endedAt: when, into: &sessions)
            }
            pendingSwitch = nil
        }
    }

    // MARK: Load / reconcile

    func reconcileOnLoad(now: Date) {
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
        }
        currentDay = dayProvider(now)
    }

    func persistAfterReconcile() {
        guard !sessions.isEmpty else { return }
        persisting.save(sessions)
    }
}
