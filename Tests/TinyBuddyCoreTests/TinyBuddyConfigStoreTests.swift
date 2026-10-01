import XCTest
@testable import TinyBuddyCore

final class TinyBuddyConfigStoreTests: XCTestCase {
    private let dayID = "2026-07-20"

    func testSaveAndLoad() {
        let store = makeEmptyStore()
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/Users/test/Code"],
            dayIdentifier: dayID
        )

        let outcome = store.save(config)
        XCTAssertEqual(outcome, .saved)

        let loaded = store.load()
        XCTAssertEqual(loaded, config)
    }

    func testSaveUnchangedReturnsUnchanged() {
        let store = makeEmptyStore()
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/Users/test/Code"],
            dayIdentifier: dayID
        )

        XCTAssertEqual(store.save(config), .saved)
        XCTAssertEqual(store.save(config), .unchanged)
    }

    func testSaveMultipleVersions() {
        let store = makeEmptyStore()
        let config1 = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/path/a"],
            dayIdentifier: dayID
        )
        let config2 = TinyBuddyAppConfig(
            configVersion: 2,
            scanRootPaths: ["/path/b"],
            dayIdentifier: dayID
        )

        XCTAssertEqual(store.save(config1), .saved)
        XCTAssertEqual(store.load(), config1)

        XCTAssertEqual(store.save(config2), .saved)
        XCTAssertEqual(store.load(), config2)
    }

    func testLoadReturnsNilForEmptyStore() {
        let store = makeEmptyStore()
        XCTAssertNil(store.load())
    }

    func testLoadConfigVersion() {
        let store = makeEmptyStore()
        XCTAssertNil(store.loadConfigVersion())

        let config = TinyBuddyAppConfig(
            configVersion: 7,
            dayIdentifier: dayID
        )
        XCTAssertEqual(store.save(config), .saved)
        XCTAssertEqual(store.loadConfigVersion(), 7)
    }

    func testLoadKeepsCompatibleV1PayloadWithoutExclusionRules() {
        let storage = ThreadSafeDictionaryStorage()
        let store = makeStore(storage: storage)
        let config = TinyBuddyAppConfig(
            configVersion: 3,
            scanRootPaths: ["/path/a"],
            dayIdentifier: dayID
        )
        var compatiblePayload = config.dictionaryValue
        compatiblePayload.removeValue(forKey: "exclusionRules")
        storage.values[TinyBuddyConfigStore.Key.configPayload] = compatiblePayload
        storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] = Int64(3)

        XCTAssertEqual(store.loadOutcome(), .loaded(config))
        XCTAssertEqual(store.save(config), .unchanged)
    }

    func testPayloadMatchWithDifferentMarkerIsNotUnchanged() {
        let storage = ThreadSafeDictionaryStorage()
        let store = makeStore(storage: storage)
        let config = TinyBuddyAppConfig(configVersion: 3, dayIdentifier: dayID)
        storage.values[TinyBuddyConfigStore.Key.configPayload] = config.dictionaryValue
        storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] = Int64(2)

        XCTAssertEqual(store.save(config), .persistenceFailed)
        XCTAssertEqual(store.loadOutcome(), .uncommitted)
        XCTAssertEqual(storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] as? Int64, 2)
    }

    func testNegativeVersionCannotBeReportedAsSaved() {
        let storage = ThreadSafeDictionaryStorage()
        let store = makeStore(storage: storage)
        let invalidConfig = TinyBuddyAppConfig(configVersion: -1, dayIdentifier: dayID)

        XCTAssertEqual(store.save(invalidConfig), .persistenceFailed)
        XCTAssertTrue(storage.values.isEmpty)
    }

    func testPayloadSynchronizationFailureRestoresPairAndRetrySaves() {
        let storage = ThreadSafeDictionaryStorage()
        var failNextSynchronization = false
        let store = makeStore(storage: storage) {
            if failNextSynchronization {
                failNextSynchronization = false
                return false
            }
            return true
        }
        let config1 = TinyBuddyAppConfig(
            configVersion: 1,
            hudEnabled: true,
            dayIdentifier: dayID
        )
        let config2 = config1.withIncrementedVersion(hudEnabled: false)

        XCTAssertEqual(store.save(config1), .saved)
        failNextSynchronization = true
        XCTAssertEqual(store.save(config2), .persistenceFailed)
        XCTAssertEqual(store.load(), config1)
        XCTAssertEqual(storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] as? Int64, 1)
        XCTAssertEqual(
            store.save(config2),
            .saved,
            "A retry after a failed payload sync must not mistake its payload for a committed pair"
        )
        XCTAssertEqual(store.load(), config2)
    }

    func testMarkerSynchronizationFailureRestoresPayloadAndMarker() {
        let storage = ThreadSafeDictionaryStorage()
        var synchronizationCount = 0
        var failOnSynchronization: Int?
        let store = makeStore(storage: storage) {
            synchronizationCount += 1
            if let failOnSynchronization,
               synchronizationCount == failOnSynchronization {
                return false
            }
            return true
        }
        let config1 = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/path/a"],
            dayIdentifier: dayID
        )
        let config2 = config1.withIncrementedVersion(scanRootPaths: ["/path/b"])

        XCTAssertEqual(store.save(config1), .saved)
        synchronizationCount = 0
        failOnSynchronization = 2
        XCTAssertEqual(store.save(config2), .persistenceFailed)

        XCTAssertEqual(store.load(), config1)
        XCTAssertTrue(
            NSDictionary(dictionary: try XCTUnwrap(
                storage.values[TinyBuddyConfigStore.Key.configPayload] as? [String: Any]
            )).isEqual(to: config1.dictionaryValue)
        )
        XCTAssertEqual(storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] as? Int64, 1)
    }

    func testInitialMarkerFailureRemovesBothKeysAndCanRetry() {
        let storage = ThreadSafeDictionaryStorage()
        var synchronizationCount = 0
        let store = makeStore(storage: storage) {
            synchronizationCount += 1
            return synchronizationCount != 2
        }
        let config = TinyBuddyAppConfig(configVersion: 1, dayIdentifier: dayID)

        XCTAssertEqual(store.save(config), .persistenceFailed)
        XCTAssertTrue(storage.values.isEmpty)
        XCTAssertEqual(store.loadOutcome(), .empty)

        XCTAssertEqual(store.save(config), .saved)
        XCTAssertEqual(store.load(), config)
    }

    func testFailedWriteDoesNotRestoreOverACompletePairFromAnotherWriter() {
        let storage = ThreadSafeDictionaryStorage()
        var publishOtherWriterDuringNextSync = false
        let concurrentConfig = TinyBuddyAppConfig(
            configVersion: 3,
            scanRootPaths: ["/path/concurrent"],
            dayIdentifier: dayID
        )
        let store = makeStore(storage: storage) {
            guard publishOtherWriterDuringNextSync else { return true }
            publishOtherWriterDuringNextSync = false
            storage.values[TinyBuddyConfigStore.Key.configPayload] = concurrentConfig.dictionaryValue
            storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] = concurrentConfig.configVersion
            return false
        }
        let config1 = TinyBuddyAppConfig(configVersion: 1, dayIdentifier: dayID)
        let config2 = config1.withIncrementedVersion(hudEnabled: false)

        XCTAssertEqual(store.save(config1), .saved)
        publishOtherWriterDuringNextSync = true
        XCTAssertEqual(store.save(config2), .persistenceFailed)

        XCTAssertEqual(store.load(), concurrentConfig)
        XCTAssertEqual(
            storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] as? Int64,
            concurrentConfig.configVersion
        )
    }

    func testStaleAndEmptyPayloadReadbacksTriggerRecovery() {
        for readback in ["stale", "empty"] {
            let storage = ThreadSafeDictionaryStorage()
            var injectNextPayloadReadback = false
            var payloadReadbackOverride: [String: Any] = [:]
            var returnOverride = false
            let store = TinyBuddyConfigStore(
                directPreferencesProvider: {
                    if returnOverride {
                        returnOverride = false
                        return payloadReadbackOverride
                    }
                    return storage.values
                },
                synchronizeReads: {},
                writeValue: { value, key in
                    storage.values[key] = value
                    if key == TinyBuddyConfigStore.Key.configPayload,
                       injectNextPayloadReadback {
                        injectNextPayloadReadback = false
                        returnOverride = true
                    }
                    return true
                },
                removeValue: { storage.removeValue(forKey: $0) },
                synchronizeWrites: { true },
                readFailureProvider: { nil }
            )
            let config1 = TinyBuddyAppConfig(
                configVersion: 1,
                hudEnabled: true,
                dayIdentifier: dayID
            )
            let config2 = config1.withIncrementedVersion(hudEnabled: false)

            XCTAssertEqual(store.save(config1), .saved, readback)
            payloadReadbackOverride = readback == "stale"
                ? [
                    TinyBuddyConfigStore.Key.configPayload: config1.dictionaryValue,
                    TinyBuddyConfigStore.Key.configCommittedVersion: Int64(1)
                ]
                : [:]
            injectNextPayloadReadback = true

            XCTAssertEqual(store.save(config2), .persistenceFailed, readback)
            XCTAssertEqual(store.load(), config1, readback)
            XCTAssertEqual(storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] as? Int64, 1, readback)
        }
    }

    func testUnconfirmedRollbackRemainsUnavailableToReaders() {
        let storage = ThreadSafeDictionaryStorage()
        var synchronizationCount = 0
        var failOnSynchronization: Int?
        var rejectRestoredMarker = false
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                if key == TinyBuddyConfigStore.Key.configCommittedVersion,
                   rejectRestoredMarker,
                   (value as? Int64) == 1 {
                    return false
                }
                storage.values[key] = value
                return true
            },
            removeValue: { storage.removeValue(forKey: $0) },
            synchronizeWrites: {
                synchronizationCount += 1
                guard let failOnSynchronization else { return true }
                return synchronizationCount != failOnSynchronization
            },
            readFailureProvider: { nil }
        )
        let config1 = TinyBuddyAppConfig(configVersion: 1, dayIdentifier: dayID)
        let config2 = config1.withIncrementedVersion(hudEnabled: false)

        XCTAssertEqual(store.save(config1), .saved)
        synchronizationCount = 0
        failOnSynchronization = 2
        rejectRestoredMarker = true
        XCTAssertEqual(store.save(config2), .persistenceFailed)

        XCTAssertNil(store.load())
        XCTAssertEqual(store.loadOutcome(), .uncommitted)
        XCTAssertNil(store.loadConfigVersion())
        XCTAssertTrue(
            NSDictionary(dictionary: try XCTUnwrap(
                storage.values[TinyBuddyConfigStore.Key.configPayload] as? [String: Any]
            )).isEqual(to: config1.dictionaryValue)
        )
        XCTAssertEqual(storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] as? Int64, 2)
    }

    func testPersistenceFailureReturnsFailed() {
        let store = makeFailingStore()
        let config = TinyBuddyAppConfig(
            configVersion: 1,
            dayIdentifier: dayID
        )
        XCTAssertEqual(store.save(config), .persistenceFailed)
        XCTAssertNil(store.load())
    }

    func testCommitMarkerMismatchReturnsNil() {
        let storage = ThreadSafeDictionaryStorage()
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

        let config = TinyBuddyAppConfig(
            configVersion: 5,
            dayIdentifier: dayID
        )
        XCTAssertEqual(store.save(config), .saved)
        XCTAssertEqual(store.load(), config)

        storage.values[TinyBuddyConfigStore.Key.configCommittedVersion] = 99
        XCTAssertNil(store.load())
    }

    func testPartialWriteProducesNoReadableState() {
        let storage = ThreadSafeDictionaryStorage()
        var failNextPayloadWrite = false
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                if key == TinyBuddyConfigStore.Key.configPayload && failNextPayloadWrite {
                    return false
                }
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )

        let config = TinyBuddyAppConfig(
            configVersion: 1,
            dayIdentifier: dayID
        )

        failNextPayloadWrite = true
        XCTAssertEqual(store.save(config), .persistenceFailed)
        XCTAssertNil(store.load())
    }

    func testGracefulFailurePreservesLastValidConfig() {
        let storage = ThreadSafeDictionaryStorage()
        var failNextCommitMarker = false
        let store = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                if key == TinyBuddyConfigStore.Key.configCommittedVersion && failNextCommitMarker {
                    return false
                }
                storage.values[key] = value
                return true
            },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )

        let config1 = TinyBuddyAppConfig(
            configVersion: 1,
            scanRootPaths: ["/path/a"],
            dayIdentifier: dayID
        )
        XCTAssertEqual(store.save(config1), .saved)
        XCTAssertEqual(store.load(), config1)

        let config2 = TinyBuddyAppConfig(
            configVersion: 2,
            scanRootPaths: ["/path/b"],
            dayIdentifier: dayID
        )
        failNextCommitMarker = true
        XCTAssertEqual(store.save(config2), .persistenceFailed)

        let loaded = store.load()
        XCTAssertEqual(loaded, config1)
    }

    private func makeEmptyStore() -> TinyBuddyConfigStore {
        let storage = ThreadSafeDictionaryStorage()
        return makeStore(storage: storage)
    }

    private func makeStore(
        storage: ThreadSafeDictionaryStorage,
        synchronizeWrites: @escaping () -> Bool = { true }
    ) -> TinyBuddyConfigStore {
        TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in
                storage.values[key] = value
                return true
            },
            removeValue: { storage.removeValue(forKey: $0) },
            synchronizeWrites: synchronizeWrites,
            readFailureProvider: { nil }
        )
    }

    private func makeFailingStore() -> TinyBuddyConfigStore {
        let storage = ThreadSafeDictionaryStorage()
        return TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { _, _ in false },
            synchronizeWrites: { false },
            readFailureProvider: { nil }
        )
    }
}

private final class ThreadSafeDictionaryStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String: Any] = [:]

    var values: [String: Any] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValues
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValues = newValue
        }
    }

    func setValue(_ value: Any, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storedValues[key] = value
    }

    func removeValue(forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedValues.removeValue(forKey: key)
        return true
    }

    subscript(key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storedValues[key]
    }
}
