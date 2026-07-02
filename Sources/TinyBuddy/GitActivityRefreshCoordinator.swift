import Foundation
import TinyBuddyCore
import WidgetKit

final class GitActivityRefreshCoordinator {
    typealias ScriptRunner = (URL) throws -> Void

    private let activityStore: GitTodayActivityStore
    private let widgetReloader: () -> Void
    private let scriptRunner: ScriptRunner
    private let refreshInterval: TimeInterval
    private let minimumRefreshSpacing: TimeInterval
    private let refreshQueue = DispatchQueue(label: "TinyBuddy.GitActivityRefresh", qos: .utility)

    private var timer: Timer?
    private var isRefreshing = false
    private var lastRefreshAttemptAt: Date?

    init(
        activityStore: GitTodayActivityStore = GitTodayActivityStore(),
        refreshInterval: TimeInterval = 5 * 60,
        minimumRefreshSpacing: TimeInterval = 60,
        widgetReloader: @escaping () -> Void = {
            WidgetCenter.shared.reloadAllTimelines()
        },
        scriptRunner: @escaping ScriptRunner = GitActivityRefreshCoordinator.runScript(at:)
    ) {
        self.activityStore = activityStore
        self.refreshInterval = refreshInterval
        self.minimumRefreshSpacing = minimumRefreshSpacing
        self.widgetReloader = widgetReloader
        self.scriptRunner = scriptRunner
    }

    func start() {
        scheduleTimerIfNeeded()
        refresh(trigger: .launch, force: true)
    }

    func handleDidBecomeActive() {
        refresh(trigger: .becameActive, force: true)
    }

    func handleReopen() {
        refresh(trigger: .reopen, force: true)
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

    private func refresh(trigger: GitTodayActivityRefreshTrigger, force: Bool = false) {
        let now = Date()

        guard force || shouldRefresh(at: now) else {
            return
        }

        guard !isRefreshing else {
            return
        }

        guard let scriptURL = locateRefreshScript() else {
            NSLog("TinyBuddy: missing git refresh script for trigger %@", String(describing: trigger))
            return
        }

        isRefreshing = true
        lastRefreshAttemptAt = now
        let previousSnapshot = activityStore.loadTodaySnapshot()
        let scriptRunner = self.scriptRunner

        refreshQueue.async { [weak self] in
            do {
                try scriptRunner(scriptURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }

                    defer {
                        self.isRefreshing = false
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

                    self.isRefreshing = false
                    NSLog("TinyBuddy: git refresh failed for trigger %@: %@", String(describing: trigger), error.localizedDescription)
                }
            }
        }
    }

    private func shouldRefresh(at now: Date) -> Bool {
        guard let lastRefreshAttemptAt else {
            return true
        }

        return now.timeIntervalSince(lastRefreshAttemptAt) >= minimumRefreshSpacing
    }

    private func locateRefreshScript() -> URL? {
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

    private static func runScript(at scriptURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TinyBuddy.GitActivityRefreshCoordinator",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "refresh script exited with status \(process.terminationStatus)"
                ]
            )
        }
    }

}
