import AppKit
import Foundation

/// Coalesces system time-environment notifications into one invalidation per
/// main-queue turn. The generic context keeps the monitor independent from the
/// persistence and refresh layers; production code supplies
/// `TinyBuddyTimeEnvironment.capture` as `capture`.
@MainActor
final class TimeEnvironmentChangeMonitor<Context> {
    enum Event {
        case environmentChanged(Context)
        case willSleep
    }

    typealias ContextProvider = () -> Context?
    typealias EventHandler = (Event) -> Void
    typealias Scheduler = (@escaping @MainActor () -> Void) -> Void

    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let contextProvider: ContextProvider
    private let eventHandler: EventHandler
    private let scheduler: Scheduler
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var isEnvironmentEmissionScheduled = false
    private var isStarted = false
    private var lifecycleGeneration = 0

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        capture: @escaping ContextProvider,
        scheduler: @escaping Scheduler = TimeEnvironmentChangeMonitor.scheduleOnMainQueue(_:),
        eventHandler: @escaping EventHandler
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.contextProvider = capture
        self.scheduler = scheduler
        self.eventHandler = eventHandler
    }

    deinit {
        notificationObservers.forEach(notificationCenter.removeObserver)
        workspaceNotificationObservers.forEach(workspaceNotificationCenter.removeObserver)
    }

    var observerCount: Int {
        notificationObservers.count + workspaceNotificationObservers.count
    }

    func start() {
        guard !isStarted else {
            return
        }

        lifecycleGeneration &+= 1
        isStarted = true
        notificationObservers = [
            observeEnvironmentChange(.NSSystemClockDidChange),
            observeEnvironmentChange(.NSSystemTimeZoneDidChange),
            observeEnvironmentChange(.NSCalendarDayChanged),
            observeEnvironmentChange(NSLocale.currentLocaleDidChangeNotification)
        ]
        workspaceNotificationObservers = [
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWillSleep()
                }
            }
        ]
    }

    func stop() {
        guard isStarted || observerCount > 0 else {
            return
        }

        lifecycleGeneration &+= 1
        isStarted = false
        isEnvironmentEmissionScheduled = false
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.removeAll()
        workspaceNotificationObservers.forEach(workspaceNotificationCenter.removeObserver)
        workspaceNotificationObservers.removeAll()
    }

    private func observeEnvironmentChange(_ name: Notification.Name) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleEnvironmentEmission()
            }
        }
    }

    private func scheduleEnvironmentEmission() {
        guard isStarted, !isEnvironmentEmissionScheduled else {
            return
        }

        isEnvironmentEmissionScheduled = true
        let scheduledGeneration = lifecycleGeneration
        scheduler { [weak self] in
            guard let self,
                  self.isStarted,
                  self.lifecycleGeneration == scheduledGeneration else {
                return
            }

            self.isEnvironmentEmissionScheduled = false
            guard let context = self.contextProvider() else {
                return
            }
            self.eventHandler(.environmentChanged(context))
        }
    }

    private func handleWillSleep() {
        guard isStarted else {
            return
        }

        eventHandler(.willSleep)
    }

    private nonisolated static func scheduleOnMainQueue(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}
