import Foundation

public struct TinyBuddyAppConfig: Equatable, Sendable {
    public let configVersion: Int64
    public let scanRootPaths: [String]
    public let launchAtLoginEnabled: Bool
    public let hudEnabled: Bool
    public let refreshStrategy: TinyBuddyRefreshStrategy
    public let exclusionRules: [TinyBuddyExclusionRule]
    public let dayIdentifier: String

    public init(
        configVersion: Int64 = 0,
        scanRootPaths: [String] = [],
        launchAtLoginEnabled: Bool = false,
        hudEnabled: Bool = true,
        refreshStrategy: TinyBuddyRefreshStrategy = .automatic,
        exclusionRules: [TinyBuddyExclusionRule] = [],
        dayIdentifier: String
    ) {
        self.configVersion = configVersion
        self.scanRootPaths = scanRootPaths
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.hudEnabled = hudEnabled
        self.refreshStrategy = refreshStrategy
        self.exclusionRules = exclusionRules
        self.dayIdentifier = dayIdentifier
    }

    public func withIncrementedVersion(
        scanRootPaths: [String]? = nil,
        launchAtLoginEnabled: Bool? = nil,
        hudEnabled: Bool? = nil,
        refreshStrategy: TinyBuddyRefreshStrategy? = nil,
        exclusionRules: [TinyBuddyExclusionRule]? = nil,
        dayIdentifier: String? = nil
    ) -> TinyBuddyAppConfig {
        TinyBuddyAppConfig(
            configVersion: configVersion + 1,
            scanRootPaths: scanRootPaths ?? self.scanRootPaths,
            launchAtLoginEnabled: launchAtLoginEnabled ?? self.launchAtLoginEnabled,
            hudEnabled: hudEnabled ?? self.hudEnabled,
            refreshStrategy: refreshStrategy ?? self.refreshStrategy,
            exclusionRules: exclusionRules ?? self.exclusionRules,
            dayIdentifier: dayIdentifier ?? self.dayIdentifier
        )
    }
}

public enum TinyBuddyRefreshStrategy: String, Codable, Sendable, Equatable, CaseIterable {
    case automatic
    case aggressive
    case conservative
    case manual
}

public struct TinyBuddyExclusionRule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let pattern: String

    public init(id: String = UUID().uuidString, pattern: String) {
        self.id = id
        self.pattern = pattern
    }

    public static func normalizedPattern(_ rawPattern: String) -> String? {
        var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        while pattern.hasPrefix("./") {
            pattern.removeFirst(2)
        }
        while pattern.count > 1, pattern.hasSuffix("/") {
            pattern.removeLast()
        }
        guard !pattern.isEmpty,
              !pattern.hasPrefix("/"),
              !pattern.contains("//"),
              !pattern.contains("\t"),
              !pattern.contains("\r"),
              !pattern.contains("\n"),
              !pattern.contains(where: { "*?[]".contains($0) }) else {
            return nil
        }
        let components = pattern.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            return nil
        }
        return pattern
    }
}

extension TinyBuddyAppConfig {
    static let supportedVersion: Int = 1

    var dictionaryValue: [String: Any] {
        [
            "configVersion": configVersion,
            "version": Self.supportedVersion,
            "scanRootPaths": scanRootPaths,
            "launchAtLoginEnabled": launchAtLoginEnabled,
            "hudEnabled": hudEnabled,
            "refreshStrategy": refreshStrategy.rawValue,
            "exclusionRules": exclusionRules.map(\.dictionaryValue),
            "dayIdentifier": dayIdentifier
        ]
    }

    init?(dictionary: [String: Any]) {
        guard let version = dictionary["version"] as? Int, version == Self.supportedVersion,
              let configVersion = dictionary["configVersion"] as? Int64,
              let scanRootPaths = dictionary["scanRootPaths"] as? [String],
              let launchAtLoginEnabled = dictionary["launchAtLoginEnabled"] as? Bool,
              let hudEnabled = dictionary["hudEnabled"] as? Bool,
              let refreshStrategyRaw = dictionary["refreshStrategy"] as? String,
              let refreshStrategy = TinyBuddyRefreshStrategy(rawValue: refreshStrategyRaw),
              let dayIdentifier = dictionary["dayIdentifier"] as? String else {
            return nil
        }
        let exclusionDictionaries = dictionary["exclusionRules"] as? [[String: Any]] ?? []
        let exclusionRules = exclusionDictionaries.compactMap(TinyBuddyExclusionRule.init(dictionary:))
        self.init(
            configVersion: configVersion,
            scanRootPaths: scanRootPaths,
            launchAtLoginEnabled: launchAtLoginEnabled,
            hudEnabled: hudEnabled,
            refreshStrategy: refreshStrategy,
            exclusionRules: exclusionRules,
            dayIdentifier: dayIdentifier
        )
    }
}

extension TinyBuddyExclusionRule {
    var dictionaryValue: [String: Any] {
        ["id": id, "pattern": pattern]
    }

    init?(dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String,
              let pattern = dictionary["pattern"] as? String else {
            return nil
        }
        self.id = id
        self.pattern = pattern
    }
}
