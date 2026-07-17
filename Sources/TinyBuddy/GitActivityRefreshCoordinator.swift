import AppKit
import Foundation
import TinyBuddyCore
import WidgetKit
import Darwin

extension Notification.Name {
    static let gitActivityRefreshStatusDidChange = Notification.Name("TinyBuddy.gitActivityRefreshStatusDidChange")
    static let gitActivityRefreshDidStart = Notification.Name("TinyBuddy.gitActivityRefreshDidStart")
    static let gitActivityRefreshRequested = Notification.Name("TinyBuddy.gitActivityRefreshRequested")
    static let gitActivitySnapshotDidChange = Notification.Name("TinyBuddy.gitActivitySnapshotDidChange")
    static let gitScanRootAuthorizationRequested = Notification.Name("TinyBuddy.gitScanRootAuthorizationRequested")
    static let tinyBuddyTimeEnvironmentDidChange = Notification.Name("TinyBuddy.timeEnvironmentDidChange")
}

enum TinyBuddyLifecycleNotification {
    static let generationKey = "TinyBuddy.lifecycleGeneration"
}

enum GitRefreshScriptOutcome: String, Equatable {
    case success
    case partial
    case skipped
    case failed
    case unknown

    init(metricsValue: String) {
        self = Self(rawValue: metricsValue) ?? .unknown
    }
}

struct GitRefreshScriptMetrics: Equatable {
    let repositoryCount: Int?
    let invalidRepositoryCount: Int?
    let refreshOutcome: GitRefreshScriptOutcome?
    let cacheHitCount: Int?
    let reflogUnchangedSkipCount: Int?
    let recomputedRepositoryCount: Int?
    let retainedRepositoryCount: Int?
    let sharedDataWritten: Bool?

    init(
        repositoryCount: Int?,
        invalidRepositoryCount: Int? = nil,
        refreshOutcome: GitRefreshScriptOutcome? = nil,
        cacheHitCount: Int?,
        reflogUnchangedSkipCount: Int?,
        recomputedRepositoryCount: Int?,
        retainedRepositoryCount: Int? = nil,
        sharedDataWritten: Bool?
    ) {
        self.repositoryCount = repositoryCount
        self.invalidRepositoryCount = invalidRepositoryCount
        self.refreshOutcome = refreshOutcome
        self.cacheHitCount = cacheHitCount
        self.reflogUnchangedSkipCount = reflogUnchangedSkipCount
        self.recomputedRepositoryCount = recomputedRepositoryCount
        self.retainedRepositoryCount = retainedRepositoryCount
        self.sharedDataWritten = sharedDataWritten
    }
}

struct GitRefreshScriptResult {
    let standardOutput: String
    let standardError: String
    let metrics: GitRefreshScriptMetrics?
}

struct GitRefreshTimeScopeLease: Equatable {
    let token: String
    let fileURL: URL?
}

struct GitRefreshScriptResultParser {
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
            refreshOutcome: values["refresh_outcome"].map(GitRefreshScriptOutcome.init(metricsValue:)),
            cacheHitCount: values["cache_hit_count"].flatMap(Int.init),
            reflogUnchangedSkipCount: values["reflog_unchanged_skip_count"].flatMap(Int.init),
            recomputedRepositoryCount: values["recomputed_repository_count"].flatMap(Int.init),
            retainedRepositoryCount: values["retained_repository_count"].flatMap(Int.init),
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

private final class GitRefreshScriptExecutionController {
    private let lock = NSLock()
    private weak var process: Process?
    private var cancellationRequested = false

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        cancellationRequested = false
        lock.unlock()
    }

    func shouldStart(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.process === process && !cancellationRequested
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
            cancellationRequested = false
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let process = self.process
        cancellationRequested = process != nil
        lock.unlock()

        guard let process, process.isRunning else {
            return
        }
        process.terminate()
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
    typealias ScriptRunner = (
        URL,
        [URL],
        TinyBuddyTimeContext,
        GitRefreshTimeScopeLease
    ) throws -> GitRefreshScriptResult
    typealias ScriptURLProvider = () -> URL?
    typealias AuthorizedRootsProvider = () -> GitScanRootAccessResult
    typealias DiagnosticRecorder = (GitActivityRefreshDiagnostic, GitTodayActivityRefreshTrigger) -> Void
    typealias TimeScopePublisher = (String) -> URL?
    typealias ActivityCommitHook = () -> Void

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

    private enum ActivityCommitPreparation {
        case failed(GitActivityRefreshDiagnostic)
        case prepared(didPublishSnapshot: Bool, didChangeWidgetActivity: Bool)
    }

    private let activityStore: GitTodayActivityStore
    private let dailyStatsStore: DailyStatsStore
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let widgetReloader: () throws -> Void
    private let sharedSnapshotDiagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder
    private let scriptRunner: ScriptRunner
    private let cancelScript: () -> Void
    private let scriptURLProvider: ScriptURLProvider
    private let authorizedRootsProvider: AuthorizedRootsProvider
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let monotonicTimeProvider: () -> TimeInterval
    private let timeScopePublisher: TimeScopePublisher
    private let beforeActivityCommit: ActivityCommitHook
    private let workspaceNotificationCenter: NotificationCenter
    private let statusNotificationCenter: NotificationCenter
    private let diagnosticRecorder: DiagnosticRecorder
    private let refreshInterval: TimeInterval
    private let minimumRefreshSpacing: TimeInterval
    private let wakeRefreshCoalescingInterval: TimeInterval
    private let clockDiscontinuityTolerance: TimeInterval
    private let refreshQueue = DispatchQueue(label: "TinyBuddy.GitActivityRefresh", qos: .utility)
    private let activityCommitLock = NSLock()

    private var timer: Timer?
    private var dayBoundaryTimer: Timer?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var isStarted = false
    private var lifecycleGeneration = 0
    private var activityCommitGeneration = 0
    private var activeTimeContext: TinyBuddyTimeContext
    private var lastObservedTimeContext: TinyBuddyTimeContext
    private var lastObservedMonotonicTime: TimeInterval
    private var currentTimeScopeToken = UUID().uuidString
    private var currentTimeScopeFileURL: URL?
    private var needsWakeRevalidation = false
    private var isApplicationActive = false
    private var isRefreshing = false
    private var lastRefreshAttemptMonotonicTime: TimeInterval?
    private var lastRefreshFailureMonotonicTime: TimeInterval?
    private var lastWakeRefreshMonotonicTime: TimeInterval?
    private var pendingAuthorizationRefresh = false
    private var forceWidgetReloadAfterCurrentRefresh = false
    private var didReloadWidgetDuringCurrentRefresh = false
    private var lastWidgetExperienceState: GitActivityExperienceState
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
        widgetReloader: @escaping () throws -> Void = {
            WidgetCenter.shared.reloadAllTimelines()
        },
        scriptURLProvider: @escaping ScriptURLProvider = GitActivityRefreshCoordinator.locateRefreshScript,
        scriptRunner: ScriptRunner? = nil,
        cancelScript: @escaping () -> Void = {},
        authorizedRootsProvider: AuthorizedRootsProvider? = nil,
        timeEnvironment: TinyBuddyTimeEnvironment? = nil,
        dateProvider: @escaping () -> Date = Date.init,
        monotonicTimeProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        timeScopePublisher: TimeScopePublisher? = nil,
        beforeActivityCommit: @escaping ActivityCommitHook = {},
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        statusNotificationCenter: NotificationCenter = .default,
        diagnosticRecorder: @escaping DiagnosticRecorder = GitActivityRefreshCoordinator.logDiagnostic(_:trigger:),
        sharedSnapshotDiagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder = .shared,
        wakeRefreshCoalescingInterval: TimeInterval = 5,
        clockDiscontinuityTolerance: TimeInterval = 5
    ) {
        var adapterCalendar = Calendar.autoupdatingCurrent
        adapterCalendar.timeZone = .autoupdatingCurrent
        let resolvedTimeEnvironment = timeEnvironment ?? TinyBuddyTimeEnvironment(
            calendar: adapterCalendar,
            dateProvider: dateProvider
        )
        let initialTimeContext = resolvedTimeEnvironment.capture()
            ?? GitActivityRefreshCoordinator.fallbackTimeContext
        let initialMonotonicTime = monotonicTimeProvider()
        self.activityStore = activityStore
        self.dailyStatsStore = dailyStatsStore
        self.combinedSnapshotStore = combinedSnapshotStore ?? dailyStatsStore.makeCombinedSnapshotStore()
        self.refreshStatusStore = refreshStatusStore
        self.refreshInterval = refreshInterval
        self.minimumRefreshSpacing = minimumRefreshSpacing
        self.widgetReloader = widgetReloader
        self.sharedSnapshotDiagnosticRecorder = sharedSnapshotDiagnosticRecorder
        self.scriptURLProvider = scriptURLProvider
        if let scriptRunner {
            self.scriptRunner = scriptRunner
            self.cancelScript = cancelScript
        } else {
            let executionController = GitRefreshScriptExecutionController()
            self.scriptRunner = { scriptURL, rootURLs, timeContext, timeScopeLease in
                try GitActivityRefreshCoordinator.runScript(
                    at: scriptURL,
                    scanningRoots: rootURLs,
                    timeContext: timeContext,
                    timeScopeLease: timeScopeLease,
                    executionController: executionController
                )
            }
            self.cancelScript = executionController.cancel
        }
        self.authorizedRootsProvider = authorizedRootsProvider ?? gitScanRootStore.accessAuthorizedRootResult
        self.timeEnvironment = resolvedTimeEnvironment
        self.monotonicTimeProvider = monotonicTimeProvider
        self.timeScopePublisher = timeScopePublisher
            ?? GitActivityRefreshCoordinator.publishTimeScopeToken
        self.beforeActivityCommit = beforeActivityCommit
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.statusNotificationCenter = statusNotificationCenter
        self.diagnosticRecorder = diagnosticRecorder
        self.wakeRefreshCoalescingInterval = wakeRefreshCoalescingInterval
        self.clockDiscontinuityTolerance = clockDiscontinuityTolerance
        self.activeTimeContext = initialTimeContext
        self.lastObservedTimeContext = initialTimeContext
        self.lastObservedMonotonicTime = initialMonotonicTime
        self.lastWidgetExperienceState = GitActivityExperienceState(
            refreshStatus: refreshStatusStore.load(),
            activitySnapshot: activityStore.loadTodaySnapshot()
        )
    }

    func start(isApplicationActive: Bool = true) {
        guard !isStarted else {
            return
        }

        isStarted = true
        if let context = timeEnvironment.capture() {
            activeTimeContext = context
            observeTimeContext(context, at: monotonicTimeProvider())
        }
        renewTimeScopeLease()
        registerWorkspaceNotificationsIfNeeded()
        self.isApplicationActive = isApplicationActive
        if isApplicationActive {
            scheduleTimerIfNeeded()
        }
        scheduleDayBoundaryTimer()
        refresh(trigger: .launch, force: true)
    }

    func handleDidBecomeActive() {
        isApplicationActive = true
        scheduleTimerIfNeeded()
        if needsWakeRevalidation {
            needsWakeRevalidation = false
            invalidateTimeEnvironment(
                adopting: timeEnvironment.capture() ?? activeTimeContext,
                trigger: .becameActive,
                monotonicTime: monotonicTimeProvider()
            )
            return
        }
        if revalidateTimeContextIfNeeded(trigger: .becameActive) {
            return
        }
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
        if revalidateTimeContextIfNeeded(trigger: .reopen) {
            return
        }
        refresh(trigger: .reopen)
    }

    func handleTimeEnvironmentChanged(_ context: TinyBuddyTimeContext) {
        let monotonicTime = monotonicTimeProvider()
        guard shouldRevalidateTimeContext(context, at: monotonicTime) else {
            observeTimeContext(context, at: monotonicTime)
            return
        }
        invalidateTimeEnvironment(
            adopting: context,
            trigger: .timeEnvironmentChanged,
            monotonicTime: monotonicTime
        )
    }

    func handleWillSleep() {
        needsWakeRevalidation = true
        advanceLifecycleGeneration()
        isRefreshing = false
        timer?.invalidate()
        timer = nil
        dayBoundaryTimer?.invalidate()
        dayBoundaryTimer = nil
        pendingWakeRefreshTrigger = nil
        pendingWakeRefreshRequestedAt = nil
        renewTimeScopeLease()
        cancelScript()
    }

    func handleAuthorizationChanged() {
        if isApplicationActive {
            scheduleTimerIfNeeded()
        }
        if isRefreshing {
            pendingAuthorizationRefresh = true
            cancelScript()
            return
        }
        didReloadWidgetDuringCurrentRefresh = false
        forceWidgetReloadAfterCurrentRefresh = true
        if !refresh(trigger: .reopen, force: true, bypassFailureBackoff: true) {
            if !didReloadWidgetDuringCurrentRefresh {
                reloadWidgetForStateChange()
            }
            didReloadWidgetDuringCurrentRefresh = false
            forceWidgetReloadAfterCurrentRefresh = false
        }
    }

    func handleManualRefresh() {
        if isRefreshing {
            return
        }
        didReloadWidgetDuringCurrentRefresh = false
        forceWidgetReloadAfterCurrentRefresh = true
        if !refresh(trigger: .reopen, force: true, bypassFailureBackoff: true) {
            if !didReloadWidgetDuringCurrentRefresh {
                reloadWidgetForStateChange()
            }
            didReloadWidgetDuringCurrentRefresh = false
            forceWidgetReloadAfterCurrentRefresh = false
        }
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
        advanceLifecycleGeneration()
        renewTimeScopeLease()
        isApplicationActive = false
        isRefreshing = false
        timer?.invalidate()
        timer = nil
        dayBoundaryTimer?.invalidate()
        dayBoundaryTimer = nil
        workspaceNotificationObservers.forEach(workspaceNotificationCenter.removeObserver)
        workspaceNotificationObservers.removeAll()
        pendingAuthorizationRefresh = false
        forceWidgetReloadAfterCurrentRefresh = false
        didReloadWidgetDuringCurrentRefresh = false
        pendingWakeRefreshTrigger = nil
        pendingWakeRefreshRequestedAt = nil
        needsWakeRevalidation = false
        cancelScript()
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

                self.handleTimerFired()
            }
        }
    }

    private func scheduleDayBoundaryTimer() {
        dayBoundaryTimer?.invalidate()
        let interval = max(0.1, activeTimeContext.nextDayBoundary.timeIntervalSince(activeTimeContext.now))
        dayBoundaryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let context = self.timeEnvironment.capture() ?? self.activeTimeContext
                self.invalidateTimeEnvironment(
                    adopting: context,
                    trigger: .timeEnvironmentChanged,
                    monotonicTime: self.monotonicTimeProvider()
                )
            }
        }
    }

    private func handleTimerFired() {
        guard isApplicationActive else {
            return
        }
        if revalidateTimeContextIfNeeded(trigger: .timer) {
            return
        }
        refresh(trigger: .timer)
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

        if needsWakeRevalidation {
            needsWakeRevalidation = false
            let context = timeEnvironment.capture() ?? activeTimeContext
            invalidateTimeEnvironment(
                adopting: context,
                trigger: trigger,
                monotonicTime: monotonicTimeProvider()
            )
            return
        }
        if revalidateTimeContextIfNeeded(trigger: trigger) {
            return
        }

        let monotonicTime = monotonicTimeProvider()

        if isRefreshing {
            pendingWakeRefreshTrigger = trigger
            pendingWakeRefreshRequestedAt = activeTimeContext.now
            return
        }

        if let lastWakeRefreshMonotonicTime,
           monotonicTime - lastWakeRefreshMonotonicTime < wakeRefreshCoalescingInterval {
            return
        }

        if refresh(trigger: trigger, force: true) {
            lastWakeRefreshMonotonicTime = monotonicTime
        }
    }

    private func finishRefresh(succeeded: Bool) {
        isRefreshing = false

        if forceWidgetReloadAfterCurrentRefresh && !didReloadWidgetDuringCurrentRefresh {
            reloadWidgetForStateChange()
        }
        forceWidgetReloadAfterCurrentRefresh = false
        didReloadWidgetDuringCurrentRefresh = false

        if pendingAuthorizationRefresh {
            pendingAuthorizationRefresh = false
            forceWidgetReloadAfterCurrentRefresh = true
            if refresh(trigger: .reopen, force: true, bypassFailureBackoff: true) {
                return
            }
            reloadWidgetForStateChange()
            forceWidgetReloadAfterCurrentRefresh = false
        }

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
           let lastWakeRefreshMonotonicTime,
           let pendingWakeRefreshRequestedAt,
           activeTimeContext.now.timeIntervalSince(pendingWakeRefreshRequestedAt) >= 0,
           monotonicTimeProvider() - lastWakeRefreshMonotonicTime < wakeRefreshCoalescingInterval {
            return
        }

        if refresh(trigger: pendingWakeRefreshTrigger, force: true) {
            lastWakeRefreshMonotonicTime = monotonicTimeProvider()
        }
    }

    @discardableResult
    private func refresh(
        trigger: GitTodayActivityRefreshTrigger,
        force: Bool = false,
        bypassFailureBackoff: Bool = false
    ) -> Bool {
        let timeContext = timeEnvironment.capture() ?? activeTimeContext
        let monotonicTime = monotonicTimeProvider()

        guard bypassFailureBackoff || shouldRetryAfterFailure(at: monotonicTime) else {
            return false
        }
        guard force || shouldRefresh(at: monotonicTime) else {
            return false
        }
        guard !isRefreshing else {
            return false
        }

        if currentTimeScopeFileURL == nil {
            renewTimeScopeLease()
        }
        guard currentTimeScopeFileURL != nil else {
            lastRefreshAttemptMonotonicTime = monotonicTime
            lastRefreshFailureMonotonicTime = monotonicTime
            let diagnostic = GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .scriptExecution,
                reason: .scriptExecutionFailed
            )
            recordRefreshStatus(
                refreshedAt: timeContext.now,
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

        guard let scriptURL = scriptURLProvider() else {
            lastRefreshAttemptMonotonicTime = monotonicTime
            lastRefreshFailureMonotonicTime = monotonicTime
            let diagnostic = GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .scriptLookup,
                reason: .scriptMissing
            )
            recordRefreshStatus(
                refreshedAt: timeContext.now,
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
        if accessResult.issue == .authorizationInvalid,
           authorizedRootURLs.isEmpty {
            lastRefreshAttemptMonotonicTime = monotonicTime
            lastRefreshFailureMonotonicTime = monotonicTime
            let diagnostic = diagnostic(for: accessResult.issue)
            recordRefreshStatus(
                refreshedAt: timeContext.now,
                trigger: trigger,
                outcome: .failed,
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

        guard !authorizedRootURLs.isEmpty else {
            timer?.invalidate()
            timer = nil
            let diagnostic = diagnostic(for: accessResult.issue)
            recordRefreshStatus(
                refreshedAt: timeContext.now,
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
        didReloadWidgetDuringCurrentRefresh = false
        statusNotificationCenter.post(
            name: .gitActivityRefreshDidStart,
            object: nil,
            userInfo: lifecycleNotificationUserInfo
        )
        lastRefreshAttemptMonotonicTime = monotonicTime
        let lifecycleGeneration = self.lifecycleGeneration
        let scriptRunner = self.scriptRunner
        let timeScopeLease = GitRefreshTimeScopeLease(
            token: currentTimeScopeToken,
            fileURL: currentTimeScopeFileURL
        )

        refreshQueue.async { [weak self] in
            var didStopAccessingRoots = false
            defer {
                if !didStopAccessingRoots {
                    scopedRoots.forEach { $0.stopAccessing() }
                }
            }

            do {
                let result = try scriptRunner(
                    scriptURL,
                    authorizedRootURLs,
                    timeContext,
                    timeScopeLease
                )
                scopedRoots.forEach { $0.stopAccessing() }
                didStopAccessingRoots = true
                let scriptOutcome = result.metrics?.refreshOutcome
                let commitPreparation: ActivityCommitPreparation?
                if scriptOutcome == .failed || scriptOutcome == .unknown || scriptOutcome == .skipped {
                    commitPreparation = nil
                } else {
                    let lifecycleIsCurrent = DispatchQueue.main.sync { [weak self] in
                        self?.lifecycleGeneration == lifecycleGeneration
                    }
                    guard lifecycleIsCurrent else {
                        return
                    }
                    let completionContext: TinyBuddyTimeContext? = DispatchQueue.main.sync { [weak self] in
                        guard let self else {
                            return nil
                        }
                        return self.validatedCompletionContext(
                            for: timeContext,
                            startedAtMonotonicTime: monotonicTime
                        )
                    }
                    guard let completionContext else {
                        DispatchQueue.main.async { [weak self] in
                            self?.handleDetectedTimeDiscontinuity(trigger: trigger)
                        }
                        return
                    }
                    self?.beforeActivityCommit()
                    guard let self,
                          let currentCommitPreparation = self.prepareActivityCommitIfCurrent(
                              lifecycleGeneration: lifecycleGeneration,
                              refreshedAt: completionContext.now
                          ) else {
                        return
                    }
                    commitPreparation = currentCommitPreparation
                }
                DispatchQueue.main.async { [weak self] in
                    self?.completeRefresh(
                        result: result,
                        commitPreparation: commitPreparation,
                        accessIssue: accessResult.issue,
                        authorizedRootCount: authorizedRootURLs.count,
                        trigger: trigger,
                        startedWith: timeContext,
                        startedAtMonotonicTime: monotonicTime,
                        lifecycleGeneration: lifecycleGeneration
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.completeFailedRefresh(
                        error: error,
                        authorizedRootCount: authorizedRootURLs.count,
                        trigger: trigger,
                        startedWith: timeContext,
                        startedAtMonotonicTime: monotonicTime,
                        lifecycleGeneration: lifecycleGeneration
                    )
                }
            }
        }

        return true
    }

    private func completeRefresh(
        result: GitRefreshScriptResult,
        commitPreparation: ActivityCommitPreparation?,
        accessIssue: GitScanRootAccessIssue?,
        authorizedRootCount: Int,
        trigger: GitTodayActivityRefreshTrigger,
        startedWith timeContext: TinyBuddyTimeContext,
        startedAtMonotonicTime: TimeInterval,
        lifecycleGeneration: Int
    ) {
        guard self.lifecycleGeneration == lifecycleGeneration else {
            return
        }
        guard let completionContext = validatedCompletionContext(
            for: timeContext,
            startedAtMonotonicTime: startedAtMonotonicTime
        ) else {
            handleDetectedTimeDiscontinuity(trigger: trigger)
            return
        }

        let completedAtMonotonicTime = monotonicTimeProvider()
        let scriptOutcome = result.metrics?.refreshOutcome
        if scriptOutcome == .failed || scriptOutcome == .unknown {
            let diagnostic = GitActivityRefreshDiagnostic(
                source: .gitActivityRefresh,
                stage: .scriptExecution,
                reason: .scriptExecutionFailed
            )
            lastRefreshFailureMonotonicTime = completedAtMonotonicTime
            recordRefreshStatus(
                refreshedAt: completionContext.now,
                trigger: trigger,
                outcome: .failed,
                diagnostic: diagnostic,
                metrics: makeMetrics(
                    startedAtMonotonicTime: startedAtMonotonicTime,
                    finishedAtMonotonicTime: completedAtMonotonicTime,
                    authorizedRootCount: authorizedRootCount,
                    scriptMetrics: result.metrics,
                    widgetReloaded: false,
                    diagnostic: diagnostic
                )
            )
            finishRefresh(succeeded: false)
            return
        }

        let hasPartialRecovery = accessIssue == .authorizationInvalid
            || scriptOutcome == .partial
            || (scriptOutcome == nil && (result.metrics?.invalidRepositoryCount ?? 0) > 0)
        if scriptOutcome == .skipped {
            let diagnostic = hasPartialRecovery
                ? partialRecoveryDiagnostic(
                    hasInvalidAuthorization: accessIssue == .authorizationInvalid
                )
                : nil
            recordRefreshStatus(
                refreshedAt: completionContext.now,
                trigger: trigger,
                outcome: hasPartialRecovery ? .partial : .skipped,
                diagnostic: diagnostic,
                metrics: makeMetrics(
                    startedAtMonotonicTime: startedAtMonotonicTime,
                    finishedAtMonotonicTime: completedAtMonotonicTime,
                    authorizedRootCount: authorizedRootCount,
                    scriptMetrics: result.metrics,
                    widgetReloaded: false,
                    diagnostic: diagnostic
                )
            )
            lastRefreshFailureMonotonicTime = nil
            finishRefresh(succeeded: true)
            return
        }

        guard let commitPreparation else {
            return
        }
        guard validatedCompletionContext(
            for: timeContext,
            startedAtMonotonicTime: startedAtMonotonicTime
        ) != nil else {
            handleDetectedTimeDiscontinuity(trigger: trigger)
            return
        }

        let didPublishCommittedSnapshot: Bool
        let didChangePublishedWidgetActivity: Bool
        switch commitPreparation {
        case .failed(let diagnostic):
            lastRefreshFailureMonotonicTime = completedAtMonotonicTime
            recordRefreshStatus(
                refreshedAt: completionContext.now,
                trigger: trigger,
                outcome: .failed,
                diagnostic: diagnostic,
                metrics: makeMetrics(
                    startedAtMonotonicTime: startedAtMonotonicTime,
                    finishedAtMonotonicTime: completedAtMonotonicTime,
                    authorizedRootCount: authorizedRootCount,
                    scriptMetrics: result.metrics,
                    widgetReloaded: false,
                    diagnostic: diagnostic
                )
            )
            finishRefresh(succeeded: false)
            return
        case .prepared(let didPublishSnapshot, let didChangeWidgetActivity):
            didPublishCommittedSnapshot = didPublishSnapshot
            didChangePublishedWidgetActivity = didChangeWidgetActivity
        }

        if didPublishCommittedSnapshot {
            statusNotificationCenter.post(
                name: .gitActivitySnapshotDidChange,
                object: nil,
                userInfo: lifecycleNotificationUserInfo
            )
        }
        let refreshOutcome: GitActivityRefreshOutcome = hasPartialRecovery ? .partial : .succeeded
        let diagnostic = hasPartialRecovery
            ? partialRecoveryDiagnostic(
                hasInvalidAuthorization: accessIssue == .authorizationInvalid
            )
            : nil
        let baseMetrics = makeMetrics(
            startedAtMonotonicTime: startedAtMonotonicTime,
            finishedAtMonotonicTime: completedAtMonotonicTime,
            authorizedRootCount: authorizedRootCount,
            scriptMetrics: result.metrics,
            widgetReloaded: false,
            diagnostic: diagnostic
        )
        let nextExperienceState = GitActivityExperienceState(
            refreshStatus: GitActivityRefreshStatus(
                refreshedAt: completionContext.now,
                trigger: trigger,
                outcome: refreshOutcome,
                diagnostic: diagnostic,
                metrics: baseMetrics
            ),
            activitySnapshot: activityStore.loadTodaySnapshot()
        )
        let stateWillChange = nextExperienceState != lastWidgetExperienceState
        let shouldReloadWidget = GitTodayActivityRefreshPolicy.shouldReloadWidget(
            for: trigger,
            didChange: didChangePublishedWidgetActivity
        )
        var didReloadWidget = false
        if shouldReloadWidget && !stateWillChange {
            didReloadWidget = reloadWidgetForStateChange()
            didReloadWidgetDuringCurrentRefresh = didReloadWidget
        }

        recordRefreshStatus(
            refreshedAt: completionContext.now,
            trigger: trigger,
            outcome: refreshOutcome,
            diagnostic: diagnostic,
            metrics: metricsByRecordingWidgetReload(
                baseMetrics,
                didReload: didReloadWidget
            )
        )
        lastRefreshFailureMonotonicTime = nil
        finishRefresh(succeeded: true)
    }

    private func completeFailedRefresh(
        error: Error,
        authorizedRootCount: Int,
        trigger: GitTodayActivityRefreshTrigger,
        startedWith timeContext: TinyBuddyTimeContext,
        startedAtMonotonicTime: TimeInterval,
        lifecycleGeneration: Int
    ) {
        guard self.lifecycleGeneration == lifecycleGeneration else {
            return
        }
        guard let completionContext = validatedCompletionContext(
            for: timeContext,
            startedAtMonotonicTime: startedAtMonotonicTime
        ) else {
            handleDetectedTimeDiscontinuity(trigger: trigger)
            return
        }

        let scriptMetrics = (error as? GitRefreshScriptExecutionError)?.metrics
        if let scriptError = error as? GitRefreshScriptExecutionError {
            NSLog(
                "TinyBuddy: git refresh script failure %@",
                Self.scriptFailureSummary(
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
        let completedAtMonotonicTime = monotonicTimeProvider()
        lastRefreshFailureMonotonicTime = completedAtMonotonicTime
        recordRefreshStatus(
            refreshedAt: completionContext.now,
            trigger: trigger,
            outcome: .failed,
            diagnostic: diagnostic,
            metrics: makeMetrics(
                startedAtMonotonicTime: startedAtMonotonicTime,
                finishedAtMonotonicTime: completedAtMonotonicTime,
                authorizedRootCount: authorizedRootCount,
                scriptMetrics: scriptMetrics,
                widgetReloaded: false,
                diagnostic: diagnostic
            )
        )
        finishRefresh(succeeded: false)
    }

    private func prepareActivityCommit(refreshedAt: Date) -> ActivityCommitPreparation {
        let currentActivityRead = activityStore.loadTodaySnapshotRead()
        let currentSnapshot = currentActivityRead.snapshot
        guard currentSnapshot.focusBlockCount != nil,
              currentSnapshot.commitCount != nil else {
            return .failed(
                GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .activitySnapshotLoad,
                    reason: .refreshedActivityUnavailable
                )
            )
        }

        let fallbackSnapshot = dailyStatsStore.loadSnapshot()
        guard fallbackSnapshot.stats.dayIdentifier == activeTimeContext.dayIdentifier else {
            return .failed(
                GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .activitySnapshotLoad,
                    reason: .refreshedActivityUnavailable
                )
            )
        }
        let expectedDayIdentifier = fallbackSnapshot.stats.dayIdentifier
        let previouslyCommittedRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        previouslyCommittedRead.observation.map(sharedSnapshotDiagnosticRecorder.record)
        if let observation = previouslyCommittedRead.observation,
           observation.reason == .versionIncompatible
            || observation.reason == .appGroupUnavailable
            || observation.reason == .sandboxReadDenied {
            return .failed(combinedSnapshotCommitDiagnostic())
        }

        let recoverableReadFault: TinyBuddySharedSnapshotObservation?
        if let observation = previouslyCommittedRead.observation,
           previouslyCommittedRead.snapshot == nil,
           observation.reason == .snapshotCorrupt || observation.reason == .staleData {
            recoverableReadFault = observation
        } else {
            recoverableReadFault = nil
        }
        let previouslyCommittedSnapshot = previouslyCommittedRead.snapshot
        let previouslyPublishedActivity = previouslyCommittedSnapshot?.activitySnapshot
        let combinedUpdate = combinedSnapshotStore.updateActivitySlice(
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
             .versionIncompatible,
             .revisionExhausted,
             .persistenceFailed:
            didReachCommittedCheckpoint = false
        }
        guard didReachCommittedCheckpoint else {
            combinedUpdate.observation.map(sharedSnapshotDiagnosticRecorder.record)
            return .failed(combinedSnapshotCommitDiagnostic())
        }

        let committedReadAfterUpdate = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        committedReadAfterUpdate.observation.map(sharedSnapshotDiagnosticRecorder.record)
        guard let committedSnapshotAfterUpdate = committedReadAfterUpdate.snapshot else {
            if committedReadAfterUpdate.observation == nil {
                sharedSnapshotDiagnosticRecorder.record(
                    phase: .snapshotWrite,
                    reason: .persistenceFailed,
                    recovery: .stopped
                )
            }
            return .failed(combinedSnapshotCommitDiagnostic())
        }
        if let recoverableReadFault {
            sharedSnapshotDiagnosticRecorder.record(
                phase: .snapshotRead,
                reason: recoverableReadFault.reason,
                recovery: combinedUpdate.didPersist ? .rebuilt : .rereadSucceeded,
                attemptCount: recoverableReadFault.attemptCount + 1
            )
        }

        let didPublishCommittedSnapshot = previouslyCommittedSnapshot != committedSnapshotAfterUpdate
        if didPublishCommittedSnapshot {
            mirrorActivitySnapshotToStandardDefaults(currentSnapshot, refreshedAt: refreshedAt)
        }
        return .prepared(
            didPublishSnapshot: didPublishCommittedSnapshot,
            didChangeWidgetActivity: PublishedWidgetActivity(previouslyPublishedActivity)
                != PublishedWidgetActivity(committedSnapshotAfterUpdate.activitySnapshot)
        )
    }

    /// Serializes the final semantic commit with lifecycle invalidation. A time
    /// change that wins this lock advances the generation before an old refresh
    /// can write; a commit that wins completes atomically before invalidation is
    /// published, after which its completion notification is discarded.
    private func prepareActivityCommitIfCurrent(
        lifecycleGeneration: Int,
        refreshedAt: Date
    ) -> ActivityCommitPreparation? {
        activityCommitLock.lock()
        defer { activityCommitLock.unlock() }

        guard activityCommitGeneration == lifecycleGeneration else {
            return nil
        }
        return prepareActivityCommit(refreshedAt: refreshedAt)
    }

    private func advanceLifecycleGeneration() {
        activityCommitLock.lock()
        lifecycleGeneration &+= 1
        activityCommitGeneration = lifecycleGeneration
        activityCommitLock.unlock()
    }

    private func combinedSnapshotCommitDiagnostic() -> GitActivityRefreshDiagnostic {
        GitActivityRefreshDiagnostic(
            source: .gitActivityRefresh,
            stage: .combinedSnapshotCommit,
            reason: .combinedSnapshotCommitFailed
        )
    }

    private func shouldRefresh(at monotonicTime: TimeInterval) -> Bool {
        guard let lastRefreshAttemptMonotonicTime else {
            return true
        }

        let elapsed = monotonicTime - lastRefreshAttemptMonotonicTime
        return elapsed < 0 || elapsed >= minimumRefreshSpacing
    }

    private func shouldRetryAfterFailure(at monotonicTime: TimeInterval) -> Bool {
        guard let lastRefreshFailureMonotonicTime else {
            return true
        }

        let elapsed = monotonicTime - lastRefreshFailureMonotonicTime
        return elapsed < 0 || elapsed >= refreshInterval
    }

    private func revalidateTimeContextIfNeeded(
        trigger: GitTodayActivityRefreshTrigger
    ) -> Bool {
        let context = timeEnvironment.capture() ?? activeTimeContext
        let monotonicTime = monotonicTimeProvider()
        guard shouldRevalidateTimeContext(context, at: monotonicTime) else {
            observeTimeContext(context, at: monotonicTime)
            return false
        }
        invalidateTimeEnvironment(
            adopting: context,
            trigger: trigger,
            monotonicTime: monotonicTime
        )
        return true
    }

    private func shouldRevalidateTimeContext(
        _ context: TinyBuddyTimeContext,
        at monotonicTime: TimeInterval
    ) -> Bool {
        if context.dayIdentifier != activeTimeContext.dayIdentifier
            || context.signature != activeTimeContext.signature {
            return true
        }

        let monotonicElapsed = max(0, monotonicTime - lastObservedMonotonicTime)
        let expectedNow = lastObservedTimeContext.now.addingTimeInterval(monotonicElapsed)
        return abs(context.now.timeIntervalSince(expectedNow)) > clockDiscontinuityTolerance
    }

    private func observeTimeContext(
        _ context: TinyBuddyTimeContext,
        at monotonicTime: TimeInterval
    ) {
        lastObservedTimeContext = context
        lastObservedMonotonicTime = monotonicTime
    }

    private func invalidateTimeEnvironment(
        adopting context: TinyBuddyTimeContext,
        trigger: GitTodayActivityRefreshTrigger,
        monotonicTime: TimeInterval
    ) {
        advanceLifecycleGeneration()
        activeTimeContext = context
        observeTimeContext(context, at: monotonicTime)
        isRefreshing = false
        pendingAuthorizationRefresh = false
        pendingWakeRefreshTrigger = nil
        pendingWakeRefreshRequestedAt = nil
        forceWidgetReloadAfterCurrentRefresh = false
        didReloadWidgetDuringCurrentRefresh = false
        renewTimeScopeLease()
        cancelScript()
        if isApplicationActive {
            scheduleTimerIfNeeded()
        }
        if isStarted {
            scheduleDayBoundaryTimer()
        }
        statusNotificationCenter.post(
            name: .tinyBuddyTimeEnvironmentDidChange,
            object: context,
            userInfo: lifecycleNotificationUserInfo
        )
        _ = reloadWidgetForStateChange()
        _ = refresh(
            trigger: trigger,
            force: true,
            bypassFailureBackoff: true
        )
    }

    private func validatedCompletionContext(
        for startedContext: TinyBuddyTimeContext,
        startedAtMonotonicTime: TimeInterval
    ) -> TinyBuddyTimeContext? {
        let completionContext = timeEnvironment.capture() ?? activeTimeContext
        guard completionContext.dayIdentifier == startedContext.dayIdentifier,
              completionContext.signature == startedContext.signature else {
            return nil
        }
        let elapsed = max(0, monotonicTimeProvider() - startedAtMonotonicTime)
        let expectedNow = startedContext.now.addingTimeInterval(elapsed)
        guard abs(completionContext.now.timeIntervalSince(expectedNow))
            <= clockDiscontinuityTolerance else {
            return nil
        }
        return completionContext
    }

    private func handleDetectedTimeDiscontinuity(
        trigger: GitTodayActivityRefreshTrigger
    ) {
        let context = timeEnvironment.capture() ?? activeTimeContext
        invalidateTimeEnvironment(
            adopting: context,
            trigger: trigger == .timer ? .timer : .timeEnvironmentChanged,
            monotonicTime: monotonicTimeProvider()
        )
    }

    private func renewTimeScopeLease() {
        currentTimeScopeToken = UUID().uuidString
        TinyBuddyTimeScopeState.shared.replaceProcessToken(currentTimeScopeToken)
        currentTimeScopeFileURL = timeScopePublisher(currentTimeScopeToken)
    }

    private var lifecycleNotificationUserInfo: [AnyHashable: Any] {
        [TinyBuddyLifecycleNotification.generationKey: lifecycleGeneration]
    }

    private func recordRefreshStatus(
        refreshedAt: Date,
        trigger: GitTodayActivityRefreshTrigger,
        outcome: GitActivityRefreshOutcome,
        diagnostic: GitActivityRefreshDiagnostic?,
        metrics: GitActivityRefreshMetrics? = nil
    ) {
        if let diagnostic {
            diagnosticRecorder(diagnostic, trigger)
            recordSharedSnapshotObservation(for: diagnostic)
        }
        let preliminaryStatus = GitActivityRefreshStatus(
            refreshedAt: refreshedAt,
            trigger: trigger,
            outcome: outcome,
            diagnostic: diagnostic,
            metrics: metrics
        )
        // Persist the new state before asking WidgetKit to read it. This keeps
        // Timeline reloads from racing against the previous refresh status.
        refreshStatusStore.save(preliminaryStatus)

        let nextWidgetExperienceState = GitActivityExperienceState(
            refreshStatus: preliminaryStatus,
            activitySnapshot: activityStore.loadTodaySnapshot()
        )
        var didReloadForStateChange = false
        if nextWidgetExperienceState != lastWidgetExperienceState {
            didReloadForStateChange = reloadWidgetForStateChange()
            if didReloadForStateChange {
                didReloadWidgetDuringCurrentRefresh = true
            }
        }
        lastWidgetExperienceState = nextWidgetExperienceState

        let finalMetrics = metrics.map {
            metricsByRecordingWidgetReload(
                $0,
                didReload: didReloadForStateChange
            )
        }
        let status = GitActivityRefreshStatus(
            refreshedAt: refreshedAt,
            trigger: trigger,
            outcome: outcome,
            diagnostic: diagnostic,
            metrics: finalMetrics
        )
        if status != preliminaryStatus {
            refreshStatusStore.save(status)
        }
        statusNotificationCenter.post(
            name: .gitActivityRefreshStatusDidChange,
            object: status,
            userInfo: lifecycleNotificationUserInfo
        )
    }

    @discardableResult
    private func reloadWidgetForStateChange() -> Bool {
        do {
            try widgetReloader()
            return true
        } catch {
            sharedSnapshotDiagnosticRecorder.record(
                phase: .timelineReload,
                reason: .timelineReloadFailed,
                recovery: .stopped
            )
            return false
        }
    }

    private func metricsByRecordingWidgetReload(
        _ metrics: GitActivityRefreshMetrics,
        didReload: Bool
    ) -> GitActivityRefreshMetrics {
        GitActivityRefreshMetrics(
            durationMilliseconds: metrics.durationMilliseconds,
            authorizedRootCount: metrics.authorizedRootCount,
            repositoryCount: metrics.repositoryCount,
            cacheHitCount: metrics.cacheHitCount,
            reflogUnchangedSkipCount: metrics.reflogUnchangedSkipCount,
            recomputedRepositoryCount: metrics.recomputedRepositoryCount,
            invalidRepositoryCount: metrics.invalidRepositoryCount,
            sharedDataWritten: metrics.sharedDataWritten,
            widgetReloaded: didReload || metrics.widgetReloaded == true,
            reason: metrics.reason
        )
    }

    private func recordSharedSnapshotObservation(
        for diagnostic: GitActivityRefreshDiagnostic
    ) {
        switch diagnostic.reason {
        case .authorizationRequired, .authorizationInvalid:
            sharedSnapshotDiagnosticRecorder.record(
                phase: .gitScan,
                reason: .gitScanSkipped,
                recovery: .stopped
            )
        case .partialAuthorizationRecovery, .partialRecovery:
            sharedSnapshotDiagnosticRecorder.record(
                phase: .gitScan,
                reason: .gitScanPartial,
                recovery: .none
            )
        case .scriptMissing, .scriptExecutionFailed, .refreshedActivityUnavailable:
            sharedSnapshotDiagnosticRecorder.record(
                phase: .gitScan,
                reason: .gitScanFailed,
                recovery: .stopped
            )
        case .combinedSnapshotCommitFailed:
            // The underlying read/update path records the precise snapshot
            // observation before this user-facing status is emitted. Do not
            // overwrite an access, version, stale, or write diagnostic here.
            break
        }
    }

    private func makeMetrics(
        startedAtMonotonicTime: TimeInterval,
        finishedAtMonotonicTime: TimeInterval,
        authorizedRootCount: Int,
        scriptMetrics: GitRefreshScriptMetrics?,
        widgetReloaded: Bool,
        diagnostic: GitActivityRefreshDiagnostic?
    ) -> GitActivityRefreshMetrics {
        let duration = max(0, finishedAtMonotonicTime - startedAtMonotonicTime)
        let durationMilliseconds = Int(min(duration * 1_000, Double(Int.max)))
        return GitActivityRefreshMetrics(
            durationMilliseconds: durationMilliseconds,
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

    private func partialRecoveryDiagnostic(
        hasInvalidAuthorization: Bool
    ) -> GitActivityRefreshDiagnostic {
        GitActivityRefreshDiagnostic(
            source: .gitActivityRefresh,
            stage: hasInvalidAuthorization ? .authorizationResolution : .scriptExecution,
            reason: hasInvalidAuthorization ? .partialAuthorizationRecovery : .partialRecovery
        )
    }

    private func mirrorActivitySnapshotToStandardDefaults(
        _ snapshot: GitTodayActivitySnapshot,
        refreshedAt: Date
    ) {
        let defaults = UserDefaults.standard
        guard let dayIdentifier = activeTimeContext.dayIdentifier(for: refreshedAt),
              dayIdentifier == activeTimeContext.dayIdentifier else {
            return
        }

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

    private static let fallbackTimeContext: TinyBuddyTimeContext = {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        return TinyBuddyTimeContext(
            now: Date(timeIntervalSince1970: 0),
            timeZone: timeZone,
            locale: Locale(identifier: "en_US_POSIX"),
            sourceCalendar: calendar
        )!
    }()

    private static func publishTimeScopeToken(_ token: String) -> URL? {
        guard let fileURL = TinyBuddySharedData.timeScopeTokenURL() else {
            return nil
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let tombstone = "invalid-\(token)\n"
            do {
                try Data(tombstone.utf8).write(to: fileURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
            }
            try Data("\(token)\n".utf8).write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    private static func runScript(
        at scriptURL: URL,
        scanningRoots rootURLs: [URL],
        timeContext: TinyBuddyTimeContext,
        timeScopeLease: GitRefreshTimeScopeLease,
        executionController: GitRefreshScriptExecutionController
    ) throws -> GitRefreshScriptResult {
        let process = Process()
        executionController.register(process)
        defer { executionController.clear(process) }
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = scriptProcessArguments()
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        environment["LC_ALL"] = "C"
        environment["TZ"] = timeContext.timeZone.identifier
        environment["TINYBUDDY_TODAY"] = timeContext.dayIdentifier
        environment["TINYBUDDY_REFRESH_EPOCH"] = String(timeContext.epochSeconds)
        environment["TINYBUDDY_TIME_SCOPE_IDENTIFIER"] = timeContext.signature.portableScopeIdentifier
        if let timeScopeFileURL = timeScopeLease.fileURL {
            environment["TINYBUDDY_TIME_SCOPE_FILE"] = timeScopeFileURL.path
            environment["TINYBUDDY_TIME_SCOPE_TOKEN"] = timeScopeLease.token
        }
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
        let processExited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            processExited.signal()
        }

        guard executionController.shouldStart(process) else {
            throw CancellationError()
        }
        try process.run()
        standardInputPipe.fileHandleForWriting.write(try Data(contentsOf: scriptURL))
        try standardInputPipe.fileHandleForWriting.close()
        let didTimeOut = processExited.wait(timeout: .now() + 120) == .timedOut
        if didTimeOut {
            process.terminate()
            if processExited.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                processExited.wait()
            }
        }
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

        guard !didTimeOut, process.terminationStatus == 0 else {
            throw GitRefreshScriptExecutionError(
                terminationStatus: didTimeOut ? 124 : process.terminationStatus,
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
                        let candidate = token.trimmingCharacters(
                            in: CharacterSet(charactersIn: "\"'`()[]{}<>,:;")
                        )
                        let trustedExecutablePrefixes = [
                            "/usr/bin/",
                            "/bin/",
                            "/usr/sbin/",
                            "/sbin/",
                            "/usr/libexec/",
                            "/usr/local/bin/",
                            "/opt/homebrew/bin/",
                            "/opt/local/bin/"
                        ]
                        let pathComponents = candidate.split(
                            separator: "/",
                            omittingEmptySubsequences: true
                        )
                        guard !pathComponents.contains("..") else {
                            return nil
                        }
                        let standardizedCandidate = URL(fileURLWithPath: candidate)
                            .standardizedFileURL.path
                        guard trustedExecutablePrefixes.contains(where: standardizedCandidate.hasPrefix) else {
                            return nil
                        }
                        guard let basename = standardizedCandidate.split(separator: "/").last.map(String.init),
                              !basename.isEmpty,
                              basename.allSatisfy({ character in
                                  character.isLetter || character.isNumber
                                      || character == "." || character == "-" || character == "_"
                              }) else {
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
