import Foundation
import XCTest
@testable import TinyBuddyCore

private final class ProjectRegistryMemoryStore: TinyBuddyProjectRegistryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TinyBuddyProjectRegistrySnapshot?
    var failsSaves = false

    init(_ value: TinyBuddyProjectRegistrySnapshot? = nil) {
        self.value = value
    }

    func load() -> TinyBuddyProjectRegistrySnapshot? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func save(_ snapshot: TinyBuddyProjectRegistrySnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failsSaves else { return false }
        value = snapshot
        return true
    }
}

final class ProjectIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_752_854_400)

    func testRepositoryMoveRenameAndWorktreeResolveToOneStableProject() throws {
        let store = ProjectRegistryMemoryStore()
        let stableID = TinyBuddyProjectID(rawValue: "stable-project")
        let registry = TinyBuddyProjectRegistry(store: store, idProvider: { stableID })
        let token = registry.beginScan()

        let original = try resolved(registry.observe(observation(
            fingerprint: "roots:a1b2",
            alias: "/old/Project/.git",
            name: "Project"
        ), token: token))
        let moved = try resolved(registry.observe(observation(
            fingerprint: "roots:a1b2",
            alias: "/new/Renamed/.git",
            name: "Renamed"
        ), token: token))
        let worktree = try resolved(registry.observe(observation(
            fingerprint: "roots:a1b2",
            alias: "/new/Renamed/.git/worktrees/feature",
            name: "feature"
        ), token: token))

        XCTAssertEqual(original.id, stableID)
        XCTAssertEqual(moved.id, stableID)
        XCTAssertEqual(worktree.id, stableID)
        XCTAssertEqual(registry.currentSnapshot.projects.count, 1)
        XCTAssertEqual(registry.resolve(projectKey: "/old/Project/.git")?.id, stableID)
        XCTAssertEqual(registry.resolve(projectKey: "/new/Renamed/.git")?.id, stableID)
    }

    func testArchivedProjectDoesNotReactivateWhenObservedOrReauthorized() throws {
        let store = ProjectRegistryMemoryStore()
        let registry = TinyBuddyProjectRegistry(
            store: store,
            idProvider: { TinyBuddyProjectID(rawValue: "archived") }
        )
        let firstToken = registry.beginScan()
        let project = try resolved(registry.observe(observation(
            fingerprint: "roots:archive",
            alias: "/repo/.git",
            name: "Repo"
        ), token: firstToken))
        guard case .saved = registry.archive(id: project.id) else {
            return XCTFail("archive should save")
        }

        let reauthorizationToken = registry.beginScan()
        let observed = try resolved(registry.observe(observation(
            fingerprint: "roots:archive",
            alias: "/reauthorized/repo/.git",
            name: "Repo Again"
        ), token: reauthorizationToken))

        XCTAssertEqual(observed.state, .archived)
        XCTAssertNil(registry.automaticContext(for: project.id.rawValue))
        guard case .saved = registry.restore(id: project.id) else {
            return XCTFail("explicit restore should save")
        }
        XCTAssertNotNil(registry.automaticContext(for: project.id.rawValue))
    }

    func testSuccessfulScanDistinguishesUnavailableFromArchivedAndRemoved() throws {
        let active = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "active"),
            kind: .gitRepository,
            displayName: "Active",
            repositoryFingerprint: "roots:active",
            aliases: ["/active/.git"]
        )
        var archived = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "archived"),
            kind: .gitRepository,
            displayName: "Archived",
            repositoryFingerprint: "roots:archived",
            aliases: ["/archived/.git"]
        )
        archived.state = .archived
        var removed = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "removed"),
            kind: .gitRepository,
            displayName: "Removed",
            repositoryFingerprint: "roots:removed",
            aliases: ["/removed/.git"]
        )
        removed.state = .removed
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(
            projects: [active, archived, removed]
        ))
        let registry = TinyBuddyProjectRegistry(store: store)

        guard case .saved = registry.finishSuccessfulScan(
            token: registry.beginScan(),
            observedProjectIDs: [],
            at: now
        ) else { return XCTFail("scan reconciliation should save") }

        let byID = Dictionary(uniqueKeysWithValues: registry.currentSnapshot.projects.map { ($0.id, $0) })
        XCTAssertEqual(byID[active.id]?.state, .temporarilyUnavailable)
        XCTAssertEqual(byID[active.id]?.unavailableSince, now)
        XCTAssertEqual(byID[archived.id]?.state, .archived)
        XCTAssertEqual(byID[removed.id]?.state, .removed)
    }

    func testPermissionFailureMarksOnlyProjectsUnderUnavailableAuthorization() {
        let first = project(id: "first", name: "First", alias: "/authorized-a/first/.git")
        let second = project(id: "second", name: "Second", alias: "/authorized-b/second/.git")
        let registry = TinyBuddyProjectRegistry(store: ProjectRegistryMemoryStore(
            TinyBuddyProjectRegistrySnapshot(projects: [first, second])
        ))

        guard case .saved = registry.markTemporarilyUnavailable(
            aliasPrefixes: ["/authorized-a"],
            at: now
        ) else { return XCTFail("availability update should save") }

        XCTAssertEqual(registry.resolve(id: first.id)?.state, .temporarilyUnavailable)
        XCTAssertEqual(registry.resolve(id: second.id)?.state, .active)
    }

    func testMergePreviewPreservesStatisticsAndUndoRestoresIdentities() throws {
        let target = project(id: "target", name: "Canonical", alias: "/new/.git")
        let duplicate = project(id: "duplicate", name: "Legacy", alias: "/old/.git")
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(
            projects: [target, duplicate]
        ))
        let registry = TinyBuddyProjectRegistry(store: store)
        let sessions = [
            endedSession(projectKey: "/new/.git", minutes: 30, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            endedSession(projectKey: "/old/.git", minutes: 45, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        ]
        let preview = try XCTUnwrap(registry.previewMerge(
            targetID: target.id,
            sourceIDs: [duplicate.id],
            sessions: sessions,
            now: now
        ))
        XCTAssertEqual(preview.affectedSessionCount, 2)
        XCTAssertEqual(preview.preservedFocusDuration, 75 * 60, accuracy: 0.001)

        let undo: TinyBuddyProjectMergeUndo
        switch registry.merge(preview) {
        case .saved(_, let token): undo = token
        default: return XCTFail("merge should save")
        }
        XCTAssertEqual(registry.resolve(projectKey: "/old/.git")?.id, target.id)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == duplicate.id }?.state, .removed)

        guard case .saved = registry.undoMerge(undo) else {
            return XCTFail("undo should save")
        }
        XCTAssertEqual(registry.resolve(projectKey: "/old/.git")?.id, duplicate.id)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == duplicate.id }?.state, .active)
    }

    func testDelayedScanCannotRecreateMergedIdentity() throws {
        let target = project(id: "target", name: "Canonical", alias: "/new/.git")
        let duplicate = project(id: "duplicate", name: "Legacy", alias: "/old/.git")
        let registry = TinyBuddyProjectRegistry(store: ProjectRegistryMemoryStore(
            TinyBuddyProjectRegistrySnapshot(projects: [target, duplicate])
        ))
        let staleToken = registry.beginScan()
        let preview = try XCTUnwrap(registry.previewMerge(
            targetID: target.id,
            sourceIDs: [duplicate.id],
            sessions: [],
            now: now
        ))
        guard case .saved = registry.merge(preview) else { return XCTFail("merge should save") }

        XCTAssertEqual(registry.observe(observation(
            fingerprint: "roots:shared",
            alias: "/old/.git",
            name: "Legacy"
        ), token: staleToken), .ignoredStale)
        XCTAssertEqual(registry.currentSnapshot.projects.count, 2)
        XCTAssertEqual(registry.resolve(projectKey: "/old/.git")?.id, target.id)
    }

    func testFailedPersistenceLeavesRegistryAndStatisticsUnchanged() throws {
        let target = project(id: "target", name: "Canonical", alias: "/new/.git")
        let duplicate = project(id: "duplicate", name: "Legacy", alias: "/old/.git")
        let initial = TinyBuddyProjectRegistrySnapshot(projects: [target, duplicate])
        let store = ProjectRegistryMemoryStore(initial)
        let registry = TinyBuddyProjectRegistry(store: store)
        let sessions = [endedSession(projectKey: "/old/.git", minutes: 20, id: UUID())]
        let preview = try XCTUnwrap(registry.previewMerge(
            targetID: target.id,
            sourceIDs: [duplicate.id],
            sessions: sessions,
            now: now
        ))
        store.failsSaves = true

        XCTAssertEqual(registry.merge(preview), .persistenceFailed)
        XCTAssertEqual(registry.currentSnapshot, initial)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.activeDuration(now: now) }, 20 * 60, accuracy: 0.001)
    }

    func testHistoryResolverCombinesLegacyAliasesWithoutDoubleCounting() throws {
        let target = project(id: "target", name: "Canonical", alias: "/new/.git")
        let duplicate = project(id: "duplicate", name: "Legacy", alias: "/old/.git")
        let registry = TinyBuddyProjectRegistry(store: ProjectRegistryMemoryStore(
            TinyBuddyProjectRegistrySnapshot(
                revision: 1,
                generation: 1,
                projects: [target, duplicate],
                redirects: [duplicate.id: target.id]
            )
        ))
        let sessions = [
            endedSession(projectKey: "/new/.git", minutes: 30, id: UUID()),
            endedSession(projectKey: "/old/.git", minutes: 45, id: UUID())
        ]
        let cache = FocusHistoryAggregationCache(
            sessions: sessions,
            projectResolver: { context in
                guard let resolved = registry.resolve(projectKey: context.key) else { return context }
                return FocusProjectContext(key: resolved.id.rawValue, displayName: resolved.displayName)
            }
        )
        let snapshot = try cache.snapshot(for: FocusHistoryQuery(
            referenceDayIdentifier: "2025-07-18",
            source: FocusHistorySource(health: .available),
            activeProjectKeys: [target.id.rawValue],
            defaultDailyGoalMinutes: 60
        ))

        let distribution = try XCTUnwrap(snapshot.currentWeek.projectDistribution)
        XCTAssertEqual(distribution.count, 1)
        XCTAssertEqual(distribution[0].displayName, "Canonical")
        XCTAssertEqual(distribution[0].focusDuration, 75 * 60, accuracy: 0.001)
        XCTAssertEqual(distribution[0].completedSessionCount, 2)
    }

    func testDiscoveryManifestRejectsPartialRowsAndReconcilesPartialScanWithoutRemoval() throws {
        let suite = "ProjectDiscoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let encode: (String) -> String = { Data($0.utf8).base64EncodedString() }
        defaults.set(
            "v1\n\(encode("git-roots:abc"))\t\(encode("/moved/.git"))\t\(encode("Moved"))\n",
            forKey: TinyBuddyProjectDiscoveryStore.Key.manifest
        )
        let discovery = TinyBuddyProjectDiscoveryStore(
            userDefaults: defaults,
            dateProvider: { self.now }
        )
        let manifest = try XCTUnwrap(discovery.loadManifest())
        XCTAssertEqual(manifest.observations.count, 1)

        let missing = project(id: "missing", name: "Offline", alias: "/offline/.git")
        let registry = TinyBuddyProjectRegistry(store: ProjectRegistryMemoryStore(
            TinyBuddyProjectRegistrySnapshot(projects: [missing])
        ))
        let reconciliation = try XCTUnwrap(TinyBuddyProjectDiscoveryReconciler.reconcile(
            manifest,
            registry: registry,
            completeScan: false,
            at: now
        ))
        XCTAssertFalse(reconciliation.didCompleteAvailabilityReconciliation)
        XCTAssertEqual(registry.resolve(id: missing.id)?.state, .active)

        defaults.set("v1\nnot-base64\tbroken", forKey: TinyBuddyProjectDiscoveryStore.Key.manifest)
        XCTAssertNil(discovery.loadManifest())
    }

    func testFileStorePublishesWholeRegistryAndRecoversPreviousSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectRegistryTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("registry.json")
        let store = TinyBuddyProjectRegistryFileStore(fileURL: url)
        let first = TinyBuddyProjectRegistrySnapshot(projects: [
            project(id: "first", name: "First", alias: "/first/.git")
        ])
        let second = TinyBuddyProjectRegistrySnapshot(
            revision: 1,
            generation: 1,
            projects: [project(id: "second", name: "Second", alias: "/second/.git")]
        )

        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))
        XCTAssertEqual(store.load(), second)

        try Data("corrupt".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(store.load(), first)
    }

    private func observation(
        fingerprint: String,
        alias: String,
        name: String
    ) -> TinyBuddyGitProjectObservation {
        TinyBuddyGitProjectObservation(
            repositoryFingerprint: fingerprint,
            repositoryAlias: alias,
            suggestedDisplayName: name,
            observedAt: now
        )
    }

    private func resolved(
        _ result: TinyBuddyProjectObservationResult
    ) throws -> TinyBuddyProject {
        guard case .resolved(let project) = result else {
            throw NSError(domain: "ProjectIdentityTests", code: 1)
        }
        return project
    }

    private func project(id: String, name: String, alias: String) -> TinyBuddyProject {
        TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: id),
            kind: .gitRepository,
            displayName: name,
            repositoryFingerprint: "roots:shared",
            aliases: [alias]
        )
    }

    private func endedSession(projectKey: String, minutes: Int, id: UUID) -> FocusSession {
        let end = now
        let start = end.addingTimeInterval(TimeInterval(-minutes * 60))
        return FocusSession(
            id: id,
            project: FocusProjectContext(key: projectKey, displayName: projectKey),
            dayIdentifier: "2025-07-18",
            startedAt: start,
            endedAt: end,
            status: .ended,
            lastUserActivityAt: end,
            lastStateChangeAt: end
        )
    }
}
