import AppKit
import Foundation
import TinyBuddyCore
import WidgetKit
import Darwin

extension Notification.Name {
    static let gitActivityRefreshStatusDidChange = Notification.Name("TinyBuddy.gitActivityRefreshStatusDidChange")
}

struct GitRefreshScriptMetrics: Equatable {
    let repositoryCount: Int?
    let cacheHitCount: Int?
    let reflogUnchangedSkipCount: Int?
    let recomputedRepositoryCount: Int?
    let sharedDataWritten: Bool?
}

struct GitRefreshScriptResult {
    let standardOutput: String
    let standardError: String
    let metrics: GitRefreshScriptMetrics?
}

private struct GitRefreshScriptResultParser {
    static let metricsPrefix = "TINYBUDDY_REFRESH_METRICS\t"

    static func parseMetrics(from standardOutput: String) -> GitRefreshScriptMetrics? {
        let metricsLine = standardOutput
            .split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix(metricsPrefix) }
            .map(String.init)

        guard let metricsLine else {
            return nil
        }

        let payload = String(metricsLine.dropFirst(metricsPrefix.count))
        var values: [String: String] = [:]
        for field in payload.split(separator: "\t") {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }
            values[parts[0]] = parts[1]
        }

        return GitRefreshScriptMetrics(
            repositoryCount: values["repository_count"].flatMap(Int.init),
            cacheHitCount: values["cache_hit_count"].flatMap(Int.init),
            reflogUnchangedSkipCount: values["reflog_unchanged_skip_count"].flatMap(Int.init),
            recomputedRepositoryCount: values["recomputed_repository_count"].flatMap(Int.init),
            sharedDataWritten: values["shared_data_written"].flatMap { value in
                switch value {
                case "1":
                    return true
                case "0":
                    return false
                default:
                    return nil
                }
            }
        )
    }

    static func outputWithoutMetricsLine(_ standardOutput: String) -> String {
        standardOutput
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix(metricsPrefix) }
            .map(String.init)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GitRefreshScriptExecutionError: LocalizedError {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let metrics: GitRefreshScriptMetrics?

    var errorDescription: String? {
        let scriptDiagnostics = [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if scriptDiagnostics.isEmpty {
            return "refresh script exited with status \(terminationStatus)"
        }

        return "refresh script exited with status \(terminationStatus):\n\(scriptDiagnostics)"
    }
}

final class GitActivityRefreshCoordinator {
    typealias ScriptRunner = (URL, [URL]) throws -> GitRefreshScriptResult
    typealias ScriptURLProvider = () -> URL?
    typealias AuthorizedRootsProvider = () -> [ScopedGitScanRoot]

    private let activityStore: GitTodayActivityStore
    private let refreshStatusStore: GitActivityRefreshStatusStore
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
    private var pendingWakeRefreshRequestedAt: Date?

    init(
        activityStore: GitTodayActivityStore = GitTodayActivityStore(),
        refreshStatusStore: GitActivityRefreshStatusStore = GitActivityRefreshStatusStore(),
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
        self.refreshStatusStore = refreshStatusStore
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
        refresh(trigger: .becameActive)
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
            pendingWakeRefreshRequestedAt = now
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .skipped,
                reason: "refresh already in progress",
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    widgetReloaded: false,
                    reason: "refresh already in progress"
                )
            )
            return
        }

        if let lastWakeRefreshAt,
           now.timeIntervalSince(lastWakeRefreshAt) < wakeRefreshCoalescingInterval {
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .skipped,
                reason: "wake refresh coalesced",
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    widgetReloaded: false,
                    reason: "wake refresh coalesced"
                )
            )
            return
        }

        if refresh(trigger: trigger, force: true) {
            lastWakeRefreshAt = now
        }
    }

    private func finishRefresh(succeeded: Bool) {
        isRefreshing = false

        guard let pendingWakeRefreshTrigger else {
            return
        }

        let pendingWakeRefreshRequestedAt = self.pendingWakeRefreshRequestedAt
        self.pendingWakeRefreshTrigger = nil
        self.pendingWakeRefreshRequestedAt = nil

        if succeeded,
           let lastWakeRefreshAt,
           let pendingWakeRefreshRequestedAt,
           pendingWakeRefreshRequestedAt.timeIntervalSince(lastWakeRefreshAt) < wakeRefreshCoalescingInterval {
            return
        }

        if refresh(trigger: pendingWakeRefreshTrigger, force: true) {
            lastWakeRefreshAt = dateProvider()
        }
    }

    @discardableResult
    private func refresh(trigger: GitTodayActivityRefreshTrigger, force: Bool = false) -> Bool {
        let now = dateProvider()

        guard force || shouldRefresh(at: now) else {
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .skipped,
                reason: "minimum refresh spacing not reached",
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    widgetReloaded: false,
                    reason: "minimum refresh spacing not reached"
                )
            )
            return false
        }

        guard !isRefreshing else {
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .skipped,
                reason: "refresh already in progress",
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    widgetReloaded: false,
                    reason: "refresh already in progress"
                )
            )
            return false
        }

        guard let scriptURL = scriptURLProvider() else {
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .failed,
                reason: "missing git refresh script",
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    widgetReloaded: false,
                    reason: "missing git refresh script"
                )
            )
            NSLog("TinyBuddy: missing git refresh script for trigger %@", String(describing: trigger))
            return false
        }

        let scopedRoots = authorizedRootsProvider()
        let authorizedRootURLs = scopedRoots.map(\.url)
        guard !authorizedRootURLs.isEmpty else {
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .skipped,
                reason: "no authorized Git scan roots",
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: 0,
                    widgetReloaded: false,
                    reason: "no authorized Git scan roots"
                )
            )
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
                let scriptResult = try scriptRunner(scriptURL, authorizedRootURLs)
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }

                    defer {
                        self.finishRefresh(succeeded: true)
                    }

                    let currentSnapshot = self.activityStore.loadTodaySnapshot()
                    let refreshResult = self.activityStore.makeRefreshResult(
                        previousSnapshot: previousSnapshot,
                        currentSnapshot: currentSnapshot
                    )
                    self.mirrorActivitySnapshotToStandardDefaults(
                        currentSnapshot,
                        refreshedAt: now
                    )
                    let didReloadWidget = GitTodayActivityRefreshPolicy.shouldReloadWidget(
                        for: trigger,
                        didChange: refreshResult.didChange
                    )
                    if didReloadWidget {
                        self.widgetReloader()
                    }

                    self.recordRefreshStatus(
                        refreshedAt: now,
                        trigger: trigger,
                        outcome: .succeeded,
                        reason: nil,
                        metrics: self.makeMetrics(
                            startedAt: now,
                            finishedAt: self.dateProvider(),
                            authorizedRootCount: authorizedRootURLs.count,
                            scriptMetrics: scriptResult.metrics,
                            widgetReloaded: didReloadWidget,
                            reason: nil
                        )
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }

                    let scriptMetrics = (error as? GitRefreshScriptExecutionError)?.metrics
                    self.recordRefreshStatus(
                        refreshedAt: now,
                        trigger: trigger,
                        outcome: .failed,
                        reason: self.summarizedReason(from: error),
                        metrics: self.makeMetrics(
                            startedAt: now,
                            finishedAt: self.dateProvider(),
                            authorizedRootCount: authorizedRootURLs.count,
                            scriptMetrics: scriptMetrics,
                            widgetReloaded: false,
                            reason: self.summarizedReason(from: error)
                        )
                    )
                    self.finishRefresh(succeeded: false)
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

    private func recordRefreshStatus(
        refreshedAt: Date,
        trigger: GitTodayActivityRefreshTrigger,
        outcome: GitActivityRefreshOutcome,
        reason: String?,
        metrics: GitActivityRefreshMetrics? = nil
    ) {
        let status = GitActivityRefreshStatus(
            refreshedAt: refreshedAt,
            trigger: trigger,
            outcome: outcome,
            reason: summarizedReason(reason),
            metrics: metrics
        )
        refreshStatusStore.save(status)
        NotificationCenter.default.post(name: .gitActivityRefreshStatusDidChange, object: status)
    }

    private func makeMetrics(
        startedAt: Date,
        finishedAt: Date,
        authorizedRootCount: Int,
        scriptMetrics: GitRefreshScriptMetrics?,
        widgetReloaded: Bool,
        reason: String?
    ) -> GitActivityRefreshMetrics {
        GitActivityRefreshMetrics(
            durationMilliseconds: max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000)),
            authorizedRootCount: authorizedRootCount,
            repositoryCount: scriptMetrics?.repositoryCount,
            cacheHitCount: scriptMetrics?.cacheHitCount,
            reflogUnchangedSkipCount: scriptMetrics?.reflogUnchangedSkipCount,
            recomputedRepositoryCount: scriptMetrics?.recomputedRepositoryCount,
            sharedDataWritten: scriptMetrics?.sharedDataWritten,
            widgetReloaded: widgetReloaded,
            reason: summarizedReason(reason)
        )
    }

    private func summarizedReason(from error: Error) -> String? {
        summarizedReason(error.localizedDescription)
    }

    private func summarizedReason(_ reason: String?) -> String? {
        guard let reason else {
            return nil
        }

        let singleLineReason = reason
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let singleLineReason, !singleLineReason.isEmpty else {
            return nil
        }

        let maxLength = 160
        guard singleLineReason.count > maxLength else {
            return singleLineReason
        }

        let endIndex = singleLineReason.index(singleLineReason.startIndex, offsetBy: maxLength)
        return String(singleLineReason[..<endIndex])
    }

    private func mirrorActivitySnapshotToStandardDefaults(
        _ snapshot: GitTodayActivitySnapshot,
        refreshedAt: Date
    ) {
        let defaults = UserDefaults.standard
        let dayIdentifier = Self.dayIdentifier(for: refreshedAt)

        defaults.set(dayIdentifier, forKey: GitTodayFocusBlockCountStore.Key.dayIdentifier)
        defaults.set(snapshot.focusBlockCount ?? 0, forKey: GitTodayFocusBlockCountStore.Key.count)
        defaults.set(dayIdentifier, forKey: GitTodayCommitCountStore.Key.dayIdentifier)
        defaults.set(snapshot.commitCount ?? 0, forKey: GitTodayCommitCountStore.Key.count)
        defaults.set(dayIdentifier, forKey: GitTodayRecentProjectStore.Key.dayIdentifier)

        if let recentProjectName = snapshot.recentProjectName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !recentProjectName.isEmpty {
            defaults.set(recentProjectName, forKey: GitTodayRecentProjectStore.Key.projectName)
        } else {
            defaults.removeObject(forKey: GitTodayRecentProjectStore.Key.projectName)
        }

        defaults.synchronize()
    }

    private static func dayIdentifier(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
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

    private static func runScript(at scriptURL: URL, scanningRoots rootURLs: [URL]) throws -> GitRefreshScriptResult {
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

        let metrics = GitRefreshScriptResultParser.parseMetrics(from: standardOutput)
        let visibleOutput = GitRefreshScriptResultParser.outputWithoutMetricsLine(standardOutput)

        guard process.terminationStatus == 0 else {
            throw GitRefreshScriptExecutionError(
                terminationStatus: process.terminationStatus,
                standardOutput: visibleOutput,
                standardError: standardError,
                metrics: metrics
            )
        }

        guard !standardError.isEmpty else {
            return GitRefreshScriptResult(
                standardOutput: visibleOutput,
                standardError: standardError,
                metrics: metrics
            )
        }

        NSLog("TinyBuddy: git refresh script diagnostics: %@", standardError)
        return GitRefreshScriptResult(
            standardOutput: visibleOutput,
            standardError: standardError,
            metrics: metrics
        )
    }

    private static func resolvedUserHomeDirectoryPath() -> String {
        if let homeDirectory = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }),
           !homeDirectory.isEmpty {
            return homeDirectory
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
