import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class TinyBuddyConfigCoordinatorTests: XCTestCase {
    private let dayID = "2026-07-20"

    @MainActor
    func testStartLoadsPersistedConfig() {
        let (coordinator, storage, _, _, _) = makeCoordinator()
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
    func testStartPublishesInitialConfigWhenNoPersistedConfig() {
        let (coordinator, _, _, _, _) = makeCoordinator()
        coordinator.start()
        XCTAssertNotNil(coordinator.currentConfig())
        XCTAssertEqual(coordinator.currentConfig()?.configVersion, 1)
    }

    @MainActor
    func testProposeScanRootsChangeTriggersRebuild() {
        var rebuildCallCount = 0
        var rescheduleCallCount = 0
        let (coordinator, storage, _, _, _) = makeCoordinator(
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
        let (coordinator, storage, _, _, _) = makeCoordinator(
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
    func testProposeLaunchAtLoginChange() {
        var rebuildCallCount = 0
        let (coordinator, storage, _, _, _) = makeCoordinator(
            rebuildClosure: { rebuildCallCount += 1 }
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

        coordinator.proposeLaunchAtLoginChange(true)

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
    func testRapidChangesCoalesce() {
        var rebuildCallCount = 0
        let (coordinator, storage, _, _, _) = makeCoordinator(
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
        let (coordinator, storage, _, _, _) = makeCoordinator()

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
        let (coordinator, storage, _, _, _) = makeCoordinator()

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
            rescheduleTimer: {}
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
        rescheduleClosure: @escaping () -> Void = {}
    ) -> (TinyBuddyConfigCoordinator, InMemoryConfigStorage, TinyBuddyConfigStore, Int, Int) {
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
            rescheduleTimer: rescheduleClosure
        )
        return (coordinator, storage, configStore, 0, 0)
    }
}

private final class InMemoryConfigStorage: @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Any] = [:]
}

enum TinyBuddyTestConfigRootsProvider {
    static var currentRoots: [String] = []

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
