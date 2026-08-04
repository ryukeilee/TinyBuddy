import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class TinyBuddyLoginItemManagerTests: XCTestCase {
    private enum TestError: Error {
        case denied
    }

    /// Stateful fake: register/unregister mutate the status so the manager's
    /// refresh path observes real transitions. No test touches SMAppService.
    private final class FakeLoginItemState {
        var status: TinyBuddyLoginItemManager.Status
        var registerCallCount = 0
        var unregisterCallCount = 0
        var registerError: TestError?
        var unregisterError: TestError?

        init(status: TinyBuddyLoginItemManager.Status = .notRegistered) {
            self.status = status
        }

        func register() throws {
            registerCallCount += 1
            if let registerError { throw registerError }
            status = .enabled
        }

        func unregister() throws {
            unregisterCallCount += 1
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    @MainActor
    private func makeManager(
        status: TinyBuddyLoginItemManager.Status = .notRegistered,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> (TinyBuddyLoginItemManager, FakeLoginItemState) {
        let state = FakeLoginItemState(status: status)
        let manager = TinyBuddyLoginItemManager(
            statusProvider: { state.status },
            register: { try state.register() },
            unregister: { try state.unregister() },
            notificationCenter: notificationCenter
        )
        return (manager, state)
    }

    // MARK: - Idempotency

    @MainActor
    func testSetEnabledTrueWhenAlreadyEnabledIsNoOp() throws {
        let (manager, state) = makeManager(status: .enabled)
        try manager.setEnabled(true)
        XCTAssertEqual(state.registerCallCount, 0)
        XCTAssertEqual(manager.cachedStatus, .enabled)
        XCTAssertTrue(manager.isEnabled)
    }

    @MainActor
    func testSetEnabledFalseWhenNotRegisteredIsNoOp() throws {
        let (manager, state) = makeManager(status: .notRegistered)
        try manager.setEnabled(false)
        XCTAssertEqual(state.unregisterCallCount, 0)
        XCTAssertEqual(manager.cachedStatus, .notRegistered)
    }

    @MainActor
    func testSetEnabledFalseWhenNotFoundIsNoOp() throws {
        let (manager, state) = makeManager(status: .notFound)
        try manager.setEnabled(false)
        XCTAssertEqual(state.unregisterCallCount, 0)
        XCTAssertEqual(manager.cachedStatus, .notFound)
    }

    // MARK: - Transitions

    @MainActor
    func testSetEnabledTrueRegistersAndRefreshesCachedStatus() throws {
        let (manager, state) = makeManager(status: .notRegistered)
        try manager.setEnabled(true)
        XCTAssertEqual(state.registerCallCount, 1)
        XCTAssertEqual(state.unregisterCallCount, 0)
        XCTAssertEqual(manager.cachedStatus, .enabled)
        XCTAssertTrue(manager.isEnabled)
    }

    @MainActor
    func testSetEnabledFalseUnregistersAndRefreshesCachedStatus() throws {
        let (manager, state) = makeManager(status: .enabled)
        try manager.setEnabled(false)
        XCTAssertEqual(state.unregisterCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .notRegistered)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testSetEnabledTrueFromRequiresApprovalAttemptsRegistration() throws {
        let (manager, state) = makeManager(status: .requiresApproval)
        try manager.setEnabled(true)
        XCTAssertEqual(state.registerCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .enabled)
    }

    @MainActor
    func testSetEnabledFalseFromRequiresApprovalAttemptsRemoval() throws {
        let (manager, state) = makeManager(status: .requiresApproval)
        try manager.setEnabled(false)
        XCTAssertEqual(state.unregisterCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .notRegistered)
    }

    // MARK: - Typed errors

    @MainActor
    func testRegisterFailureThrowsTypedError() {
        let (manager, state) = makeManager(status: .notRegistered)
        state.registerError = .denied
        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            XCTAssertEqual(error as? TinyBuddyLoginItemError, .registrationFailed)
        }
        XCTAssertEqual(state.registerCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .notRegistered)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testUnregisterFailureThrowsTypedError() {
        let (manager, state) = makeManager(status: .enabled)
        state.unregisterError = .denied
        XCTAssertThrowsError(try manager.setEnabled(false)) { error in
            XCTAssertEqual(error as? TinyBuddyLoginItemError, .unregistrationFailed)
        }
        XCTAssertEqual(state.unregisterCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .enabled)
    }

    // MARK: - Bounded recovery

    @MainActor
    func testRecoveryRepairsNotFoundWhenIntentEnabled() throws {
        let (manager, state) = makeManager(status: .notFound)
        try manager.recoverIfNeeded(intentEnabled: true)
        XCTAssertEqual(state.unregisterCallCount, 1)
        XCTAssertEqual(state.registerCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .enabled)
    }

    @MainActor
    func testRecoveryRepairsErrorWhenIntentEnabled() throws {
        let (manager, state) = makeManager(status: .error)
        try manager.recoverIfNeeded(intentEnabled: true)
        XCTAssertEqual(state.unregisterCallCount, 1)
        XCTAssertEqual(state.registerCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .enabled)
    }

    @MainActor
    func testRecoverySkipsHealthyStates() throws {
        // Intent enabled with a healthy or approval-pending state: no calls.
        for status in [TinyBuddyLoginItemManager.Status.enabled, .notRegistered, .requiresApproval] {
            let (manager, state) = makeManager(status: status)
            try manager.recoverIfNeeded(intentEnabled: true)
            XCTAssertEqual(state.registerCallCount, 0, "status=\(status)")
            XCTAssertEqual(state.unregisterCallCount, 0, "status=\(status)")
        }
        // Intent disabled with stale states: no calls.
        for status in [TinyBuddyLoginItemManager.Status.notFound, .error] {
            let (manager, state) = makeManager(status: status)
            try manager.recoverIfNeeded(intentEnabled: false)
            XCTAssertEqual(state.registerCallCount, 0, "status=\(status)")
            XCTAssertEqual(state.unregisterCallCount, 0, "status=\(status)")
        }
    }

    @MainActor
    func testRecoveryFailureThrowsWithoutRetry() {
        let (manager, state) = makeManager(status: .notFound)
        state.registerError = .denied
        XCTAssertThrowsError(try manager.recoverIfNeeded(intentEnabled: true)) { error in
            XCTAssertEqual(error as? TinyBuddyLoginItemError, .registrationFailed)
        }
        XCTAssertEqual(state.unregisterCallCount, 1)
        XCTAssertEqual(state.registerCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .notFound)
    }

    @MainActor
    func testRecoveryIgnoresFailedStaleCleanup() throws {
        let (manager, state) = makeManager(status: .error)
        state.unregisterError = .denied
        try manager.recoverIfNeeded(intentEnabled: true)
        XCTAssertEqual(state.unregisterCallCount, 1)
        XCTAssertEqual(state.registerCallCount, 1)
        XCTAssertEqual(manager.cachedStatus, .enabled)
    }

    // MARK: - Refresh broadcasting

    @MainActor
    func testRefreshStatusBroadcastsOnlyOnChange() {
        let center = NotificationCenter()
        let (manager, state) = makeManager(status: .enabled, notificationCenter: center)
        var broadcastCount = 0
        var broadcastObjects: [TinyBuddyLoginItemManager] = []
        let observer = center.addObserver(
            forName: .tinyBuddyLoginItemStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            broadcastCount += 1
            if let object = notification.object as? TinyBuddyLoginItemManager {
                broadcastObjects.append(object)
            }
        }
        defer { center.removeObserver(observer) }

        XCTAssertEqual(manager.refreshStatus(), .enabled)
        XCTAssertEqual(broadcastCount, 0)

        state.status = .notRegistered
        XCTAssertEqual(manager.refreshStatus(), .notRegistered)
        XCTAssertEqual(broadcastCount, 1)
        XCTAssertEqual(broadcastObjects.map(\.cachedStatus), [.notRegistered])
        XCTAssertTrue(broadcastObjects.allSatisfy { $0 === manager })

        XCTAssertEqual(manager.refreshStatus(), .notRegistered)
        XCTAssertEqual(broadcastCount, 1)
    }

    // MARK: - Unbundled process

    @MainActor
    func testSharedInstanceIsNotEnabledOutsideAppBundle() {
        // A test runner has no app bundle; the cached status must read as
        // non-enabled and the access must not crash or hit register/unregister.
        XCTAssertEqual(TinyBuddyLoginItemManager.shared.isEnabled, false)
    }
}

@MainActor
final class GitScanRootSettingsViewModelLoginItemTests: XCTestCase {
    private enum TestError: Error {
        case denied
    }

    private final class FakeLoginItemState {
        var status: TinyBuddyLoginItemManager.Status
        var registerError: TestError?
        var registerResultStatus: TinyBuddyLoginItemManager.Status = .enabled

        init(status: TinyBuddyLoginItemManager.Status = .notRegistered) {
            self.status = status
        }

        func register() throws {
            if let registerError { throw registerError }
            status = registerResultStatus
        }

        func unregister() {
            status = .notRegistered
        }
    }

    @MainActor
    private func makeContext(
        status: TinyBuddyLoginItemManager.Status = .notRegistered
    ) -> (GitScanRootSettingsViewModel, FakeLoginItemState, NotificationCenter) {
        let center = NotificationCenter()
        let state = FakeLoginItemState(status: status)
        let manager = TinyBuddyLoginItemManager(
            statusProvider: { state.status },
            register: { try state.register() },
            unregister: { state.unregister() },
            notificationCenter: center
        )
        let suiteName = "TinyBuddyLoginItemViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                guard let path = String(data: data, encoding: .utf8) else { return nil }
                return ResolvedScopedGitScanRoot(
                    root: ScopedGitScanRoot(url: URL(fileURLWithPath: path)),
                    bookmarkDataIsStale: false
                )
            },
            rootUsabilityChecker: { _ in nil }
        )
        let configStorage = InMemoryLoginItemConfigStorage()
        let configStore = TinyBuddyConfigStore(
            directPreferencesProvider: { configStorage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                configStorage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        let viewModel = GitScanRootSettingsViewModel(
            store: store,
            configStore: configStore,
            loginItemManager: manager,
            notificationCenter: center
        )
        return (viewModel, state, center)
    }

    func testSetLaunchAtLoginSuccessPostsChangeRequest() {
        let (viewModel, _, center) = makeContext(status: .notRegistered)
        var receivedEnabled: [Bool] = []
        let observer = center.addObserver(
            forName: .tinyBuddyLaunchAtLoginChangeRequested,
            object: nil,
            queue: nil
        ) { notification in
            receivedEnabled.append(
                notification.userInfo?[TinyBuddyLoginItemCommand.enabledKey] as? Bool ?? false
            )
        }
        defer { center.removeObserver(observer) }

        viewModel.setLaunchAtLogin(true)

        XCTAssertEqual(receivedEnabled, [true])
        XCTAssertEqual(viewModel.launchAtLoginEnabled, true)
        XCTAssertNil(viewModel.loginItemErrorMessage)
    }

    func testSetLaunchAtLoginFailurePublishesChineseErrorAndRollsBack() {
        let (viewModel, state, center) = makeContext(status: .notRegistered)
        state.registerError = .denied
        var postCount = 0
        let observer = center.addObserver(
            forName: .tinyBuddyLaunchAtLoginChangeRequested,
            object: nil,
            queue: nil
        ) { _ in
            postCount += 1
        }
        defer { center.removeObserver(observer) }

        viewModel.setLaunchAtLogin(true)

        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(viewModel.launchAtLoginEnabled, false)
        XCTAssertEqual(viewModel.loginItemErrorMessage, "无法更改登录启动项，请稍后重试。")
    }

    func testSetLaunchAtLoginRequiresApprovalPublishesGuidance() {
        let (viewModel, state, _) = makeContext(status: .requiresApproval)
        // Registration succeeds but the system keeps approval pending.
        state.registerResultStatus = .requiresApproval

        viewModel.setLaunchAtLogin(true)

        XCTAssertEqual(viewModel.launchAtLoginEnabled, false)
        XCTAssertEqual(
            viewModel.loginItemErrorMessage,
            "已请求启用登录启动项，请在「系统设置 › 通用 › 登录项」中批准。"
        )
    }

    func testStatusNotificationRefreshesToggleState() async {
        let (viewModel, state, center) = makeContext(status: .enabled)
        XCTAssertEqual(viewModel.launchAtLoginEnabled, true)

        // Simulate the system removing the login item while the app runs.
        state.status = .notRegistered
        center.post(name: .tinyBuddyLoginItemStatusDidChange, object: nil)
        await Task.yield()

        XCTAssertEqual(viewModel.launchAtLoginEnabled, false)
    }
}

private final class InMemoryLoginItemConfigStorage: @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Any] = [:]
}
