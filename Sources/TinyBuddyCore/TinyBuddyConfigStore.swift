import Foundation

public final class TinyBuddyConfigStore {
    public enum Key {
        public static let configPayload = "tinybuddy.appConfig.payload.v1"
        public static let configCommittedVersion = "tinybuddy.appConfig.committedVersion.v1"
    }

    public enum SaveOutcome: Equatable, Sendable {
        case saved
        case unchanged
        case persistenceFailed
    }

    private let directPreferencesProvider: () -> [String: Any]
    private let synchronizeReads: () -> Void
    private let writeValue: (Any, String) -> Bool
    private let synchronizeWrites: () -> Bool
    private let readFailureProvider: () -> TinyBuddySharedSnapshotReason?

    private static let lock = NSLock()

    public convenience init() {
        let preferencesStore = TinyBuddyAppGroupPreferencesStore()
        self.init(
            directPreferencesProvider: {
                preferencesStore.loadDictionary() ?? [:]
            },
            synchronizeReads: {},
            writeValue: { value, key in
                preferencesStore.writeValue(value, forKey: key)
            },
            synchronizeWrites: {
                preferencesStore.synchronize()
            },
            readFailureProvider: {
                TinyBuddySharedData.isAppGroupContainerAvailable()
                    && TinyBuddySharedData.isAppGroupDefaultsAvailable()
                    ? nil
                    : .appGroupUnavailable
            }
        )
    }

    init(
        directPreferencesProvider: @escaping () -> [String: Any],
        synchronizeReads: @escaping () -> Void,
        writeValue: @escaping (Any, String) -> Bool,
        synchronizeWrites: @escaping () -> Bool,
        readFailureProvider: @escaping () -> TinyBuddySharedSnapshotReason?
    ) {
        self.directPreferencesProvider = directPreferencesProvider
        self.synchronizeReads = synchronizeReads
        self.writeValue = writeValue
        self.synchronizeWrites = synchronizeWrites
        self.readFailureProvider = readFailureProvider
    }

    public func load() -> TinyBuddyAppConfig? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        synchronizeReads()
        let direct = directPreferencesProvider()
        guard readFailureProvider() == nil else {
            return nil
        }

        guard let marker = direct[Key.configCommittedVersion] as? Int64,
              marker >= 0,
              let payloadDict = direct[Key.configPayload] as? [String: Any],
              let payloadVersion = payloadDict["configVersion"] as? Int64,
              payloadVersion == marker,
              let config = TinyBuddyAppConfig(dictionary: payloadDict) else {
            return nil
        }
        return config
    }

    public func loadConfigVersion() -> Int64? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        synchronizeReads()
        let direct = directPreferencesProvider()
        guard let marker = direct[Key.configCommittedVersion] as? Int64, marker >= 0 else {
            return nil
        }
        return marker
    }

    public func save(_ config: TinyBuddyAppConfig) -> SaveOutcome {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        synchronizeReads()
        let direct = directPreferencesProvider()

        if let existingPayload = direct[Key.configPayload] as? [String: Any],
           let existingConfig = TinyBuddyAppConfig(dictionary: existingPayload),
           existingConfig == config {
            return .unchanged
        }

        let previousPayload = direct[Key.configPayload]

        let payload = config.dictionaryValue
        guard PropertyListSerialization.propertyList(payload, isValidFor: .binary) else {
            return .persistenceFailed
        }

        guard writeValue(payload, Key.configPayload),
              synchronizeWrites(),
              readbackPayload() as? [String: Any] != nil else {
            return .persistenceFailed
        }

        guard writeValue(config.configVersion, Key.configCommittedVersion),
              synchronizeWrites(),
              readbackCommittedVersion() == config.configVersion else {
            if let previousPayload {
                _ = writeValue(previousPayload, Key.configPayload)
            } else {
                _ = writeValue("" as NSString, Key.configPayload)
            }
            _ = synchronizeWrites()
            return .persistenceFailed
        }

        return .saved
    }

    private func readbackPayload() -> Any? {
        directPreferencesProvider()[Key.configPayload]
    }

    private func readbackCommittedVersion() -> Int64? {
        directPreferencesProvider()[Key.configCommittedVersion] as? Int64
    }
}
