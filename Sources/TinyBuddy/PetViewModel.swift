import Foundation
import WidgetKit
import TinyBuddyCore

@MainActor
final class PetViewModel: ObservableObject {
    enum DisplayState: Equatable {
        case idle
        case focusing
        case completed
        case active

        var selectedStatus: PetStatus? {
            switch self {
            case .idle:
                return .idle
            case .focusing:
                return .focusing
            case .completed:
                return .completedOnce
            case .active:
                return nil
            }
        }
    }

    struct RefreshDiagnostics: Equatable {
        let badgeTitle: String
        let summary: String
        let detail: String
        let reason: String?
        let outcome: GitActivityRefreshOutcome?
    }

    @Published private(set) var status: PetStatus
    @Published private(set) var stats: DailyStats
    @Published private(set) var hudPresentation: TinyBuddyWidgetPresentation
    @Published private(set) var displayState: DisplayState
    @Published private(set) var refreshDiagnostics: RefreshDiagnostics

    private let store: DailyStatsStore
    private let session: PetSession
    private let activityStore: GitTodayActivityStore
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let notificationCenter: NotificationCenter
    private var refreshStatusObserver: NSObjectProtocol?

    init(
        store: DailyStatsStore = DailyStatsStore(),
        activityStore: GitTodayActivityStore = GitTodayActivityStore(),
        refreshStatusStore: GitActivityRefreshStatusStore = GitActivityRefreshStatusStore(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        let session = PetSession(store: store)
        let snapshot = store.loadSnapshot()
        let activitySnapshot = activityStore.loadTodaySnapshot()
        self.session = session
        self.activityStore = activityStore
        self.refreshStatusStore = refreshStatusStore
        self.notificationCenter = notificationCenter
        self.status = snapshot.status
        self.stats = snapshot.stats
        self.hudPresentation = Self.makeHUDPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )
        self.displayState = Self.makeDisplayState(from: activitySnapshot)
        self.refreshDiagnostics = Self.makeRefreshDiagnostics(from: refreshStatusStore.load())
        self.refreshStatusObserver = notificationCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let status = notification.object as? GitActivityRefreshStatus
                self.refreshDiagnostics = Self.makeRefreshDiagnostics(
                    from: status ?? self.refreshStatusStore.load()
                )
                self.reloadHUDState()
            }
        }
    }

    func select(_ nextStatus: PetStatus) {
        session.select(nextStatus)
        reloadHUDState()
        WidgetCenter.shared.reloadAllTimelines()
    }

    deinit {
        if let refreshStatusObserver {
            notificationCenter.removeObserver(refreshStatusObserver)
        }
    }

    private static func makeRefreshDiagnostics(from status: GitActivityRefreshStatus?) -> RefreshDiagnostics {
        guard let status else {
            return RefreshDiagnostics(
                badgeTitle: "未刷新",
                summary: "等待首次 Git 刷新",
                detail: "启动后会自动尝试刷新",
                reason: nil,
                outcome: nil
            )
        }

        return RefreshDiagnostics(
            badgeTitle: badgeTitle(for: status.outcome),
            summary: "\(triggerTitle(for: status.trigger))触发 \(outcomeTitle(for: status.outcome))",
            detail: Self.refreshDateFormatter.string(from: status.refreshedAt),
            reason: localizedReason(for: status.reason),
            outcome: status.outcome
        )
    }

    private func reloadHUDState() {
        let snapshot = store.loadSnapshot()
        let activitySnapshot = activityStore.loadTodaySnapshot()
        status = snapshot.status
        stats = snapshot.stats
        hudPresentation = Self.makeHUDPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )
        displayState = Self.makeDisplayState(from: activitySnapshot)
    }

    private static func makeHUDPresentation(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot
    ) -> TinyBuddyWidgetPresentation {
        TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: activitySnapshot.focusBlockCount ?? 0,
            completionCountOverride: activitySnapshot.commitCount ?? 0,
            recentProjectName: activitySnapshot.recentProjectName,
            statusTitleSource: .gitTodayActivity
        )
    }

    private static func makeDisplayState(from activitySnapshot: GitTodayActivitySnapshot) -> DisplayState {
        switch ((activitySnapshot.focusBlockCount ?? 0) > 0, (activitySnapshot.commitCount ?? 0) > 0) {
        case (false, false):
            return .idle
        case (true, false):
            return .focusing
        case (false, true):
            return .completed
        case (true, true):
            return .active
        }
    }

    private static func localizedReason(for reason: String?) -> String? {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), reason.isEmpty == false else {
            return nil
        }

        let normalizedReason = reason.lowercased()

        if normalizedReason.contains("missing git refresh script") {
            return "刷新组件缺失，暂时无法读取 Git 活动。"
        }

        if normalizedReason.contains("minimum refresh spacing not reached") {
            return "刚刚刷新过，稍后会自动再次尝试。"
        }

        if normalizedReason.contains("no authorized git scan roots") {
            return "还没有可用的 Git 目录授权，暂时无法刷新。"
        }

        return "刷新暂时不可用，请稍后再试。"
    }

    private static func badgeTitle(for outcome: GitActivityRefreshOutcome) -> String {
        switch outcome {
        case .succeeded:
            return "成功"
        case .skipped:
            return "跳过"
        case .failed:
            return "失败"
        }
    }

    private static func outcomeTitle(for outcome: GitActivityRefreshOutcome) -> String {
        switch outcome {
        case .succeeded:
            return "刷新成功"
        case .skipped:
            return "刷新跳过"
        case .failed:
            return "刷新失败"
        }
    }

    private static func triggerTitle(for trigger: GitTodayActivityRefreshTrigger) -> String {
        switch trigger {
        case .launch:
            return "启动"
        case .becameActive:
            return "前台"
        case .reopen:
            return "重开"
        case .didWake:
            return "系统唤醒"
        case .screensDidWake:
            return "屏幕唤醒"
        case .sessionDidBecomeActive:
            return "会话激活"
        case .timer:
            return "定时器"
        }
    }

    private static let refreshDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
