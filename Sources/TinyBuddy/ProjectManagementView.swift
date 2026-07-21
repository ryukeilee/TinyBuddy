import SwiftUI
import TinyBuddyCore

struct ProjectManagementView: View {
    let registryProvider: () -> TinyBuddyProjectRegistry?
    let sessionEngineProvider: () -> FocusSessionEngine?
    let recentProjectStore: GitTodayRecentProjectStore

    @State private var projects: [TinyBuddyProject] = []
    @State private var selectedID: TinyBuddyProjectID?
    @State private var editedName = ""
    @State private var mergePreview: TinyBuddyProjectMergePreview?
    @State private var mergeUndo: TinyBuddyProjectMergeUndo?
    @State private var message: String?

    private var registry: TinyBuddyProjectRegistry? { registryProvider() }
    private var selectedProject: TinyBuddyProject? {
        projects.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(projects, selection: $selectedID) { project in
                ProjectIdentityRow(project: project)
                    .tag(project.id)
            }
            .listStyle(.sidebar)
            .navigationTitle("项目身份")
        } detail: {
            if let selectedProject {
                projectDetail(selectedProject)
            } else if registry == nil {
                ContentUnavailableView(
                    "项目注册表不可用",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("App Group 存储当前不可用，未执行任何身份迁移。")
                )
            } else {
                ContentUnavailableView(
                    "选择一个项目",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("TinyBuddy.projectRegistryDidChange")
        )) { _ in reload() }
        .alert("合并项目", isPresented: Binding(
            get: { mergePreview != nil },
            set: { if !$0 { mergePreview = nil } }
        )) {
            Button("取消", role: .cancel) { mergePreview = nil }
            Button("合并") { commitMerge() }
        } message: {
            if let preview = mergePreview {
                Text("将 \(preview.sources.count) 个重复身份合并到“\(preview.target.displayName)”。会话 \(preview.affectedSessionCount) 条，专注时长 \(duration(preview.preservedFocusDuration))；历史不会删除。")
            }
        }
    }

    @ViewBuilder
    private func projectDetail(_ project: TinyBuddyProject) -> some View {
        Form {
            Section("显示") {
                TextField("项目名称", text: $editedName)
                Button("保存名称") { rename(project) }
                    .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("状态") {
                LabeledContent("当前状态", value: stateLabel(project.state))
                LabeledContent("稳定身份", value: project.id.rawValue)
                    .textSelection(.enabled)
                if let unavailableSince = project.unavailableSince {
                    LabeledContent("不可用起始", value: unavailableSince.formatted())
                }
                if project.state == .archived {
                    Button("恢复为活跃项目") { restore(project) }
                } else if project.state != .removed {
                    Button("归档项目", role: .destructive) { archive(project) }
                }
            }

            if project.kind == .gitRepository {
                Section("仓库身份") {
                    LabeledContent("已识别位置", value: "\(project.aliases.count)")
                    if duplicateSources(for: project).isEmpty {
                        Text("未发现使用同一仓库证据的重复项目。")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("发现 \(duplicateSources(for: project).count) 个重复身份，可先预览再合并。")
                        Button("预览合并") { prepareMerge(project) }
                    }
                }
            }

            if let mergeUndo {
                Section("撤销") {
                    Button("撤销上次项目合并") { undoMerge(mergeUndo) }
                }
            }

            if let message {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.displayName)
        .onChange(of: selectedID) { _, _ in syncEditedName() }
        .onAppear(perform: syncEditedName)
    }

    private func reload() {
        projects = registry?.currentSnapshot.projects
            .filter { $0.state != .removed }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            } ?? []
        if selectedID == nil || !projects.contains(where: { $0.id == selectedID }) {
            selectedID = projects.first?.id
        }
        syncEditedName()
    }

    private func syncEditedName() {
        editedName = selectedProject?.displayName ?? ""
    }

    private func duplicateSources(for project: TinyBuddyProject) -> [TinyBuddyProject] {
        guard let registry else { return [] }
        return registry.duplicateGroups()
            .first { $0.projects.contains(where: { $0.id == project.id }) }?
            .projects.filter { $0.id != project.id } ?? []
    }

    private func prepareMerge(_ target: TinyBuddyProject) {
        guard let registry else { return }
        let sources = Set(duplicateSources(for: target).map(\.id))
        mergePreview = registry.previewMerge(
            targetID: target.id,
            sourceIDs: sources,
            sessions: sessionEngineProvider()?.allSessions ?? [],
            now: Date()
        )
    }

    private func commitMerge() {
        guard let registry, let preview = mergePreview else { return }
        self.mergePreview = nil
        switch registry.merge(preview) {
        case .saved(_, let undo):
            mergeUndo = undo
            sessionEngineProvider()?.refreshProjectIdentityPresentation()
            refreshRecentProjectDisplay(registry)
            message = "项目已合并；撤销入口会保留到下一次身份修改。"
        case .rejectedStale:
            message = "项目已发生变化，请重新预览。"
        case .rejectedInvalid:
            message = "合并条件无效，未修改任何数据。"
        case .persistenceFailed:
            message = "无法持久化合并，原项目和历史保持不变。"
        }
        reload()
    }

    private func undoMerge(_ undo: TinyBuddyProjectMergeUndo) {
        guard let registry else { return }
        switch registry.undoMerge(undo) {
        case .saved:
            mergeUndo = nil
            sessionEngineProvider()?.refreshProjectIdentityPresentation()
            refreshRecentProjectDisplay(registry)
            message = "项目合并已撤销。"
        case .rejectedStale:
            message = "合并后已有其他身份修改，无法安全撤销。"
        case .rejectedInvalid, .persistenceFailed:
            message = "撤销未保存，当前项目身份保持不变。"
        }
        reload()
    }

    private func rename(_ project: TinyBuddyProject) {
        apply(registry?.rename(id: project.id, displayName: editedName), success: "项目名称已更新。")
    }

    private func archive(_ project: TinyBuddyProject) {
        apply(registry?.archive(id: project.id), success: "项目已归档；历史数据仍会保留。")
    }

    private func restore(_ project: TinyBuddyProject) {
        apply(registry?.restore(id: project.id), success: "项目已按你的选择恢复为活跃状态。")
    }

    private func apply(_ result: TinyBuddyProjectMutationResult?, success: String) {
        guard let registry, let result else { return }
        switch result {
        case .saved:
            mergeUndo = nil
            sessionEngineProvider()?.refreshProjectIdentityPresentation()
            refreshRecentProjectDisplay(registry)
            message = success
        case .rejectedStale:
            message = "项目已发生变化，请重试。"
        case .rejectedInvalid:
            message = "操作无效，未修改项目。"
        case .persistenceFailed:
            message = "无法保存操作，原数据保持不变。"
        }
        reload()
    }

    private func refreshRecentProjectDisplay(_ registry: TinyBuddyProjectRegistry) {
        guard let storedID = recentProjectStore.loadTodayProjectID(),
              let resolved = registry.resolve(id: storedID) else { return }
        // Preserve the source ID across merge so undo can restore its original
        // recent-activity attribution; only the presentation label changes.
        recentProjectStore.saveTodayProject(id: storedID, displayName: resolved.displayName)
    }

    private func stateLabel(_ state: TinyBuddyProjectState) -> String {
        switch state {
        case .active: return "活跃"
        case .temporarilyUnavailable: return "暂时不可用"
        case .archived: return "已归档"
        case .removed: return "已移除"
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}

private struct ProjectIdentityRow: View {
    let project: TinyBuddyProject

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(project.state == .active ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        project.kind == .gitRepository ? "shippingbox" : "app"
    }

    private var status: String {
        switch project.state {
        case .active: return "活跃"
        case .temporarilyUnavailable: return "暂时不可用"
        case .archived: return "已归档"
        case .removed: return "已移除"
        }
    }
}
