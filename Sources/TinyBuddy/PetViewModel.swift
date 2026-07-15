import AppKit
import Foundation
import WidgetKit
import TinyBuddyCore

@MainActor
final class PetViewModel: ObservableObject {
    private struct CombinedHUDState {
        let snapshot: TinyBuddySnapshot
        let activitySnapshot: GitTodayActivitySnapshot
        let didPersist: Bool
    }

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
        let actionTitle: String?
    }

    @Published private(set) var status: PetStatus
    @Published private(set) var stats: DailyStats
    @Published private(set) var hudPresentation: TinyBuddyWidgetPresentation
    @Published private(set) var displayState: DisplayState
    @Published private(set) var refreshDiagnostics: RefreshDiagnostics
    @Published private(set) var hiddenSnapshotDiagnosticSummary: TinyBuddyHiddenSnapshotDiagnosticSummary?

    var selectedStatus: PetStatus {
        status
    }

    var notificationObserverCount: Int {
        observers.count
    }

    private let store: DailyStatsStore
    private let session: PetSession
    private let activityStore: GitTodayActivityStore
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let notificationCenter: NotificationCenter
    private let widgetReloader: () throws -> Void
    private let sharedSnapshotDiagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder
    private var rebuiltSnapshotFaultIdentifiers: Set<String>
    private var latestRefreshStatus: GitActivityRefreshStatus?
    private var observers: [NSObjectProtocol] = []

    init(
        store: DailyStatsStore = DailyStatsStore(),
        activityStore: GitTodayActivityStore = GitTodayActivityStore(),
        combinedSnapshotStore: TinyBuddyCombinedSnapshotStore? = nil,
        refreshStatusStore: GitActivityRefreshStatusStore = GitActivityRefreshStatusStore(),
        notificationCenter: NotificationCenter = .default,
        widgetReloader: @escaping () throws -> Void = {
            WidgetCenter.shared.reloadAllTimelines()
        },
        sharedSnapshotDiagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder = .shared
    ) {
        self.store = store
        let session = PetSession(store: store)
        let combinedSnapshotStore = combinedSnapshotStore ?? store.makeCombinedSnapshotStore()
        let latestRefreshStatus = refreshStatusStore.load()
        let fallbackSnapshot = store.loadSnapshot()
        var rebuiltSnapshotFaultIdentifiers: Set<String> = []
        let committedReadBeforePublication = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: fallbackSnapshot.stats.dayIdentifier
        )
        committedReadBeforePublication.observation.map(sharedSnapshotDiagnosticRecorder.record)
        let committedSnapshotBeforePublication = committedReadBeforePublication.snapshot
        let hadSameDayCommittedSnapshot = committedSnapshotBeforePublication?.dayIdentifier
            == fallbackSnapshot.stats.dayIdentifier
        let widgetPresentationBeforePublication: TinyBuddyWidgetPresentation
        if let committedSnapshot = committedSnapshotBeforePublication,
           committedSnapshot.dayIdentifier == fallbackSnapshot.stats.dayIdentifier {
            widgetPresentationBeforePublication = Self.makeHUDPresentation(
                snapshot: committedSnapshot.snapshot,
                activitySnapshot: committedSnapshot.activitySnapshot
            )
        } else {
            widgetPresentationBeforePublication = Self.makeHUDPresentation(
                snapshot: fallbackSnapshot,
                activitySnapshot: GitTodayActivitySnapshot(
                    focusBlockCount: nil,
                    commitCount: nil,
                    recentProjectName: nil
                )
            )
        }
        let combinedHUDState = Self.publishAndLoadCombinedSnapshot(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            includeTrustedActivity: Self.shouldIncludeTrustedActivity(
                for: latestRefreshStatus
            ),
            diagnosticRecorder: sharedSnapshotDiagnosticRecorder,
            rebuiltSnapshotFaultIdentifiers: &rebuiltSnapshotFaultIdentifiers
        )
        let snapshot = combinedHUDState.snapshot
        let activitySnapshot = combinedHUDState.activitySnapshot
        let hudPresentation = Self.makeHUDPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )
        self.session = session
        self.activityStore = activityStore
        self.combinedSnapshotStore = combinedSnapshotStore
        self.refreshStatusStore = refreshStatusStore
        self.notificationCenter = notificationCenter
        self.widgetReloader = widgetReloader
        self.sharedSnapshotDiagnosticRecorder = sharedSnapshotDiagnosticRecorder
        self.rebuiltSnapshotFaultIdentifiers = rebuiltSnapshotFaultIdentifiers
        self.latestRefreshStatus = latestRefreshStatus
        self.status = snapshot.status
        self.stats = snapshot.stats
        self.hudPresentation = hudPresentation
        self.displayState = Self.makeDisplayState(from: hudPresentation)
        self.refreshDiagnostics = Self.makeRefreshDiagnostics(from: latestRefreshStatus)
        self.hiddenSnapshotDiagnosticSummary = sharedSnapshotDiagnosticRecorder.latestSummary
        if combinedHUDState.didPersist
            && (hadSameDayCommittedSnapshot || widgetPresentationBeforePublication != hudPresentation) {
            reloadWidgetIfPossible()
        }
        observers.append(notificationCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let status = notification.object as? GitActivityRefreshStatus
                    ?? self.refreshStatusStore.load()
                self.latestRefreshStatus = status
                self.refreshDiagnostics = Self.makeRefreshDiagnostics(
                    from: status
                )
                self.reloadCommittedHUDState()
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: .gitActivitySnapshotDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadCommittedHUDState()
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restorePersistedState()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .tinyBuddySharedSnapshotDiagnosticDidChange,
            object: sharedSnapshotDiagnosticRecorder,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.hiddenSnapshotDiagnosticSummary = self.sharedSnapshotDiagnosticRecorder.latestSummary
            }
        })
    }

    func select(_ nextStatus: PetStatus) {
        session.select(nextStatus)
        if reloadHUDState() {
            reloadWidgetIfPossible()
        }
    }

    func requestGitScanAuthorization() {
        notificationCenter.post(name: .gitScanRootAuthorizationRequested, object: nil)
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func restorePersistedState() {
        latestRefreshStatus = refreshStatusStore.load()
        refreshDiagnostics = Self.makeRefreshDiagnostics(from: latestRefreshStatus)
        if reloadHUDState() {
            reloadWidgetIfPossible()
        }
    }

    private static func makeRefreshDiagnostics(from status: GitActivityRefreshStatus?) -> RefreshDiagnostics {
        guard let status else {
            return RefreshDiagnostics(
                badgeTitle: "未刷新",
                summary: "等待首次 Git 刷新",
                detail: "启动后会自动尝试刷新",
                reason: nil,
                outcome: nil,
                actionTitle: nil
            )
        }

        let diagnosticReason = status.diagnostic?.reason
        let actionTitle = authorizationActionTitle(for: diagnosticReason)

        return RefreshDiagnostics(
            badgeTitle: badgeTitle(for: status.outcome),
            summary: summaryTitle(for: status, diagnosticReason: diagnosticReason),
            detail: Self.refreshDateFormatter.string(from: status.refreshedAt),
            reason: localizedReason(for: diagnosticReason, fallbackReason: status.reason),
            outcome: status.outcome,
            actionTitle: actionTitle
        )
    }

    @discardableResult
    private func reloadHUDState() -> Bool {
        let combinedHUDState = Self.publishAndLoadCombinedSnapshot(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            includeTrustedActivity: Self.shouldIncludeTrustedActivity(
                for: latestRefreshStatus
            ),
            diagnosticRecorder: sharedSnapshotDiagnosticRecorder,
            rebuiltSnapshotFaultIdentifiers: &rebuiltSnapshotFaultIdentifiers
        )
        let snapshot = combinedHUDState.snapshot
        let activitySnapshot = combinedHUDState.activitySnapshot
        let didChange = applyHUDState(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )
        hiddenSnapshotDiagnosticSummary = sharedSnapshotDiagnosticRecorder.latestSummary
        return didChange && combinedHUDState.didPersist
    }

    private func reloadCommittedHUDState() {
        let fallbackSnapshot = store.loadSnapshot()
        let snapshot: TinyBuddySnapshot
        let activitySnapshot: GitTodayActivitySnapshot

        let combinedRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: fallbackSnapshot.stats.dayIdentifier
        )
        combinedRead.observation.map(sharedSnapshotDiagnosticRecorder.record)
        if let observation = combinedRead.observation,
           combinedRead.snapshot == nil,
           observation.reason == .snapshotCorrupt || observation.reason == .staleData {
            _ = reloadHUDState()
            return
        }
        if let combinedSnapshot = combinedRead.snapshot {
            snapshot = combinedSnapshot.snapshot
            activitySnapshot = combinedSnapshot.activitySnapshot
        } else {
            snapshot = fallbackSnapshot
            activitySnapshot = GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            )
        }
        _ = applyHUDState(snapshot: snapshot, activitySnapshot: activitySnapshot)
        hiddenSnapshotDiagnosticSummary = sharedSnapshotDiagnosticRecorder.latestSummary
    }

    @discardableResult
    private func applyHUDState(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot
    ) -> Bool {
        let hudPresentation = Self.makeHUDPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )
        let didChange = self.hudPresentation != hudPresentation
        status = snapshot.status
        stats = snapshot.stats
        self.hudPresentation = hudPresentation
        displayState = Self.makeDisplayState(from: hudPresentation)
        return didChange
    }

    private static func makeHUDPresentation(
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot
    ) -> TinyBuddyWidgetPresentation {
        TinyBuddyWidgetPresentation(snapshot: snapshot, activitySnapshot: activitySnapshot)
    }

    private static func publishAndLoadCombinedSnapshot(
        store: DailyStatsStore,
        activityStore: GitTodayActivityStore,
        combinedSnapshotStore: TinyBuddyCombinedSnapshotStore,
        includeTrustedActivity: Bool,
        diagnosticRecorder: TinyBuddySharedSnapshotDiagnosticRecorder,
        rebuiltSnapshotFaultIdentifiers: inout Set<String>
    ) -> CombinedHUDState {
        let snapshot = store.loadSnapshot()
        let expectedDayIdentifier = snapshot.stats.dayIdentifier
        let validatedRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        validatedRead.observation.map(diagnosticRecorder.record)
        if validatedRead.observation == nil, validatedRead.snapshot != nil {
            rebuiltSnapshotFaultIdentifiers = Set(
                rebuiltSnapshotFaultIdentifiers.filter {
                    !$0.hasSuffix(".\(expectedDayIdentifier)")
                }
            )
        }
        let activityRead = includeTrustedActivity
            ? activityStore.loadTodaySnapshotRead()
            : nil

        if let observation = validatedRead.observation {
            if let recoveredSnapshot = validatedRead.snapshot {
                let faultBudgetIdentifier = "\(observation.identifier).\(expectedDayIdentifier)"
                if observation.reason == .snapshotCorrupt,
                   rebuiltSnapshotFaultIdentifiers.insert(faultBudgetIdentifier).inserted {
                    guard combinedSnapshotStore.repairValidatedSnapshot(recoveredSnapshot) else {
                        diagnosticRecorder.record(
                            phase: .snapshotWrite,
                            reason: .persistenceFailed,
                            recovery: .stopped
                        )
                        return CombinedHUDState(
                            snapshot: recoveredSnapshot.snapshot,
                            activitySnapshot: recoveredSnapshot.activitySnapshot,
                            didPersist: false
                        )
                    }
                    let repairedRead = combinedSnapshotStore.readValidated(
                        expectedDayIdentifier: expectedDayIdentifier
                    )
                    repairedRead.observation.map(diagnosticRecorder.record)
                    guard let repairedSnapshot = repairedRead.snapshot,
                          repairedRead.observation == nil else {
                        diagnosticRecorder.record(
                            phase: .snapshotWrite,
                            reason: .persistenceFailed,
                            recovery: .stopped
                        )
                        return CombinedHUDState(
                            snapshot: recoveredSnapshot.snapshot,
                            activitySnapshot: recoveredSnapshot.activitySnapshot,
                            didPersist: false
                        )
                    }
                    diagnosticRecorder.record(
                        phase: .snapshotRead,
                        reason: .snapshotCorrupt,
                        recovery: .rebuilt,
                        attemptCount: observation.attemptCount + 1
                    )
                    rebuiltSnapshotFaultIdentifiers.remove(faultBudgetIdentifier)
                    return CombinedHUDState(
                        snapshot: repairedSnapshot.snapshot,
                        activitySnapshot: repairedSnapshot.activitySnapshot,
                        didPersist: true
                    )
                }
                return CombinedHUDState(
                    snapshot: recoveredSnapshot.snapshot,
                    activitySnapshot: recoveredSnapshot.activitySnapshot,
                    didPersist: false
                )
            }
            let faultBudgetIdentifier = "\(observation.identifier).\(expectedDayIdentifier)"
            guard observation.reason == .snapshotCorrupt || observation.reason == .staleData,
                  rebuiltSnapshotFaultIdentifiers.insert(faultBudgetIdentifier).inserted else {
                return neutralHUDState(snapshot)
            }

            let rebuiltUpdate = combinedSnapshotStore.updatePetSlice(
                snapshot,
                fallbackActivitySnapshot: activityRead?.snapshot,
                fallbackActivityRevision: activityRead?.trustedRevision
            )
            rebuiltUpdate.observation.map(diagnosticRecorder.record)
            guard rebuiltUpdate.didPersist || rebuiltUpdate.outcome == .alreadyCurrent else {
                if rebuiltUpdate.observation == nil {
                    diagnosticRecorder.record(
                        phase: .snapshotWrite,
                        reason: .persistenceFailed,
                        recovery: .stopped
                    )
                }
                return neutralHUDState(snapshot)
            }
            diagnosticRecorder.record(
                phase: .snapshotRead,
                reason: observation.reason,
                recovery: rebuiltUpdate.didPersist ? .rebuilt : .rereadSucceeded,
                attemptCount: observation.attemptCount + 1
            )
            let rebuiltRead = combinedSnapshotStore.readValidated(
                expectedDayIdentifier: expectedDayIdentifier
            )
            rebuiltRead.observation.map(diagnosticRecorder.record)
            guard let rebuiltSnapshot = rebuiltRead.snapshot else {
                return neutralHUDState(snapshot)
            }
            rebuiltSnapshotFaultIdentifiers.remove(faultBudgetIdentifier)
            return CombinedHUDState(
                snapshot: rebuiltSnapshot.snapshot,
                activitySnapshot: rebuiltSnapshot.activitySnapshot,
                didPersist: true
            )
        }

        let combinedUpdate = combinedSnapshotStore.updatePetSlice(
            snapshot,
            fallbackActivitySnapshot: activityRead?.snapshot,
            fallbackActivityRevision: activityRead?.trustedRevision
        )
        combinedUpdate.observation.map(diagnosticRecorder.record)

        guard combinedUpdate.didPersist || combinedUpdate.outcome == .alreadyCurrent else {
            if let retainedSnapshot = validatedRead.snapshot {
                return CombinedHUDState(
                    snapshot: retainedSnapshot.snapshot,
                    activitySnapshot: retainedSnapshot.activitySnapshot,
                    didPersist: false
                )
            }
            return neutralHUDState(snapshot)
        }
        let publishedRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        publishedRead.observation.map(diagnosticRecorder.record)
        guard let combinedSnapshot = publishedRead.snapshot else {
            return neutralHUDState(snapshot)
        }

        return CombinedHUDState(
            snapshot: combinedSnapshot.snapshot,
            activitySnapshot: combinedSnapshot.activitySnapshot,
            didPersist: combinedUpdate.didPersist
        )
    }

    private static func neutralHUDState(_ snapshot: TinyBuddySnapshot) -> CombinedHUDState {
        CombinedHUDState(
            snapshot: snapshot,
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            didPersist: false
        )
    }

    private func reloadWidgetIfPossible() {
        do {
            try widgetReloader()
        } catch {
            sharedSnapshotDiagnosticRecorder.record(
                phase: .timelineReload,
                reason: .timelineReloadFailed,
                recovery: .stopped
            )
            hiddenSnapshotDiagnosticSummary = sharedSnapshotDiagnosticRecorder.latestSummary
        }
    }

    private static func shouldIncludeTrustedActivity(
        for refreshStatus: GitActivityRefreshStatus?
    ) -> Bool {
        refreshStatus?.outcome != .failed
            || refreshStatus?.diagnostic?.reason != .combinedSnapshotCommitFailed
    }

    private static func makeDisplayState(from presentation: TinyBuddyWidgetPresentation) -> DisplayState {
        switch presentation.displayState {
        case .idle:
            return .idle
        case .focusing:
            return .focusing
        case .completed:
            return .completed
        case .active:
            return .active
        }
    }

    private static func localizedReason(
        for diagnosticReason: GitActivityRefreshDiagnosticReason?,
        fallbackReason: String?
    ) -> String? {
        if let diagnosticReason {
            switch diagnosticReason {
            case .scriptMissing:
                return "刷新组件缺失，暂时无法读取 Git 活动。"
            case .authorizationRequired:
                return "还没有可用的 Git 目录授权，授权后即可恢复 Git 刷新。"
            case .authorizationInvalid:
                return "之前授权的 Git 扫描目录已失效，可能已被移动、删除或系统权限失效，请重新授权。"
            case .scriptExecutionFailed:
                return "Git 刷新执行失败，请稍后再试。"
            case .refreshedActivityUnavailable:
                return "Git 刷新完成，但暂时无法恢复活动快照。"
            case .partialRecovery:
                return "部分 Git 仓库已刷新；有失效 worktree 被跳过，请检查授权目录中的仓库。"
            case .combinedSnapshotCommitFailed:
                return "Git 活动已读取，但统一快照提交失败；当前继续显示上次完整数据。"
            }
        }

        guard let fallbackReason = fallbackReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              fallbackReason.isEmpty == false else {
            return nil
        }

        if fallbackReason.lowercased().contains("minimum refresh spacing not reached") {
            return "刚刚刷新过，稍后会自动再次尝试。"
        }

        return "刷新暂时不可用，请稍后再试。"
    }

    private static func authorizationActionTitle(
        for diagnosticReason: GitActivityRefreshDiagnosticReason?
    ) -> String? {
        guard let diagnosticReason else {
            return nil
        }

        if diagnosticReason == .authorizationRequired || diagnosticReason == .authorizationInvalid {
            return "重新授权 Git 目录"
        }

        return nil
    }

    private static func summaryTitle(
        for status: GitActivityRefreshStatus,
        diagnosticReason: GitActivityRefreshDiagnosticReason?
    ) -> String {
        if diagnosticReason == .authorizationInvalid {
            return "Git 目录授权已失效"
        }

        if diagnosticReason == .authorizationRequired {
            return "等待 Git 目录授权"
        }

        if diagnosticReason == .partialRecovery {
            return "Git 活动已部分刷新"
        }

        return "\(triggerTitle(for: status.trigger))触发 \(outcomeTitle(for: status.outcome))"
    }

    private static func badgeTitle(for outcome: GitActivityRefreshOutcome) -> String {
        switch outcome {
        case .succeeded:
            return "成功"
        case .partial:
            return "有警告"
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
        case .partial:
            return "刷新部分成功"
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
