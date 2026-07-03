import AppKit
import Foundation
import TinyBuddyCore
import WidgetKit
import Darwin

final class GitActivityRefreshCoordinator {
    typealias ScriptRunner = (URL, [URL]) throws -> Void
    typealias ScriptURLProvider = () -> URL?
    typealias AuthorizedRootsProvider = () -> [ScopedGitScanRoot]

    private let activityStore: GitTodayActivityStore
    private let widgetReloader: () -> Void
    private let scriptRunner: ScriptRunner
    private let scriptURLProvider: ScriptURLProvider
    private let authorizedRootsProvider: AuthorizedRootsProvider
    private let dateProvider: () -> Date
    private let workspaceNotificationCenter: NotificationCenter
    private let refreshInterval: TimeInterval
    private let minimumRefreshSpacing: TimeInterval
    private let wakeRefreshCoalescingInterval: TimeInterval
    private let refreshQueue = DispatchQueue(label: "TinyBuddy.GitActivityRefresh", qos: .utility)

    private var timer: Timer?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var isRefreshing = false
    private var lastRefreshAttemptAt: Date?
    private var lastWakeRefreshAt: Date?
    private var pendingWakeRefreshTrigger: GitTodayActivityRefreshTrigger?

    init(
        activityStore: GitTodayActivityStore = GitTodayActivityStore(),
        gitScanRootStore: GitScanRootAuthorizationStore = GitScanRootAuthorizationStore(),
        refreshInterval: TimeInterval = 5 * 60,
        minimumRefreshSpacing: TimeInterval = 60,
        widgetReloader: @escaping () -> Void = {
            WidgetCenter.shared.reloadAllTimelines()
        },
        scriptURLProvider: @escaping ScriptURLProvider = GitActivityRefreshCoordinator.locateRefreshScript,
        scriptRunner: @escaping ScriptRunner = GitActivityRefreshCoordinator.runScript(at:scanningRoots:),
        authorizedRootsProvider: AuthorizedRootsProvider? = nil,
        dateProvider: @escaping () -> Date = Date.init,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        wakeRefreshCoalescingInterval: TimeInterval = 5
    ) {
        self.activityStore = activityStore
        self.refreshInterval = refreshInterval
        self.minimumRefreshSpacing = minimumRefreshSpacing
        self.widgetReloader = widgetReloader
        self.scriptURLProvider = scriptURLProvider
        self.scriptRunner = scriptRunner
        self.authorizedRootsProvider = authorizedRootsProvider ?? gitScanRootStore.accessAuthorizedRoots
        self.dateProvider = dateProvider
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.wakeRefreshCoalescingInterval = wakeRefreshCoalescingInterval
    }

    func start() {
        registerWorkspaceNotificationsIfNeeded()
        scheduleTimerIfNeeded()
        refresh(trigger: .launch, force: true)
    }

    func handleDidBecomeActive() {
        refresh(trigger: .becameActive, force: true)
    }

    func handleReopen() {
        refresh(trigger: .reopen, force: true)
    }

    func handleDidWake() {
        requestWakeRefresh(trigger: .didWake)
    }

    func handleScreensDidWake() {
        requestWakeRefresh(trigger: .screensDidWake)
    }

    func handleSessionDidBecomeActive() {
        requestWakeRefresh(trigger: .sessionDidBecomeActive)
    }

    deinit {
        workspaceNotificationObservers.forEach(workspaceNotificationCenter.removeObserver)
    }

    private func scheduleTimerIfNeeded() {
        guard timer == nil else {
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(trigger: .timer)
            }
        }
    }

    private func registerWorkspaceNotificationsIfNeeded() {
        guard workspaceNotificationObservers.isEmpty else {
            return
        }

        workspaceNotificationObservers = [
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleDidWake()
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleScreensDidWake()
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSessionDidBecomeActive()
            }
        ]
    }

    private func requestWakeRefresh(trigger: GitTodayActivityRefreshTrigger) {
        let now = dateProvider()

        if isRefreshing {
            pendingWakeRefreshTrigger = trigger
            return
        }

        if let lastWakeRefreshAt,
           now.timeIntervalSince(lastWakeRefreshAt) < wakeRefreshCoalescingInterval {
            return
        }

        if refresh(trigger: trigger, force: true) {
            lastWakeRefreshAt = now
        }
    }

    private func finishRefresh() {
        isRefreshing = false

        guard let pendingWakeRefreshTrigger else {
            return
        }

        self.pendingWakeRefreshTrigger = nil
        if refresh(trigger: pendingWakeRefreshTrigger, force: true) {
            lastWakeRefreshAt = dateProvider()
        }
    }

    @discardableResult
    private func refresh(trigger: GitTodayActivityRefreshTrigger, force: Bool = false) -> Bool {
        let now = dateProvider()

        guard force || shouldRefresh(at: now) else {
            return false
        }

        guard !isRefreshing else {
            return false
        }

        guard let scriptURL = scriptURLProvider() else {
            NSLog("TinyBuddy: missing git refresh script for trigger %@", String(describing: trigger))
            return false
        }

        let scopedRoots = authorizedRootsProvider()
        let authorizedRootURLs = scopedRoots.map(\.url)
        guard !authorizedRootURLs.isEmpty else {
            NSLog("TinyBuddy: skipping git refresh for trigger %@ because no Git scan roots are authorized", String(describing: trigger))
            scopedRoots.forEach { $0.stopAccessing() }
            return false
        }

        isRefreshing = true
        lastRefreshAttemptAt = now
        let previousSnapshot = activityStore.loadTodaySnapshot()
        let scriptRunner = self.scriptRunner

        refreshQueue.async { [weak self] in
            defer {
                scopedRoots.forEach { $0.stopAccessing() }
            }

            do {
                try scriptRunner(scriptURL, authorizedRootURLs)
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }

                    defer {
                        self.finishRefresh()
                    }

                    let currentSnapshot = self.activityStore.loadTodaySnapshot()
                    let refreshResult = self.activityStore.makeRefreshResult(
                        previousSnapshot: previousSnapshot,
                        currentSnapshot: currentSnapshot
                    )
                    if GitTodayActivityRefreshPolicy.shouldReloadWidget(
                        for: trigger,
                        didChange: refreshResult.didChange
                    ) {
                        self.widgetReloader()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }

                    self.finishRefresh()
                    NSLog("TinyBuddy: git refresh failed for trigger %@: %@", String(describing: trigger), error.localizedDescription)
                }
            }
        }

        return true
    }

    private func shouldRefresh(at now: Date) -> Bool {
        guard let lastRefreshAttemptAt else {
            return true
        }

        return now.timeIntervalSince(lastRefreshAttemptAt) >= minimumRefreshSpacing
    }

    private static func locateRefreshScript() -> URL? {
        if let bundledURL = Bundle.main.url(forResource: "update_git_completion_count", withExtension: "sh") {
            return bundledURL
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let fallbackURL = resourceURL.appendingPathComponent("update_git_completion_count.sh")
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
            return nil
        }

        return fallbackURL
    }

    private static func runScript(at scriptURL: URL, scanningRoots rootURLs: [URL]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        let userHomePath = resolvedUserHomeDirectoryPath()
        environment["TINYBUDDY_USER_HOME"] = userHomePath
        environment["TINYBUDDY_GIT_SCAN_ROOTS"] = rootURLs
            .map(\.standardizedFileURL.path)
            .joined(separator: "\n")
        if let appGroupContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
        ) {
            let preferencesDirectoryURL = appGroupContainerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Preferences", isDirectory: true)
            let preferencesPlistURL = preferencesDirectoryURL
                .appendingPathComponent("\(TinyBuddySharedData.appGroupIdentifier).plist")
            environment["TINYBUDDY_APP_GROUP_CONTAINER"] = appGroupContainerURL.path
            environment["TINYBUDDY_APP_GROUP_PREFERENCES_DIR"] = preferencesDirectoryURL.path
            environment["TINYBUDDY_APP_GROUP_PREFERENCES_PLIST"] = preferencesPlistURL.path
        }
        process.environment = environment

        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
        let standardOutputURL = temporaryDirectoryURL.appendingPathComponent(UUID().uuidString)
        let standardErrorURL = temporaryDirectoryURL.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
        let standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
        let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
        defer {
            try? standardOutputHandle.close()
            try? standardErrorHandle.close()
            try? FileManager.default.removeItem(at: standardOutputURL)
            try? FileManager.default.removeItem(at: standardErrorURL)
        }
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle

        try process.run()
        process.waitUntilExit()
        try standardOutputHandle.close()
        try standardErrorHandle.close()

        let standardOutput = String(
            data: (try? Data(contentsOf: standardOutputURL)) ?? Data(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let standardError = String(
            data: (try? Data(contentsOf: standardErrorURL)) ?? Data(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let scriptDiagnostics = [standardOutput, standardError]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw NSError(
                domain: "TinyBuddy.GitActivityRefreshCoordinator",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: scriptDiagnostics.isEmpty
                        ? "refresh script exited with status \(process.terminationStatus)"
                        : "refresh script exited with status \(process.terminationStatus):\n\(scriptDiagnostics)"
                ]
            )
        }

        guard !standardError.isEmpty else {
            return
        }

        NSLog("TinyBuddy: git refresh script diagnostics: %@", standardError)
    }

    private static func resolvedUserHomeDirectoryPath() -> String {
        if let homeDirectory = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }),
           !homeDirectory.isEmpty {
            return homeDirectory
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
