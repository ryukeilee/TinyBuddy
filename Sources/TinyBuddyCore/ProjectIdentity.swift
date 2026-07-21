import Foundation
import OSLog

public struct TinyBuddyProjectID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum TinyBuddyProjectKind: String, Codable, Equatable, Sendable {
    case gitRepository
    case application
    case manual
}

public enum TinyBuddyProjectState: String, Codable, Equatable, Sendable {
    case active
    case temporarilyUnavailable
    case archived
    case removed
}

/// One durable project. `repositoryFingerprint` is path/name independent,
/// while `aliases` retain every previously observed common-dir or app key.
public struct TinyBuddyProject: Codable, Equatable, Sendable, Identifiable {
    public let id: TinyBuddyProjectID
    public let kind: TinyBuddyProjectKind
    public var displayName: String
    public var repositoryFingerprint: String?
    public var aliases: Set<String>
    public var state: TinyBuddyProjectState
    public var isDisplayNameCustomized: Bool
    public var lastSeenAt: Date?
    public var unavailableSince: Date?

    public init(
        id: TinyBuddyProjectID = TinyBuddyProjectID(),
        kind: TinyBuddyProjectKind,
        displayName: String,
        repositoryFingerprint: String? = nil,
        aliases: Set<String> = [],
        state: TinyBuddyProjectState = .active,
        isDisplayNameCustomized: Bool = false,
        lastSeenAt: Date? = nil,
        unavailableSince: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.repositoryFingerprint = repositoryFingerprint
        self.aliases = aliases
        self.state = state
        self.isDisplayNameCustomized = isDisplayNameCustomized
        self.lastSeenAt = lastSeenAt
        self.unavailableSince = unavailableSince
    }
}

public struct TinyBuddyProjectRegistrySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let revision: Int64
    /// Changes whenever an explicit identity decision invalidates an in-flight scan.
    public let generation: Int64
    public var projects: [TinyBuddyProject]
    /// Source IDs remain tombstoned after merge. Historical and delayed inputs
    /// resolve through this map instead of recreating the source identity.
    public var redirects: [TinyBuddyProjectID: TinyBuddyProjectID]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: Int64 = 0,
        generation: Int64 = 0,
        projects: [TinyBuddyProject] = [],
        redirects: [TinyBuddyProjectID: TinyBuddyProjectID] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.generation = generation
        self.projects = projects
        self.redirects = redirects
    }

    public var isSemanticallyValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              revision >= 0,
              generation >= 0,
              Set(projects.map(\.id)).count == projects.count else {
            return false
        }
        let ids = Set(projects.map(\.id))
        for project in projects {
            guard !project.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !project.aliases.contains(where: {
                      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }),
                  project.repositoryFingerprint.map({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) ?? true else {
                return false
            }
        }
        for (source, target) in redirects {
            guard source != target, ids.contains(source), ids.contains(target) else { return false }
            var cursor = target
            var visited: Set<TinyBuddyProjectID> = [source]
            while let next = redirects[cursor] {
                guard visited.insert(cursor).inserted else { return false }
                cursor = next
            }
        }
        return true
    }
}

public protocol TinyBuddyProjectRegistryPersisting: Sendable {
    func load() -> TinyBuddyProjectRegistrySnapshot?
    @discardableResult func save(_ snapshot: TinyBuddyProjectRegistrySnapshot) -> Bool
}

/// Atomic file-backed registry. A failed encode or replacement leaves the
/// previous identity graph intact, so readers never observe a half-merge.
public final class TinyBuddyProjectRegistryFileStore: TinyBuddyProjectRegistryPersisting, @unchecked Sendable {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(
        fileURL: URL,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.fileURL = fileURL
        self.encoder = encoder
        self.decoder = decoder
    }

    public func load() -> TinyBuddyProjectRegistrySnapshot? {
        lock.lock(); defer { lock.unlock() }
        return read(fileURL) ?? read(backupURL)
    }

    @discardableResult
    public func save(_ snapshot: TinyBuddyProjectRegistrySnapshot) -> Bool {
        guard snapshot.isSemanticallyValid,
              let data = try? encoder.encode(snapshot) else { return false }
        lock.lock(); defer { lock.unlock() }
        let directory = fileURL.deletingLastPathComponent()
        let staged = directory.appendingPathComponent("\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: staged, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let previous = try Data(contentsOf: fileURL)
                try previous.write(to: backupURL, options: .atomic)
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: fileURL)
            }
            return read(fileURL) == snapshot
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return false
        }
    }

    private var backupURL: URL {
        fileURL.appendingPathExtension("bak")
    }

    private let logger = Logger(
        subsystem: "local.tinybuddy",
        category: "TinyBuddyProjectRegistryFileStore"
    )

    private func read(_ url: URL) -> TinyBuddyProjectRegistrySnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(TinyBuddyProjectRegistrySnapshot.self, from: data),
              snapshot.isSemanticallyValid else { return nil }
        // Additional diagnostic validation via unified validator
        let violations = TinyBuddyDataValidator.validateProjectRegistry(snapshot)
        if !violations.isEmpty {
            let criticalCount = violations.filter { $0.severity == .critical }.count
            let errorCount = violations.filter { $0.severity == .error }.count
            let warningCount = violations.filter { $0.severity == .warning }.count
            logger.debug(
                "Project registry validation: \(criticalCount) critical, \(errorCount) errors, \(warningCount) warnings"
            )
            for violation in violations where violation.severity == .critical {
                logger.debug("  [CRITICAL] \(violation.description, privacy: .public)")
            }
        }
        return snapshot
    }
}

public struct TinyBuddyProjectScanToken: Equatable, Sendable {
    public let generation: Int64

    public init(generation: Int64) {
        self.generation = generation
    }
}

public struct TinyBuddyGitProjectObservation: Equatable, Sendable {
    public let repositoryFingerprint: String
    public let repositoryAlias: String
    public let suggestedDisplayName: String
    public let observedAt: Date

    public init(
        repositoryFingerprint: String,
        repositoryAlias: String,
        suggestedDisplayName: String,
        observedAt: Date
    ) {
        self.repositoryFingerprint = repositoryFingerprint
        self.repositoryAlias = repositoryAlias
        self.suggestedDisplayName = suggestedDisplayName
        self.observedAt = observedAt
    }
}

public struct TinyBuddyProjectDiscoveryManifest: Equatable, Sendable {
    public let observations: [TinyBuddyGitProjectObservation]

    public init(observations: [TinyBuddyGitProjectObservation]) {
        self.observations = observations
    }
}

/// Reads the scanner's path-private, base64-delimited discovery payload. A
/// malformed row invalidates the whole manifest so a partial parse can never
/// mark a valid project unavailable.
public final class TinyBuddyProjectDiscoveryStore {
    public enum Key {
        public static let manifest = "tinybuddy.gitProjects.discovery.v1"
        public static let recentRepositoryFingerprint =
            "tinybuddy.gitTodayRecentProject.repositoryFingerprint.v1"
    }

    private let defaults: UserDefaults
    private let dateProvider: () -> Date

    public init(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        dateProvider: @escaping () -> Date = Date.init
    ) {
        defaults = userDefaults
        self.dateProvider = dateProvider
    }

    public func loadManifest() -> TinyBuddyProjectDiscoveryManifest? {
        defaults.synchronize()
        guard let payload = defaults.string(forKey: Key.manifest) else { return nil }
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "v1" else { return nil }
        var observations: [TinyBuddyGitProjectObservation] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let fingerprint = Self.decode(fields[0]),
                  let alias = Self.decode(fields[1]),
                  let name = Self.decode(fields[2]),
                  !fingerprint.isEmpty,
                  !alias.isEmpty,
                  !name.isEmpty else { return nil }
            observations.append(TinyBuddyGitProjectObservation(
                repositoryFingerprint: fingerprint,
                repositoryAlias: alias,
                suggestedDisplayName: name,
                observedAt: dateProvider()
            ))
        }
        return TinyBuddyProjectDiscoveryManifest(observations: observations)
    }

    public func loadRecentRepositoryFingerprint() -> String? {
        defaults.string(forKey: Key.recentRepositoryFingerprint).flatMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func decode(_ value: Substring) -> String? {
        guard let data = Data(base64Encoded: String(value)),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }
}

public enum TinyBuddyProjectObservationResult: Equatable, Sendable {
    case resolved(TinyBuddyProject)
    case ignoredStale
    case rejectedInvalid
    case persistenceFailed
}

public struct TinyBuddyProjectDuplicateGroup: Equatable, Sendable, Identifiable {
    public let fingerprint: String
    public let projects: [TinyBuddyProject]
    public var id: String { fingerprint }
}

public struct TinyBuddyProjectMergePreview: Equatable, Sendable {
    public let registryRevision: Int64
    public let target: TinyBuddyProject
    public let sources: [TinyBuddyProject]
    public let affectedSessionCount: Int
    public let preservedFocusDuration: TimeInterval

    public init(
        registryRevision: Int64,
        target: TinyBuddyProject,
        sources: [TinyBuddyProject],
        affectedSessionCount: Int,
        preservedFocusDuration: TimeInterval
    ) {
        self.registryRevision = registryRevision
        self.target = target
        self.sources = sources
        self.affectedSessionCount = affectedSessionCount
        self.preservedFocusDuration = preservedFocusDuration
    }
}

public struct TinyBuddyProjectMergeUndo: Equatable, Sendable {
    fileprivate let before: TinyBuddyProjectRegistrySnapshot
    fileprivate let committedRevision: Int64
}

public enum TinyBuddyProjectMutationResult: Equatable, Sendable {
    case saved(TinyBuddyProjectRegistrySnapshot)
    case rejectedStale
    case rejectedInvalid
    case persistenceFailed
}

public enum TinyBuddyProjectMergeResult: Equatable, Sendable {
    case saved(snapshot: TinyBuddyProjectRegistrySnapshot, undo: TinyBuddyProjectMergeUndo)
    case rejectedStale
    case rejectedInvalid
    case persistenceFailed
}

public struct TinyBuddyProjectDiscoveryReconciliation: Equatable, Sendable {
    public let observedProjectIDs: Set<TinyBuddyProjectID>
    public let didCompleteAvailabilityReconciliation: Bool

    public init(
        observedProjectIDs: Set<TinyBuddyProjectID>,
        didCompleteAvailabilityReconciliation: Bool
    ) {
        self.observedProjectIDs = observedProjectIDs
        self.didCompleteAvailabilityReconciliation = didCompleteAvailabilityReconciliation
    }
}

/// Thread-safe identity authority. All public mutations build a complete next
/// graph and publish it with one atomic store replacement.
public final class TinyBuddyProjectRegistry: @unchecked Sendable {
    private let store: TinyBuddyProjectRegistryPersisting
    private let idProvider: @Sendable () -> TinyBuddyProjectID
    private let lock = NSLock()
    private var snapshot: TinyBuddyProjectRegistrySnapshot

    public init(
        store: TinyBuddyProjectRegistryPersisting,
        idProvider: @escaping @Sendable () -> TinyBuddyProjectID = { TinyBuddyProjectID() }
    ) {
        self.store = store
        self.idProvider = idProvider
        snapshot = store.load() ?? TinyBuddyProjectRegistrySnapshot()
    }

    public var currentSnapshot: TinyBuddyProjectRegistrySnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func beginScan() -> TinyBuddyProjectScanToken {
        lock.lock(); defer { lock.unlock() }
        return TinyBuddyProjectScanToken(generation: snapshot.generation)
    }

    public func observe(
        _ observation: TinyBuddyGitProjectObservation,
        token: TinyBuddyProjectScanToken
    ) -> TinyBuddyProjectObservationResult {
        let fingerprint = normalize(observation.repositoryFingerprint)
        let alias = normalize(observation.repositoryAlias)
        let name = normalize(observation.suggestedDisplayName)
        guard let fingerprint, let alias, let name else { return .rejectedInvalid }

        lock.lock(); defer { lock.unlock() }
        guard token.generation == snapshot.generation else { return .ignoredStale }
        var working = snapshot
        let fingerprintMatches = working.projects.indices.filter {
            working.projects[$0].repositoryFingerprint == fingerprint
        }
        let aliasMatches = working.projects.indices.filter {
            working.projects[$0].aliases.contains(alias)
        }
        let candidateIndices = Set(fingerprintMatches + aliasMatches)

        let resolvedIndex: Int
        if let activeIndex = candidateIndices.first(where: {
            working.projects[$0].state != .removed
        }) {
            resolvedIndex = activeIndex
        } else if let removedIndex = candidateIndices.first {
            // A merged/removed identity is a tombstone. Resolve it through the
            // redirect instead of recreating the old project.
            let removedID = working.projects[removedIndex].id
            guard let targetID = terminalTarget(for: removedID, in: working),
                  let targetIndex = working.projects.firstIndex(where: { $0.id == targetID }) else {
                return .rejectedInvalid
            }
            resolvedIndex = targetIndex
        } else {
            guard working.revision < Int64.max else { return .rejectedInvalid }
            let project = TinyBuddyProject(
                id: idProvider(),
                kind: .gitRepository,
                displayName: name,
                repositoryFingerprint: fingerprint,
                aliases: [alias],
                state: .active,
                lastSeenAt: observation.observedAt
            )
            working.projects.append(project)
            working = advanced(working, generation: working.generation)
            guard store.save(working) else { return .persistenceFailed }
            snapshot = working
            return .resolved(project)
        }

        var project = working.projects[resolvedIndex]
        project.aliases.insert(alias)
        project.repositoryFingerprint = fingerprint
        project.lastSeenAt = max(project.lastSeenAt ?? observation.observedAt, observation.observedAt)
        project.unavailableSince = nil
        // Explicit archive/removal decisions never auto-revert on observation.
        if project.state == .temporarilyUnavailable {
            project.state = .active
        }
        if !project.isDisplayNameCustomized {
            project.displayName = name
        }
        guard project != working.projects[resolvedIndex] else { return .resolved(project) }
        working.projects[resolvedIndex] = project
        working = advanced(working, generation: working.generation)
        guard store.save(working) else { return .persistenceFailed }
        snapshot = working
        return .resolved(project)
    }

    /// Marks only projects missed by a completed current-generation scan.
    /// A partial/failed scan must not call this method.
    @discardableResult
    public func finishSuccessfulScan(
        token: TinyBuddyProjectScanToken,
        observedProjectIDs: Set<TinyBuddyProjectID>,
        at date: Date
    ) -> TinyBuddyProjectMutationResult {
        mutate(expectedGeneration: token.generation, advancesGeneration: false) { working in
            for index in working.projects.indices {
                guard working.projects[index].kind == .gitRepository,
                      working.projects[index].state == .active,
                      !observedProjectIDs.contains(working.projects[index].id) else { continue }
                working.projects[index].state = .temporarilyUnavailable
                working.projects[index].unavailableSince = date
            }
            return true
        }
    }

    public func duplicateGroups() -> [TinyBuddyProjectDuplicateGroup] {
        lock.lock(); defer { lock.unlock() }
        let candidates = snapshot.projects.filter {
            $0.kind == .gitRepository && $0.state != .removed && $0.repositoryFingerprint != nil
        }
        return Dictionary(grouping: candidates, by: { $0.repositoryFingerprint! })
            .filter { $0.value.count > 1 }
            .map { TinyBuddyProjectDuplicateGroup(fingerprint: $0.key, projects: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.fingerprint < $1.fingerprint }
    }

    public func previewMerge(
        targetID: TinyBuddyProjectID,
        sourceIDs: Set<TinyBuddyProjectID>,
        sessions: [FocusSession],
        now: Date
    ) -> TinyBuddyProjectMergePreview? {
        lock.lock(); defer { lock.unlock() }
        guard !sourceIDs.isEmpty,
              !sourceIDs.contains(targetID),
              let target = snapshot.projects.first(where: { $0.id == targetID && $0.state != .removed }) else {
            return nil
        }
        let sources = snapshot.projects.filter { sourceIDs.contains($0.id) && $0.state != .removed }
        guard sources.count == sourceIDs.count else { return nil }
        let affectedIDs = sourceIDs.union([targetID])
        let matching = sessions.filter { session in
            resolvedProjectID(for: session.project.key, in: snapshot).map(affectedIDs.contains) ?? false
        }
        return TinyBuddyProjectMergePreview(
            registryRevision: snapshot.revision,
            target: target,
            sources: sources.sorted { $0.id < $1.id },
            affectedSessionCount: matching.count,
            preservedFocusDuration: matching.reduce(0) { $0 + $1.activeDuration(now: now) }
        )
    }

    public func merge(_ preview: TinyBuddyProjectMergePreview) -> TinyBuddyProjectMergeResult {
        lock.lock(); defer { lock.unlock() }
        guard preview.registryRevision == snapshot.revision,
              snapshot.revision < Int64.max,
              snapshot.generation < Int64.max,
              let targetIndex = snapshot.projects.firstIndex(where: {
                  $0.id == preview.target.id && $0.state != .removed
              }) else { return .rejectedStale }
        let sourceIDs = Set(preview.sources.map(\.id))
        let sourceIndices = snapshot.projects.indices.filter {
            sourceIDs.contains(snapshot.projects[$0].id) && snapshot.projects[$0].state != .removed
        }
        guard sourceIndices.count == sourceIDs.count, !sourceIDs.contains(preview.target.id) else {
            return .rejectedInvalid
        }

        let before = snapshot
        var working = snapshot
        var target = working.projects[targetIndex]
        for index in sourceIndices {
            let source = working.projects[index]
            target.aliases.formUnion(source.aliases)
            if target.repositoryFingerprint == nil {
                target.repositoryFingerprint = source.repositoryFingerprint
            }
            working.projects[index].state = .removed
            working.redirects[source.id] = target.id
            for (redirectSource, redirectTarget) in working.redirects where redirectTarget == source.id {
                working.redirects[redirectSource] = target.id
            }
        }
        working.projects[targetIndex] = target
        working = advanced(working, generation: working.generation + 1)
        guard working.isSemanticallyValid else { return .rejectedInvalid }
        guard store.save(working) else { return .persistenceFailed }
        snapshot = working
        return .saved(
            snapshot: working,
            undo: TinyBuddyProjectMergeUndo(before: before, committedRevision: working.revision)
        )
    }

    public func undoMerge(_ undo: TinyBuddyProjectMergeUndo) -> TinyBuddyProjectMutationResult {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.revision == undo.committedRevision,
              snapshot.revision < Int64.max,
              snapshot.generation < Int64.max else { return .rejectedStale }
        var restored = undo.before
        restored = TinyBuddyProjectRegistrySnapshot(
            revision: snapshot.revision + 1,
            generation: snapshot.generation + 1,
            projects: restored.projects,
            redirects: restored.redirects
        )
        guard store.save(restored) else { return .persistenceFailed }
        snapshot = restored
        return .saved(restored)
    }

    public func rename(id: TinyBuddyProjectID, displayName: String) -> TinyBuddyProjectMutationResult {
        guard let name = normalize(displayName) else { return .rejectedInvalid }
        return mutate(advancesGeneration: true) { working in
            guard let index = working.projects.firstIndex(where: { $0.id == id && $0.state != .removed }) else {
                return false
            }
            working.projects[index].displayName = name
            working.projects[index].isDisplayNameCustomized = true
            return true
        }
    }

    public func archive(id: TinyBuddyProjectID) -> TinyBuddyProjectMutationResult {
        setExplicitState(id: id, state: .archived)
    }

    public func markTemporarilyUnavailable(
        aliasPrefixes: Set<String>,
        at date: Date
    ) -> TinyBuddyProjectMutationResult {
        let prefixes = Set(aliasPrefixes.compactMap(normalize))
        guard !prefixes.isEmpty else { return .rejectedInvalid }
        return mutate(advancesGeneration: true) { working in
            var changed = false
            for index in working.projects.indices {
                guard working.projects[index].state == .active,
                      working.projects[index].aliases.contains(where: { alias in
                          prefixes.contains { prefix in
                              alias == prefix || alias.hasPrefix(prefix + "/")
                          }
                      }) else { continue }
                working.projects[index].state = .temporarilyUnavailable
                working.projects[index].unavailableSince = date
                changed = true
            }
            return changed
        }
    }

    public func restore(id: TinyBuddyProjectID) -> TinyBuddyProjectMutationResult {
        setExplicitState(id: id, state: .active)
    }

    public func resolve(id: TinyBuddyProjectID) -> TinyBuddyProject? {
        lock.lock(); defer { lock.unlock() }
        let target = terminalTarget(for: id, in: snapshot) ?? id
        return snapshot.projects.first { $0.id == target }
    }

    public func resolve(projectKey: String) -> TinyBuddyProject? {
        lock.lock(); defer { lock.unlock() }
        guard let id = resolvedProjectID(for: projectKey, in: snapshot) else { return nil }
        return snapshot.projects.first { $0.id == id }
    }

    /// Automatic attribution is intentionally limited to active projects.
    public func automaticContext(for projectKey: String) -> FocusProjectContext? {
        guard let project = resolve(projectKey: projectKey), project.state == .active else { return nil }
        return FocusProjectContext(key: project.id.rawValue, displayName: project.displayName)
    }

    private func setExplicitState(
        id: TinyBuddyProjectID,
        state: TinyBuddyProjectState
    ) -> TinyBuddyProjectMutationResult {
        mutate(advancesGeneration: true) { working in
            guard state == .active || state == .archived,
                  let index = working.projects.firstIndex(where: { $0.id == id && $0.state != .removed }) else {
                return false
            }
            working.projects[index].state = state
            working.projects[index].unavailableSince = nil
            return true
        }
    }

    private func mutate(
        expectedGeneration: Int64? = nil,
        advancesGeneration: Bool,
        _ body: (inout TinyBuddyProjectRegistrySnapshot) -> Bool
    ) -> TinyBuddyProjectMutationResult {
        lock.lock(); defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != snapshot.generation {
            return .rejectedStale
        }
        guard snapshot.revision < Int64.max,
              !advancesGeneration || snapshot.generation < Int64.max else {
            return .rejectedInvalid
        }
        var working = snapshot
        guard body(&working) else { return .rejectedInvalid }
        working = advanced(
            working,
            generation: advancesGeneration ? working.generation + 1 : working.generation
        )
        guard working.isSemanticallyValid else { return .rejectedInvalid }
        guard store.save(working) else { return .persistenceFailed }
        snapshot = working
        return .saved(working)
    }

    private func advanced(
        _ value: TinyBuddyProjectRegistrySnapshot,
        generation: Int64
    ) -> TinyBuddyProjectRegistrySnapshot {
        TinyBuddyProjectRegistrySnapshot(
            revision: value.revision + 1,
            generation: generation,
            projects: value.projects,
            redirects: value.redirects
        )
    }

    private func normalize(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func terminalTarget(
        for id: TinyBuddyProjectID,
        in value: TinyBuddyProjectRegistrySnapshot
    ) -> TinyBuddyProjectID? {
        var current = id
        var visited = Set<TinyBuddyProjectID>()
        while let next = value.redirects[current] {
            guard visited.insert(current).inserted else { return nil }
            current = next
        }
        return current == id ? nil : current
    }

    private func resolvedProjectID(
        for key: String,
        in value: TinyBuddyProjectRegistrySnapshot
    ) -> TinyBuddyProjectID? {
        let direct = TinyBuddyProjectID(rawValue: key)
        if value.projects.contains(where: { $0.id == direct }) {
            return terminalTarget(for: direct, in: value) ?? direct
        }
        guard let project = value.projects.first(where: {
            $0.aliases.contains(key) || $0.repositoryFingerprint == key
        }) else { return nil }
        return terminalTarget(for: project.id, in: value) ?? project.id
    }
}

public enum TinyBuddyProjectDiscoveryReconciler {
    /// Imports all valid observations. Availability is changed only after a
    /// complete scanner success; partial results preserve every unseen project.
    public static func reconcile(
        _ manifest: TinyBuddyProjectDiscoveryManifest,
        registry: TinyBuddyProjectRegistry,
        completeScan: Bool,
        at date: Date
    ) -> TinyBuddyProjectDiscoveryReconciliation? {
        let token = registry.beginScan()
        var observedIDs = Set<TinyBuddyProjectID>()
        for observation in manifest.observations {
            switch registry.observe(observation, token: token) {
            case .resolved(let project):
                observedIDs.insert(project.id)
            case .ignoredStale, .rejectedInvalid, .persistenceFailed:
                return nil
            }
        }
        if completeScan {
            guard case .saved = registry.finishSuccessfulScan(
                token: token,
                observedProjectIDs: observedIDs,
                at: date
            ) else { return nil }
        }
        return TinyBuddyProjectDiscoveryReconciliation(
            observedProjectIDs: observedIDs,
            didCompleteAvailabilityReconciliation: completeScan
        )
    }
}
