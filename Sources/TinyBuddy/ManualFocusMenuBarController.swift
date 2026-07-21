import AppKit
import SwiftUI
import TinyBuddyCore

/// Menu bar controller for TinyBuddy manual focus control.
/// Provides a status item in the macOS menu bar that displays the current
/// focus state and offers project selection, start/pause/resume/end controls.
///
/// All state reads go through the shared engine; the menu bar never creates
/// parallel sessions or duplicate records.
@MainActor
final class ManualFocusMenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var refreshTimer: Timer?
    private var engine: FocusSessionEngine?
    private var registeredProjectsProvider: () -> [TinyBuddyProject]
    private var recentProjectNameProvider: () -> String?

    private var lastDisplayedState: ManualFocusControlState = .idle
    private var lastDisplayedProject: String?
    private var lastDisplayedDuration: TimeInterval = 0

    // Anti-bounce: track last confirmed command to prevent double-fire.
    private var lastCommandToken: UUID?

    init(
        recentProjectNameProvider: @escaping () -> String? = { nil },
        registeredProjectsProvider: @escaping () -> [TinyBuddyProject] = { [] }
    ) {
        self.recentProjectNameProvider = recentProjectNameProvider
        self.registeredProjectsProvider = registeredProjectsProvider
        super.init()
    }

    deinit {
        MainActor.assumeIsolated {
            refreshTimer?.invalidate()
        }
    }

    // MARK: - Lifecycle

    func start(with engine: FocusSessionEngine) {
        self.engine = engine
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎯"
        item.button?.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        item.button?.toolTip = "TinyBuddy 专注控制"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatusDisplay()
            }
        }
        refreshStatusDisplay()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        dismissPopover()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        engine = nil
    }

    func setEngine(_ engine: FocusSessionEngine?) {
        self.engine = engine
        if engine == nil {
            stop()
        } else if statusItem == nil {
            start(with: engine!)
        } else {
            refreshStatusDisplay()
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover, popover.isShown {
            dismissPopover()
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo view: NSView) {
        let contentView = MenuBarFocusView(
            recentProjectName: recentProjectNameProvider(),
            registeredProjects: registeredProjectsProvider(),
            manualControlState: engine?.manualControlState ?? .idle,
            onStartFocus: { [weak self] project in
                self?.startManualFocus(project: project)
            },
            onPause: { [weak self] in
                self?.pauseManualFocus()
            },
            onResume: { [weak self] in
                self?.resumeManualFocus()
            },
            onEnd: { [weak self] in
                self?.endManualFocus()
            }
        )

        let hosting = NSHostingController(rootView: contentView)
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 320)
        popover.behavior = .transient
        popover.contentViewController = hosting
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        self.popover = popover
    }

    private func dismissPopover() {
        popover?.close()
        popover = nil
    }

    // MARK: - Status Display

    private func refreshStatusDisplay() {
        guard let engine, let button = statusItem?.button else { return }
        let state = engine.manualControlState

        // Debounce: don't update title unless state or project changed.
        let projectName: String? = {
            switch state {
            case .idle: return nil
            case .focusing(let p, _, _): return p.displayName
            case .paused(let p, _, _, _): return p.displayName
            }
        }()
        let duration: TimeInterval = {
            switch state {
            case .idle: return 0
            case .focusing(_, _, let d): return d
            case .paused(_, _, _, let d): return d
            }
        }()

        guard state != lastDisplayedState
                || projectName != lastDisplayedProject
                || Int(duration / 60) != Int(lastDisplayedDuration / 60) else {
            return
        }

        lastDisplayedState = state
        lastDisplayedProject = projectName
        lastDisplayedDuration = duration

        switch state {
        case .idle:
            button.title = "🎯"
            button.toolTip = "TinyBuddy — 开始专注"

        case .focusing(_, _, let dur):
            let mins = Int(dur) / 60
            button.title = "▶ \(mins)m"
            button.toolTip = "\(projectName ?? "") — 专注中 (\(mins)分钟)"

        case .paused(_, _, _, let dur):
            let mins = Int(dur) / 60
            button.title = "⏸ \(mins)m"
            button.toolTip = "\(projectName ?? "") — 已暂停 (\(mins)分钟)"
        }
    }

    // MARK: - Manual Control Actions

    private func startManualFocus(project: FocusProjectContext) {
        guard let engine else { return }
        let token = UUID()
        lastCommandToken = token
        _ = engine.startManualFocus(project: project, at: Date(), commandToken: token)
        refreshStatusDisplay()
        dismissPopover()
    }

    private func pauseManualFocus() {
        guard let engine else { return }
        let token = UUID()
        lastCommandToken = token
        _ = engine.pauseManualFocus(at: Date(), commandToken: token)
        refreshStatusDisplay()
        dismissPopover()
    }

    private func resumeManualFocus() {
        guard let engine else { return }
        let token = UUID()
        lastCommandToken = token
        _ = engine.resumeManualFocus(at: Date(), commandToken: token)
        refreshStatusDisplay()
        dismissPopover()
    }

    private func endManualFocus() {
        guard let engine else { return }
        let token = UUID()
        lastCommandToken = token
        _ = engine.endManualFocus(at: Date(), commandToken: token)
        refreshStatusDisplay()
        dismissPopover()
    }
}

// MARK: - Menu Bar Focus View (SwiftUI)

private struct MenuBarFocusView: View {
    let recentProjectName: String?
    let registeredProjects: [TinyBuddyProject]
    let manualControlState: ManualFocusControlState

    let onStartFocus: (FocusProjectContext) -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            Divider()

            // Content
            switch manualControlState {
            case .idle:
                idleContent
            case .focusing(let project, _, let duration):
                focusingContent(project: project, duration: duration)
            case .paused(let project, _, _, let duration):
                pausedContent(project: project, duration: duration)
            }
        }
        .frame(width: 280)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: headerIcon)
                .foregroundStyle(headerColor)
            Text(headerTitle)
                .font(.headline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var headerIcon: String {
        switch manualControlState {
        case .idle: return "scope"
        case .focusing: return "scope"
        case .paused: return "pause.circle.fill"
        }
    }

    private var headerColor: Color {
        switch manualControlState {
        case .idle: return .secondary
        case .focusing: return .green
        case .paused: return .orange
        }
    }

    private var headerTitle: String {
        switch manualControlState {
        case .idle: return "手动专注"
        case .focusing: return "专注中"
        case .paused: return "已暂停"
        }
    }

    // MARK: - Idle

    private var idleContent: some View {
        ManualFocusProjectPicker(
            recentProjectName: recentProjectName,
            registeredProjects: registeredProjects,
            onSubmit: onStartFocus
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Focusing

    private func focusingContent(project: FocusProjectContext, duration: TimeInterval) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(project.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(formatDuration(duration))
                    .font(.largeTitle.monospacedDigit())
                    .foregroundStyle(.green)
                Text("已专注")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

            HStack(spacing: 12) {
                controlButton(title: "暂停", icon: "pause.circle.fill", color: .orange, action: onPause)
                controlButton(title: "结束", icon: "stop.circle.fill", color: .red, action: onEnd)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Paused

    private func pausedContent(project: FocusProjectContext, duration: TimeInterval) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(project.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(formatDuration(duration))
                    .font(.largeTitle.monospacedDigit())
                    .foregroundStyle(.orange)
                Text("已暂停")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

            HStack(spacing: 12) {
                controlButton(title: "继续", icon: "play.circle.fill", color: .green, action: onResume)
                controlButton(title: "结束", icon: "stop.circle.fill", color: .red, action: onEnd)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func controlButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
