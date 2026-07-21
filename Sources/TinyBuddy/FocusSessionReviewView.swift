import SwiftUI
import TinyBuddyCore

/// Settings-only correction surface. Every command carries a session UUID to
/// the engine; it never indexes into a rescanned list or writes the journal.
struct FocusSessionReviewView: View {
    let engineProvider: () -> FocusSessionEngine?

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
        return engine?.allSessions.sorted { $0.startedAt > $1.startedAt } ?? []
    }
    private var selectedSession: FocusSession? {
        guard selected.count == 1, let id = selected.first else { return nil }
        return sessions.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专注记录复核")
                .font(.title2.weight(.semibold))
            Text("选择已结束记录后可修正项目和时间；所有操作按稳定会话标识保存。")
                .foregroundStyle(.secondary)

            if let engine {
                let summary = engine.derivedSnapshot()
                Text("今日已记录 \(formatted(summary.focusDuration)) · \(summary.completedSessionCount) 个完成会话")
                    .font(.subheadline)

                HStack(spacing: 16) {
                    List(sessions, selection: $selected) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.project.displayName)
                            Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(session.endedAt?.formatted(date: .omitted, time: .shortened) ?? "进行中")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if session.isManuallyConfirmed {
                                Text("已确认")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .tag(session.id)
                    }
                    .frame(minWidth: 300)
                    .onChange(of: selected) { _, _ in loadSelection() }

                    editor
                        .frame(minWidth: 320, alignment: .topLeading)
                }
            } else {
                ContentUnavailableView("专注记录尚未就绪", systemImage: "clock.badge.exclamationmark", description: Text("请等待主应用完成启动后重试。"))
            }
        }
        .padding()
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

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedSession == nil ? "请选择一条记录" : "修正记录")
                .font(.headline)
            TextField("项目标识", text: $projectKey)
            TextField("项目名称", text: $projectName)
            DatePicker("开始", selection: $start)
            DatePicker("结束", selection: $end)
            HStack {
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
    private func delete() { guard let id = selectedSession?.id else { return }; apply(engine?.deleteSession(id: id)) }
    private func split() { guard let id = selectedSession?.id else { return }; apply(engine?.splitSession(id: id, at: splitAt)) }
    private func merge() { apply(engine?.mergeSessions(ids: Array(selected))) }
    private func undo() { apply(engine?.undoLastEdit()) }

    private func apply(_ result: FocusSessionEditResult?) {
        guard let result else { message = "专注记录尚未就绪"; return }
        switch result {
        case .saved:
            // The durable session journal is committed here. The App bridge
            // separately confirms the shared HUD/Widget snapshot, so do not
            // claim a presentation update before that checkpoint succeeds.
            message = "记录已保存，正在同步今日统计与展示。"
            selected.removeAll()
        case .rejected(let error):
            message = errorMessage(error)
        }
        refreshID = UUID()
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
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
        }
    }
}
