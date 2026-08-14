import Foundation

/// Policy decisions for attributing user activity to a focus project.
public struct FocusAttributionPolicy: Equatable, Sendable {
    /// How long a git activity remains attributable after it was last seen.
    /// `nil` means git activities never expire.
    public var gitAttributionWindow: TimeInterval?

    public init(gitAttributionWindow: TimeInterval? = 300) {
        self.gitAttributionWindow = gitAttributionWindow
    }
}

/// High‑level coordinator that maps app‑level concepts (foreground app, git
/// activity, input events) into the `FocusSessionEngine`.  Designed to be used
/// on `@MainActor` and called by an AppKit bridge.
///
/// Attribution policy:
/// - If the foreground app is a code editor and we have recent non‑automated
///   git activity, attribute focus to the git project.
/// - Otherwise, attribute to the foreground app (identified by bundle id).
@MainActor
public final class FocusSessionCoordinator {
    private let engine: FocusSessionEngine
    private let policy: FocusAttributionPolicy
    private let clock: FocusClock
    private let gitProjectResolver: @MainActor (String, String) -> FocusProjectContext?
    /// Evaluated against the *final* attribution candidate on every report.
    /// Returning true suppresses automatic focus for that project. Evaluating
    /// here (rather than at discovery time) lets the latest rules take effect
    /// immediately and prevents a stale asynchronous scan result from reviving
    /// automatic focus for an excluded repository.
    private let exclusionGate: @MainActor (FocusProjectContext) -> Bool

    private var foreground: (bundleID: String, displayName: String, isCodeEditor: Bool)?
    private var recentGit: (key: String, displayName: String, at: Date)?

    // MARK: Init

    public init(
        engine: FocusSessionEngine,
        policy: FocusAttributionPolicy = FocusAttributionPolicy(),
        clock: FocusClock,
        gitProjectResolver: @escaping @MainActor (String, String) -> FocusProjectContext? = {
            FocusProjectContext(key: $0, displayName: $1)
        },
        exclusionGate: @escaping @MainActor (FocusProjectContext) -> Bool = { _ in false }
    ) {
        self.engine = engine
        self.policy = policy
        self.clock = clock
        self.gitProjectResolver = gitProjectResolver
        self.exclusionGate = exclusionGate
    }

    // MARK: - App‑facing events

    /// Call when the frontmost application changes.
    public func reportForegroundApp(
        bundleID: String,
        displayName: String,
        isCodeEditor: Bool,
        at date: Date? = nil
    ) {
        // A Git event belongs to the editor instance/project that produced it,
        // not to every later code editor.  Clear it on an application switch;
        // otherwise returning to another editor can attribute input to a
        // stale repository for the attribution window.
        if let previous = foreground, previous.bundleID != bundleID {
            recentGit = nil
        }
        foreground = (bundleID, displayName, isCodeEditor)
        engine.foregroundProjectChanged(to: focusProject(), at: date ?? clock.now)
    }

    /// Call on any user input event (keyboard or mouse).
    public func reportUserInput(at date: Date? = nil) {
        engine.userActivity(
            in: focusProject(),
            at: date ?? clock.now,
            reason: .userActivity
        )
    }

    /// Periodic heartbeat while the user is active (idle-poll cadence). Feeds
    /// the engine's confirmation gate so sustained work confirms even without
    /// transition, commit, or foreground events; never mutates an open
    /// same-project session.
    public func reportSustainedActivity(at date: Date? = nil) {
        engine.reportSustainedActivity(in: focusProject(), at: date ?? clock.now)
    }

    /// Call on non‑automated git activity.  `automated: true` is silently ignored,
    /// satisfying the "background git must not create sessions" requirement.
    public func reportGitActivity(
        repoKey: String,
        displayName: String,
        automated: Bool,
        at date: Date? = nil
    ) {
        guard !automated else { return }
        let when = date ?? clock.now
        guard let project = gitProjectResolver(repoKey, displayName) else {
            recentGit = nil
            return
        }
        recentGit = (project.key, project.displayName, when)
        engine.userActivity(in: focusProject(), at: when, reason: .gitActivity)
    }

    /// The user became idle for `idleThreshold`.
    public func reportIdle(at date: Date? = nil) {
        engine.idleDetected(at: date ?? clock.now)
    }

    /// Prolonged idle beyond the long‑absence threshold.
    public func reportProlongedIdle(at date: Date? = nil) {
        engine.endPausedSessionAfterLongAbsence(at: date ?? clock.now)
    }

    /// Screen was locked.
    public func reportLock(at date: Date? = nil) {
        engine.lockScreen(at: date ?? clock.now)
    }

    /// Screen was unlocked.  Does NOT resume a session; the next activity starts fresh.
    public func reportUnlock(at date: Date? = nil) {
        engine.unlock(at: date ?? clock.now)
    }

    /// Call after unlock or wake when the user is already active, to skip
    /// waiting for the next idle poll. This uses the coordinator's attribution
    /// logic (foreground app, recent git activity) to determine the project.
    /// The engine's confirmation gate still requires sustained activity before
    /// a fresh automatic session starts; a paused manual session remains
    /// paused until an explicit manual resume command.
    public func reportActiveAfterIdle(at date: Date? = nil) {
        let now = date ?? clock.now
        engine.userActivity(in: focusProject(), at: now, reason: .userActivity)
    }

    /// System is about to sleep.
    public func reportSleep(at date: Date? = nil) {
        engine.systemSleep(at: date ?? clock.now)
    }

    /// System woke.  No session resumption.
    public func reportWake(at date: Date? = nil) {
        engine.systemWake(at: date ?? clock.now)
    }

    /// Wall‑clock time changed (manual change, NTP correction, DST, or day boundary).
    public func reportTimeChange(dayIdentifier: String, at date: Date? = nil) {
        engine.timeChanged(at: date ?? clock.now, dayIdentifier: dayIdentifier)
    }

    /// App is about to terminate normally (e.g. `NSApplication.willTerminateNotification`).
    public func reportTerminate(at date: Date? = nil) {
        engine.appWillTerminate(at: date ?? clock.now)
    }

    /// Crash or process kill (best‑effort handler).
    public func reportCrash(at date: Date? = nil) {
        engine.crash(at: date ?? clock.now)
    }

    // MARK: - Queries

    public func currentFocusProject() -> FocusProjectContext? {
        engine.currentProject
    }

    public func focusDurationToday() -> TimeInterval {
        engine.focusDurationToday()
    }

    public func projectDurationsToday() -> [String: TimeInterval] {
        engine.projectDurationsToday()
    }
}

// MARK: - Attribution

private extension FocusSessionCoordinator {
    /// The project that focus should be attributed to *now*, or `nil` when no
    /// foreground app is active or the candidate is excluded by the latest rules.
    func focusProject() -> FocusProjectContext? {
        guard let fg = foreground else { return nil }

        let candidate: FocusProjectContext
        if fg.isCodeEditor, let git = recentGit {
            let stillAttributable = policy.gitAttributionWindow.map {
                clock.now.timeIntervalSince(git.at) <= $0
            } ?? true
            candidate = stillAttributable
                ? FocusProjectContext(key: git.key, displayName: git.displayName)
                : project(for: fg)
        } else {
            candidate = project(for: fg)
        }

        guard !exclusionGate(candidate) else { return nil }
        return candidate
    }

    func project(for fg: (bundleID: String, displayName: String, isCodeEditor: Bool)) -> FocusProjectContext {
        FocusProjectContext(key: fg.bundleID, displayName: fg.displayName)
    }
}
