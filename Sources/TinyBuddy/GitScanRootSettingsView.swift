import SwiftUI

extension Notification.Name {
    static let gitScanRootAuthorizationAddRequested = Notification.Name(
        "TinyBuddy.gitScanRootAuthorizationAddRequested"
    )
    static let gitScanRootAuthorizationReauthorizationRequested = Notification.Name(
        "TinyBuddy.gitScanRootAuthorizationReauthorizationRequested"
    )
    static let gitScanRootAuthorizationRepairRequested = Notification.Name(
        "TinyBuddy.gitScanRootAuthorizationRepairRequested"
    )
    static let gitScanRootAuthorizationRemovalRequested = Notification.Name(
        "TinyBuddy.gitScanRootAuthorizationRemovalRequested"
    )
    static let gitScanRootAuthorizationRemoveAllRequested = Notification.Name(
        "TinyBuddy.gitScanRootAuthorizationRemoveAllRequested"
    )
    static let gitScanRootAuthorizationsDidChange = Notification.Name(
        "TinyBuddy.gitScanRootAuthorizationsDidChange"
    )
    static let tinyBuddySettingsDidChange = Notification.Name(
        "TinyBuddy.settingsDidChange"
    )
}

enum GitScanRootAuthorizationCommand {
    static let authorizationIdentifierKey = "TinyBuddy.gitScanRootAuthorizationIdentifier"
}

@MainActor
final class GitScanRootSettingsViewModel: ObservableObject {
    @Published private(set) var authorizations: [GitScanRootAuthorization] = []

    private let store: GitScanRootAuthorizationStore
    private let notificationCenter: NotificationCenter
    private var authorizationsDidChangeObserver: NSObjectProtocol?

    init(
        store: GitScanRootAuthorizationStore = GitScanRootAuthorizationStore(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.notificationCenter = notificationCenter
        reloadAuthorizations()
        authorizationsDidChangeObserver = notificationCenter.addObserver(
            forName: .gitScanRootAuthorizationsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadAuthorizations()
            }
        }
    }

    func requestAuthorization() {
        notificationCenter.post(name: .gitScanRootAuthorizationAddRequested, object: nil)
    }

    func requestReauthorization(for identifier: String) {
        postAuthorizationCommand(
            named: .gitScanRootAuthorizationReauthorizationRequested,
            identifier: identifier
        )
    }

    func removeAuthorization(id: String) {
        postAuthorizationCommand(
            named: .gitScanRootAuthorizationRemovalRequested,
            identifier: id
        )
    }

    func removeAllAuthorizations() {
        notificationCenter.post(name: .gitScanRootAuthorizationRemoveAllRequested, object: nil)
    }

    private func reloadAuthorizations() {
        authorizations = store.authorizationStatuses()
    }

    private func postAuthorizationCommand(named name: Notification.Name, identifier: String) {
        notificationCenter.post(
            name: name,
            object: nil,
            userInfo: [GitScanRootAuthorizationCommand.authorizationIdentifierKey: identifier]
        )
    }

    deinit {
        if let authorizationsDidChangeObserver {
            notificationCenter.removeObserver(authorizationsDidChangeObserver)
        }
    }
}

struct GitScanRootSettingsView: View {
    @StateObject private var viewModel: GitScanRootSettingsViewModel

    init(viewModel: GitScanRootSettingsViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? GitScanRootSettingsViewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Git 扫描目录")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("TinyBuddy 仅扫描你在此授权的目录中的 Git 元数据。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Git 扫描目录设置。TinyBuddy 仅扫描你在此授权的目录中的 Git 元数据。")

            Group {
                if viewModel.authorizations.isEmpty {
                    ContentUnavailableView(
                        "尚未添加 Git 目录",
                        systemImage: "folder.badge.plus",
                        description: Text("添加一个或多个开发目录后，TinyBuddy 才能读取 Git 活动。")
                    )
                } else {
                    List(viewModel.authorizations) { authorization in
                        authorizationRow(authorization)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button {
                    viewModel.requestAuthorization()
                } label: {
                    Label("添加 Git 目录", systemImage: "plus")
                }
                .accessibilityHint("打开文件选择器，选择一个或多个开发目录进行授权")

                Spacer()

                Button("移除全部", role: .destructive) {
                    viewModel.removeAllAuthorizations()
                }
                .disabled(viewModel.authorizations.isEmpty)
                .accessibilityLabel("移除全部授权目录")
                .accessibilityHint("移除所有已授权的 Git 扫描目录")
            }

            Divider()
                .accessibilityHidden(true)

            Toggle(isOn: Binding(
                get: { TinyBuddyLoginItemManager.shared.isEnabled },
                set: { newValue in
                    try? TinyBuddyLoginItemManager.shared.setEnabled(newValue)
                    NotificationCenter.default.post(
                        name: .tinyBuddySettingsDidChange,
                        object: nil
                    )
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录时启动 TinyBuddy")
                        .font(.subheadline)
                    Text("启用后，TinyBuddy 会在你登录 macOS 时自动启动")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityHint("启用后，TinyBuddy 会在你登录 macOS 时自动启动")
        }
        .frame(minWidth: 560, minHeight: 380)
        .scenePadding()
    }

    @ViewBuilder
    private func authorizationRow(_ authorization: GitScanRootAuthorization) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: stateSymbol(for: authorization.state))
                .foregroundStyle(stateColor(for: authorization.state))
                .frame(width: 18)
                .accessibilityLabel(stateSymbolAccessibilityLabel(for: authorization.state))

            VStack(alignment: .leading, spacing: 4) {
                Text(authorization.displayName)
                    .font(.headline)
                Text(authorization.lastKnownPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(statusText(for: authorization.state))
                    .font(.caption)
                    .foregroundStyle(stateColor(for: authorization.state))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(authorizationRowAccessibilityLabel(for: authorization))

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Button("重新授权") {
                    viewModel.requestReauthorization(for: authorization.id)
                }
                .accessibilityLabel("重新授权「\(authorization.displayName)」")
                .accessibilityHint("重新选择该目录以刷新授权")

                Button("移除", role: .destructive) {
                    viewModel.removeAuthorization(id: authorization.id)
                }
                .accessibilityLabel("移除「\(authorization.displayName)」")
                .accessibilityHint("从授权列表中移除该目录")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(authorizationRowAccessibilityLabel(for: authorization))
    }

    private func authorizationRowAccessibilityLabel(for authorization: GitScanRootAuthorization) -> String {
        let stateText: String
        switch authorization.state {
        case .available:
            stateText = "可用"
        case .unavailable(let reason):
            stateText = "不可用：\(localizedReason(for: reason))"
        }
        return "\(authorization.displayName)，\(authorization.lastKnownPath)，状态：\(stateText)"
    }

    private func stateSymbolAccessibilityLabel(for state: GitScanRootAuthorizationState) -> String {
        switch state {
        case .available:
            return "授权可用"
        case .unavailable:
            return "授权不可用"
        }
    }

    private func stateSymbol(for state: GitScanRootAuthorizationState) -> String {
        switch state {
        case .available:
            return "checkmark.circle.fill"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    private func stateColor(for state: GitScanRootAuthorizationState) -> Color {
        switch state {
        case .available:
            return .green
        case .unavailable:
            return .orange
        }
    }

    private func statusText(for state: GitScanRootAuthorizationState) -> String {
        switch state {
        case .available:
            return "可用"
        case .unavailable(let reason):
            return "已失效：\(localizedReason(for: reason))"
        }
    }

    private func localizedReason(for reason: GitScanRootAuthorizationFailureReason) -> String {
        switch reason {
        case .bookmarkCorruptOrRevoked:
            return "授权信息已失效或损坏。"
        case .directoryUnavailable:
            return "目录已移动、删除或当前不可用。"
        case .permissionDenied:
            return "系统未授予该目录的访问权限。"
        case .bookmarkRefreshFailed:
            return "无法刷新目录授权，请重新授权。"
        case .scopeTooBroad:
            return "该目录范围过大，无法用于 Git 扫描。"
        }
    }
}
