import SwiftUI
import TinyBuddyCore

/// Resolves a picker label to the stable project identity shared by automatic
/// attribution. A recent-project label is only upgraded when it maps to one
/// active registered project; ambiguity deliberately keeps an isolated manual
/// key instead of guessing the wrong project.
enum ManualFocusProjectIdentityResolver {
    static func customProject(named displayName: String) -> FocusProjectContext {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return FocusProjectContext(
            key: "manual.custom-v2.\(trimmed)",
            displayName: trimmed
        )
    }

    static func recentProject(
        named displayName: String,
        registeredProjects: [TinyBuddyProject]
    ) -> FocusProjectContext {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = registeredProjects.filter { project in
            project.state == .active
                && project.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        if matches.count == 1, let project = matches.first {
            return FocusProjectContext(
                key: project.id.rawValue,
                displayName: project.displayName
            )
        }
        return FocusProjectContext(key: "manual.recent.\(trimmed)", displayName: trimmed)
    }
}

/// Name-based search/filter for the manual focus project picker. Filtering only
/// hides rows from the caller-supplied registry projection; it never mints,
/// rewrites, or duplicates a project identity, so confirming a filtered row
/// resolves to exactly the same stable `FocusProjectContext` as before.
enum ManualFocusProjectFilter {
    /// Below this many registered projects the option list is short enough to
    /// scan directly, so the search field stays hidden and the picker keeps its
    /// original layout.
    static let searchFieldMinimumProjectCount = 6

    static func shouldShowSearchField(registeredProjectCount: Int) -> Bool {
        registeredProjectCount >= searchFieldMinimumProjectCount
    }

    /// Trims surrounding whitespace/newlines so a stray space never hides every
    /// row, without otherwise altering the typed query.
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSearching(_ query: String) -> Bool {
        !normalizedQuery(query).isEmpty
    }

    /// Case- and diacritic-insensitive substring match. Locale is deliberately
    /// unspecified so the result is deterministic across systems.
    static func matches(_ name: String, query: String) -> Bool {
        let trimmed = normalizedQuery(query)
        guard !trimmed.isEmpty else { return true }
        return fold(name).contains(fold(trimmed))
    }

    /// Empty or whitespace-only queries return the input untouched, preserving
    /// the registry's existing ordering and deduplication.
    static func projects(_ projects: [TinyBuddyProject], query: String) -> [TinyBuddyProject] {
        guard isSearching(query) else { return projects }
        return projects.filter { matches($0.displayName, query: query) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// A reusable project picker used by both the HUD and menu bar.
/// It surfaces recent Git projects, registered projects from the identity
/// registry, and allows entering a custom project name.
///
/// Anti-bounce: the confirm action is debounced so rapid repeated clicks produce
/// exactly one state change. The caller must supply a project resolver to handle
/// the final `FocusProjectContext` creation.
struct ManualFocusProjectPicker: View {
    let recentProjectName: String?
    let registeredProjects: [TinyBuddyProject]
    let onSubmit: (FocusProjectContext) -> Void
    let isDisabled: Bool

    @State private var customName: String = ""
    @State private var selectedRegisteredID: TinyBuddyProjectID?
    @State private var lastConfirmedToken: UUID?
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool

    private enum Source: Hashable {
        case recent(String)
        case registered(TinyBuddyProjectID)
        case custom
    }

    @State private var selectedSource: Source?

    init(
        recentProjectName: String?,
        registeredProjects: [TinyBuddyProject],
        isDisabled: Bool = false,
        onSubmit: @escaping (FocusProjectContext) -> Void
    ) {
        self.recentProjectName = recentProjectName
        self.registeredProjects = registeredProjects
        self.isDisabled = isDisabled
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isDisabled {
                projectOptions
                customEntryRow
                confirmButton
            }
        }
        .onAppear {
            // Default to recent project if available.
            if selectedSource == nil, let recent = recentProjectName {
                selectedSource = .recent(recent)
                customName = recent
            }
        }
    }

    // MARK: - Project Options

    @ViewBuilder
    private var projectOptions: some View {
        if ManualFocusProjectFilter.shouldShowSearchField(registeredProjectCount: registeredProjects.count) {
            searchField
        }

        if let recent = recentProjectName,
           ManualFocusProjectFilter.matches(recent, query: searchQuery) {
            sourceRow(
                source: .recent(recent),
                icon: "clock.arrow.circlepath",
                label: "最近项目",
                detail: recent,
                isRecommended: true
            )
        }

        let visibleProjects = ManualFocusProjectFilter.projects(registeredProjects, query: searchQuery)

        if !registeredProjects.isEmpty {
            Text(ManualFocusProjectFilter.isSearching(searchQuery)
                 ? "已知项目（\(visibleProjects.count)）"
                 : "已知项目")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            if visibleProjects.isEmpty {
                Text("没有名称匹配“\(ManualFocusProjectFilter.normalizedQuery(searchQuery))”的项目")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(visibleProjects) { project in
                sourceRow(
                    source: .registered(project.id),
                    icon: project.kind == .gitRepository ? "shippingbox" : "app",
                    label: project.displayName,
                    detail: project.kind == .gitRepository ? "Git 仓库" : "应用",
                    isRecommended: false
                )
            }
        }

        sourceRow(
            source: .custom,
            icon: "square.and.pencil",
            label: "自定义项目",
            detail: nil,
            isRecommended: false
        )
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("搜索项目名称", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.caption)
            if ManualFocusProjectFilter.isSearching(searchQuery) {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func sourceRow(
        source: Source,
        icon: String,
        label: String,
        detail: String?,
        isRecommended: Bool
    ) -> some View {
        Button {
            selectedSource = source
            switch source {
            case .recent(let name):
                customName = name
            case .registered:
                customName = label
            case .custom:
                customName = ""
                isSearchFocused = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(selectedSource == source ? .blue : .secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isRecommended {
                    Text("推荐")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.1))
                        .clipShape(Capsule())
                }
                Spacer()
                if selectedSource == source {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedSource == source ? Color.blue.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Custom Entry

    private var customEntryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if selectedSource == .custom {
                Text("输入项目名称")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("项目名称", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($isSearchFocused)
                    .onSubmit {
                        confirmSelection()
                    }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Confirm

    private var confirmButton: some View {
        Button {
            confirmSelection()
        } label: {
            Label("开始专注", systemImage: "play.fill")
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDisabled)
        .padding(.top, 4)
    }

    // MARK: - Action

    private func confirmSelection() {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isDisabled else { return }

        // Anti-bounce: same name confirmed twice without source change is idempotent.
        let token = UUID()
        guard token != lastConfirmedToken else { return }
        lastConfirmedToken = token

        let context: FocusProjectContext
        if let source = selectedSource {
            switch source {
            case .recent:
                context = ManualFocusProjectIdentityResolver.recentProject(
                    named: trimmed,
                    registeredProjects: registeredProjects
                )
            case .registered(let id):
                if let project = registeredProjects.first(where: { $0.id == id }) {
                    context = FocusProjectContext(key: project.id.rawValue, displayName: project.displayName)
                } else {
                    context = FocusProjectContext(key: "manual.\(trimmed)", displayName: trimmed)
                }
            case .custom:
                context = ManualFocusProjectIdentityResolver.customProject(named: trimmed)
            }
        } else {
            context = FocusProjectContext(key: "manual.\(trimmed)", displayName: trimmed)
        }

        onSubmit(context)
    }
}
