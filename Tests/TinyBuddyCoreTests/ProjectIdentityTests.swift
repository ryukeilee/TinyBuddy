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

    func testFileStoreKeepsValidBackupWhenPrimaryIsCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectRegistryBackupTests.\(UUID().uuidString)", isDirectory: true)
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

        // Primary becomes unreadable. Load falls back to the backup (first).
        try Data("corrupt".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(store.load(), first)

        // A later save must not copy the corrupt primary over the only good
        // backup; otherwise a second corruption would destroy every copy.
        let third = TinyBuddyProjectRegistrySnapshot(
            revision: 2,
            generation: 2,
            projects: [project(id: "third", name: "Third", alias: "/third/.git")]
        )
        XCTAssertTrue(store.save(third))
        try Data("corrupt-again".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(store.load(), first)
    }

    func testFileStoreRejectsRedirectLoopSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectRegistryLoopTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("registry.json")
        let store = TinyBuddyProjectRegistryFileStore(fileURL: url)
        let loop = TinyBuddyProjectRegistrySnapshot(
            projects: [
                project(id: "a", name: "A", alias: "/a/.git"),
                project(id: "b", name: "B", alias: "/b/.git")
            ],
            redirects: [
                TinyBuddyProjectID(rawValue: "a"): TinyBuddyProjectID(rawValue: "b"),
                TinyBuddyProjectID(rawValue: "b"): TinyBuddyProjectID(rawValue: "a")
            ]
        )
        XCTAssertFalse(loop.isSemanticallyValid)
        XCTAssertFalse(store.save(loop))
        XCTAssertNil(store.load())
    }

    func testCaseOnlyRenameAndReferenceResolveToOneStableProject() throws {
        let store = ProjectRegistryMemoryStore()
        let stableID = TinyBuddyProjectID(rawValue: "case-stable")
        let registry = TinyBuddyProjectRegistry(store: store, idProvider: { stableID })
        let token = registry.beginScan()

        let original = try resolved(registry.observe(observation(
            fingerprint: "git-roots:abc",
            alias: "/Users/Me/Repo/.git",
            name: "Repo"
        ), token: token))
        // A case-only rename on a case-insensitive volume changes the alias
        // string but not the repository. Both resolution paths must still
        // land on the single durable identity.
        XCTAssertEqual(registry.resolve(projectKey: "/USERS/me/REPO/.GIT")?.id, stableID)
        XCTAssertEqual(registry.resolve(projectKey: "GIT-ROOTS:ABC")?.id, stableID)

        let renamed = try resolved(registry.observe(observation(
            fingerprint: "git-roots:abc",
            alias: "/Users/Me/Repo/.GIT",
            name: "Repo"
        ), token: token))
        XCTAssertEqual(renamed.id, stableID)
        XCTAssertEqual(registry.currentSnapshot.projects.count, 1)
        XCTAssertEqual(original.id, renamed.id)
    }

    func testCaseFoldedResolutionFallsBackForLegacyReferences() throws {
        // Observation matching stays case-exact, so read-side resolution folds
        // case only as a fallback: stale references recorded before a case-only
        // rename still land on the durable identity, while exact-case keys are
        // never crossed.
        let first = project(id: "legacy", name: "Legacy", alias: "/OLD/Path/.git")
        var second = project(id: "current", name: "Current", alias: "/new/path/.git")
        second.repositoryFingerprint = "git-roots:shared"
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(projects: [first, second]))
        let registry = TinyBuddyProjectRegistry(store: store)

        XCTAssertEqual(registry.resolve(projectKey: "/OLD/Path/.git")?.id, first.id)
        XCTAssertEqual(registry.resolve(projectKey: "/new/path/.git")?.id, second.id)
        // Folded fallback resolves the stale different-case reference that has
        // no exact counterpart anywhere in the registry.
        XCTAssertEqual(registry.resolve(projectKey: "/new/PATH/.GIT")?.id, second.id)
        XCTAssertEqual(registry.resolve(projectKey: "GIT-ROOTS:SHARED")?.id, second.id)

        // An observation with a different-case alias and the shared fingerprint
        // consolidates into the fingerprint owner instead of minting a third
        // identity; the unrelated legacy row is left untouched.
        let token = registry.beginScan()
        let resolved = try resolved(registry.observe(observation(
            fingerprint: "git-roots:shared",
            alias: "/new/PATH/.GIT",
            name: "Current"
        ), token: token))
        XCTAssertEqual(resolved.id, second.id)
        XCTAssertTrue(registry.currentSnapshot.projects
            .first { $0.id == second.id }?.aliases.contains("/new/PATH/.GIT") == true)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == first.id }?.state, .active)
    }

    func testCaseTwinAliasesOnCaseSensitiveVolumeStayDistinct() throws {
        // /Repo and /repo are genuinely different repositories that can coexist
        // on a case-sensitive volume. Observation must never fold their aliases
        // together, and resolution must prefer the exact-case row.
        let upper = project(id: "upper", name: "Upper", alias: "/Repo/.git")
        var lower = project(id: "lower", name: "Lower", alias: "/repo/.git")
        lower.repositoryFingerprint = "git-roots:lower"
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(projects: [upper, lower]))
        let registry = TinyBuddyProjectRegistry(store: store)
        let token = registry.beginScan()

        let upperResolved = try resolved(registry.observe(observation(
            fingerprint: "git-roots:upper",
            alias: "/Repo/.git",
            name: "Upper"
        ), token: token))
        XCTAssertEqual(upperResolved.id, upper.id)
        // Neither row was merged into the other.
        XCTAssertEqual(registry.currentSnapshot.projects.filter { $0.state != .removed }.count, 2)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == upper.id }?.state, .active)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == lower.id }?.state, .active)
        XCTAssertEqual(registry.resolve(projectKey: "/Repo/.git")?.id, upper.id)
        XCTAssertEqual(registry.resolve(projectKey: "/repo/.git")?.id, lower.id)
    }

    func testAutoMergeConsolidatesDuplicateGroupsAndPreservesHistory() throws {
        // The policy target is deterministic: active, then customized name,
        // then smallest stable ID — so "a-canonical" wins over "b-legacy".
        let target = project(id: "a-canonical", name: "Canonical", alias: "/canonical/.git")
        var duplicate = project(id: "b-legacy", name: "Legacy", alias: "/legacy/.git")
        duplicate.repositoryFingerprint = "ROOTS:SHARED" // case differs on purpose
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(projects: [target, duplicate]))
        let registry = TinyBuddyProjectRegistry(store: store)

        let undo: TinyBuddyProjectMergeUndo?
        switch registry.autoMergeDuplicates() {
        case .completed(let count, let token):
            XCTAssertEqual(count, 1)
            undo = token
        case .persistenceFailed:
            return XCTFail("auto-merge should persist")
        }

        // The merged-out row stays as a tombstone; one identity is active.
        XCTAssertEqual(registry.currentSnapshot.projects.count, 2)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == target.id }?.state, .active)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == duplicate.id }?.state, .removed)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == target.id }?.aliases.count, 2)
        XCTAssertEqual(registry.resolve(projectKey: "/legacy/.git")?.id, target.id)
        XCTAssertEqual(registry.resolve(projectKey: "roots:shared")?.id, target.id)
        XCTAssertEqual(registry.resolve(projectKey: "ROOTS:SHARED")?.id, target.id)

        // Repeated passes are no-ops once consolidated.
        guard case .completed(0, _) = registry.autoMergeDuplicates() else {
            return XCTFail("second auto-merge pass should be a no-op")
        }

        guard let undo else { return XCTFail("undo token missing") }
        guard case .saved = registry.undoMerge(undo) else {
            return XCTFail("auto-merge undo should save")
        }
        XCTAssertEqual(registry.currentSnapshot.projects.count, 2)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == duplicate.id }?.state, .active)
        XCTAssertEqual(registry.resolve(projectKey: "/legacy/.git")?.id, duplicate.id)
    }

    func testAutoMergePrefersActiveTargetAndSkipsArchivedGroups() throws {
        var unavailable = project(id: "unavailable", name: "Unavailable", alias: "/unavailable/.git")
        unavailable.state = .temporarilyUnavailable
        unavailable.repositoryFingerprint = "roots:same"
        var active = project(id: "active", name: "Active", alias: "/active/.git")
        active.repositoryFingerprint = "roots:same"
        var archived = project(id: "archived", name: "Archived", alias: "/archived/.git")
        archived.state = .archived
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(projects: [
            unavailable, active, archived
        ]))
        let registry = TinyBuddyProjectRegistry(store: store)

        // The archived member makes its group ineligible; only the active/
        // unavailable pair merges, preferring the active project as target.
        guard case .completed(let count, _) = registry.autoMergeDuplicates(),
              count == 1 else {
            return XCTFail("expected exactly one eligible merge")
        }
        let byID = Dictionary(uniqueKeysWithValues: registry.currentSnapshot.projects.map { ($0.id, $0) })
        XCTAssertEqual(byID[active.id]?.state, .active)
        XCTAssertEqual(byID[unavailable.id]?.state, .removed)
        XCTAssertEqual(byID[archived.id]?.state, .archived)
        XCTAssertEqual(registry.resolve(id: unavailable.id)?.id, active.id)
    }

    func testAutoMergeSkipsEntirelyArchivedGroup() throws {
        var archivedTarget = project(id: "archived-target", name: "Archived Target", alias: "/at/.git")
        archivedTarget.state = .archived
        var archivedSource = project(id: "archived-source", name: "Archived Source", alias: "/as/.git")
        archivedSource.state = .archived
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(projects: [
            archivedTarget, archivedSource
        ]))
        let registry = TinyBuddyProjectRegistry(store: store)

        guard case .completed(0, _) = registry.autoMergeDuplicates() else {
            return XCTFail("archived group must not be merged automatically")
        }
        XCTAssertEqual(registry.currentSnapshot.projects.count, 2)
        XCTAssertEqual(registry.resolve(projectKey: "/as/.git")?.id, archivedSource.id)
    }

    func testAutoMergePersistenceFailureLeavesRegistryUnchanged() throws {
        let target = project(id: "target", name: "Canonical", alias: "/canonical/.git")
        let duplicate = project(id: "duplicate", name: "Legacy", alias: "/legacy/.git")
        let initial = TinyBuddyProjectRegistrySnapshot(projects: [target, duplicate])
        let store = ProjectRegistryMemoryStore(initial)
        let registry = TinyBuddyProjectRegistry(store: store)
        store.failsSaves = true

        XCTAssertEqual(registry.autoMergeDuplicates(), .persistenceFailed)
        XCTAssertEqual(registry.currentSnapshot, initial)
        XCTAssertEqual(registry.resolve(projectKey: "/legacy/.git")?.id, duplicate.id)
    }

    func testAutoMergeKeepsRecentProjectResolvableThroughRedirect() throws {
        let target = project(id: "a-target", name: "Canonical", alias: "/canonical/.git")
        let duplicate = project(id: "b-duplicate", name: "Legacy", alias: "/legacy/.git")
        let registry = TinyBuddyProjectRegistry(store: ProjectRegistryMemoryStore(
            TinyBuddyProjectRegistrySnapshot(projects: [target, duplicate])
        ))
        guard case .completed(1, _) = registry.autoMergeDuplicates() else {
            return XCTFail("auto-merge should merge")
        }

        // The recent-project store may still hold the duplicate's ID from
        // before the merge; resolving it must land on the canonical project.
        XCTAssertEqual(registry.resolve(id: duplicate.id)?.id, target.id)
        XCTAssertEqual(registry.automaticContext(for: duplicate.id.rawValue)?.key, target.id.rawValue)
    }

    func testObservationNeverMergesArchivedProjectAsSource() throws {
        // The archived project's old path is taken over by a different
        // repository.  An observation of the new repository must resolve to
        // its own identity without silently tombstoning the archived row and
        // routing its future observations through an active identity.
        var archived = project(id: "archived", name: "Legacy Repo", alias: "/old/.git")
        archived.state = .archived
        archived.repositoryFingerprint = "roots:legacy"
        let active = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "active"),
            kind: .gitRepository,
            displayName: "Current Repo",
            repositoryFingerprint: "roots:current",
            aliases: ["/current/.git"]
        )
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(
            projects: [archived, active]
        ))
        let registry = TinyBuddyProjectRegistry(store: store)
        let token = registry.beginScan()

        // The current repo now lives at the archived repo's old path.
        let observed = try resolved(registry.observe(observation(
            fingerprint: "roots:current",
            alias: "/old/.git",
            name: "Current Repo"
        ), token: token))
        XCTAssertEqual(observed.id, active.id)
        XCTAssertEqual(registry.currentSnapshot.projects.count, 2,
                       "the archived identity must not be merged away")
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == archived.id }?.state, .archived)
        XCTAssertEqual(registry.currentSnapshot.redirects.count, 0)
        XCTAssertEqual(registry.resolve(projectKey: "roots:current")?.id, active.id)
        XCTAssertEqual(registry.resolve(projectKey: "roots:legacy")?.id, archived.id)
        XCTAssertNil(registry.automaticContext(for: archived.id.rawValue))
        XCTAssertNotNil(registry.automaticContext(for: active.id.rawValue))

        // When the archived repository returns to its old path, it resolves
        // back to the archived identity (never re-activated, never merged
        // into the active row), and the active row stays intact.
        let returnToken = registry.beginScan()
        let returned = try resolved(registry.observe(observation(
            fingerprint: "roots:legacy",
            alias: "/old/.git",
            name: "Legacy Repo"
        ), token: returnToken))
        XCTAssertEqual(returned.id, archived.id)
        XCTAssertEqual(returned.state, .archived)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == active.id }?.state, .active)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == active.id }?.repositoryFingerprint, "roots:current")
    }

    func testObservationKeepsDistinctActiveRepositoriesSharingOnePath() throws {
        // Without any archive involvement, two different repositories that
        // claimed the same path at different times must not be folded into
        // one identity by an alias match; their fingerprints differ.
        let first = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "first"),
            kind: .gitRepository,
            displayName: "First",
            repositoryFingerprint: "roots:first",
            aliases: ["/shared/.git"]
        )
        let second = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "second"),
            kind: .gitRepository,
            displayName: "Second",
            repositoryFingerprint: "roots:second",
            aliases: ["/elsewhere/.git"]
        )
        let store = ProjectRegistryMemoryStore(TinyBuddyProjectRegistrySnapshot(
            projects: [first, second]
        ))
        let registry = TinyBuddyProjectRegistry(store: store)
        let token = registry.beginScan()

        // Second moved into the path first used by First.
        let secondObserved = try resolved(registry.observe(observation(
            fingerprint: "roots:second",
            alias: "/shared/.git",
            name: "Second"
        ), token: token))
        XCTAssertEqual(secondObserved.id, second.id)
        XCTAssertEqual(registry.currentSnapshot.projects.count, 2)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == first.id }?.state, .active)
        XCTAssertEqual(registry.currentSnapshot.projects.first { $0.id == first.id }?.repositoryFingerprint, "roots:first")
        XCTAssertEqual(registry.currentSnapshot.redirects.count, 0)

        // First's own re-observation still lands on First.
        let secondToken = registry.beginScan()
        let firstAgain = try resolved(registry.observe(observation(
            fingerprint: "roots:first",
            alias: "/moved/.git",
            name: "First"
        ), token: secondToken))
        XCTAssertEqual(firstAgain.id, first.id)
        XCTAssertEqual(registry.currentSnapshot.projects.count, 2)
        XCTAssertEqual(registry.resolve(projectKey: "roots:first")?.id, first.id)
        XCTAssertEqual(registry.resolve(projectKey: "roots:second")?.id, second.id)
    }

    func testCompleteReconciliationFinishesAfterObservationRepairsDuplicateIdentity() throws {
        let canonical = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "canonical"),
            kind: .gitRepository,
            displayName: "Canonical",
            repositoryFingerprint: "roots:shared",
            aliases: ["/canonical/.git"]
        )
        let legacy = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "legacy"),
            kind: .gitRepository,
            displayName: "Legacy",
            repositoryFingerprint: nil,
            aliases: ["/legacy/.git"]
        )
        let missing = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "missing"),
            kind: .gitRepository,
            displayName: "Missing",
            repositoryFingerprint: "roots:missing",
            aliases: ["/missing/.git"]
        )
        let registry = TinyBuddyProjectRegistry(store: ProjectRegistryMemoryStore(
            TinyBuddyProjectRegistrySnapshot(projects: [canonical, legacy, missing])
        ))
        let manifest = TinyBuddyProjectDiscoveryManifest(observations: [observation(
            fingerprint: "roots:shared",
            alias: "/legacy/.git",
            name: "Canonical"
        )])

        let reconciliation = try XCTUnwrap(TinyBuddyProjectDiscoveryReconciler.reconcile(
            manifest,
            registry: registry,
            completeScan: true,
            at: now
        ))

        XCTAssertTrue(reconciliation.didCompleteAvailabilityReconciliation)
        XCTAssertEqual(reconciliation.observedProjectIDs, Set([canonical.id]))
        XCTAssertEqual(registry.resolve(id: legacy.id)?.id, canonical.id)
        XCTAssertEqual(
            registry.currentSnapshot.projects.first { $0.id == legacy.id }?.state,
            .removed
        )
        XCTAssertEqual(registry.resolve(id: missing.id)?.state, .temporarilyUnavailable)
    }

    func testRestoreReconnectsLatestIdentityAndAttribution() throws {
        let store = ProjectRegistryMemoryStore()
        let stableID = TinyBuddyProjectID(rawValue: "stable")
        let registry = TinyBuddyProjectRegistry(store: store, idProvider: { stableID })
        let token = registry.beginScan()

        let project = try resolved(registry.observe(observation(
            fingerprint: "roots:repo",
            alias: "/repo/.git",
            name: "Repo"
        ), token: token))
        guard case .saved = registry.archive(id: project.id) else {
            return XCTFail("archive should save")
        }
        XCTAssertNil(registry.automaticContext(for: project.id.rawValue))

        // A scan started before the archive must not re-activate the project.
        let staleToken = registry.beginScan()
        guard case .saved = registry.restore(id: project.id) else {
            return XCTFail("restore should save")
        }
        XCTAssertNotNil(registry.automaticContext(for: project.id.rawValue))
        XCTAssertEqual(registry.observe(observation(
            fingerprint: "roots:repo",
            alias: "/repo/.git",
            name: "Repo"
        ), token: staleToken), .ignoredStale)

        // A fresh scan after restore refreshes identity evidence and keeps the
        // project active; automatic attribution resolves to the canonical id
        // and the latest display name.
        let freshToken = registry.beginScan()
        let refreshed = try resolved(registry.observe(observation(
            fingerprint: "roots:repo",
            alias: "/moved/repo/.git",
            name: "Repo"
        ), token: freshToken))
        XCTAssertEqual(refreshed.state, .active)
        XCTAssertTrue(refreshed.aliases.contains("/moved/repo/.git"))
        XCTAssertEqual(registry.automaticContext(for: "roots:repo")?.key, stableID.rawValue)
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
