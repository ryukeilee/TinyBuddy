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
final class ManualFocusMenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private(set) var popover: NSPopover?
    private var popoverHostingController: NSHostingController<MenuBarFocusView>?
    private var refreshTimer: Timer?
    private let scheduleRefresh: (TimeInterval, Bool, @escaping @MainActor () -> Void) -> Timer
    private var engine: FocusSessionEngine?
    private var projectRegistryObserver: NSObjectProtocol?
    private var presentationObservers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private var registeredProjectsProvider: () -> [TinyBuddyProject]
    private var recentProjectNameProvider: () -> String?

    private var lastDisplayedTransition: String?
    private var lastDisplayedProject: String?
    private var lastDisplayedDuration: TimeInterval = 0

    // Anti-bounce: track last confirmed command to prevent double-fire.
    private var lastCommandToken: UUID?

    init(
        recentProjectNameProvider: @escaping () -> String? = { nil },
        registeredProjectsProvider: @escaping () -> [TinyBuddyProject] = { [] },
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        scheduleRefresh: @escaping (TimeInterval, Bool, @escaping @MainActor () -> Void) -> Timer = { interval, repeats, action in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.scheduleRefresh = scheduleRefresh
        self.recentProjectNameProvider = recentProjectNameProvider
        self.registeredProjectsProvider = registeredProjectsProvider
        super.init()
    }

    deinit {
        MainActor.assumeIsolated {
            refreshTimer?.invalidate()
            if let projectRegistryObserver {
                notificationCenter.removeObserver(projectRegistryObserver)
            }
            presentationObservers.forEach(notificationCenter.removeObserver)
            if let wakeObserver { workspaceNotificationCenter.removeObserver(wakeObserver) }
        }
    }

    // MARK: - Lifecycle

    func start(with engine: FocusSessionEngine) {
        self.engine = engine
        if projectRegistryObserver == nil {
            projectRegistryObserver = notificationCenter.addObserver(
                forName: Notification.Name("TinyBuddy.projectRegistryDidChange"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
        if presentationObservers.isEmpty {
            for name in [Notification.Name.gitActivitySnapshotDidChange,
                         .tinyBuddyTimeEnvironmentDidChange,
                         NSApplication.didBecomeActiveNotification] {
                presentationObservers.append(notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            wakeObserver = workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        guard statusItem == nil else { refresh(); return }
        lastDisplayedTransition = nil

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎯"
        item.button?.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        item.button?.toolTip = "TinyBuddy 专注控制"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        refresh()
    }

    func stop() {
        engine = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let projectRegistryObserver {
            notificationCenter.removeObserver(projectRegistryObserver)
            self.projectRegistryObserver = nil
        }
        presentationObservers.forEach(notificationCenter.removeObserver)
        presentationObservers.removeAll()
        if let wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        dismissPopover()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func setEngine(_ engine: FocusSessionEngine?) {
        self.engine = engine
        if engine == nil {
            stop()
        } else if statusItem == nil {
            start(with: engine!)
        } else {
            refresh()
        }
    }

    // MARK: - Popover

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover != nil {
            dismissPopover()
        } else {
            showPopover(relativeTo: button)
        }
    }

    func showPopover(relativeTo view: NSView) {
        let hosting = NSHostingController(rootView: makePopoverContent())
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 320)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting
        self.popover = popover
        popoverHostingController = hosting
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        refresh()
    }

    private func makePopoverContent(state: ManualFocusControlState? = nil) -> MenuBarFocusView {
        MenuBarFocusView(
            recentProjectName: recentProjectNameProvider(),
            registeredProjects: registeredProjectsProvider(),
            manualControlState: state ?? engine?.manualControlState ?? .idle,
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
    }

    private func refreshPopoverContent(_ state: ManualFocusControlState) {
        guard popover != nil else { return }
        popoverHostingController?.rootView = makePopoverContent(state: state)
    }

    private func dismissPopover() {
        popover?.delegate = nil
        popover?.close()
        popover = nil
        popoverHostingController = nil
        if engine != nil, statusItem != nil { refresh() }
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        popover = nil
        popoverHostingController = nil
        if engine != nil, statusItem != nil { refresh() }
    }

    // MARK: - Status Display

    /// Refreshes the menu-bar projection from the shared engine immediately.
    /// App lifecycle and HUD commands use this hook so the menu bar does not
    /// wait for a duration tick to converge.
    func refresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let engine, statusItem != nil else { return }
        let state = engine.manualControlState
        refreshStatusDisplay(state)
        refreshPopoverContent(state)
        if let interval = Self.refreshInterval(for: state, popoverIsShown: popover != nil) {
            refreshTimer = scheduleRefresh(interval, false) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// Transitions arrive through the committed engine callback and registry
    /// observer. Only accumulating duration needs a timer: minute precision
    /// in the status item, second precision from presentation until didClose.
    /// Do not sample isShown during presentation: AppKit sets it asynchronously.
    static func refreshInterval(for state: ManualFocusControlState, popoverIsShown: Bool) -> TimeInterval? {
        guard case .focusing(_, _, let duration) = state else { return nil }
        let precision: TimeInterval = popoverIsShown ? 1 : 60
        return max(0.05, precision - max(0, duration).truncatingRemainder(dividingBy: precision))
    }

    var statusTitle: String? { statusItem?.button?.title }

    private func refreshStatusDisplay(_ state: ManualFocusControlState) {
        guard let button = statusItem?.button else { return }

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

        guard state.transitionIdentity != lastDisplayedTransition
                || projectName != lastDisplayedProject
                || Int(duration / 60) != Int(lastDisplayedDuration / 60) else {
            return
        }

        lastDisplayedTransition = state.transitionIdentity
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
        refresh()
        dismissPopover()
    }

    private func pauseManualFocus() {
        guard let engine else { return }
        let token = UUID()
        lastCommandToken = token
        _ = engine.pauseManualFocus(at: Date(), commandToken: token)
        refresh()
        dismissPopover()
    }

    private func resumeManualFocus() {
        guard let engine else { return }
        let token = UUID()
        lastCommandToken = token
        _ = engine.resumeManualFocus(at: Date(), commandToken: token)
        refresh()
        dismissPopover()
    }

    private func endManualFocus() {
        guard let engine else { return }
        let token = UUID()
        lastCommandToken = token
        _ = engine.endManualFocus(at: Date(), commandToken: token)
        refresh()
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
