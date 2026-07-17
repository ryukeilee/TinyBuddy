import AppKit
import SwiftUI
import WidgetKit

private let tinyBuddyHUDWindowIdentifier = NSUserInterfaceItemIdentifier("TinyBuddy.HUDWindow")

@main
struct TinyBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            PetView()
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
    private var authorizationCommandObservers: [NSObjectProtocol] = []
    private lazy var gitActivityRefreshCoordinator = GitActivityRefreshCoordinator(
        gitScanRootStore: gitScanRootAuthorizationStore
    )
    private lazy var gitScanRootAuthorizationController = GitScanRootAuthorizationController(
        store: gitScanRootAuthorizationStore,
        onboardingStore: onboardingStore
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HUDWindowPositionController.shared.start()
        registerAuthorizationCommandObservers()
        gitActivityRefreshCoordinator.start(isApplicationActive: NSApp.isActive)
    }

    func applicationWillTerminate(_ notification: Notification) {
        authorizationCommandObservers.forEach(notificationCenter.removeObserver)
        authorizationCommandObservers.removeAll()
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
    }
}
