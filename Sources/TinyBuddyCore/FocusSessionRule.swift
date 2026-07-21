import Foundation

// MARK: - Rule Set

/// A versioned, codable snapshot of all rules used to generate focus sessions.
/// Every automatic session is tagged with the rule version that produced it,
/// enabling deterministic replay and upgrade previews.
public struct FocusSessionRuleSet: Codable, Equatable, Sendable {
    /// Monotonic version identifier. `major` bumps on incompatible changes.
    public let version: FocusSessionRuleVersion
    /// The threshold configuration in effect when these rules were active.
    public let configuration: FocusSessionConfiguration
    /// The attribution policy in effect.
    public let attributionPolicy: FocusAttributionPolicy
    /// When this rule set was created (wall-clock time, for diagnostics only).
    public let createdAt: Date
    /// Optional human-readable label (e.g. "v1 initial", "v2 shorter idle").
    public let label: String

    public init(
        version: FocusSessionRuleVersion,
        configuration: FocusSessionConfiguration,
        attributionPolicy: FocusAttributionPolicy = FocusAttributionPolicy(),
        createdAt: Date = Date(),
        label: String = ""
    ) {
        self.version = version
        self.configuration = configuration
        self.attributionPolicy = attributionPolicy
        self.createdAt = createdAt
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case version, configuration, attributionPolicy, createdAt, label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(FocusSessionRuleVersion.self, forKey: .version)
        configuration = try container.decode(FocusSessionConfiguration.self, forKey: .configuration)
        attributionPolicy = try container.decodeIfPresent(FocusAttributionPolicy.self, forKey: .attributionPolicy)
            ?? FocusAttributionPolicy()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    /// Compares two rule sets and returns the differences between them.
    /// Each entry is a stable, human-readable description of a change.
    public func differences(from other: FocusSessionRuleSet) -> [String] {
        var result: [String] = []

        if version != other.version {
            result.append("Rule version: \(other.version.major).\(other.version.minor) → \(version.major).\(version.minor)")
        }

        // Configuration differences
        if configuration.idleThreshold != other.configuration.idleThreshold {
            result.append("Idle threshold: \(formatSeconds(other.configuration.idleThreshold)) → \(formatSeconds(configuration.idleThreshold))")
        }
        if configuration.briefInterruptionThreshold != other.configuration.briefInterruptionThreshold {
            result.append("Brief interruption threshold: \(formatSeconds(other.configuration.briefInterruptionThreshold)) → \(formatSeconds(configuration.briefInterruptionThreshold))")
        }
        if configuration.longAbsenceThreshold != other.configuration.longAbsenceThreshold {
            result.append("Long absence threshold: \(formatSeconds(other.configuration.longAbsenceThreshold)) → \(formatSeconds(configuration.longAbsenceThreshold))")
        }
        if configuration.maxSessionSpan != other.configuration.maxSessionSpan {
            let old = other.configuration.maxSessionSpan.map { formatSeconds($0) } ?? "unlimited"
            let new = configuration.maxSessionSpan.map { formatSeconds($0) } ?? "unlimited"
            result.append("Max session span: \(old) → \(new)")
        }

        // Attribution policy differences
        if attributionPolicy.gitAttributionWindow != other.attributionPolicy.gitAttributionWindow {
            let old = other.attributionPolicy.gitAttributionWindow.map { formatSeconds($0) } ?? "unlimited"
            let new = attributionPolicy.gitAttributionWindow.map { formatSeconds($0) } ?? "unlimited"
            result.append("Git attribution window: \(old) → \(new)")
        }

        return result
    }

    private func formatSeconds(_ ti: TimeInterval) -> String {
        let minutes = Int(ti / 60)
        let seconds = Int(ti.truncatingRemainder(dividingBy: 60))
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }
}

// MARK: - Rule Version comparison

extension FocusSessionRuleVersion: Comparable {
    public static func < (lhs: FocusSessionRuleVersion, rhs: FocusSessionRuleVersion) -> Bool {
        lhs.major < rhs.major || (lhs.major == rhs.major && lhs.minor < rhs.minor)
    }
}

// MARK: - FocusAttributionPolicy Codable conformance

extension FocusAttributionPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case gitAttributionWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gitAttributionWindow = try container.decodeIfPresent(TimeInterval.self, forKey: .gitAttributionWindow)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(gitAttributionWindow, forKey: .gitAttributionWindow)
    }
}

// MARK: - FocusSessionConfiguration Codable conformance

extension FocusSessionConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case idleThreshold, briefInterruptionThreshold, longAbsenceThreshold
        case maxSessionSpan, dayBoundaryTolerance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idleThreshold = try container.decode(TimeInterval.self, forKey: .idleThreshold)
        briefInterruptionThreshold = try container.decode(TimeInterval.self, forKey: .briefInterruptionThreshold)
        longAbsenceThreshold = try container.decode(TimeInterval.self, forKey: .longAbsenceThreshold)
        maxSessionSpan = try container.decodeIfPresent(TimeInterval.self, forKey: .maxSessionSpan)
        dayBoundaryTolerance = try container.decodeIfPresent(TimeInterval.self, forKey: .dayBoundaryTolerance) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idleThreshold, forKey: .idleThreshold)
        try container.encode(briefInterruptionThreshold, forKey: .briefInterruptionThreshold)
        try container.encode(longAbsenceThreshold, forKey: .longAbsenceThreshold)
        try container.encodeIfPresent(maxSessionSpan, forKey: .maxSessionSpan)
        try container.encodeIfPresent(dayBoundaryTolerance, forKey: .dayBoundaryTolerance)
    }
}

// MARK: - Rule Set Registry

/// Manages the current and historical rule sets.
/// Persisted via shared UserDefaults so all processes read the same rules.
public final class FocusSessionRuleRegistry: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Key {
        static let currentRuleSet = "tinybuddy.focusRule.currentRuleSet.v1"
        static let previousRuleSet = "tinybuddy.focusRule.previousRuleSet.v1"
        static let upgradeState = "tinybuddy.focusRule.upgradeState.v1"
    }

    private let lock = NSLock()

    public init(userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()) {
        self.defaults = userDefaults
    }

    /// The currently active rule set. Returns a default if none has been registered.
    public var currentRuleSet: FocusSessionRuleSet {
        lock.lock(); defer { lock.unlock() }
        return readRuleSet(forKey: Key.currentRuleSet)
            ?? FocusSessionRuleSet(
                version: .current,
                configuration: FocusSessionConfiguration(),
                label: "default"
            )
    }

    /// The previous rule set, if one exists (used for rollback).
    public var previousRuleSet: FocusSessionRuleSet? {
        lock.lock(); defer { lock.unlock() }
        return readRuleSet(forKey: Key.previousRuleSet)
    }

    /// Registers a new rule set as current, moving the old current to previous.
    /// If no current rule set is persisted (first registration), the current
    /// default is implicitly saved as previous. Returns false if persistence fails.
    @discardableResult
    public func registerNewRuleSet(_ ruleSet: FocusSessionRuleSet) -> Bool {
        lock.lock(); defer { lock.unlock() }

        // Ensure the current default is persisted before moving it.
        if loadRawData(forKey: Key.currentRuleSet) == nil {
            let defaultRuleSet = FocusSessionRuleSet(
                version: .current,
                configuration: FocusSessionConfiguration(),
                label: "default"
            )
            if let defaultData = try? JSONEncoder().encode(defaultRuleSet) {
                _ = saveRawData(defaultData, forKey: Key.currentRuleSet)
            }
        }

        // Move current to previous
        if let currentData = loadRawData(forKey: Key.currentRuleSet) {
            guard saveRawData(currentData, forKey: Key.previousRuleSet) else {
                return false
            }
        }

        // Save new as current
        guard let data = try? JSONEncoder().encode(ruleSet),
              saveRawData(data, forKey: Key.currentRuleSet) else {
            // Rollback previous restore
            _ = deleteRawData(forKey: Key.previousRuleSet)
            return false
        }

        return true
    }

    /// Rolls back to the previous rule set. The current becomes the "previous"
    /// after rollback, and the previous becomes current. Returns false when
    /// there is no previous rule set or persistence fails.
    @discardableResult
    public func rollbackToPrevious() -> Bool {
        lock.lock(); defer { lock.unlock() }

        guard let previousData = loadRawData(forKey: Key.previousRuleSet),
              (try? JSONDecoder().decode(FocusSessionRuleSet.self, from: previousData)) != nil else {
            return false
        }

        // Exchange current ↔ previous
        let currentData = loadRawData(forKey: Key.currentRuleSet)

        guard saveRawData(previousData, forKey: Key.currentRuleSet) else {
            return false
        }

        if let currentData {
            _ = saveRawData(currentData, forKey: Key.previousRuleSet)
        } else {
            _ = deleteRawData(forKey: Key.previousRuleSet)
        }

        return true
    }

    /// Clears the previous rule set (called after a successful upgrade is confirmed).
    @discardableResult
    public func clearPreviousRuleSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deleteRawData(forKey: Key.previousRuleSet)
    }

    // MARK: - Upgrade State Persistence

    /// Persisted upgrade state keyed by rule version string.
    public struct UpgradeRecoveryState: Codable, Equatable, Sendable {
        /// The new rule set being upgraded to.
        public let newRuleSet: FocusSessionRuleSet
        /// The rule set being upgraded from.
        public let oldRuleSet: FocusSessionRuleSet
        /// The date range being recalculated.
        public let dayStart: String
        public let dayEnd: String
        /// The archive revision at the time of the upgrade snapshot.
        public let archiveRevision: Int64
        /// When the upgrade was initiated.
        public let startedAt: Date

        public init(
            newRuleSet: FocusSessionRuleSet,
            oldRuleSet: FocusSessionRuleSet,
            dayStart: String,
            dayEnd: String,
            archiveRevision: Int64,
            startedAt: Date = Date()
        ) {
            self.newRuleSet = newRuleSet
            self.oldRuleSet = oldRuleSet
            self.dayStart = dayStart
            self.dayEnd = dayEnd
            self.archiveRevision = archiveRevision
            self.startedAt = startedAt
        }
    }

    /// Saves the upgrade recovery state so a failed upgrade can be detected and
    /// rolled back on next launch.
    @discardableResult
    public func saveUpgradeState(_ state: UpgradeRecoveryState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return saveRawData(data, forKey: Key.upgradeState)
    }

    /// Loads the persisted upgrade recovery state.
    public func loadUpgradeState() -> UpgradeRecoveryState? {
        lock.lock(); defer { lock.unlock() }
        guard let data = loadRawData(forKey: Key.upgradeState),
              let state = try? JSONDecoder().decode(UpgradeRecoveryState.self, from: data) else {
            return nil
        }
        return state
    }

    /// Clears the persisted upgrade recovery state (called after successful
    /// completion or intentional rollback).
    @discardableResult
    public func clearUpgradeState() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deleteRawData(forKey: Key.upgradeState)
    }

    // MARK: - Private

    private func readRuleSet(forKey key: String) -> FocusSessionRuleSet? {
        guard let data = loadRawData(forKey: key),
              let ruleSet = try? JSONDecoder().decode(FocusSessionRuleSet.self, from: data) else {
            return nil
        }
        return ruleSet
    }

    private func loadRawData(forKey key: String) -> Data? {
        guard let value = defaults.string(forKey: key),
              let data = Data(base64Encoded: value) else {
            return nil
        }
        return data
    }

    @discardableResult
    private func saveRawData(_ data: Data, forKey key: String) -> Bool {
        let encoded = data.base64EncodedString()
        defaults.set(encoded, forKey: key)
        defaults.synchronize()
        return true
    }

    @discardableResult
    private func deleteRawData(forKey key: String) -> Bool {
        defaults.removeObject(forKey: key)
        defaults.synchronize()
        return true
    }
}

// MARK: - Recalculation Event Log Entry

/// A single raw input event that can be replayed through a rule set to produce
/// sessions deterministically. These are recorded by the engine and stored
/// alongside the session archive.
public enum FocusSessionLogEventKind: String, Codable, Equatable, Sendable {
    case userActivity
    case foregroundProjectChanged
    case idleDetected
    case lockScreen
    case unlock
    case systemSleep
    case systemWake
    case timeChanged
    case appWillTerminate
    case crash
}

/// Lightweight log entry for deterministic replay. Contains only the minimal
/// information needed to re-process the event through any rule set.
public struct FocusSessionLogEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    public let kind: FocusSessionLogEventKind
    /// The project key if the event carries a project (userActivity, foregroundProjectChanged).
    public let projectKey: String?
    /// The project display name if the event carries a project.
    public let projectDisplayName: String?
    /// The day identifier for timeChanged events.
    public let dayIdentifier: String?

    public init(
        id: UUID = UUID(),
        at: Date,
        kind: FocusSessionLogEventKind,
        projectKey: String? = nil,
        projectDisplayName: String? = nil,
        dayIdentifier: String? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.projectKey = projectKey
        self.projectDisplayName = projectDisplayName
        self.dayIdentifier = dayIdentifier
    }
}

/// Container for the event log, persisted alongside the session archive.
public struct FocusSessionEventLog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let entries: [FocusSessionLogEntry]
    public let revision: Int64

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        entries: [FocusSessionLogEntry] = [],
        revision: Int64 = 0
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.revision = revision
    }

    public var isSemanticallyValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              revision >= 0 else { return false }
        let ids = entries.map(\.id)
        return Set(ids).count == ids.count
    }
}
