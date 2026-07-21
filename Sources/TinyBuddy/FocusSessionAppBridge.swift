import AppKit
import Foundation
import OSLog
import TinyBuddyCore

extension Notification.Name {
    static let focusSessionSnapshotSynchronizationDidFinish = Notification.Name(
        "TinyBuddy.focusSessionSnapshotSynchronizationDidFinish"
    )
}

/// Known code‑editor bundle identifiers for focus attribution.
private let knownCodeEditorBundleIDs: Set<String> = [
    "com.apple.dt.Xcode",
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeExploration",
    "com.jetbrains.AppCode",
    "com.jetbrains.CLion",
    "com.jetbrains.DataGrip",
    "com.jetbrains.GoLand",
    "com.jetbrains.IntelliJ-IDEA",
    "com.jetbrains.PyCharm",
    "com.jetbrains.Rider",
    "com.jetbrains.RubyMine",
    "com.jetbrains.WebStorm",
    "com.sublimetext.4",
    "com.sublimetext.3",
    "com.todesktop.230113.Summit",
    "co.noteplan.NotePlan3",
    "com.ia.writer.mac",
]

/// Wires system‑level macOS notifications and idle detection into the
/// `FocusSessionCoordinator`.  Designed to be owned by `AppDelegate` and
/// started after the app becomes the primary instance.
@MainActor
final class FocusSessionAppBridge {
    private let coordinator: FocusSessionCoordinator
    private let engine: FocusSessionEngine
    private let idleThreshold: TimeInterval
    private let idlePollInterval: TimeInterval
    private let workspaceNC: NotificationCenter
    private let notificationCenter: NotificationCenter

    private var idleTimer: DispatchSourceTimer?
    private var wasIdle: Bool = false
    private var activeCount: Int = 0

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ryukeili.TinyBuddy",
        category: "FocusSession"
    )

    /// The single primary-process engine used by the Settings review surface.
    /// It is intentionally not recreated there, preventing stale-reader writes.
    var sessionEngine: FocusSessionEngine { engine }

    init(
        coordinator: FocusSessionCoordinator,
        engine: FocusSessionEngine,
        idleThreshold: TimeInterval = FocusSessionConfiguration().idleThreshold,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        notificationCenter: NotificationCenter = .default
    ) {
        self.coordinator = coordinator
        self.engine = engine
        self.idleThreshold = idleThreshold
        // The default 120-second threshold needs no sub-second precision.
        // Polling at most every 30 seconds avoids a permanent five-second
        // wake-up while still bounding late idle detection to one quarter of
        // the configured threshold.
        self.idlePollInterval = min(30, max(5, idleThreshold / 4))
        self.workspaceNC = workspaceNotificationCenter
        self.notificationCenter = notificationCenter
    }

    // MARK: - Lifecycle

    func start() {
        guard idleTimer == nil else { return }
        registerWorkspaceObservers()
        startIdleDetection()
        seedForegroundApp()
        logger.notice("FocusSessionAppBridge started")
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        removeObservers()
        logger.notice("FocusSessionAppBridge stopped")
    }

    /// Must be called from `applicationWillTerminate` to finalise open sessions.
    func handleTerminate() {
        logger.notice("FocusSessionAppBridge terminating — finalising sessions")
        coordinator.reportTerminate()
    }

    // MARK: - Observers

    private var observers: [NSObjectProtocol] = []

    private func registerWorkspaceObservers() {
        // Sleep / wake
        observers.append(
            workspaceNC.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.coordinator.reportSleep() }
            }
        )
        observers.append(
            workspaceNC.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.coordinator.reportWake() }
            }
        )
        // Lock / unlock
        observers.append(
            workspaceNC.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.coordinator.reportLock() }
            }
        )
        observers.append(
            workspaceNC.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.coordinator.reportUnlock() }
            }
        )
        // Foreground app change
        observers.append(
            workspaceNC.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                    object: nil, queue: .main) { [weak self] notification in
                let app = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier ?? ""
                let displayName = app?.localizedName ?? bundleID
                guard !bundleID.isEmpty else { return }
                MainActor.assumeIsolated {
                    self?.coordinator.reportForegroundApp(
                        bundleID: bundleID,
                        displayName: displayName,
                        isCodeEditor: Self.isCodeEditor(bundleID)
                    )
                }
            }
        )
        // System clock / time‑zone change
        observers.append(
            notificationCenter.addObserver(forName: .NSSystemClockDidChange,
                                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleTimeChange() }
            }
        )
    }

    private func removeObservers() {
        observers.forEach(workspaceNC.removeObserver)
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
    }

    // MARK: - Idle detection

    private func startIdleDetection() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        let leeway = max(1, Int(idlePollInterval / 5))
        timer.schedule(
            deadline: .now() + idlePollInterval,
            repeating: idlePollInterval,
            leeway: .seconds(leeway)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkIdleState() }
        }
        timer.resume()
        idleTimer = timer
    }

    private func checkIdleState() {
        let idleKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)
        let idleMouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp)
        let idleSeconds = min(idleKey, idleMouse)
        let isNowIdle = idleSeconds > idleThreshold

        if isNowIdle, !wasIdle {
            wasIdle = true
            checkDayChange()
            coordinator.reportIdle()
        } else if !isNowIdle, wasIdle {
            wasIdle = false
            checkDayChange()
            coordinator.reportUserInput()
        } else if !isNowIdle {
            activeCount += 1
            if activeCount % 6 == 0 {
                checkDayChange()
            }
        }
    }

    private func seedForegroundApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }
        coordinator.reportForegroundApp(
            bundleID: bundleID,
            displayName: frontApp.localizedName ?? bundleID,
            isCodeEditor: Self.isCodeEditor(bundleID)
        )
    }

    // MARK: - Day change / time change

    private var lastCheckedDay: String?

    private func checkDayChange() {
        guard let context = TinyBuddyTimeEnvironment().capture() else { return }
        let now = context.now
        let day = context.dayIdentifier(for: now) ?? context.dayIdentifier
        guard let last = lastCheckedDay else {
            lastCheckedDay = day
            return
        }
        guard day != last else { return }
        lastCheckedDay = day
        coordinator.reportTimeChange(dayIdentifier: day, at: now)
    }

    private func handleTimeChange() {
        guard let context = TinyBuddyTimeEnvironment().capture() else { return }
        let now = context.now
        let day = context.dayIdentifier(for: now) ?? context.dayIdentifier
        lastCheckedDay = day
        coordinator.reportTimeChange(dayIdentifier: day, at: now)
    }

    // MARK: - Editor detection

    private static func isCodeEditor(_ bundleID: String) -> Bool {
        // JetBrains products use hashed bundle IDs per product version.
        if bundleID.hasPrefix("com.jetbrains.") { return true }
        if bundleID.hasPrefix("com.microsoft.VSCode") { return true }
        return knownCodeEditorBundleIDs.contains(bundleID)
    }
}

// MARK: - Convenience factory

extension FocusSessionAppBridge {
    /// Creates a standard bridge using the App Group container for persistence.
    @MainActor
    static func createStandard(
        projectRegistry: TinyBuddyProjectRegistry? = nil
    ) -> FocusSessionAppBridge? {
        guard let appGroupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ryukeili.TinyBuddy") else {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "com.ryukeili.TinyBuddy",
                category: "FocusSession"
            ).error("App Group container unavailable — FocusSessionAppBridge disabled")
            return nil
        }
        let storeURL = appGroupURL
            .appendingPathComponent("focus-sessions", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let fileStore = FocusSessionFileStore(fileURL: storeURL)
        let clock = SystemFocusClock()
        let config = FocusSessionConfiguration()
        let historyGoalPreferences = FocusGoalPreferencesStore()
        let timeEnv = TinyBuddyTimeEnvironment()
        let dayProvider: (Date) -> String = { date in
            timeEnv.capture()?.dayIdentifier(for: date) ?? ""
        }
        let nextDayBoundary: (Date) -> Date? = { date in
            var calendar = Calendar.current
            calendar.timeZone = timeEnv.capture()?.timeZone ?? .current
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        }

        let engine = FocusSessionEngine(
            clock: clock,
            persisting: fileStore,
            config: config,
            dayIdentifier: dayProvider,
            nextDayBoundary: nextDayBoundary,
            historyGoalMinutes: {
                historyGoalPreferences.loadConfiguration().dailyFocusGoalMinutes
            },
            historyActiveProjectKeys: { sessions in
                projectRegistry.map { registry in
                    var activeKeys = Set(registry.currentSnapshot.projects.compactMap { project in
                        project.state == .active ? project.id.rawValue : nil
                    })
                    // Foreground-app projects are outside the Git registry and
                    // remain active under their existing bundle-ID identity.
                    for session in sessions where registry.resolve(projectKey: session.project.key) == nil {
                        activeKeys.insert(session.project.key)
                    }
                    return activeKeys
                }
            },
            projectContextResolver: { context in
                guard let project = projectRegistry?.resolve(projectKey: context.key) else {
                    return context
                }
                return FocusProjectContext(
                    key: project.id.rawValue,
                    displayName: project.displayName
                )
            }
        )
        let coordinator = FocusSessionCoordinator(
            engine: engine,
            policy: FocusAttributionPolicy(),
            clock: clock
        )
        return FocusSessionAppBridge(
            coordinator: coordinator,
            engine: engine
        )
    }
}
