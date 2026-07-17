import AppKit
import Foundation
import IOKit.ps

extension Notification.Name {
    static let tinyBuddyHUDWindowDidConfigure = Notification.Name(
        "TinyBuddy.hudWindowDidConfigure"
    )
}

struct TinyBuddyPowerState: Equatable, Sendable {
    let isOnBatteryPower: Bool
    let isLowPowerModeEnabled: Bool

    static func current(processInfo: ProcessInfo = .processInfo) -> TinyBuddyPowerState {
        TinyBuddyPowerState(
            isOnBatteryPower: currentPowerSourceIsBattery(),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
    }

    private static func currentPowerSourceIsBattery() -> Bool {
        let powerSourcesInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let sourceType = IOPSGetProvidingPowerSourceType(powerSourcesInfo)?
            .takeUnretainedValue() else {
            return false
        }

        return sourceType as String == kIOPSBatteryPowerValue
    }
}

/// Coalesces low-power notifications before publishing one semantic power-state
/// change. AC/battery state is sampled on the app's existing lifecycle and
/// refresh wakes; keeping an IOPS notification run-loop source alive causes a
/// large number of otherwise avoidable interrupt wakeups on macOS.
@MainActor
final class TinyBuddyPowerStateMonitor {
    typealias StateProvider = () -> TinyBuddyPowerState
    typealias EventHandler = (TinyBuddyPowerState) -> Void
    typealias Scheduler = (@escaping @MainActor () -> Void) -> Void

    private let notificationCenter: NotificationCenter
    private let stateProvider: StateProvider
    private let eventHandler: EventHandler
    private let scheduler: Scheduler
    private var powerStateObserver: NSObjectProtocol?
    private var lastPublishedState: TinyBuddyPowerState?
    private var isEmissionScheduled = false
    private var isStarted = false
    private var lifecycleGeneration = 0

    init(
        notificationCenter: NotificationCenter = .default,
        stateProvider: @escaping StateProvider = { TinyBuddyPowerState.current() },
        scheduler: @escaping Scheduler = TinyBuddyPowerStateMonitor.scheduleOnMainQueue(_:),
        eventHandler: @escaping EventHandler
    ) {
        self.notificationCenter = notificationCenter
        self.stateProvider = stateProvider
        self.scheduler = scheduler
        self.eventHandler = eventHandler
    }

    deinit {
        if let powerStateObserver {
            notificationCenter.removeObserver(powerStateObserver)
        }
    }

    var observerCount: Int {
        powerStateObserver == nil ? 0 : 1
    }

    func start() {
        guard !isStarted else {
            return
        }

        lifecycleGeneration &+= 1
        isStarted = true
        powerStateObserver = notificationCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleEmission()
            }
        }

        publishCurrentState(force: true)
    }

    func stop() {
        guard isStarted || observerCount > 0 else {
            return
        }

        lifecycleGeneration &+= 1
        isStarted = false
        isEmissionScheduled = false
        if let powerStateObserver {
            notificationCenter.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
    }

    private func scheduleEmission() {
        guard isStarted, !isEmissionScheduled else {
            return
        }

        isEmissionScheduled = true
        let scheduledGeneration = lifecycleGeneration
        scheduler { [weak self] in
            guard let self,
                  self.isStarted,
                  self.lifecycleGeneration == scheduledGeneration else {
                return
            }
            self.isEmissionScheduled = false
            self.publishCurrentState()
        }
    }

    private func publishCurrentState(force: Bool = false) {
        let state = stateProvider()
        guard force || state != lastPublishedState else {
            return
        }

        lastPublishedState = state
        eventHandler(state)
    }

    private nonisolated static func scheduleOnMainQueue(
        _ action: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}

/// Converts the several NSWindow signals produced by one visibility transition
/// into a single boolean update. It intentionally observes all app windows and
/// lets the injected provider select the TinyBuddy HUD; unrelated notifications
/// therefore cannot cause a refresh unless the HUD's semantic visibility changed.
@MainActor
final class HUDVisibilityMonitor {
    typealias VisibilityProvider = () -> Bool
    typealias EventHandler = (Bool) -> Void
    typealias Scheduler = (@escaping @MainActor () -> Void) -> Void

    private let notificationCenter: NotificationCenter
    private let visibilityProvider: VisibilityProvider
    private let eventHandler: EventHandler
    private let scheduler: Scheduler
    private var observers: [NSObjectProtocol] = []
    private var lastPublishedVisibility: Bool?
    private var isEmissionScheduled = false
    private var isStarted = false
    private var lifecycleGeneration = 0

    init(
        notificationCenter: NotificationCenter = .default,
        visibilityProvider: @escaping VisibilityProvider,
        scheduler: @escaping Scheduler = HUDVisibilityMonitor.scheduleOnMainQueue(_:),
        eventHandler: @escaping EventHandler
    ) {
        self.notificationCenter = notificationCenter
        self.visibilityProvider = visibilityProvider
        self.scheduler = scheduler
        self.eventHandler = eventHandler
    }

    deinit {
        observers.forEach(notificationCenter.removeObserver)
    }

    var observerCount: Int {
        observers.count
    }

    func start() {
        guard !isStarted else {
            return
        }

        lifecycleGeneration &+= 1
        isStarted = true
        observers = [
            .tinyBuddyHUDWindowDidConfigure,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ].map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleEmission()
                }
            }
        }

        publishCurrentVisibility(force: true)
    }

    func stop() {
        guard isStarted || !observers.isEmpty else {
            return
        }

        lifecycleGeneration &+= 1
        isStarted = false
        isEmissionScheduled = false
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
    }

    private func scheduleEmission() {
        guard isStarted, !isEmissionScheduled else {
            return
        }

        isEmissionScheduled = true
        let scheduledGeneration = lifecycleGeneration
        scheduler { [weak self] in
            guard let self,
                  self.isStarted,
                  self.lifecycleGeneration == scheduledGeneration else {
                return
            }
            self.isEmissionScheduled = false
            self.publishCurrentVisibility()
        }
    }

    private func publishCurrentVisibility(force: Bool = false) {
        let isVisible = visibilityProvider()
        guard force || isVisible != lastPublishedVisibility else {
            return
        }

        lastPublishedVisibility = isVisible
        eventHandler(isVisible)
    }

    private nonisolated static func scheduleOnMainQueue(
        _ action: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}
