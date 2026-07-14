import AppKit
import Foundation
import TinyBuddyCore
import WidgetKit
import Darwin

extension Notification.Name {
    static let gitActivityRefreshStatusDidChange = Notification.Name("TinyBuddy.gitActivityRefreshStatusDidChange")
    static let gitActivitySnapshotDidChange = Notification.Name("TinyBuddy.gitActivitySnapshotDidChange")
    static let gitScanRootAuthorizationRequested = Notification.Name("TinyBuddy.gitScanRootAuthorizationRequested")
}

struct GitRefreshScriptMetrics: Equatable {
    let repositoryCount: Int?
    let invalidRepositoryCount: Int?
    let cacheHitCount: Int?
    let reflogUnchangedSkipCount: Int?
    let recomputedRepositoryCount: Int?
    let sharedDataWritten: Bool?

    init(
        repositoryCount: Int?,
        invalidRepositoryCount: Int? = nil,
        cacheHitCount: Int?,
        reflogUnchangedSkipCount: Int?,
        recomputedRepositoryCount: Int?,
        sharedDataWritten: Bool?
    ) {
        self.repositoryCount = repositoryCount
        self.invalidRepositoryCount = invalidRepositoryCount
        self.cacheHitCount = cacheHitCount
        self.reflogUnchangedSkipCount = reflogUnchangedSkipCount
        self.recomputedRepositoryCount = recomputedRepositoryCount
        self.sharedDataWritten = sharedDataWritten
    }
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
            invalidRepositoryCount: values["invalid_repository_count"].flatMap(Int.init),
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
        "refresh script exited with status \(terminationStatus)"
    }
}

final class GitActivityRefreshCoordinator {
    typealias ScriptRunner = (URL, [URL]) throws -> GitRefreshScriptResult
    typealias ScriptURLProvider = () -> URL?
    typealias AuthorizedRootsProvider = () -> GitScanRootAccessResult
    typealias DiagnosticRecorder = (GitActivityRefreshDiagnostic, GitTodayActivityRefreshTrigger) -> Void

    private struct PublishedWidgetActivity: Equatable {
        let focusBlockCount: Int
        let commitCount: Int
        let recentProjectName: String?

        init(_ snapshot: GitTodayActivitySnapshot?) {
            focusBlockCount = max(0, snapshot?.focusBlockCount ?? 0)
            commitCount = max(0, snapshot?.commitCount ?? 0)
            let projectName = snapshot?.recentProjectName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            recentProjectName = projectName?.isEmpty == false ? projectName : nil
        }
    }

    private let activityStore: GitTodayActivityStore
    private let dailyStatsStore: DailyStatsStore
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let widgetReloader: () -> Void
    private let scriptRunner: ScriptRunner
    private let scriptURLProvider: ScriptURLProvider
    private let authorizedRootsProvider: AuthorizedRootsProvider
    private let dateProvider: () -> Date
    private let workspaceNotificationCenter: NotificationCenter
    private let statusNotificationCenter: NotificationCenter
    private let diagnosticRecorder: DiagnosticRecorder
    private let refreshInterval: TimeInterval
    private let minimumRefreshSpacing: TimeInterval
    private let wakeRefreshCoalescingInterval: TimeInterval
    private let refreshQueue = DispatchQueue(label: "TinyBuddy.GitActivityRefresh", qos: .utility)

    private var timer: Timer?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var isStarted = false
    private var lifecycleGeneration = 0
    private var isApplicationActive = false
    private var isRefreshing = false
    private var lastRefreshAttemptAt: Date?
    private var lastRefreshFailureAt: Date?
    private var lastWakeRefreshAt: Date?
    private var pendingWakeRefreshTrigger: GitTodayActivityRefreshTrigger?
    private var pendingWakeRefreshRequestedAt: Date?

    init(
        activityStore: GitTodayActivityStore = GitTodayActivityStore(),
        dailyStatsStore: DailyStatsStore = DailyStatsStore(),
        combinedSnapshotStore: TinyBuddyCombinedSnapshotStore? = nil,
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
        statusNotificationCenter: NotificationCenter = .default,
        diagnosticRecorder: @escaping DiagnosticRecorder = GitActivityRefreshCoordinator.logDiagnostic(_:trigger:),
        wakeRefreshCoalescingInterval: TimeInterval = 5
    ) {
        self.activityStore = activityStore
        self.dailyStatsStore = dailyStatsStore
        self.combinedSnapshotStore = combinedSnapshotStore ?? dailyStatsStore.makeCombinedSnapshotStore()
        self.refreshStatusStore = refreshStatusStore
        self.refreshInterval = refreshInterval
        self.minimumRefreshSpacing = minimumRefreshSpacing
        self.widgetReloader = widgetReloader
        self.scriptURLProvider = scriptURLProvider
        self.scriptRunner = scriptRunner
        self.authorizedRootsProvider = authorizedRootsProvider ?? gitScanRootStore.accessAuthorizedRootResult
        self.dateProvider = dateProvider
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.statusNotificationCenter = statusNotificationCenter
        self.diagnosticRecorder = diagnosticRecorder
        self.wakeRefreshCoalescingInterval = wakeRefreshCoalescingInterval
    }

    func start(isApplicationActive: Bool = true) {
        guard !isStarted else {
            return
        }

        isStarted = true
        registerWorkspaceNotificationsIfNeeded()
        self.isApplicationActive = isApplicationActive
        if isApplicationActive {
            scheduleTimerIfNeeded()
        }
        refresh(trigger: .launch, force: true)
    }

    func handleDidBecomeActive() {
        isApplicationActive = true
        scheduleTimerIfNeeded()
        refresh(trigger: .becameActive)
    }

    func handleDidResignActive() {
        isApplicationActive = false
        timer?.invalidate()
        timer = nil
        pendingWakeRefreshTrigger = nil
        pendingWakeRefreshRequestedAt = nil
    }

    func handleReopen() {
        if isApplicationActive {
            scheduleTimerIfNeeded()
        }
        refresh(trigger: .reopen)
    }

    func handleAuthorizationChanged() {
        if isApplicationActive {
            scheduleTimerIfNeeded()
        }
        refresh(trigger: .reopen, force: true, bypassFailureBackoff: true)
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

    func stop() {
        isStarted = false
        lifecycleGeneration &+= 1
        isApplicationActive = false
        isRefreshing = false
        timer?.invalidate()
        timer = nil
        workspaceNotificationObservers.forEach(workspaceNotificationCenter.removeObserver)
        workspaceNotificationObservers.removeAll()
        pendingWakeRefreshTrigger = nil
        pendingWakeRefreshRequestedAt = nil
    }

    deinit {
        stop()
    }

    var isPeriodicRefreshScheduled: Bool {
        timer != nil
    }

    var workspaceNotificationObserverCount: Int {
        workspaceNotificationObservers.count
    }

    private func scheduleTimerIfNeeded() {
        guard timer == nil else {
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isApplicationActive else {
                    return
                }

                self.refresh(trigger: .timer)
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
        guard isApplicationActive else {
            return
        }

        let now = dateProvider()

        if isRefreshing {
            pendingWakeRefreshTrigger = trigger
            pendingWakeRefreshRequestedAt = now
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

    private func finishRefresh(succeeded: Bool) {
        isRefreshing = false

        guard isApplicationActive else {
            pendingWakeRefreshTrigger = nil
            pendingWakeRefreshRequestedAt = nil
            return
        }

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
    private func refresh(
        trigger: GitTodayActivityRefreshTrigger,
        force: Bool = false,
        bypassFailureBackoff: Bool = false
    ) -> Bool {
        let now = dateProvider()

        guard bypassFailureBackoff || shouldRetryAfterFailure(at: now) else {
            return false
        }

        guard force || shouldRefresh(at: now) else {
            return false
        }

        guard !isRefreshing else {
            return false
        }

        guard let scriptURL = scriptURLProvider() else {
            lastRefreshAttemptAt = now
            lastRefreshFailureAt = now
            let diagnostic = GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .scriptLookup,
                reason: .scriptMissing
            )
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .failed,
                diagnostic: diagnostic,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    widgetReloaded: false,
                    reason: diagnostic.stableIdentifier
                )
            )
            return false
        }

        let accessResult = authorizedRootsProvider()
        let scopedRoots = accessResult.roots
        let authorizedRootURLs = scopedRoots.map(\.url)
        if accessResult.issue == .authorizationInvalid {
            lastRefreshAttemptAt = now
            lastRefreshFailureAt = now
            let diagnostic = diagnostic(for: accessResult.issue)
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .failed,
                diagnostic: diagnostic,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: authorizedRootURLs.count,
                    widgetReloaded: false,
                    reason: diagnostic.stableIdentifier
                )
            )
            scopedRoots.forEach { $0.stopAccessing() }
            return false
        }

        guard !authorizedRootURLs.isEmpty else {
            timer?.invalidate()
            timer = nil
            let diagnostic = diagnostic(for: accessResult.issue)
            recordRefreshStatus(
                refreshedAt: now,
                trigger: trigger,
                outcome: .skipped,
                diagnostic: diagnostic,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 0,
                    authorizedRootCount: 0,
                    widgetReloaded: false,
                    reason: diagnostic.stableIdentifier
                )
            )
            scopedRoots.forEach { $0.stopAccessing() }
            return false
        }

        isRefreshing = true
        lastRefreshAttemptAt = now
        let lifecycleGeneration = self.lifecycleGeneration
        let scriptRunner = self.scriptRunner

        refreshQueue.async { [weak self] in
            defer {
                scopedRoots.forEach { $0.stopAccessing() }
            }

            do {
                let scriptResult = try scriptRunner(scriptURL, authorizedRootURLs)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.lifecycleGeneration == lifecycleGeneration else {
                        return
                    }

                    let currentActivityRead = self.activityStore.loadTodaySnapshotRead()
                    let currentSnapshot = currentActivityRead.snapshot
                    guard currentSnapshot.focusBlockCount != nil,
                          currentSnapshot.commitCount != nil else {
                        let diagnostic = GitActivityRefreshDiagnostic(
                            source: .gitActivityRefresh,
                            stage: .activitySnapshotLoad,
                            reason: .refreshedActivityUnavailable
                        )
                        self.lastRefreshFailureAt = now
                        self.recordRefreshStatus(
                            refreshedAt: now,
                            trigger: trigger,
                            outcome: .failed,
                            diagnostic: diagnostic,
                            metrics: self.makeMetrics(
                                startedAt: now,
                                finishedAt: self.dateProvider(),
                                authorizedRootCount: authorizedRootURLs.count,
                                scriptMetrics: scriptResult.metrics,
                                widgetReloaded: false,
                                diagnostic: diagnostic
                            )
                        )
                        self.finishRefresh(succeeded: false)
                        return
                    }

                    let fallbackSnapshot = self.dailyStatsStore.loadSnapshot()
                    let previouslyCommittedSnapshot = self.combinedSnapshotStore.loadReadOnly()
                    let previouslyPublishedActivity = previouslyCommittedSnapshot?.dayIdentifier
                        == fallbackSnapshot.stats.dayIdentifier
                        ? previouslyCommittedSnapshot?.activitySnapshot
                        : nil
                    let combinedUpdate = self.combinedSnapshotStore.updateActivitySlice(
                        currentSnapshot,
                        activityRevision: currentActivityRead.trustedRevision,
                        fallbackSnapshot: fallbackSnapshot
                    )
                    let didReachCommittedCheckpoint: Bool
                    switch combinedUpdate.outcome {
                    case .saved:
                        didReachCommittedCheckpoint = combinedUpdate.didPersist
                    case .alreadyCurrent:
                        didReachCommittedCheckpoint = true
                    case .rejectedStaleActivity,
                         .rejectedInvalidActivityRevision,
                         .revisionExhausted,
                         .persistenceFailed:
                        didReachCommittedCheckpoint = false
                    }

                    guard didReachCommittedCheckpoint else {
                        let diagnostic = GitActivityRefreshDiagnostic(
                            source: .gitActivityRefresh,
                            stage: .combinedSnapshotCommit,
                            reason: .combinedSnapshotCommitFailed
                        )
                        self.lastRefreshFailureAt = now
                        self.recordRefreshStatus(
                            refreshedAt: now,
                            trigger: trigger,
                            outcome: .failed,
                            diagnostic: diagnostic,
                            metrics: self.makeMetrics(
                                startedAt: now,
                                finishedAt: self.dateProvider(),
                                authorizedRootCount: authorizedRootURLs.count,
                                scriptMetrics: scriptResult.metrics,
                                widgetReloaded: false,
                                diagnostic: diagnostic
                            )
                        )
                        self.finishRefresh(succeeded: false)
                        return
                    }

                    let committedSnapshotAfterUpdate = self.combinedSnapshotStore.loadReadOnly()
                    let publishedActivityAfterUpdate = committedSnapshotAfterUpdate?.dayIdentifier
                        == fallbackSnapshot.stats.dayIdentifier
                        ? committedSnapshotAfterUpdate?.activitySnapshot
                        : nil
                    let didPublishCommittedSnapshot = previouslyCommittedSnapshot
                        != committedSnapshotAfterUpdate
                    let didChangePublishedWidgetActivity = PublishedWidgetActivity(previouslyPublishedActivity)
                        != PublishedWidgetActivity(publishedActivityAfterUpdate)

                    if didPublishCommittedSnapshot {
                        self.mirrorActivitySnapshotToStandardDefaults(
                            currentSnapshot,
                            refreshedAt: now
                        )
                        self.statusNotificationCenter.post(name: .gitActivitySnapshotDidChange, object: nil)
                    }
                    let didReloadWidget = GitTodayActivityRefreshPolicy.shouldReloadWidget(
                        for: trigger,
                        didChange: didChangePublishedWidgetActivity
                    )
                    if didReloadWidget {
                        self.widgetReloader()
                    }

                    self.recordRefreshStatus(
                        refreshedAt: now,
                        trigger: trigger,
                        outcome: scriptResult.metrics?.invalidRepositoryCount ?? 0 > 0 ? .partial : .succeeded,
                        diagnostic: scriptResult.metrics?.invalidRepositoryCount ?? 0 > 0
                            ? GitActivityRefreshDiagnostic(
                                source: .gitActivityRefresh,
                                stage: .scriptExecution,
                                reason: .partialRecovery
                            )
                            : nil,
                        metrics: self.makeMetrics(
                            startedAt: now,
                            finishedAt: self.dateProvider(),
                            authorizedRootCount: authorizedRootURLs.count,
                            scriptMetrics: scriptResult.metrics,
                            widgetReloaded: didReloadWidget,
                            diagnostic: nil
                        )
                    )
                    self.lastRefreshFailureAt = nil
                    self.finishRefresh(succeeded: true)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.lifecycleGeneration == lifecycleGeneration else {
                        return
                    }

                    let scriptMetrics = (error as? GitRefreshScriptExecutionError)?.metrics
                    if let scriptError = error as? GitRefreshScriptExecutionError {
                        NSLog(
                            "TinyBuddy: git refresh script failure %@",
                            GitActivityRefreshCoordinator.scriptFailureSummary(
                                terminationStatus: scriptError.terminationStatus,
                                standardOutput: scriptError.standardOutput,
                                standardError: scriptError.standardError
                            )
                        )
                    }
                    let diagnostic = GitActivityRefreshDiagnostic(
                        source: .gitActivityRefresh,
                        stage: .scriptExecution,
                        reason: .scriptExecutionFailed
                    )
                    self.lastRefreshFailureAt = now
                    self.recordRefreshStatus(
                        refreshedAt: now,
                        trigger: trigger,
                        outcome: .failed,
                        diagnostic: diagnostic,
                        metrics: self.makeMetrics(
                            startedAt: now,
                            finishedAt: self.dateProvider(),
                            authorizedRootCount: authorizedRootURLs.count,
                            scriptMetrics: scriptMetrics,
                            widgetReloaded: false,
                            diagnostic: diagnostic
                        )
                    )
                    self.finishRefresh(succeeded: false)
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

    private func shouldRetryAfterFailure(at now: Date) -> Bool {
        guard let lastRefreshFailureAt else {
            return true
        }

        return now.timeIntervalSince(lastRefreshFailureAt) >= refreshInterval
    }

    private func recordRefreshStatus(
        refreshedAt: Date,
        trigger: GitTodayActivityRefreshTrigger,
        outcome: GitActivityRefreshOutcome,
        diagnostic: GitActivityRefreshDiagnostic?,
        metrics: GitActivityRefreshMetrics? = nil
    ) {
        let status = GitActivityRefreshStatus(
            refreshedAt: refreshedAt,
            trigger: trigger,
            outcome: outcome,
            diagnostic: diagnostic,
            metrics: metrics
        )
        refreshStatusStore.save(status)
        statusNotificationCenter.post(name: .gitActivityRefreshStatusDidChange, object: status)
        if let diagnostic {
            diagnosticRecorder(diagnostic, trigger)
        }
    }

    private func makeMetrics(
        startedAt: Date,
        finishedAt: Date,
        authorizedRootCount: Int,
        scriptMetrics: GitRefreshScriptMetrics?,
        widgetReloaded: Bool,
        diagnostic: GitActivityRefreshDiagnostic?
    ) -> GitActivityRefreshMetrics {
        GitActivityRefreshMetrics(
            durationMilliseconds: max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000)),
            authorizedRootCount: authorizedRootCount,
            repositoryCount: scriptMetrics?.repositoryCount,
            cacheHitCount: scriptMetrics?.cacheHitCount,
            reflogUnchangedSkipCount: scriptMetrics?.reflogUnchangedSkipCount,
            recomputedRepositoryCount: scriptMetrics?.recomputedRepositoryCount,
            invalidRepositoryCount: scriptMetrics?.invalidRepositoryCount,
            sharedDataWritten: scriptMetrics?.sharedDataWritten,
            widgetReloaded: widgetReloaded,
            reason: diagnostic?.stableIdentifier
        )
    }

    private func diagnostic(for issue: GitScanRootAccessIssue?) -> GitActivityRefreshDiagnostic {
        switch issue {
        case .authorizationInvalid:
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .authorizationResolution,
                reason: .authorizationInvalid
            )
        case .authorizationRequired, .none:
            return GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .authorizationResolution,
                reason: .authorizationRequired
            )
        }
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
        process.arguments = scriptProcessArguments()
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
        environment["TMPDIR"] = Self.scriptTemporaryDirectoryEnvironment(temporaryDirectoryURL)
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
        let standardInputPipe = Pipe()
        process.standardInput = standardInputPipe

        try process.run()
        standardInputPipe.fileHandleForWriting.write(try Data(contentsOf: scriptURL))
        try standardInputPipe.fileHandleForWriting.close()
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

        return GitRefreshScriptResult(
            standardOutput: visibleOutput,
            standardError: standardError,
            metrics: metrics
        )
    }

    static func scriptProcessArguments() -> [String] {
        ["-s"]
    }

    private static func resolvedUserHomeDirectoryPath() -> String {
        if let homeDirectory = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }),
           !homeDirectory.isEmpty {
            return homeDirectory
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func scriptFailureSummary(
        terminationStatus: Int32,
        standardOutput: String,
        standardError: String
    ) -> String {
        let combinedOutput = "\(standardOutput)\n\(standardError)".lowercased()
        let permissionDenied = combinedOutput.contains("permission denied")
            || combinedOutput.contains("operation not permitted")
        let sandboxBlocked = combinedOutput.contains("operation not permitted")
            || combinedOutput.contains("sandbox")
        let pathPresent = combinedOutput.contains("/")
        let command = [
            ("mktemp", "mktemp"),
            ("find:", "find"),
            ("date:", "date"),
            ("defaults", "defaults"),
            ("plutil", "plutil"),
            ("perl", "perl"),
            ("plistbuddy", "plistbuddy")
        ].first { combinedOutput.contains($0.0) }?.1 ?? "unknown"
        let deniedExecutable = combinedOutput
            .split(whereSeparator: { $0.isWhitespace })
            .firstIndex(where: { $0 == "operation" })
            .flatMap { operationIndex in
                combinedOutput
                    .split(whereSeparator: { $0.isWhitespace })[..<operationIndex]
                    .reversed()
                    .compactMap { token -> String? in
                        let candidate = token.trimmingCharacters(in: .punctuationCharacters)
                        guard candidate.contains("/") else {
                            return nil
                        }
                        guard let basename = candidate.split(separator: "/").last.map(String.init),
                              basename.contains(".") || basename.contains("-") else {
                            return nil
                        }
                        return basename
                    }
                    .first
            }
        let classifiedCommand = command != "unknown"
            ? command
            : deniedExecutable ?? "unknown"
        let resolvedCommand = classifiedCommand == "unknown" &&
            (combinedOutput.contains("bash:") || combinedOutput.range(of: #"line [0-9]+:"#, options: .regularExpression) != nil)
            ? "shell"
            : classifiedCommand

        let permission = permissionDenied ? "denied" : "unknown"
        let sandbox = sandboxBlocked ? "blocked" : "unknown"
        let path = pathPresent ? "present" : "absent"
        let error = combinedOutput.contains("operation not permitted")
            ? "operation-not-permitted"
            : combinedOutput.contains("permission denied") ? "permission-denied" : "unknown"
        let lineNumber = combinedOutput
            .range(of: #"line [0-9]+:"#, options: .regularExpression)
            .map { combinedOutput[$0].filter(\.isNumber) }
            ?? "unknown"
        return "status=\(terminationStatus) stdout_bytes=\(standardOutput.utf8.count) stderr_bytes=\(standardError.utf8.count) permission=\(permission) sandbox=\(sandbox) path=\(path) command=\(resolvedCommand) error=\(error) line=\(lineNumber)"
    }

    static func scriptTemporaryDirectoryEnvironment(_ url: URL) -> String {
        url.path.hasSuffix("/") ? url.path : "\(url.path)/"
    }

    private static func logDiagnostic(
        _ diagnostic: GitActivityRefreshDiagnostic,
        trigger: GitTodayActivityRefreshTrigger
    ) {
        NSLog(
            "TinyBuddy: git refresh diagnostic %@ for trigger %@",
            diagnostic.stableIdentifier,
            String(describing: trigger)
        )
    }
}
