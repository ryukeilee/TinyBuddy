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
        return TinyBuddyConfigStore(
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
    var values: [String: Any] = [:]

    subscript(key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
}
