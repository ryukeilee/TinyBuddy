import Foundation

public final class TinyBuddyConfigStore: @unchecked Sendable {
    public enum Key {
        public static let configPayload = "tinybuddy.appConfig.payload.v1"
        public static let configCommittedVersion = "tinybuddy.appConfig.committedVersion.v1"
    }

    public enum SaveOutcome: Equatable, Sendable {
        case saved
        case unchanged
        case persistenceFailed
    }

    public enum LoadOutcome: Equatable, Sendable {
        case loaded(TinyBuddyAppConfig)
        case empty
        case unavailable
        /// One or both config keys exist, but they do not form a committed pair.
        /// This includes compatible payloads with no marker: they are preserved
        /// for explicit recovery rather than treated as a first-install store.
        case uncommitted
    }

    private let directPreferencesProvider: () -> [String: Any]
    private let synchronizeReads: () -> Void
    private let writeValue: (Any, String) -> Bool
    private let removeValue: ((String) -> Bool)?
    private let synchronizeWrites: () -> Bool
    private let readFailureProvider: () -> TinyBuddySharedSnapshotReason?

    private struct StoredValues {
        let payload: Any?
        let marker: Any?
    }

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
            removeValue: { key in
                preferencesStore.removeValue(forKey: key)
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
        removeValue: ((String) -> Bool)? = nil,
        synchronizeWrites: @escaping () -> Bool,
        readFailureProvider: @escaping () -> TinyBuddySharedSnapshotReason?
    ) {
        self.directPreferencesProvider = directPreferencesProvider
        self.synchronizeReads = synchronizeReads
        self.writeValue = writeValue
        self.removeValue = removeValue
        self.synchronizeWrites = synchronizeWrites
        self.readFailureProvider = readFailureProvider
    }

    public func load() -> TinyBuddyAppConfig? {
        guard case .loaded(let config) = loadOutcome() else {
            return nil
        }
        return config
    }

    public func loadOutcome() -> LoadOutcome {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard let values = readStoredValues() else {
            return .unavailable
        }
        return classify(values)
    }

    public func loadConfigVersion() -> Int64? {
        guard case .loaded(let config) = loadOutcome() else {
            return nil
        }
        return config.configVersion
    }

    public func save(_ config: TinyBuddyAppConfig) -> SaveOutcome {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard config.configVersion >= 0 else {
            return .persistenceFailed
        }

        guard let previous = readStoredValues() else {
            return .persistenceFailed
        }

        switch classify(previous) {
        case .loaded(let existingConfig) where existingConfig == config:
            return .unchanged
        case .loaded, .empty:
            break
        case .unavailable, .uncommitted:
            return .persistenceFailed
        }

        let payload = config.dictionaryValue
        guard PropertyListSerialization.propertyList(payload, isValidFor: .binary) else {
            return .persistenceFailed
        }
        let target = StoredValues(payload: payload, marker: config.configVersion)

        guard writeValue(payload, Key.configPayload),
              synchronizeWrites(),
              payloadMatches(readStoredValues(), payload: payload) else {
            _ = restore(previous: previous, target: target)
            return .persistenceFailed
        }

        guard writeValue(config.configVersion, Key.configCommittedVersion),
              synchronizeWrites(),
              valuesMatch(readStoredValues(), target) else {
            _ = restore(previous: previous, target: target)
            return .persistenceFailed
        }

        guard valuesMatch(readStoredValues(), target) else {
            _ = restore(previous: previous, target: target)
            return .persistenceFailed
        }

        return .saved
    }

    private func readStoredValues() -> StoredValues? {
        synchronizeReads()
        let direct = directPreferencesProvider()
        guard readFailureProvider() == nil else {
            return nil
        }
        return StoredValues(
            payload: direct[Key.configPayload],
            marker: direct[Key.configCommittedVersion]
        )
    }

    private func classify(_ values: StoredValues) -> LoadOutcome {
        if values.payload == nil, values.marker == nil {
            return .empty
        }
        guard let marker = values.marker as? Int64,
              marker >= 0,
              let payload = values.payload as? [String: Any],
              let payloadVersion = payload["configVersion"] as? Int64,
              payloadVersion == marker,
              let config = TinyBuddyAppConfig(dictionary: payload) else {
            return .uncommitted
        }
        return .loaded(config)
    }

    private func payloadMatches(_ values: StoredValues?, payload: [String: Any]) -> Bool {
        guard let values,
              let actual = values.payload as? [String: Any] else {
            return false
        }
        return NSDictionary(dictionary: actual).isEqual(to: payload)
    }

    private func valuesMatch(_ values: StoredValues?, _ expected: StoredValues) -> Bool {
        guard let values else {
            return false
        }
        return propertyListValue(values.payload, equals: expected.payload)
            && propertyListValue(values.marker, equals: expected.marker)
    }

    private func propertyListValue(_ lhs: Any?, equals rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left as [String: Any], right as [String: Any]):
            return NSDictionary(dictionary: left).isEqual(to: right)
        case let (left as NSNumber, right as NSNumber):
            return left == right
        case let (left as NSString, right as NSString):
            return left == right
        default:
            return false
        }
    }

    /// Restores both members of the pair after a failed write. The read-before-
    /// restore guard avoids replacing a different complete pair published by
    /// another writer. There is no cross-process compare-and-swap in CFPreferences,
    /// so a concurrent writer that publishes the exact same pair is indistinguishable.
    private func restore(previous: StoredValues, target: StoredValues) -> Bool {
        guard let current = readStoredValues() else {
            return false
        }

        let payloadWasWritten = propertyListValue(current.payload, equals: target.payload)
        let isPrevious = valuesMatch(current, previous)
        let isTarget = valuesMatch(current, target)
        let hasAttemptedPayloadWithPreviousMarker = payloadWasWritten
            && propertyListValue(current.marker, equals: previous.marker)
        guard isPrevious || isTarget || hasAttemptedPayloadWithPreviousMarker else {
            return false
        }

        if let previousPayload = previous.payload {
            guard writeValue(previousPayload, Key.configPayload),
                  synchronizeWrites(),
                  let afterPayload = readStoredValues(),
                  propertyListValue(afterPayload.payload, equals: previousPayload),
                  propertyListValue(afterPayload.marker, equals: previous.marker)
                    || propertyListValue(afterPayload.marker, equals: target.marker) else {
                return false
            }
            guard let previousMarker = previous.marker,
                  writeValue(previousMarker, Key.configCommittedVersion),
                  synchronizeWrites(),
                  valuesMatch(readStoredValues(), previous) else {
                return false
            }
            return true
        }

        guard let removeValue,
              removeValue(Key.configPayload),
              synchronizeWrites(),
              let afterPayloadRemoval = readStoredValues(),
              afterPayloadRemoval.payload == nil,
              afterPayloadRemoval.marker == nil
                || propertyListValue(afterPayloadRemoval.marker, equals: target.marker),
              removeValue(Key.configCommittedVersion),
              synchronizeWrites(),
              valuesMatch(readStoredValues(), previous) else {
            return false
        }
        return true
    }
}
