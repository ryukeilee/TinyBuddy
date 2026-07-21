import SwiftUI
import TinyBuddyCore

// MARK: - Focus History List View

/// A paginated, filterable session list that loads data lazily and prevents
/// stale results from overwriting newer queries.
///
/// Features:
/// - Cursor-based pagination (loads more as user scrolls)
/// - Filter toolbar with date range, project, status, keyword search
/// - Cancellable queries (rapid filter changes only serve the latest)
/// - Distinct loading, error, empty, and data states
/// - Pull-to-refresh
struct FocusHistoryListView: View {
    @State private var controller: HistoryQueryController

    @State private var searchText = ""
    @State private var selectedProjectKey: String? = nil
    @State private var selectedStatus: FocusSessionStatus? = nil
    @State private var dayStart: String? = nil
    @State private var dayEnd: String? = nil
    @State private var showDateFilter = false
    @State private var projectOptions: [(key: String, name: String)] = []

    private let pageSize = 50

    init(controller: HistoryQueryController) {
        self._controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterToolbar
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            content
        }
        .task {
            await controller.refresh()
            await loadProjectOptions()
        }
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            Task {
                var q = controller.query
                q.keyword = trimmed.isEmpty ? nil : trimmed
                await controller.updateQuery(q)
            }
        }
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索项目", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(.textBackgroundColor))
            .cornerRadius(6)

            // Project filter
            projectFilterMenu

            // Status filter
            statusFilterMenu

            // Date range toggle
            Button {
                showDateFilter.toggle()
            } label: {
                Image(systemName: "calendar")
                    .foregroundColor(dateFilterActive ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("日期范围筛选")
            .popover(isPresented: $showDateFilter) {
                dateFilterPopover
            }
        }
    }

    // MARK: - Project Filter

    private var projectFilterMenu: some View {
        Menu {
            Button("全部项目") {
                selectedProjectKey = nil
                applyFilters()
            }
            .foregroundColor(selectedProjectKey == nil ? .accentColor : .primary)

            ForEach(projectOptions, id: \.key) { option in
                Button(option.name) {
                    selectedProjectKey = option.key
                    applyFilters()
                }
                .foregroundColor(selectedProjectKey == option.key ? .accentColor : .primary)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                if let key = selectedProjectKey,
                   let name = projectOptions.first(where: { $0.key == key })?.name {
                    Text(name)
                        .lineLimit(1)
                        .font(.subheadline)
                }
            }
            .foregroundColor(selectedProjectKey != nil ? .accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Status Filter

    private var statusFilterMenu: some View {
        Menu {
            Button("全部状态") {
                selectedStatus = nil
                applyFilters()
            }
            .foregroundColor(selectedStatus == nil ? .accentColor : .primary)

            Button("已结束") {
                selectedStatus = .ended
                applyFilters()
            }
            .foregroundColor(selectedStatus == .ended ? .accentColor : .primary)

            Button("进行中") {
                selectedStatus = .active
                applyFilters()
            }
            .foregroundColor(selectedStatus == .active ? .accentColor : .primary)

            Button("已暂停") {
                selectedStatus = .paused
                applyFilters()
            }
            .foregroundColor(selectedStatus == .paused ? .accentColor : .primary)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                if let status = selectedStatus {
                    Text(statusLabel(status))
                        .font(.subheadline)
                }
            }
            .foregroundColor(selectedStatus != nil ? .accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Date Filter Popover

    private var dateFilterPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("日期范围")
                .font(.headline)
            TextField("开始日期 (yyyy-MM-dd)", text: Binding(
                get: { dayStart ?? "" },
                set: { dayStart = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)
            TextField("结束日期 (yyyy-MM-dd)", text: Binding(
                get: { dayEnd ?? "" },
                set: { dayEnd = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)

            HStack {
                Button("清除") {
                    dayStart = nil
                    dayEnd = nil
                    applyFilters()
                    showDateFilter = false
                }
                Button("应用") {
                    applyFilters()
                    showDateFilter = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 240)
    }

    private var dateFilterActive: Bool {
        dayStart != nil || dayEnd != nil
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch controller.loadState {
        case .idle:
            Color.clear

        case .loading where controller.allSessions.isEmpty:
            loadingView

        case .loading:
            // Loading more — show indicator at bottom of existing content
            sessionList

        case .loaded(let page) where page.sessions.isEmpty:
            emptyView

        case .loaded:
            sessionList

        case .failure:
            errorView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("加载专注记录中…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("无匹配记录")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("尝试更改筛选条件或确认有已结束的专注会话。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("加载失败")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(controller.loadState.errorMessage ?? "未知错误")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await controller.refresh() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            ForEach(controller.allSessions) { session in
                SessionRowView(session: session)
                    .onAppear {
                        // Trigger load-more when approaching the end
                        if session.id == controller.allSessions.last?.id {
                            Task { await controller.loadMore() }
                        }
                    }
            }

            // Loading indicator at bottom during pagination
            if controller.loadState.isLoading && !controller.allSessions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.6)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            // Count summary
            if case .loaded(let page) = controller.loadState {
                HStack {
                    Spacer()
                    Text(summaryText(page: page))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset)
        .refreshable {
            await controller.refresh()
        }
    }

    // MARK: - Helpers

    private func summaryText(page: FocusSessionQueryPage) -> String {
        let shown = controller.allSessions.count
        if let total = page.totalEstimatedCount, total > shown {
            return "显示 \(shown) / 共 \(total) 条记录"
        }
        return "共 \(shown) 条记录"
    }

    private func statusLabel(_ status: FocusSessionStatus) -> String {
        switch status {
        case .active: return "进行中"
        case .paused: return "已暂停"
        case .ended: return "已结束"
        }
    }

    private func applyFilters() {
        var q = FocusSessionQuery()
        q.dayStart = dayStart
        q.dayEnd = dayEnd
        q.projectKey = selectedProjectKey
        q.status = selectedStatus
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        q.keyword = trimmed.isEmpty ? nil : trimmed
        Task {
            await controller.updateQuery(q, debounceSeconds: 0)
        }
    }

    private func loadProjectOptions() async {
        // Derive unique projects from all loaded sessions
        var unique: [String: String] = [:]
        for session in controller.allSessions {
            unique[session.project.key] = session.project.displayName
        }
        projectOptions = unique.map { (key: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Session Row View

private struct SessionRowView: View {
    let session: FocusSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.project.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                statusBadge
            }

            HStack(spacing: 8) {
                Label(session.dayIdentifier, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(formattedRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if session.status == .ended {
                    Label(formattedDuration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                authorityLabel
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        switch session.status {
        case .active:
            return Text("进行中")
                .font(.caption2)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)
        case .paused:
            return Text("已暂停")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(4)
        case .ended:
            return Text("已结束")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
    }

    private var formattedRange: String {
        let start = session.startedAt.formatted(date: .omitted, time: .shortened)
        if let end = session.endedAt {
            return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(start) – 进行中"
    }

    private var formattedDuration: String {
        let dur = session.activeDuration(now: session.endedAt ?? Date())
        let minutes = Int(dur / 60)
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private var authorityLabel: some View {
        switch session.decisionAuthority {
        case .automatic:
            return Label("自动识别", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .userConfirmed:
            return Label("用户确认", systemImage: "hand.thumbsup")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .manualCorrection:
            return Label("手动修正", systemImage: "pencil")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case nil:
            return Label("历史记录", systemImage: "clock.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
