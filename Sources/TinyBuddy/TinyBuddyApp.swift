import AppKit
import SwiftUI
import WidgetKit

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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let gitScanRootAuthorizationStore = GitScanRootAuthorizationStore()
    private let notificationCenter = NotificationCenter.default
    private lazy var gitActivityRefreshCoordinator = GitActivityRefreshCoordinator(
        gitScanRootStore: gitScanRootAuthorizationStore
    )
    private lazy var gitScanRootAuthorizationController = GitScanRootAuthorizationController(
        store: gitScanRootAuthorizationStore
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notificationCenter.addObserver(
            self,
            selector: #selector(handleGitScanRootAuthorizationRequest),
            name: .gitScanRootAuthorizationRequested,
            object: nil
        )
        gitScanRootAuthorizationController.requestAuthorizationIfNeeded()
        gitActivityRefreshCoordinator.start(isApplicationActive: NSApp.isActive)
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        gitScanRootAuthorizationController.requestAuthorizationIfNeeded()
        gitActivityRefreshCoordinator.handleReopen()
        if flag == false {
            restoreHUDWindow(from: sender)
        }
        return true
    }

    @objc
    private func handleGitScanRootAuthorizationRequest() {
        gitScanRootAuthorizationController.requestAuthorization()
        gitActivityRefreshCoordinator.handleAuthorizationChanged()
        restoreHUDWindow(from: NSApp)
    }

    private func restoreHUDWindow(from application: NSApplication) {
        guard let window = application.windows.first(where: { $0.canBecomeKey && $0.contentViewController != nil }) else {
            return
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
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
    }
}
