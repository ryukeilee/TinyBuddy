import AppKit
import OSLog
import SwiftUI
import TinyBuddyCore
import WidgetKit

private let tinyBuddyHUDWindowIdentifier = NSUserInterfaceItemIdentifier("TinyBuddy.HUDWindow")
private let tinyBuddyHUDLogger = Logger(subsystem: "local.tinybuddy", category: "HUD")

@MainActor
private func publishTinyBuddyHUDReadyWhenVisible(
    _ window: NSWindow,
    remainingAttempts: Int = 150
) {
    let targetSize = NSSize(width: 284, height: 520)
    let isTargetSize = abs(window.contentLayoutRect.width - targetSize.width) < 0.5
        && abs(window.contentLayoutRect.height - targetSize.height) < 0.5
    let isSemanticallyVisible = window.isVisible
        && !window.isMiniaturized
        && window.screen != nil
        && window.alphaValue > 0

    if window.identifier == tinyBuddyHUDWindowIdentifier,
       isTargetSize,
       isSemanticallyVisible {
        tinyBuddyHUDLogger.notice(
            "HUD ready identifier=TinyBuddy.HUDWindow width=284 height=520"
        )
        return
    }

    guard remainingAttempts > 0 else {
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        publishTinyBuddyHUDReadyWhenVisible(
            window,
            remainingAttempts: remainingAttempts - 1
        )
    }
}

@main
struct TinyBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            PetView(viewModel: appDelegate.petViewModel)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            GitScanRootSettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let onboardingStore = TinyBuddyOnboardingStore()
    private let gitScanRootAuthorizationStore = GitScanRootAuthorizationStore()
    private let notificationCenter = NotificationCenter.default
    private let timeEnvironment = TinyBuddyTimeEnvironment()
    private var authorizationCommandObservers: [NSObjectProtocol] = []
    private lazy var dailyStatsStore = DailyStatsStore(timeEnvironment: timeEnvironment)
    private lazy var activityStore = GitTodayActivityStore(timeEnvironment: timeEnvironment)
    private lazy var refreshStatusStore = GitActivityRefreshStatusStore(
        timeEnvironment: timeEnvironment
    )
    private lazy var combinedSnapshotStore = dailyStatsStore.makeCombinedSnapshotStore()
    lazy var petViewModel = PetViewModel(
        onboardingStore: onboardingStore,
        store: dailyStatsStore,
        activityStore: activityStore,
        combinedSnapshotStore: combinedSnapshotStore,
        refreshStatusStore: refreshStatusStore,
        notificationCenter: notificationCenter,
        timeEnvironment: timeEnvironment
    )
    private lazy var gitActivityRefreshCoordinator = GitActivityRefreshCoordinator(
        activityStore: activityStore,
        dailyStatsStore: dailyStatsStore,
        combinedSnapshotStore: combinedSnapshotStore,
        refreshStatusStore: refreshStatusStore,
        gitScanRootStore: gitScanRootAuthorizationStore,
        timeEnvironment: timeEnvironment,
        repositoryChangeMonitorFactory: { [gitScanRootAuthorizationStore] changeHandler in
            GitRepositoryChangeMonitor(
                authorizedRootsProvider: gitScanRootAuthorizationStore.accessAuthorizedRootResult,
                changeHandler: changeHandler
            )
        }
    )
    private lazy var powerStateMonitor = TinyBuddyPowerStateMonitor { [weak self] state in
        self?.gitActivityRefreshCoordinator.handlePowerStateChanged(state)
    }
    private lazy var hudVisibilityMonitor = HUDVisibilityMonitor(
        visibilityProvider: { [weak self] in
            self?.isHUDVisible ?? false
        }
    ) { [weak self] isVisible in
        self?.gitActivityRefreshCoordinator.handleInterfaceVisibilityChanged(
            isVisible: isVisible
        )
    }
    private lazy var timeEnvironmentChangeMonitor = TimeEnvironmentChangeMonitor<TinyBuddyTimeContext>(
        notificationCenter: notificationCenter,
        capture: { [timeEnvironment] in
            timeEnvironment.capture()
        }
    ) { [weak self] event in
        guard let self else {
            return
        }
        switch event {
        case .environmentChanged(let context):
            self.gitActivityRefreshCoordinator.handleTimeEnvironmentChanged(context)
        case .willSleep:
            self.gitActivityRefreshCoordinator.handleWillSleep()
        }
    }
    private lazy var gitScanRootAuthorizationController = GitScanRootAuthorizationController(
        store: gitScanRootAuthorizationStore,
        onboardingStore: onboardingStore
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HUDWindowPositionController.shared.start()
        registerAuthorizationCommandObservers()
        timeEnvironmentChangeMonitor.start()
        gitActivityRefreshCoordinator.start(
            isApplicationActive: NSApp.isActive,
            isInterfaceVisible: isHUDVisible,
            powerState: TinyBuddyPowerState.current()
        )
        powerStateMonitor.start()
        hudVisibilityMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        authorizationCommandObservers.forEach(notificationCenter.removeObserver)
        authorizationCommandObservers.removeAll()
        hudVisibilityMonitor.stop()
        powerStateMonitor.stop()
        timeEnvironmentChangeMonitor.stop()
        gitActivityRefreshCoordinator.stop()
        HUDWindowPositionController.shared.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        gitActivityRefreshCoordinator.handleDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        gitActivityRefreshCoordinator.handleDidResignActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if gitScanRootAuthorizationStore.hasAuthorizedRoots {
            gitActivityRefreshCoordinator.handleReopen()
        } else {
            handleAuthorizationRequest(
                didChange: gitScanRootAuthorizationController.requestAuthorization()
            )
        }
        restoreHUDWindow(from: sender)
        return true
    }

    private func registerAuthorizationCommandObservers() {
        guard authorizationCommandObservers.isEmpty else {
            return
        }

        authorizationCommandObservers = [
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRequested) { [weak self] _ in
                self?.handleAuthorizationRequest(
                    didChange: self?.gitScanRootAuthorizationController.requestAuthorization() ?? false
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationAddRequested) { [weak self] _ in
                self?.handleAuthorizationRequest(
                    didChange: self?.gitScanRootAuthorizationController.requestAuthorization() ?? false
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRepairRequested) { [weak self] _ in
                self?.handleAuthorizationRequest(
                    didChange: self?.gitScanRootAuthorizationController.requestReauthorizationForFirstUnavailableRoot() ?? false
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationReauthorizationRequested) { [weak self] notification in
                guard let identifier = notification.userInfo?[GitScanRootAuthorizationCommand.authorizationIdentifierKey] as? String else {
                    return
                }
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.requestReauthorization(for: identifier) ?? false
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRemovalRequested) { [weak self] notification in
                guard let identifier = notification.userInfo?[GitScanRootAuthorizationCommand.authorizationIdentifierKey] as? String else {
                    return
                }
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.removeAuthorization(id: identifier) ?? false
                )
            },
            observeAuthorizationCommand(named: .gitScanRootAuthorizationRemoveAllRequested) { [weak self] _ in
                self?.handleAuthorizationChange(
                    didChange: self?.gitScanRootAuthorizationController.removeAllAuthorizations() ?? false
                )
            },
            observeAuthorizationCommand(named: .gitActivityRefreshRequested) { [weak self] _ in
                self?.gitActivityRefreshCoordinator.handleManualRefresh()
            }
        ]
    }

    private func observeAuthorizationCommand(
        named name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { notification in
            Task { @MainActor in
                handler(notification)
            }
        }
    }

    private func handleAuthorizationChange(didChange: Bool) {
        guard didChange else {
            return
        }

        notificationCenter.post(name: .gitScanRootAuthorizationsDidChange, object: nil)
        gitActivityRefreshCoordinator.handleAuthorizationChanged()
        restoreHUDWindow(from: NSApp)
    }

    private func handleAuthorizationRequest(didChange: Bool) {
        notificationCenter.post(name: .gitScanRootAuthorizationsDidChange, object: nil)
        guard didChange else {
            return
        }
        gitActivityRefreshCoordinator.handleAuthorizationChanged()
        restoreHUDWindow(from: NSApp)
    }

    private func restoreHUDWindow(from application: NSApplication, shouldPresent: Bool = true) {
        guard let window = application.windows.first(where: {
            $0.identifier == tinyBuddyHUDWindowIdentifier
        }) else {
            return
        }

        if shouldPresent, window.isMiniaturized {
            window.deminiaturize(nil)
        }

        HUDWindowPositionController.shared.prepare(window: window)
        guard shouldPresent else {
            return
        }

        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        publishTinyBuddyHUDReadyWhenVisible(window)
        notificationCenter.post(name: .tinyBuddyHUDWindowDidConfigure, object: window)
    }

    private var isHUDVisible: Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier == tinyBuddyHUDWindowIdentifier
        }) else {
            return false
        }

        return window.isVisible
            && !window.isMiniaturized
            && window.screen != nil
            && window.alphaValue > 0
    }
}

struct WindowConfigurator: NSViewRepresentable {
    private let fixedWidth: CGFloat = 284
    private let fixedHeight: CGFloat = 520

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }

        let isFirstConfiguration = window.identifier != tinyBuddyHUDWindowIdentifier
        window.title = "TinyBuddy"
        window.identifier = tinyBuddyHUDWindowIdentifier
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView?.layoutSubtreeIfNeeded()

        let targetSize = NSSize(width: fixedWidth, height: fixedHeight)

        if window.contentLayoutRect.size != targetSize {
            window.setContentSize(targetSize)
        }

        window.minSize = targetSize
        window.maxSize = targetSize
        window.standardWindowButton(.zoomButton)?.isHidden = true
        HUDWindowPositionController.shared.attach(to: window)
        NotificationCenter.default.post(
            name: .tinyBuddyHUDWindowDidConfigure,
            object: window
        )
        if isFirstConfiguration {
            publishTinyBuddyHUDReadyWhenVisible(window)
        }
    }
}
