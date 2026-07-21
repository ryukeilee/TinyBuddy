import SwiftUI
import TinyBuddyCore

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
        if let recent = recentProjectName {
            sourceRow(
                source: .recent(recent),
                icon: "clock.arrow.circlepath",
                label: "最近项目",
                detail: recent,
                isRecommended: true
            )
        }

        if !registeredProjects.isEmpty {
            Text("已知项目")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            ForEach(registeredProjects) { project in
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
                context = FocusProjectContext(key: "manual.recent.\(trimmed)", displayName: trimmed)
            case .registered(let id):
                if let project = registeredProjects.first(where: { $0.id == id }) {
                    context = FocusProjectContext(key: project.id.rawValue, displayName: project.displayName)
                } else {
                    context = FocusProjectContext(key: "manual.\(trimmed)", displayName: trimmed)
                }
            case .custom:
                let key = "manual.custom.\(trimmed)".replacingOccurrences(of: " ", with: "-")
                context = FocusProjectContext(key: key, displayName: trimmed)
            }
        } else {
            context = FocusProjectContext(key: "manual.\(trimmed)", displayName: trimmed)
        }

        onSubmit(context)
    }
}
