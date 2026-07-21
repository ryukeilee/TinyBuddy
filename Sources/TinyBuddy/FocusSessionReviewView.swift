import SwiftUI
import TinyBuddyCore

/// Settings-only correction surface. Every command carries a session UUID to
/// the engine; it never indexes into a rescanned list or writes the journal.
///
/// Sessions are loaded via `HistoryQueryController` with cursor-based pagination
/// instead of loading all sessions at once.
struct FocusSessionReviewView: View {
    let engineProvider: () -> FocusSessionEngine?
    let historyController: HistoryQueryController

    @State private var selected = Set<UUID>()
    @State private var projectKey = ""
    @State private var projectName = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var splitAt = Date()
    @State private var message: String?
    @State private var refreshID = UUID()

    private var engine: FocusSessionEngine? { engineProvider() }
    private var sessions: [FocusSession] {
        _ = refreshID
        return historyController.allSessions
    }
    private var selectedSession: FocusSession? {
        guard selected.count == 1, let id = selected.first else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Evidence for the selected session, loaded from the engine.
    private var selectedEvidence: FocusSessionEvidence? {
        guard let id = selectedSession?.id, let engine else { return nil }
        return engine.evidence(for: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专注记录复核")
                .font(.title2.weight(.semibold))
            Text("选择记录可查看开始、暂停、恢复、结束和项目归属原因；已结束记录可确认或修正。")
                .foregroundStyle(.secondary)

            if let engine {
                if let summary = engine.focusHistoryPublication()?.snapshot.recentDays.last {
                    switch summary.state {
                    case .sessions, .noSessions:
                        Text("今日已记录 \(formatted(summary.focusDuration ?? 0)) · \(summary.completedSessionCount ?? 0) 个完成会话")
                            .font(.subheadline)
                    case .unknown:
                        Text("今日历史暂不可用，不会以 0 代替未知结果。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    // Paginated session list
                    sessionList

                    // Editor panel
                    ScrollView {
                        editor
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(minWidth: 320)
                }
            } else {
                ContentUnavailableView("专注记录尚未就绪", systemImage: "clock.badge.exclamationmark", description: Text("请等待主应用完成启动后重试。"))
            }
        }
        .padding()
        .task {
            await initialLoad()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .focusSessionSnapshotSynchronizationDidFinish
        )) { notification in
            let succeeded = notification.userInfo?["succeeded"] as? Bool ?? false
            message = succeeded
                ? "统计与 HUD、Widget 展示已同步。"
                : "记录已保存，但展示快照未写入；下次启动会自动恢复同步。"
            refreshID = UUID()
        }
    }

    // MARK: - Paginated Session List

    @ViewBuilder
    private var sessionList: some View {
        VStack(spacing: 0) {
            // Filter/search toolbar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("搜索项目", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onChange(of: searchText) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        Task {
                            var q = historyController.query
                            q.keyword = trimmed.isEmpty ? nil : trimmed
                            await historyController.updateQuery(q, debounceSeconds: 0.3)
                        }
                    }
                if !searchText.isEmpty {
                    Button { searchText = ""; Task { await resetQuery() } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Session list with loading states
            Group {
                if case .loading = historyController.loadState, sessions.isEmpty {
                    VStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.6)
                        Spacer()
                    }
                } else if sessions.isEmpty {
                    VStack {
                        Spacer()
                        Text("无匹配记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    List(sessions, selection: $selected) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.project.displayName)
                            Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(session.endedAt?.formatted(date: .omitted, time: .shortened) ?? "进行中")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(authorityLabel(session))
                                .font(.caption2)
                                .foregroundStyle(authorityColor(session))
                        }
                        .tag(session.id)
                        .onAppear {
                            if session.id == sessions.last?.id {
                                Task { await historyController.loadMore() }
                            }
                        }
                    }
                    .onChange(of: selected) { _, _ in loadSelection() }
                }
            }
        }
        .frame(minWidth: 300)
    }

    @State private var searchText = ""

    private func initialLoad() async {
        // Show ended sessions by default in review view
        var q = FocusSessionQuery()
        q.status = .ended
        await historyController.updateQuery(q, debounceSeconds: 0)
    }

    private func resetQuery() async {
        searchText = ""
        var q = FocusSessionQuery()
        q.status = .ended
        await historyController.updateQuery(q, debounceSeconds: 0)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedSession == nil ? "请选择一条记录" : "修正记录")
                .font(.headline)
            if let session = selectedSession {
                sourceExplanation(session)
                Divider()
            }
            TextField("项目标识", text: $projectKey)
            TextField("项目名称", text: $projectName)
            DatePicker("开始", selection: $start)
            DatePicker("结束", selection: $end)
            HStack {
                Button("确认记录") { confirm() }
                    .disabled(selectedSession == nil || selectedSession?.isOpen == true || selectedSession?.isManuallyConfirmed == true)
                Button("保存修正") { saveEdit() }.disabled(selectedSession == nil)
                Button("删除") { delete() }.disabled(selectedSession == nil)
            }
            Divider()
            DatePicker("拆分时间", selection: $splitAt)
            HStack {
                Button("拆分") { split() }.disabled(selectedSession == nil)
                Button("合并所选") { merge() }.disabled(selected.count < 2)
                Button("撤销上次编辑") { undo() }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func loadSelection() {
        guard let session = selectedSession else { return }
        projectKey = session.project.key
        projectName = session.project.displayName
        start = session.startedAt
        end = session.endedAt ?? session.startedAt
        splitAt = start.addingTimeInterval(max(1, end.timeIntervalSince(start) / 2))
    }

    private func saveEdit() {
        guard let id = selectedSession?.id else { return }
        apply(engine?.editSession(id: id, project: FocusProjectContext(key: projectKey, displayName: projectName), startedAt: start, endedAt: end))
    }
    private func confirm() { guard let id = selectedSession?.id else { return }; apply(engine?.confirmSession(id: id)) }
    private func delete() { guard let id = selectedSession?.id else { return }; apply(engine?.deleteSession(id: id)) }
    private func split() { guard let id = selectedSession?.id else { return }; apply(engine?.splitSession(id: id, at: splitAt)) }
    private func merge() { apply(engine?.mergeSessions(ids: Array(selected))) }
    private func undo() { apply(engine?.undoLastEdit()) }

    private func apply(_ result: FocusSessionEditResult?) {
        guard let result else { message = "专注记录尚未就绪"; return }
        switch result {
        case .saved:
            message = "记录已保存，正在同步今日统计与展示。"
            selected.removeAll()
            // Invalidate query cache and reload after edit
            Task {
                await historyController.notifyChanges([])
                await historyController.reload()
                refreshID = UUID()
            }
            return
        case .rejected(let error):
            message = errorMessage(error)
        }
        refreshID = UUID()
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    @ViewBuilder
    private func sourceExplanation(_ session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("数据来源", value: authorityLabel(session))
            // Evidence details (schema v2+)
            if let evidence = selectedEvidence {
                evidenceSection(evidence)
            }
            // Decision events (always shown when available)
            if let events = session.decisionEvents, !events.isEmpty {
                let sortedEvents = events.sorted { lhs, rhs in
                    if lhs.at != rhs.at { return lhs.at < rhs.at }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                ForEach(sortedEvents) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text("\(kindLabel(event.kind))：\(reasonLabel(event.reason))")
                            .font(.caption)
                        Spacer(minLength: 4)
                        Text(sourceLabel(event.source))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !events.contains(where: { $0.kind == .started }) {
                    Label("较早的自动判定来源缺失；现有状态未被用来补写原因。", systemImage: "clock.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("历史记录：创建时尚未保存判定来源，无法证明具体原因。", systemImage: "clock.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func evidenceSection(_ evidence: FocusSessionEvidence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Confidence badge
            HStack(spacing: 4) {
                Image(systemName: confidenceIcon(evidence.confidence))
                    .foregroundStyle(confidenceColor(evidence.confidence))
                Text(confidenceLabel(evidence.confidence))
                    .font(.caption.weight(.medium))
            }
            .padding(.vertical, 2)

            // Project attribution
            LabeledContent("归属依据", value: evidence.projectAttribution.explanation)
                .font(.caption)

            // Attribution source
            LabeledContent("归属方式", value: sourceLabel(evidence.projectAttribution.source))
                .font(.caption)

            // Rule version
            LabeledContent("规则版本", value: "v\(evidence.ruleVersion.major).\(evidence.ruleVersion.minor)")
                .font(.caption)

            // Caveat (low confidence reason)
            if let caveat = evidence.projectAttribution.caveat {
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Detailed decision explanations
            if !evidence.decisionExplanations.isEmpty {
                Divider()
                Text("决策详情")
                    .font(.caption.weight(.semibold))
                ForEach(evidence.decisionExplanations) { explanation in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(explanation.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(explanation.explanation)
                            .font(.caption)
                        Spacer(minLength: 4)
                        confidenceBadge(explanation.confidence)
                    }
                }
            }
        }
        .padding(8)
        .background(confidenceColor(evidence.confidence).opacity(0.08))
        .cornerRadius(6)
    }

    private func confidenceIcon(_ confidence: FocusSessionEvidenceConfidence) -> String {
        switch confidence {
        case .high: return "checkmark.shield"
        case .low: return "exclamationmark.shield"
        case .pending: return "questionmark.shield"
        }
    }

    private func confidenceColor(_ confidence: FocusSessionEvidenceConfidence) -> Color {
        switch confidence {
        case .high: return .green
        case .low: return .orange
        case .pending: return .secondary
        }
    }

    private func confidenceLabel(_ confidence: FocusSessionEvidenceConfidence) -> String {
        switch confidence {
        case .high: return "高置信度 — 有明确证据支持"
        case .low: return "低置信度 — 依据部分或间接证据"
        case .pending: return "待确认 — 证据不足以确定归属"
        }
    }

    @ViewBuilder
    private func confidenceBadge(_ confidence: FocusSessionEvidenceConfidence) -> some View {
        switch confidence {
        case .high:
            Text("确定").font(.caption2).foregroundStyle(.green)
        case .low:
            Text("存疑").font(.caption2).foregroundStyle(.orange)
        case .pending:
            Text("待定").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sourceLabel(_ source: FocusSessionAttributionSource) -> String {
        switch source {
        case .foregroundApp: return "前段应用关联"
        case .gitActivity: return "Git 活动关联"
        case .manual: return "用户手动选择"
        case .unknown: return "未知"
        }
    }

    private func authorityLabel(_ session: FocusSession) -> String {
        switch session.decisionAuthority {
        case .automatic: return "自动识别"
        case .userConfirmed: return "用户确认"
        case .manualCorrection: return "手动修正"
        case nil: return "历史记录"
        }
    }

    private func authorityColor(_ session: FocusSession) -> Color {
        session.decisionAuthority == nil ? .secondary : .primary
    }

    private func sourceLabel(_ source: FocusSessionDecisionSource) -> String {
        switch source {
        case .automatic: return "自动"
        case .userConfirmed: return "用户确认"
        case .manualCorrection: return "手动修正"
        }
    }

    private func kindLabel(_ kind: FocusSessionDecisionKind) -> String {
        switch kind {
        case .started: return "开始"
        case .paused: return "暂停"
        case .resumed: return "恢复"
        case .ended: return "结束"
        case .projectChanged: return "项目改归属"
        case .confirmed: return "确认"
        case .corrected: return "修正"
        case .split: return "拆分"
        case .merged: return "合并"
        case .undo: return "撤销"
        }
    }

    private func reasonLabel(_ reason: FocusSessionDecisionReason) -> String {
        switch reason {
        case .userActivity: return "检测到用户活动"
        case .gitActivity: return "检测到 Git 变化"
        case .idle: return "达到空闲阈值"
        case .lockScreen: return "屏幕锁定"
        case .systemSleep: return "系统休眠"
        case .projectSwitch: return "切换到其他项目"
        case .dayBoundary: return "本地日期变更，自动结束"
        case .appTermination: return "应用退出，自动结束"
        case .crashRecovery: return "异常退出后安全收尾"
        case .manualConfirmation: return "用户确认原记录"
        case .manualCorrection: return "用户手动修改"
        case .manualSplit: return "用户手动拆分"
        case .manualMerge: return "用户手动合并"
        case .undo: return "用户撤销上次编辑"
        }
    }

    private func errorMessage(_ error: FocusSessionEditError) -> String {
        switch error {
        case .sessionNotFound: return "记录已不存在，请刷新后重试。"
        case .sessionIsActive: return "进行中的会话不能修正；请先结束它。"
        case .invalidProject: return "项目标识和名称不能为空。"
        case .invalidTimeRange: return "结束时间必须晚于开始时间，合并记录必须相邻。"
        case .futureTime: return "不能使用未来时间。"
        case .overlappingSession: return "修改会与已有记录重叠。"
        case .crossDayBoundaryUnavailable: return "无法安全按本地日期拆分该记录。"
        case .insufficientSessionsToMerge: return "至少选择两条记录才能合并。"
        case .splitOutsideSession: return "拆分时间必须位于该会话内。"
        case .persistenceFailed: return "未能写入磁盘，原记录与统计保持不变。"
        case .nothingToUndo: return "没有可撤销的编辑。"
        case .alreadyConfirmed: return "这条记录已经由用户确认或修正。"
        }
    }
}
