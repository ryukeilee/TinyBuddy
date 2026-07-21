import Foundation

/// Policy decisions for attributing user activity to a focus project.
public struct FocusAttributionPolicy: Sendable {
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

    private var foreground: (bundleID: String, displayName: String, isCodeEditor: Bool)?
    private var recentGit: (key: String, displayName: String, at: Date)?

    // MARK: Init

    public init(
        engine: FocusSessionEngine,
        policy: FocusAttributionPolicy = FocusAttributionPolicy(),
        clock: FocusClock
    ) {
        self.engine = engine
        self.policy = policy
        self.clock = clock
    }

    // MARK: - App‑facing events

    /// Call when the frontmost application changes.
    public func reportForegroundApp(
        bundleID: String,
        displayName: String,
        isCodeEditor: Bool,
        at date: Date? = nil
    ) {
        foreground = (bundleID, displayName, isCodeEditor)
        engine.foregroundProjectChanged(to: focusProject(), at: date ?? clock.now)
    }

    /// Call on any user input event (keyboard or mouse).
    public func reportUserInput(at date: Date? = nil) {
        engine.userActivity(in: focusProject(), at: date ?? clock.now)
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
        recentGit = (repoKey, displayName, when)
        engine.userActivity(in: focusProject(), at: when)
    }

    /// The user became idle for `idleThreshold`.
    public func reportIdle(at date: Date? = nil) {
        engine.idleDetected(at: date ?? clock.now)
    }

    /// Screen was locked.
    public func reportLock(at date: Date? = nil) {
        engine.lockScreen(at: date ?? clock.now)
    }

    /// Screen was unlocked.  Does NOT resume a session; the next activity starts fresh.
    public func reportUnlock(at date: Date? = nil) {
        engine.unlock(at: date ?? clock.now)
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
    /// foreground app is active.
    func focusProject() -> FocusProjectContext? {
        guard let fg = foreground else { return nil }

        if fg.isCodeEditor, let git = recentGit {
            if let window = policy.gitAttributionWindow {
                guard clock.now.timeIntervalSince(git.at) <= window else {
                    return project(for: fg)
                }
            }
            return FocusProjectContext(key: git.key, displayName: git.displayName)
        }

        return project(for: fg)
    }

    func project(for fg: (bundleID: String, displayName: String, isCodeEditor: Bool)) -> FocusProjectContext {
        FocusProjectContext(key: fg.bundleID, displayName: fg.displayName)
    }
}
