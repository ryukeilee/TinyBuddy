import Foundation
import ServiceManagement

extension Notification.Name {
    /// Broadcast whenever the cached login-item status changes. The object is
    /// the `TinyBuddyLoginItemManager` that refreshed its state. SMAppService
    /// exposes no change notifications, so status is refreshed at explicit
    /// points (launch, applicationDidBecomeActive, settings view onAppear).
    static let tinyBuddyLoginItemStatusDidChange = Notification.Name(
        "TinyBuddy.loginItemStatusDidChange"
    )
}

/// Typed errors surfaced to the settings UI so it can present Chinese copy
/// instead of swallowing raw SMAppService failures.
enum TinyBuddyLoginItemError: Error, LocalizedError, Equatable {
    case registrationFailed
    case unregistrationFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            "无法启用登录启动项，请稍后重试。"
        case .unregistrationFailed:
            "无法关闭登录启动项，请稍后重试。"
        }
    }
}

/// Observable source of truth for the "launch at login" SMAppService state.
/// The status is cached, refreshed on demand, and every refresh broadcasts a
/// typed status change so the UI never derives its toggle from a stale query.
@MainActor
final class TinyBuddyLoginItemManager {
    /// Mirrors `SMAppService.Status`; `.error` also covers unknown future
    /// statuses so the mapping stays total.
    enum Status: Equatable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
        case error
    }

    typealias StatusProvider = () -> Status
    typealias RegistrationHandler = () throws -> Void

    static let shared = TinyBuddyLoginItemManager()

    private let statusProvider: StatusProvider
    private let registerHandler: RegistrationHandler
    private let unregisterHandler: RegistrationHandler
    private let notificationCenter: NotificationCenter

    private(set) var cachedStatus: Status

    init(
        statusProvider: @escaping StatusProvider = {
            // The class is @MainActor, so every call to statusProvider() happens
            // on the main actor; the default closure is evaluated at the (nonisolated)
            // call site, so assert that isolation before querying SMAppService.
            MainActor.assumeIsolated {
                TinyBuddyLoginItemManager.productionStatus()
            }
        },
        register: @escaping RegistrationHandler = { try SMAppService.mainApp.register() },
        unregister: @escaping RegistrationHandler = { try SMAppService.mainApp.unregister() },
        notificationCenter: NotificationCenter = .default
    ) {
        self.statusProvider = statusProvider
        self.registerHandler = register
        self.unregisterHandler = unregister
        self.notificationCenter = notificationCenter
        self.cachedStatus = statusProvider()
    }

    /// The cached enabled state. Never queries SMAppService on access, so an
    /// unbundled process (tests, helpers) safely reads `false`.
    var isEnabled: Bool {
        cachedStatus == .enabled
    }

    /// Re-queries the provider and broadcasts `.tinyBuddyLoginItemStatusDidChange`
    /// only when the cached status actually changed.
    @discardableResult
    func refreshStatus() -> Status {
        let fresh = statusProvider()
        guard fresh != cachedStatus else {
            return fresh
        }
        cachedStatus = fresh
        notificationCenter.post(
            name: .tinyBuddyLoginItemStatusDidChange,
            object: self
        )
        return fresh
    }

    /// Idempotently brings the login item to the requested state. A target
    /// state that is already reached is a successful no-op; a failed
    /// registration/removal throws a typed error.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard cachedStatus != .enabled else { return }
            do {
                try registerHandler()
            } catch {
                throw TinyBuddyLoginItemError.registrationFailed
            }
        } else {
            guard cachedStatus != .notRegistered, cachedStatus != .notFound else { return }
            do {
                try unregisterHandler()
            } catch {
                throw TinyBuddyLoginItemError.unregistrationFailed
            }
        }
        refreshStatus()
    }

    /// Bounded repair for stale registrations (upgrade, reinstall, or app path
    /// replacement): only when the intent is enabled and the system reports
    /// `.notFound` or `.error`. A healthy state is never touched and
    /// `.requiresApproval` never loops automatically. Single-shot; a failure
    /// throws a typed error without retrying.
    func recoverIfNeeded(intentEnabled: Bool) throws {
        guard intentEnabled,
              cachedStatus == .notFound || cachedStatus == .error else {
            return
        }
        // A stale registration left behind by a replaced installation can make
        // register() fail; clearing it first keeps the repair bounded. A
        // failing cleanup is logged and ignored, never fatal.
        try? unregisterHandler()
        do {
            try registerHandler()
        } catch {
            throw TinyBuddyLoginItemError.registrationFailed
        }
        refreshStatus()
    }

    private static func productionStatus() -> Status {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .error
        }
    }
}
