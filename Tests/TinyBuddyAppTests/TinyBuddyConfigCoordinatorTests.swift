import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class TinyBuddyConfigCoordinatorTests: XCTestCase {
    private let dayID = "2026-07-20"

    private enum TestError: Error {
        case denied
    }

    /// Stateful fake login-item provider: register/unregister mutate the
    /// status so the manager's refresh path observes real transitions. No
    /// test ever calls the real SMAppService register/unregister.
    private final class FakeLoginItemState {
        var status: TinyBuddyLoginItemManager.Status
        var registerCallCount = 0
        var unregisterCallCount = 0
        var registerError: TestError?

        init(status: TinyBuddyLoginItemManager.Status = .notRegistered) {
            self.status = status
        }

        func register() throws {
            registerCallCount += 1
            if let registerError { throw registerError }
            status = .enabled
        }

        func unregister() {
            unregisterCallCount += 1
            status = .notRegistered
        }
    }

    @MainActor
    private func makeLoginItemManager(state: FakeLoginItemState) -> TinyBuddyLoginItemManager {
        TinyBuddyLoginItemManager(
            statusProvider: { state.status },
            register: { try state.register() },
            unregister: { state.unregister() },
            notificationCenter: NotificationCenter()
        )
    }

    @MainActor
    private func makeStore(storage: InMemoryConfigStorage) -> TinyBuddyConfigStore {
        TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
    }

    @MainActor
    func testStartLoadsPersistedConfig() {
        let (coordinator, storage, _, _) = makeCoordinator()
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/Users/test/Code"],
            dayIdentifier: dayID
        )
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        XCTAssertEqual(store.save(config), .saved)

        coordinator.start()
        XCTAssertEqual(coordinator.currentConfig(), config)
    }

    @MainActor
    func testReloadPersistedExclusionsRebuildsMonitoringAndPublishesConfig() {
        var rebuildCount = 0
        var rescheduleCount = 0
        let (coordinator, _, store, _) = makeCoordinator(
            rebuildClosure: { rebuildCount += 1 },
            rescheduleClosure: { rescheduleCount += 1 }
        )
        let initial = TinyBuddyAppConfig(configVersion: 1, dayIdentifier: dayID)
        XCTAssertEqual(store.save(initial), .saved)
        coordinator.start()
        let updated = initial.withIncrementedVersion(exclusionRules: [
            TinyBuddyExclusionRule(id: "private", pattern: "Teams/Private")
        ])
        XCTAssertEqual(store.save(updated), .saved)

        coordinator.reloadPersistedConfig()

        XCTAssertEqual(coordinator.currentConfig(), updated)
        XCTAssertEqual(rebuildCount, 1)
        XCTAssertEqual(rescheduleCount, 1)
    }

    @MainActor
    func testStartPreservesLastKnownPathsWhenAuthorizationIsTemporarilyUnavailable() {
        let storage = InMemoryConfigStorage()
        let configStore = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        let authorization = GitScanRootAuthorization(
            id: "offline-root",
            displayName: "Offline",
            lastKnownPath: "/Volumes/Offline/Code",
            state: .unavailable(.directoryUnavailable)
        )
        let coordinator = TinyBuddyConfigCoordinator(
            configStore: configStore,
            scanRootsProvider: {
                GitScanRootAccessResult(
                    roots: [],
                    issue: .authorizationInvalid,
                    authorizations: [authorization]
                )
            },
            loginItemManager: makeLoginItemManager(state: FakeLoginItemState())
        )

        coordinator.start()

        XCTAssertEqual(coordinator.currentConfig()?.scanRootPaths, ["/Volumes/Offline/Code"])
        XCTAssertEqual(coordinator.currentConfig()?.configVersion, 1)
    }

    @MainActor
    func testStartPublishesInitialConfigWhenNoPersistedConfig() {
        let (coordinator, _, _, _) = makeCoordinator()
        coordinator.start()
        XCTAssertNotNil(coordinator.currentConfig())
        XCTAssertEqual(coordinator.currentConfig()?.configVersion, 1)
    }

    @MainActor
    func testProposeScanRootsChangeTriggersRebuild() {
        var rebuildCallCount = 0
        var rescheduleCallCount = 0
        let (coordinator, storage, _, _) = makeCoordinator(
            rebuildClosure: { rebuildCallCount += 1 },
            rescheduleClosure: { rescheduleCallCount += 1 }
        )

        let config = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/initial/path"],
            dayIdentifier: dayID
        )
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        XCTAssertEqual(store.save(config), .saved)
        coordinator.start()

        let expectation = expectation(description: "coalesce")
        TinyBuddyTestConfigRootsProvider.currentRoots = ["/new/path"]
        coordinator.proposeScanRootsChange()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(rebuildCallCount, 1)
            XCTAssertEqual(coordinator.currentConfig()?.scanRootPaths, ["/new/path"])
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testProposeUnchangedRootsDoesNotTriggerRebuild() {
        var rebuildCallCount = 0
        let (coordinator, storage, _, _) = makeCoordinator(
            rebuildClosure: { rebuildCallCount += 1 }
        )

        let config = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/same/path"],
            dayIdentifier: dayID
        )
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        XCTAssertEqual(store.save(config), .saved)
        coordinator.start()

        TinyBuddyTestConfigRootsProvider.currentRoots = ["/same/path"]
        coordinator.proposeScanRootsChange()

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(rebuildCallCount, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testReconcilePersistedScanRootsUpdatesProjectionWithoutStartingAnotherRefresh() {
        var rebuildCallCount = 0
        var rescheduleCallCount = 0
        let (coordinator, _, store, _) = makeCoordinator(
            rebuildClosure: { rebuildCallCount += 1 },
            rescheduleClosure: { rescheduleCallCount += 1 }
        )
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/old/path"],
            dayIdentifier: dayID
        )
        XCTAssertEqual(store.save(config), .saved)
        coordinator.start()

        TinyBuddyTestConfigRootsProvider.currentRoots = ["/new/path"]
        coordinator.reconcilePersistedScanRoots()

        XCTAssertEqual(coordinator.currentConfig()?.scanRootPaths, ["/new/path"])
        XCTAssertEqual(coordinator.currentConfig()?.configVersion, 2)
        XCTAssertEqual(rebuildCallCount, 0)
        XCTAssertEqual(rescheduleCallCount, 0)
        XCTAssertEqual(store.load()?.scanRootPaths, ["/new/path"])
    }

    @MainActor
    func testProposeLaunchAtLoginChangeDrivesManagerAndPersistsIntent() throws {
        var rebuildCallCount = 0
        let loginItemState = FakeLoginItemState()
        let (coordinator, storage, _, _) = makeCoordinator(
            rebuildClosure: { rebuildCallCount += 1 },
            loginItemState: loginItemState
        )

        let config = TinyBuddyAppConfig(
            configVersion: 1,
            launchAtLoginEnabled: false,
            dayIdentifier: dayID
        )
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        XCTAssertEqual(store.save(config), .saved)
        coordinator.start()

        try coordinator.proposeLaunchAtLoginChange(true)
        XCTAssertEqual(loginItemState.registerCallCount, 1)
        XCTAssertEqual(loginItemState.unregisterCallCount, 0)

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, true)
            XCTAssertEqual(coordinator.currentConfig()?.configVersion, 2)
            XCTAssertEqual(rebuildCallCount, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testProposeLaunchAtLoginChangeSkipsWhenIntentAlreadyMatches() throws {
        let loginItemState = FakeLoginItemState()
        let (coordinator, storage, _, _) = makeCoordinator(loginItemState: loginItemState)
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            launchAtLoginEnabled: true,
            dayIdentifier: dayID
        )
        XCTAssertEqual(makeStore(storage: storage).save(config), .saved)
        coordinator.start()

        try coordinator.proposeLaunchAtLoginChange(true)

        XCTAssertEqual(loginItemState.registerCallCount, 0)
        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, true)
            XCTAssertEqual(coordinator.currentConfig()?.configVersion, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testProposeLaunchAtLoginChangeFailureDoesNotPersist() {
        let loginItemState = FakeLoginItemState()
        loginItemState.registerError = .denied
        let (coordinator, storage, _, _) = makeCoordinator(loginItemState: loginItemState)
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            launchAtLoginEnabled: false,
            dayIdentifier: dayID
        )
        XCTAssertEqual(makeStore(storage: storage).save(config), .saved)
        coordinator.start()

        XCTAssertThrowsError(try coordinator.proposeLaunchAtLoginChange(true)) { error in
            XCTAssertEqual(error as? TinyBuddyLoginItemError, .registrationFailed)
        }
        XCTAssertEqual(loginItemState.registerCallCount, 1)

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, false)
            XCTAssertEqual(coordinator.currentConfig()?.configVersion, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testBuildCurrentConfigSeedsLaunchAtLoginFromManagerWhenNoPersistedConfig() {
        let loginItemState = FakeLoginItemState(status: .enabled)
        let (coordinator, _, _, _) = makeCoordinator(loginItemState: loginItemState)
        coordinator.start()
        XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, true)
        XCTAssertEqual(coordinator.currentConfig()?.configVersion, 1)
    }

    @MainActor
    func testBuildCurrentConfigDoesNotClobberPersistedLaunchAtLoginWithLiveStatus() throws {
        let loginItemState = FakeLoginItemState(status: .notRegistered)
        let (coordinator, storage, _, _) = makeCoordinator(loginItemState: loginItemState)
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            launchAtLoginEnabled: true,
            dayIdentifier: dayID
        )
        XCTAssertEqual(makeStore(storage: storage).save(config), .saved)

        // Without start() the propose path falls back to buildCurrentConfig(),
        // which must keep the persisted intent instead of the live status.
        try coordinator.proposeHUDEnabledChange(false)

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, true)
            XCTAssertEqual(coordinator.currentConfig()?.hudEnabled, false)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testReconcileLaunchAtLoginIntentRewritesIntentFromActualState() {
        let loginItemState = FakeLoginItemState(status: .enabled)
        let (coordinator, storage, _, _) = makeCoordinator(loginItemState: loginItemState)
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            launchAtLoginEnabled: false,
            dayIdentifier: dayID
        )
        XCTAssertEqual(makeStore(storage: storage).save(config), .saved)
        coordinator.start()

        coordinator.reconcileLaunchAtLoginIntent()

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, true)
            XCTAssertEqual(coordinator.currentConfig()?.configVersion, 2)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testReconcileLaunchAtLoginIntentTurnsOffWhenSystemRemovedItem() {
        let loginItemState = FakeLoginItemState(status: .notRegistered)
        let (coordinator, storage, _, _) = makeCoordinator(loginItemState: loginItemState)
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            launchAtLoginEnabled: true,
            dayIdentifier: dayID
        )
        XCTAssertEqual(makeStore(storage: storage).save(config), .saved)
        coordinator.start()

        coordinator.reconcileLaunchAtLoginIntent()

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, false)
            XCTAssertEqual(coordinator.currentConfig()?.configVersion, 2)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testReconcileLaunchAtLoginIntentTreatsRequiresApprovalAsEnabledIntent() {
        let loginItemState = FakeLoginItemState(status: .requiresApproval)
        let (coordinator, storage, _, _) = makeCoordinator(loginItemState: loginItemState)
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            launchAtLoginEnabled: false,
            dayIdentifier: dayID
        )
        XCTAssertEqual(makeStore(storage: storage).save(config), .saved)
        coordinator.start()

        coordinator.reconcileLaunchAtLoginIntent()

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, true)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testReconcileLaunchAtLoginIntentSkipsAmbiguousStates() {
        for status in [TinyBuddyLoginItemManager.Status.notFound, .error] {
            let loginItemState = FakeLoginItemState(status: status)
            let (coordinator, storage, _, _) = makeCoordinator(loginItemState: loginItemState)
            let config = TinyBuddyAppConfig(
                configVersion: 1,
                launchAtLoginEnabled: true,
                dayIdentifier: dayID
            )
            XCTAssertEqual(makeStore(storage: storage).save(config), .saved)
            coordinator.start()

            coordinator.reconcileLaunchAtLoginIntent()

            let expectation = expectation(description: "coalesce")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertEqual(coordinator.currentConfig()?.launchAtLoginEnabled, true)
                XCTAssertEqual(coordinator.currentConfig()?.configVersion, 1)
                XCTAssertEqual(loginItemState.registerCallCount, 0)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    @MainActor
    func testRapidChangesCoalesce() {
        var rebuildCallCount = 0
        let (coordinator, storage, _, _) = makeCoordinator(
            rebuildClosure: { rebuildCallCount += 1 }
        )

        let config = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/initial/path"],
            dayIdentifier: dayID
        )
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        XCTAssertEqual(store.save(config), .saved)
        coordinator.start()

        coordinator.proposeScanRootsChange()
        coordinator.proposeScanRootsChange()
        coordinator.proposeScanRootsChange()

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(rebuildCallCount, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testConfigGenerationAdvancesOnPublish() {
        let (coordinator, storage, _, _) = makeCoordinator()

        let config = TinyBuddyAppConfig(
            configVersion: 1,
            dayIdentifier: dayID
        )
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        XCTAssertEqual(store.save(config), .saved)
        coordinator.start()

        let gen1 = coordinator.currentConfigGeneration

        coordinator.proposeHUDEnabledChange(false)

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let gen2 = coordinator.currentConfigGeneration
            XCTAssertGreaterThan(gen2, gen1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    @MainActor
    func testPersistenceFailureKeepsOldConfig() {
        var writeCallCount = 0
        let (coordinator, storage, _, _) = makeCoordinator()

        let config = TinyBuddyAppConfig(
            configVersion: 1,
            hudEnabled: true,
            dayIdentifier: dayID
        )
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                writeCallCount += 1
                if writeCallCount > 2 {
                    return false
                }
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        XCTAssertEqual(store.save(config), .saved)

        let coordinator2 = TinyBuddyConfigCoordinator(
            configStore: store,
            scanRootsProvider: { TinyBuddyTestConfigRootsProvider.result() },
            rebuildRepositoryChangeMonitor: {},
            rescheduleTimer: {},
            loginItemManager: makeLoginItemManager(state: FakeLoginItemState())
        )
        coordinator2.start()
        XCTAssertEqual(coordinator2.currentConfig()?.hudEnabled, true)

        coordinator2.proposeHUDEnabledChange(false)

        let expectation = expectation(description: "coalesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let current = coordinator2.currentConfig()
            XCTAssertEqual(current?.hudEnabled, true)
            XCTAssertEqual(current?.configVersion, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator(
        rebuildClosure: @escaping () -> Void = {},
        rescheduleClosure: @escaping () -> Void = {},
        loginItemState: FakeLoginItemState = FakeLoginItemState()
    ) -> (TinyBuddyConfigCoordinator, InMemoryConfigStorage, TinyBuddyConfigStore, FakeLoginItemState) {
        let storage = InMemoryConfigStorage()
        let configStore = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        let coordinator = TinyBuddyConfigCoordinator(
            configStore: configStore,
            scanRootsProvider: { TinyBuddyTestConfigRootsProvider.result() },
            rebuildRepositoryChangeMonitor: rebuildClosure,
            rescheduleTimer: rescheduleClosure,
            loginItemManager: makeLoginItemManager(state: loginItemState)
        )
        return (coordinator, storage, configStore, loginItemState)
    }
}

private final class InMemoryConfigStorage: @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Any] = [:]
}

enum TinyBuddyTestConfigRootsProvider {
    static nonisolated(unsafe) var currentRoots: [String] = []

    static func result() -> GitScanRootAccessResult {
        let roots = currentRoots.map { path in
            let url = URL(fileURLWithPath: path)
            return ScopedGitScanRoot(url: url)
        }
        return GitScanRootAccessResult(
            roots: roots,
            issue: nil,
            authorizations: []
        )
    }
}
