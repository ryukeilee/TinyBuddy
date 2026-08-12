import Foundation
@testable import TinyBuddyCore
import XCTest

final class GitActivityRealRepositoryFixtureTests: XCTestCase {
    func testPublishesDevelopmentInterruptionSceneWithoutRepositoryPath() throws {
        let fixture = try RealGitFixture()
        let repository = try fixture.makeRepository(named: "ResumeProject")
        try fixture.git(
            in: repository,
            ["checkout", "-b", "feature/resume"],
            environment: fixture.gitDateEnvironment("2024-01-15T09:00:00Z")
        )
        try fixture.commit(
            in: repository,
            file: "tracked.txt",
            contents: "committed\n",
            message: "Build interruption resume",
            date: "2024-01-15T09:30:00Z"
        )
        try "changed\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "staged\n".write(
            to: repository.appendingPathComponent("staged.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.git(in: repository, ["add", "staged.txt"])
        try "new\n".write(
            to: repository.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = try fixture.runScript(
            scanRoots: [fixture.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_EPOCH": "1705316400"]
        )
        let plist = try fixture.readPreferencesPlist()
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertNotNil(
            plist[DevelopmentInterruptionSnapshotStore.Key.snapshot],
            "Missing interruption snapshot; keys: \(plist.keys.sorted()); stderr: \(result.standardError)"
        )
        let encoded = try XCTUnwrap(
            plist[DevelopmentInterruptionSnapshotStore.Key.snapshot] as? String
        )
        let snapshot = try XCTUnwrap(DevelopmentInterruptionSnapshotStore.decode(encoded))

        XCTAssertEqual(snapshot.repositoryName, "ResumeProject")
        XCTAssertEqual(snapshot.branchName, "feature/resume")
        XCTAssertEqual(snapshot.workingTree.stagedCount, 1)
        XCTAssertEqual(snapshot.workingTree.modifiedCount, 1)
        XCTAssertEqual(snapshot.workingTree.untrackedCount, 1)
        XCTAssertEqual(snapshot.workingTree.conflictedCount, 0)
        XCTAssertEqual(snapshot.recentCommit?.subject, "Build interruption resume")
        XCTAssertFalse(encoded.contains(repository.path))

        let unchangedResult = try fixture.runScript(
            scanRoots: [fixture.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_EPOCH": "1705320000"]
        )
        let unchangedEncoded = try XCTUnwrap(
            (try fixture.readPreferencesPlist())[DevelopmentInterruptionSnapshotStore.Key.snapshot]
                as? String
        )
        let unchanged = try XCTUnwrap(
            DevelopmentInterruptionSnapshotStore.decode(unchangedEncoded)
        )
        XCTAssertEqual(unchangedResult.exitCode, 0, unchangedResult.standardError)
        XCTAssertEqual(unchanged.lastActivityAt, snapshot.lastActivityAt)

        try fixture.git(in: repository, ["add", "untracked.txt"])
        let changedResult = try fixture.runScript(
            scanRoots: [fixture.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_EPOCH": "1705323600"]
        )
        let changedEncoded = try XCTUnwrap(
            (try fixture.readPreferencesPlist())[DevelopmentInterruptionSnapshotStore.Key.snapshot]
                as? String
        )
        let changed = try XCTUnwrap(
            DevelopmentInterruptionSnapshotStore.decode(changedEncoded)
        )
        XCTAssertEqual(changedResult.exitCode, 0, changedResult.standardError)
        XCTAssertEqual(changed.workingTree.stagedCount, 2)
        XCTAssertEqual(changed.workingTree.untrackedCount, 0)
        XCTAssertEqual(changed.lastActivityAt, Date(timeIntervalSince1970: 1_705_323_600))
    }

    func testProjectDiscoveryFingerprintSurvivesRepositoryMoveAndRename() throws {
        let fixture = try RealGitFixture()
        let original = try fixture.makeRepository(named: "IdentityBefore")
        try fixture.commit(
            in: original,
            file: "identity.txt",
            contents: "stable\n",
            message: "identity root",
            date: "2024-01-15T09:05:00Z"
        )

        let first = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        XCTAssertEqual(first.exitCode, 0, first.standardError)
        let firstManifest = try discoveryRows(from: fixture.readPreferencesPlist())
        XCTAssertEqual(firstManifest.count, 1)

        let moved = fixture.scanRootURL.appendingPathComponent("IdentityAfter", isDirectory: true)
        try fixture.fileManager.moveItem(at: original, to: moved)
        let second = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        XCTAssertEqual(second.exitCode, 0, second.standardError)
        let secondManifest = try discoveryRows(from: fixture.readPreferencesPlist())

        XCTAssertEqual(secondManifest.count, 1)
        XCTAssertEqual(secondManifest[0].fingerprint, firstManifest[0].fingerprint)
        XCTAssertNotEqual(secondManifest[0].alias, firstManifest[0].alias)
        XCTAssertEqual(secondManifest[0].name, "IdentityAfter")
    }

    func testCanonicalRepositoryIdentityDeduplicatesWorktreesSymlinkRootsAndRepeatedRoots() throws {
        let fixture = try RealGitFixture()
        let repository = try fixture.makeRepository(named: "ProjectAlpha")
        try fixture.commit(
            in: repository,
            file: "main.txt",
            contents: "main\n",
            message: "main work",
            date: "2024-01-15T09:05:00Z"
        )

        let worktree = fixture.scanRootURL.appendingPathComponent("ProjectAlpha-feature", isDirectory: true)
        try fixture.git(
            in: repository,
            ["worktree", "add", "-b", "feature", worktree.path, "HEAD"]
        )
        try fixture.commit(
            in: worktree,
            file: "feature.txt",
            contents: "feature\n",
            message: "feature work",
            date: "2024-01-15T09:35:00Z"
        )

        let secondWorktree = fixture.scanRootURL.appendingPathComponent(
            "ProjectAlpha-review",
            isDirectory: true
        )
        try fixture.git(
            in: repository,
            ["worktree", "add", "-b", "review", secondWorktree.path, "HEAD"]
        )
        try fixture.commit(
            in: secondWorktree,
            file: "review.txt",
            contents: "review\n",
            message: "review work",
            date: "2024-01-15T10:05:00Z"
        )

        let symlinkRoot = fixture.rootURL.appendingPathComponent("scan-root-link", isDirectory: true)
        try fixture.fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: fixture.scanRootURL)

        let first = try fixture.runScript(
            scanRoots: [fixture.scanRootURL, symlinkRoot, fixture.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_EPOCH": "1705316400"]
        )
        XCTAssertEqual(first.exitCode, 0, first.standardError)
        let firstPlist = try fixture.readPreferencesPlist()
        let firstMetrics = try XCTUnwrap(fixture.metrics(from: first.standardOutput))
        let firstSnapshot = try XCTUnwrap(
            firstPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )

        XCTAssertEqual(firstMetrics["authorized_root_count"], "1")
        XCTAssertEqual(firstMetrics["repository_count"], "1")
        XCTAssertEqual(firstPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 3)
        XCTAssertEqual(firstPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 3)
        XCTAssertEqual(
            firstPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "ProjectAlpha"
        )
        let firstInterruptionPayload = try XCTUnwrap(
            firstPlist[DevelopmentInterruptionSnapshotStore.Key.snapshot] as? String
        )
        let firstInterruption = try XCTUnwrap(
            DevelopmentInterruptionSnapshotStore.decode(firstInterruptionPayload)
        )
        XCTAssertEqual(firstInterruption.branchName, "review")
        XCTAssertEqual(firstInterruption.recentCommit?.subject, "review work")

        let repeated = try fixture.runScript(
            scanRoots: [symlinkRoot, fixture.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_EPOCH": "1705320000"]
        )
        let repeatedPlist = try fixture.readPreferencesPlist()
        let repeatedMetrics = try XCTUnwrap(fixture.metrics(from: repeated.standardOutput))

        XCTAssertEqual(repeated.exitCode, 0, repeated.standardError)
        XCTAssertEqual(repeatedMetrics["repository_count"], "1")
        XCTAssertEqual(repeatedMetrics["reflog_unchanged_skip_count"], "3")
        XCTAssertEqual(repeatedMetrics["shared_data_written"], "0")
        XCTAssertEqual(
            repeatedPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String,
            firstSnapshot
        )

        let nextDay = try fixture.runScript(
            scanRoots: [fixture.scanRootURL],
            extraEnvironment: [
                "TINYBUDDY_TODAY": "2024-01-16",
                "TINYBUDDY_REFRESH_EPOCH": "1705402800"
            ]
        )
        XCTAssertEqual(nextDay.exitCode, 0, nextDay.standardError)
        let nextDayPayload = try XCTUnwrap(
            (try fixture.readPreferencesPlist())[
                DevelopmentInterruptionSnapshotStore.Key.snapshot
            ] as? String
        )
        let nextDayInterruption = try XCTUnwrap(
            DevelopmentInterruptionSnapshotStore.decode(nextDayPayload)
        )
        XCTAssertEqual(nextDayInterruption.branchName, "review")
        XCTAssertEqual(nextDayInterruption.recentCommit?.subject, "review work")
        XCTAssertEqual(nextDayInterruption.lastActivityAt, firstInterruption.lastActivityAt)
    }

    private func discoveryRows(
        from plist: [String: Any]
    ) throws -> [(fingerprint: String, alias: String, name: String)] {
        let payload = try XCTUnwrap(
            plist[TinyBuddyProjectDiscoveryStore.Key.manifest] as? String
        )
        let lines = payload.split(separator: "\n")
        XCTAssertEqual(lines.first, "v1")
        return try lines.dropFirst().map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                throw NSError(domain: "GitActivityRealRepositoryFixtureTests", code: 1)
            }
            let values = try fields.map { field -> String in
                let data = try XCTUnwrap(Data(base64Encoded: String(field)))
                return try XCTUnwrap(String(data: data, encoding: .utf8))
            }
            return (values[0], values[1], values[2])
        }
    }

    func testSubmoduleGitFileResolvesIntoParentMetadataWithoutDuplicateDiscovery() throws {
        let fixture = try RealGitFixture()
        let temporaryOrigin = try fixture.makeRepository(named: "DependencyOrigin")
        let origin = fixture.rootURL.appendingPathComponent("DependencyOrigin", isDirectory: true)
        try fixture.fileManager.moveItem(at: temporaryOrigin, to: origin)
        let monorepo = try fixture.makeRepository(named: "Monorepo")
        let initial = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        XCTAssertEqual(initial.exitCode, 0, initial.standardError)
        XCTAssertEqual(try XCTUnwrap(fixture.metrics(from: initial.standardOutput))["repository_count"], "1")

        try fixture.git(
            in: monorepo,
            ["-c", "protocol.file.allow=always", "submodule", "add", origin.path, "Modules/Dependency"]
        )
        try fixture.git(
            in: monorepo,
            ["commit", "-am", "add dependency"],
            environment: fixture.gitDateEnvironment("2024-01-14T13:00:00Z")
        )
        let submodule = monorepo.appendingPathComponent("Modules/Dependency", isDirectory: true)
        try fixture.git(in: submodule, ["config", "user.name", "Tiny Buddy"])
        try fixture.git(in: submodule, ["config", "user.email", "tinybuddy@example.com"])
        try fixture.commit(
            in: submodule,
            file: "dependency.txt",
            contents: "dependency\n",
            message: "dependency work",
            date: "2024-01-15T11:05:00Z"
        )

        let result = try fixture.runScript(
            scanRoots: [fixture.scanRootURL],
            extraEnvironment: ["TINYBUDDY_GIT_INVALIDATED_ROOTS": fixture.scanRootURL.path]
        )
        let plist = try fixture.readPreferencesPlist()
        let metrics = try XCTUnwrap(fixture.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["repository_count"], "2")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(
            plist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "Dependency"
        )
    }

    func testRealBareRepositoryUsesDefaultBranchReflogWithoutHeadLog() throws {
        let fixture = try RealGitFixture()
        let temporarySource = try fixture.makeRepository(named: "BareSource")
        let source = fixture.rootURL.appendingPathComponent("BareSource", isDirectory: true)
        try fixture.fileManager.moveItem(at: temporarySource, to: source)
        try fixture.commit(
            in: source,
            file: "bare.txt",
            contents: "bare\n",
            message: "bare work",
            date: "2024-01-15T12:05:00Z"
        )

        let bare = fixture.scanRootURL.appendingPathComponent("ProjectBare.git", isDirectory: true)
        try fixture.fileManager.createDirectory(at: bare, withIntermediateDirectories: true)
        try fixture.git(in: bare, ["init", "--bare", "-b", "main"])
        try fixture.git(in: bare, ["config", "core.logAllRefUpdates", "true"])
        try fixture.git(in: source, ["remote", "add", "bare", bare.path])
        try fixture.git(in: source, ["push", "bare", "main"])

        let headLog = bare.appendingPathComponent("logs/HEAD")
        if fixture.fileManager.fileExists(atPath: headLog.path) {
            try fixture.fileManager.removeItem(at: headLog)
        }

        XCTAssertFalse(fixture.fileManager.fileExists(
            atPath: headLog.path
        ))
        XCTAssertTrue(fixture.fileManager.fileExists(
            atPath: bare.appendingPathComponent("logs/refs/heads/main").path
        ))

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let metrics = try XCTUnwrap(fixture.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["repository_count"], "1")
        XCTAssertEqual(metrics["invalid_repository_count"], "0")
    }

    func testHistoryOperationsProduceStableLogicalCompletionEvents() throws {
        let fixture = try RealGitFixture()
        let repository = try fixture.makeRepository(named: "ProjectHistory")
        let initialRevision = try fixture.gitOutput(in: repository, ["rev-parse", "HEAD"])

        try fixture.commit(
            in: repository,
            file: "main.txt",
            contents: "main-v1\n",
            message: "main work",
            date: "2024-01-15T08:05:00Z"
        )
        try "main-v2\n".write(
            to: repository.appendingPathComponent("main.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.git(in: repository, ["add", "main.txt"])
        try fixture.git(
            in: repository,
            ["commit", "--amend", "-m", "main work amended"],
            environment: fixture.gitDateEnvironment("2024-01-15T08:20:00Z")
        )

        try fixture.git(in: repository, ["checkout", "-b", "topic", initialRevision])
        try fixture.commit(
            in: repository,
            file: "topic.txt",
            contents: "topic\n",
            message: "topic work",
            date: "2024-01-15T09:05:00Z"
        )
        try fixture.git(
            in: repository,
            ["rebase", "main"],
            environment: ["GIT_COMMITTER_DATE": "2024-01-15T10:05:00Z"]
        )
        try "topic amended\n".write(
            to: repository.appendingPathComponent("topic.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.git(in: repository, ["add", "topic.txt"])
        try fixture.git(
            in: repository,
            ["commit", "--amend", "-m", "topic work amended"],
            environment: fixture.gitDateEnvironment("2024-01-15T10:20:00Z")
        )
        try fixture.git(in: repository, ["checkout", "main"])
        try fixture.git(
            in: repository,
            ["merge", "--no-ff", "topic", "-m", "merge topic"],
            environment: fixture.gitDateEnvironment("2024-01-15T11:05:00Z")
        )

        try fixture.git(in: repository, ["checkout", "--detach", "HEAD"])
        try fixture.commit(
            in: repository,
            file: "detached.txt",
            contents: "detached\n",
            message: "detached work",
            date: "2024-01-15T12:05:00Z"
        )
        try fixture.git(in: repository, ["checkout", "main"])

        try fixture.git(in: repository, ["checkout", "-b", "disposable"])
        try fixture.commit(
            in: repository,
            file: "disposable.txt",
            contents: "disposable\n",
            message: "disposable work",
            date: "2024-01-15T13:05:00Z"
        )
        try fixture.git(in: repository, ["checkout", "main"])
        try fixture.git(in: repository, ["branch", "-D", "disposable"])

        try fixture.commit(
            in: repository,
            file: "rewritten.txt",
            contents: "rewritten\n",
            message: "rewritten work",
            date: "2024-01-15T14:05:00Z"
        )
        try fixture.git(in: repository, ["reset", "--hard", "HEAD^"])

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()
        let metrics = try XCTUnwrap(fixture.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["repository_count"], "1")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 6)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 6)
        XCTAssertEqual(
            plist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "ProjectHistory"
        )

        let repeated = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let repeatedPlist = try fixture.readPreferencesPlist()
        XCTAssertEqual(repeated.exitCode, 0, repeated.standardError)
        XCTAssertEqual(repeatedPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 6)
        XCTAssertEqual(repeatedPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 6)
    }

    func testCherryPickCountsAsCompletionAndFastForwardMergeDoesNot() throws {
        let fixture = try RealGitFixture()
        let repository = try fixture.makeRepository(named: "ProjectCherryPick")
        let base = try fixture.gitOutput(in: repository, ["rev-parse", "HEAD"])

        // A donor commit yesterday is not part of today's completion count, but
        // cherry-picking it today creates a real new commit that must count.
        try fixture.git(in: repository, ["checkout", "-b", "donor", base])
        try fixture.commit(
            in: repository,
            file: "donor.txt",
            contents: "donor\n",
            message: "donor work",
            date: "2024-01-14T23:00:00Z"
        )
        let donor = try fixture.gitOutput(in: repository, ["rev-parse", "HEAD"])
        try fixture.git(in: repository, ["checkout", "main"])

        try fixture.commit(
            in: repository,
            file: "work.txt",
            contents: "work\n",
            message: "work",
            date: "2024-01-15T09:00:00Z"
        )
        try fixture.git(
            in: repository,
            ["cherry-pick", donor],
            environment: fixture.gitDateEnvironment("2024-01-15T09:20:00Z")
        )

        // A fast-forward merge moves HEAD without creating a commit and must not
        // add a completion.
        try fixture.git(in: repository, ["checkout", "-b", "ahead"])
        try fixture.commit(
            in: repository,
            file: "ahead.txt",
            contents: "ahead\n",
            message: "ahead work",
            date: "2024-01-15T09:30:00Z"
        )
        try fixture.git(in: repository, ["checkout", "main"])
        try fixture.git(
            in: repository,
            ["merge", "ahead"],
            environment: fixture.gitDateEnvironment("2024-01-15T09:35:00Z")
        )

        // A real merge commit still counts as a completion.
        try fixture.git(in: repository, ["checkout", "-b", "ffless", "ahead"])
        try fixture.commit(
            in: repository,
            file: "mergeable.txt",
            contents: "mergeable\n",
            message: "mergeable work",
            date: "2024-01-15T09:40:00Z"
        )
        try fixture.git(in: repository, ["checkout", "main"])
        try fixture.git(
            in: repository,
            ["merge", "--no-ff", "ffless", "-m", "merge ffless"],
            environment: fixture.gitDateEnvironment("2024-01-15T09:50:00Z")
        )

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 5)
        // Events at 09:00/09:20 share the 09:00 block; 09:30/09:40/09:50 share the
        // 09:30 block. The 09:35 fast-forward adds no completion and no focus block.
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
    }

    func testCopiedRepositoryDoesNotDoubleCountSharedCompletionEvents() throws {
        let fixture = try RealGitFixture()
        let primary = try fixture.makeRepository(named: "ProjectPrimary")
        try fixture.commit(
            in: primary,
            file: "work.txt",
            contents: "work\n",
            message: "work",
            date: "2024-01-15T09:05:00Z"
        )
        try fixture.commit(
            in: primary,
            file: "more.txt",
            contents: "more\n",
            message: "more work",
            date: "2024-01-15T10:05:00Z"
        )

        // Copying the whole checkout (including its Git metadata) is an exact
        // duplicate of the same completion events in a second repository.
        let duplicate = fixture.scanRootURL.appendingPathComponent(
            "ProjectDuplicate",
            isDirectory: true
        )
        try fixture.fileManager.copyItem(at: primary, to: duplicate)

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()
        let metrics = try XCTUnwrap(fixture.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["repository_count"], "2")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
    }

    func testCopiedRepositoryAmendReplacesSingleSurvivingCompletion() throws {
        let fixture = try RealGitFixture()
        let primary = try fixture.makeRepository(named: "ProjectOriginal")
        try fixture.commit(
            in: primary,
            file: "work.txt",
            contents: "work\n",
            message: "work",
            date: "2024-01-15T09:05:00Z"
        )

        // The backup is copied before the amend, so it retains the pre-amend
        // commit while the original later amends it. Cross-repository dedup must
        // collapse the identical pre-amend commit and the amend must replace that
        // single surviving completion rather than counting the amended commit
        // a second time.
        let duplicate = fixture.scanRootURL.appendingPathComponent(
            "ProjectCopy",
            isDirectory: true
        )
        try fixture.fileManager.copyItem(at: primary, to: duplicate)

        try "work amended\n".write(
            to: primary.appendingPathComponent("work.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.git(in: primary, ["add", "work.txt"])
        try fixture.git(
            in: primary,
            ["commit", "--amend", "-m", "work amended"],
            environment: fixture.gitDateEnvironment("2024-01-15T09:10:00Z")
        )

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()
        let metrics = try XCTUnwrap(fixture.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["repository_count"], "2")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
    }

    func testRebaseInteractiveSquashKeepsRealCompletionEventsStable() throws {
        let fixture = try RealGitFixture()
        let repository = try fixture.makeRepository(named: "ProjectSquash")
        try fixture.commit(
            in: repository,
            file: "one.txt",
            contents: "one\n",
            message: "topic one",
            date: "2024-01-15T09:20:00Z"
        )
        try fixture.commit(
            in: repository,
            file: "two.txt",
            contents: "two\n",
            message: "topic two",
            date: "2024-01-15T09:25:00Z"
        )

        // An interactive rebase that squashes the second commit into the first
        // rewrites objects without creating or dropping completions: both commits
        // were real completion events today, and the squash only remaps them.
        try fixture.git(
            in: repository,
            ["rebase", "-i", "HEAD~2"],
            environment: [
                "GIT_SEQUENCE_EDITOR": "sed -i '' '2s/pick/squash/'",
                "GIT_EDITOR": "true",
                "GIT_AUTHOR_DATE": "2024-01-15T09:30:00Z",
                "GIT_COMMITTER_DATE": "2024-01-15T09:30:00Z"
            ]
        )

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()
        let metrics = try XCTUnwrap(fixture.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["repository_count"], "1")
        // Two real events stay two; the squash rewrite adds nothing and drops nothing.
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        // Both events fall in the 09:00 focus block; the rewrite remaps within it.
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)

        let repeated = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let repeatedPlist = try fixture.readPreferencesPlist()
        XCTAssertEqual(repeated.exitCode, 0, repeated.standardError)
        XCTAssertEqual(repeatedPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(repeatedPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
    }

    func testForcePushToRemoteDoesNotCreateOrDropTodayCompletions() throws {
        let fixture = try RealGitFixture()
        let repository = try fixture.makeRepository(named: "ProjectForcePush")
        try fixture.commit(
            in: repository,
            file: "work.txt",
            contents: "work\n",
            message: "work",
            date: "2024-01-15T09:10:00Z"
        )

        // A bare remote outside the scan root receives the branch. Pushing and
        // force-pushing update remote refs only; they never write the local HEAD
        // reflog, so they must not add a completion event.
        let bareRemote = fixture.rootURL.appendingPathComponent("bare-remote", isDirectory: true)
        try fixture.fileManager.createDirectory(at: bareRemote, withIntermediateDirectories: true)
        try fixture.git(in: bareRemote, ["init", "--bare"])
        try fixture.git(in: repository, ["remote", "add", "origin", bareRemote.path])
        try fixture.git(in: repository, ["push", "-u", "origin", "main"])
        try fixture.git(in: repository, ["push", "--force", "origin", "main"])

        // Rewinding to adopt a rewritten remote history is a reset (not a counted
        // kind) and must not roll back the real completion above: the reflog keeps
        // today's commit event even though HEAD moves back to the seed.
        try fixture.git(in: repository, ["reset", "--hard", "HEAD^"])

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(
            plist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "ProjectForcePush"
        )
    }

    func testCrossWorktreeRebaseMapsDuplicateSubjectsBeforeAmendingAnEarlierCommit() throws {
        let fixture = try RealGitFixture()
        let repository = try fixture.makeRepository(named: "ProjectDuplicateSubjects")
        let initialRevision = try fixture.gitOutput(in: repository, ["rev-parse", "HEAD"])

        try fixture.commit(
            in: repository,
            file: "main.txt",
            contents: "main\n",
            message: "main work",
            date: "2024-01-15T08:05:00Z"
        )
        try fixture.git(in: repository, ["checkout", "-b", "topic", initialRevision])
        try fixture.commit(
            in: repository,
            file: "first.txt",
            contents: "first\n",
            message: "same subject",
            date: "2024-01-15T09:05:00Z"
        )
        try fixture.commit(
            in: repository,
            file: "second.txt",
            contents: "second\n",
            message: "same subject",
            date: "2024-01-15T09:10:00Z"
        )
        try fixture.git(in: repository, ["checkout", "main"])
        let worktree = fixture.scanRootURL.appendingPathComponent(
            "ProjectDuplicateSubjects-topic",
            isDirectory: true
        )
        try fixture.git(in: repository, ["worktree", "add", worktree.path, "topic"])
        try fixture.git(
            in: worktree,
            ["rebase", "main"],
            environment: ["GIT_COMMITTER_DATE": "2024-01-15T10:05:00Z"]
        )
        try fixture.git(in: worktree, ["checkout", "--detach", "HEAD^"])
        try "first amended\n".write(
            to: worktree.appendingPathComponent("first.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.git(in: worktree, ["add", "first.txt"])
        try fixture.git(
            in: worktree,
            ["commit", "--amend", "-m", "same subject amended"],
            environment: fixture.gitDateEnvironment("2024-01-15T10:20:00Z")
        )

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 3)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 3)
        XCTAssertEqual(
            plist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "ProjectDuplicateSubjects"
        )

        let repeated = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let repeatedPlist = try fixture.readPreferencesPlist()
        XCTAssertEqual(repeated.exitCode, 0, repeated.standardError)
        XCTAssertEqual(repeatedPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 3)
        XCTAssertEqual(repeatedPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 3)
    }

    func testFiltersRobotBuildDependencyAndShortWindowDuplicateEvents() throws {
        let fixture = try RealGitFixture()
        let repository = try fixture.makeRepository(named: "ProjectSignal")
        try fixture.commit(
            in: repository,
            file: "human.txt",
            contents: "human\n",
            message: "human work",
            date: "2024-01-15T09:05:00Z"
        )
        try fixture.duplicateHeadReflogLine(in: repository, containing: "commit: human work")
        try fixture.commit(
            in: repository,
            file: "bot.txt",
            contents: "bot\n",
            message: "automated update",
            date: "2024-01-15T10:05:00Z",
            authorName: "dependabot[bot]",
            authorEmail: "dependabot[bot]@users.noreply.github.com",
            committerName: "Tiny Buddy",
            committerEmail: "tinybuddy@example.com"
        )

        for (relativePath, date) in [
            ("node_modules/DependencyRepo", "2024-01-15T11:05:00Z"),
            ("DerivedData/BuildRepo", "2024-01-15T12:05:00Z"),
            ("build/GeneratedRepo", "2024-01-15T13:05:00Z")
        ] {
            let noiseRepository = try fixture.makeRepository(atRelativePath: relativePath)
            try fixture.commit(
                in: noiseRepository,
                file: "noise.txt",
                contents: "noise\n",
                message: "noise work",
                date: date
            )
        }

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()
        let metrics = try XCTUnwrap(fixture.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["repository_count"], "1")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(
            plist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "ProjectSignal"
        )
    }

    func testUsesOneDayBoundaryAndDeterministicRecentProjectTieBreak() throws {
        let fixture = try RealGitFixture()
        let alpha = try fixture.makeRepository(named: "Alpha")
        let beta = try fixture.makeRepository(named: "Beta")

        try fixture.commit(
            in: alpha,
            file: "before.txt",
            contents: "before\n",
            message: "before day",
            date: "2024-01-14T23:59:59Z"
        )
        try fixture.commit(
            in: alpha,
            file: "start.txt",
            contents: "start\n",
            message: "day start",
            date: "2024-01-15T00:00:00Z"
        )
        try fixture.commit(
            in: beta,
            file: "tie.txt",
            contents: "beta\n",
            message: "beta tie",
            date: "2024-01-15T23:59:59Z"
        )
        try fixture.commit(
            in: alpha,
            file: "tie.txt",
            contents: "alpha\n",
            message: "alpha tie",
            date: "2024-01-15T23:59:59Z"
        )
        try fixture.commit(
            in: beta,
            file: "after.txt",
            contents: "after\n",
            message: "after day",
            date: "2024-01-16T00:00:00Z"
        )

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 3)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "Alpha")
    }

    func testPublishesValidRepositoryWhenAnotherRealRepositoryCannotReadARegularReflog() throws {
        let fixture = try RealGitFixture()
        let good = try fixture.makeRepository(named: "GoodProject")
        let bad = try fixture.makeRepository(named: "BadProject")
        try fixture.commit(
            in: good,
            file: "good.txt",
            contents: "good\n",
            message: "good work",
            date: "2024-01-15T09:05:00Z"
        )
        try fixture.commit(
            in: bad,
            file: "bad.txt",
            contents: "bad\n",
            message: "bad work",
            date: "2024-01-15T10:05:00Z"
        )
        try fixture.replaceHeadReflogWithDirectory(in: bad)

        let result = try fixture.runScript(scanRoots: [fixture.scanRootURL])
        let plist = try fixture.readPreferencesPlist()
        let metrics = try XCTUnwrap(fixture.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["refresh_outcome"], "partial")
        XCTAssertEqual(metrics["invalid_repository_count"], "1")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(
            plist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "GoodProject"
        )
    }
}

private final class RealGitFixture {
    let fileManager = FileManager.default
    let rootURL: URL
    let homeURL: URL
    let scanRootURL: URL
    let preferencesDirectoryURL: URL
    let plistURL: URL
    let cacheDirectoryURL: URL
    let scriptURL: URL

    init() throws {
        let fixtureIdentifier = UUID().uuidString
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("TinyBuddyRealGit-\(fixtureIdentifier)", isDirectory: true)
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        scanRootURL = rootURL.appendingPathComponent("scan-root", isDirectory: true)
        // `defaults` can write the real App Group container in production but
        // rejects arbitrary path domains under `/var/folders` in this test
        // environment. Keep Git fixtures there (so they are not `/tmp` noise)
        // and isolate only the mock preferences domain under `/private/tmp`.
        preferencesDirectoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("TinyBuddyRealGitPreferences-\(fixtureIdentifier)", isDirectory: true)
        plistURL = preferencesDirectoryURL.appendingPathComponent("group.plist")
        cacheDirectoryURL = rootURL.appendingPathComponent("repository-cache", isDirectory: true)
        scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/update_git_completion_count.sh", isDirectory: false)

        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scanRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: preferencesDirectoryURL, withIntermediateDirectories: true)
        let emptyPreferences = try PropertyListSerialization.data(
            fromPropertyList: [String: Any](),
            format: .xml,
            options: 0
        )
        try emptyPreferences.write(to: plistURL, options: .atomic)
    }

    deinit {
        try? fileManager.removeItem(at: rootURL)
        try? fileManager.removeItem(at: preferencesDirectoryURL)
    }

    func makeRepository(named name: String) throws -> URL {
        try makeRepository(atRelativePath: name)
    }

    func makeRepository(atRelativePath relativePath: String) throws -> URL {
        let repository = scanRootURL.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(in: repository, ["init", "-b", "main"])
        try git(in: repository, ["config", "user.name", "Tiny Buddy"])
        try git(in: repository, ["config", "user.email", "tinybuddy@example.com"])
        try commit(
            in: repository,
            file: "seed.txt",
            contents: "seed\n",
            message: "seed",
            date: "2024-01-14T12:00:00Z"
        )
        return repository
    }

    func commit(
        in repository: URL,
        file: String,
        contents: String,
        message: String,
        date: String,
        authorName: String = "Tiny Buddy",
        authorEmail: String = "tinybuddy@example.com",
        committerName: String? = nil,
        committerEmail: String? = nil
    ) throws {
        try contents.write(
            to: repository.appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
        try git(in: repository, ["add", file])
        var environment = gitDateEnvironment(date)
        environment["GIT_AUTHOR_NAME"] = authorName
        environment["GIT_AUTHOR_EMAIL"] = authorEmail
        environment["GIT_COMMITTER_NAME"] = committerName ?? authorName
        environment["GIT_COMMITTER_EMAIL"] = committerEmail ?? authorEmail
        try git(in: repository, ["commit", "-m", message], environment: environment)
    }

    func gitDateEnvironment(_ date: String) -> [String: String] {
        [
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_DATE": date
        ]
    }

    @discardableResult
    func git(
        in repository: URL,
        _ arguments: [String],
        environment extraEnvironment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeURL.path
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["TZ"] = "UTC"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw RealGitFixtureError.gitFailed(
                arguments: arguments,
                status: process.terminationStatus,
                standardError: stderr
            )
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func gitOutput(in repository: URL, _ arguments: [String]) throws -> String {
        try git(in: repository, arguments)
    }

    func duplicateHeadReflogLine(in repository: URL, containing marker: String) throws {
        let reflogURL = repository.appendingPathComponent(".git/logs/HEAD")
        let contents = try String(contentsOf: reflogURL, encoding: .utf8)
        let line = try XCTUnwrap(contents.split(separator: "\n").map(String.init).last { $0.contains(marker) })
        try contents.appending(line).appending("\n").write(
            to: reflogURL,
            atomically: true,
            encoding: .utf8
        )
    }

    func replaceHeadReflogWithDirectory(in repository: URL) throws {
        let reflogURL = repository.appendingPathComponent(".git/logs/HEAD", isDirectory: true)
        try fileManager.removeItem(at: reflogURL)
        try fileManager.createDirectory(at: reflogURL, withIntermediateDirectories: false)
    }

    func runScript(
        scanRoots: [URL],
        extraEnvironment: [String: String] = [:]
    ) throws -> RealGitScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeURL.path
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["TZ"] = "UTC"
        environment["TINYBUDDY_USER_HOME"] = homeURL.path
        environment["TINYBUDDY_APP_GROUP_CONTAINER"] = rootURL
            .appendingPathComponent("group-container", isDirectory: true).path
        environment["TINYBUDDY_APP_GROUP_PREFERENCES_DIR"] = preferencesDirectoryURL.path
        environment["TINYBUDDY_APP_GROUP_PREFERENCES_PLIST"] = plistURL.path
        environment["TINYBUDDY_GIT_REPOSITORY_CACHE_DIR"] = cacheDirectoryURL.path
        environment["TINYBUDDY_GIT_SCAN_ROOTS"] = scanRoots.map(\.path).joined(separator: "\n")
        environment["TINYBUDDY_TODAY"] = "2024-01-15"
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        return RealGitScriptResult(
            exitCode: process.terminationStatus,
            standardOutput: String(
                data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    func readPreferencesPlist() throws -> [String: Any] {
        guard let dictionary = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw RealGitFixtureError.preferencesUnavailable
        }
        return dictionary
    }

    func metrics(from standardOutput: String) -> [String: String]? {
        guard let line = standardOutput
            .split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix("TINYBUDDY_REFRESH_METRICS\t") }) else {
            return nil
        }

        return line.split(separator: "\t").dropFirst().reduce(into: [:]) { values, field in
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }
    }
}

private struct RealGitScriptResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private enum RealGitFixtureError: Error {
    case gitFailed(arguments: [String], status: Int32, standardError: String)
    case preferencesUnavailable
}
