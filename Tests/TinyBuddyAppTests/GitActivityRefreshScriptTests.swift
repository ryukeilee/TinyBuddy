import Foundation
@testable import TinyBuddyCore
import XCTest

final class GitActivityRefreshScriptTests: XCTestCase {
    func testScriptDoesNotUseHereStringForCachedRepositoryStats() throws {
        let harness = try ScriptHarness()
        let source = try String(contentsOf: harness.scriptURL, encoding: .utf8)

        XCTAssertFalse(source.contains("<<<"))
    }

    func testScriptUsesSandboxCompatibleRevisionSource() throws {
        let harness = try ScriptHarness()
        let source = try String(contentsOf: harness.scriptURL, encoding: .utf8)

        XCTAssertTrue(source.contains("REFRESH_EPOCH=\"$(/bin/date +%s)\""))
        XCTAssertFalse(source.contains("/usr/bin/perl -MTime::HiRes"))
    }

    func testScriptRecoversFromStaleCachedRepositoryAndReportsSuccess() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: current")]
        )

        let initialResult = try harness.run(scanRoots: [harness.scanRootURL])
        XCTAssertEqual(initialResult.exitCode, 0)

        try "\(repoURL.path)\n\(harness.scanRootURL.appendingPathComponent("StaleWorktree").path)\n"
            .write(to: harness.repositoryCacheFileURL, atomically: true, encoding: .utf8)

        let recoveredResult = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: recoveredResult.standardOutput))

        XCTAssertEqual(recoveredResult.exitCode, 0)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(metrics["repository_count"], "1")
        XCTAssertEqual(metrics["shared_data_written"], "0")
    }

    func testScriptRecoversStaleCacheWithValidAndInvalidRepositoriesAsPartialSuccess() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: current")]
        )
        XCTAssertEqual(try harness.run(scanRoots: [harness.scanRootURL]).exitCode, 0)

        _ = try harness.makeRepositoryWithExternalGitDir(
            named: "BrokenWorktree",
            commonDirRelativePath: "../missing-common-dir"
        )
        try "\(repoURL.path)\n\(harness.scanRootURL.appendingPathComponent("StaleWorktree").path)\n"
            .write(to: harness.repositoryCacheFileURL, atomically: true, encoding: .utf8)

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(metrics["repository_count"], "1")
        XCTAssertEqual(metrics["invalid_repository_count"], "1")
        XCTAssertEqual(metrics["refresh_outcome"], "partial")
        XCTAssertTrue(result.standardError.contains("partial refresh"))
    }

    func testScriptRejectsAnInvalidExplicitRevisionBeforeWritingSharedData() throws {
        let harness = try ScriptHarness()

        let result = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "9223372036854775808"]
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.standardError.contains("explicit refresh revision is invalid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.plistURL.path))
    }

    func testScriptReportsSkippedMetricsWhenNoAuthorizedRootsAreSupplied() throws {
        let harness = try ScriptHarness()

        let result = try harness.run(scanRoots: [])
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(metrics["refresh_outcome"], "skipped")
        XCTAssertEqual(metrics["authorized_root_count"], "0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.plistURL.path))
    }

    func testScriptRecoversSnapshotWriteLocksLeftByTerminatedProcesses() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")]
        )

        try harness.fileManager.createDirectory(
            at: harness.snapshotWriteLockURL,
            withIntermediateDirectories: false
        )
        let ownerlessResult = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "100"]
        )

        XCTAssertEqual(ownerlessResult.exitCode, 0, ownerlessResult.standardError)
        XCTAssertFalse(harness.fileManager.fileExists(atPath: harness.snapshotWriteLockURL.path))

        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "commit: second")
            ]
        )
        try harness.setReflogModificationDate(for: repoURL, to: Date().addingTimeInterval(2))
        try harness.fileManager.createDirectory(
            at: harness.snapshotWriteLockURL.appendingPathComponent("owner-99999999", isDirectory: true),
            withIntermediateDirectories: true
        )

        let terminatedOwnerResult = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "101"]
        )
        let snapshotValue = try XCTUnwrap(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        let snapshot = try XCTUnwrap(GitTodayActivityTrustedSnapshotStore.decode(snapshotValue))

        XCTAssertEqual(terminatedOwnerResult.exitCode, 0, terminatedOwnerResult.standardError)
        XCTAssertEqual(snapshot.revision, 101)
        XCTAssertEqual(snapshot.activity.commitCount, 2)
        XCTAssertFalse(harness.fileManager.fileExists(atPath: harness.snapshotWriteLockURL.path))
    }

    func testScriptFailsWithoutChangingSharedDataWhenAutomaticRevisionIsExhausted() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")]
        )
        let initialResult = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "9223372036854775807"]
        )
        XCTAssertEqual(initialResult.exitCode, 0, initialResult.standardError)
        let initialPlist = try harness.readPreferencesPlist()
        let initialSnapshot = try XCTUnwrap(
            initialPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )

        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "commit: second")
            ]
        )
        try harness.setReflogModificationDate(for: repoURL, to: Date().addingTimeInterval(2))

        let exhaustedResult = try harness.run(scanRoots: [harness.scanRootURL])
        let finalPlist = try harness.readPreferencesPlist()
        let exhaustedMetrics = try XCTUnwrap(harness.metrics(from: exhaustedResult.standardOutput))

        XCTAssertEqual(exhaustedResult.exitCode, 75)
        XCTAssertEqual(exhaustedMetrics["refresh_outcome"], "failed")
        XCTAssertTrue(exhaustedResult.standardError.contains("trusted snapshot revision is exhausted"))
        XCTAssertEqual(
            finalPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String,
            initialSnapshot
        )
        XCTAssertEqual(finalPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(finalPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertFalse(harness.fileManager.fileExists(atPath: harness.snapshotWriteLockURL.path))
    }

    func testScriptAdvancesAutomaticRevisionAfterWallClockRollback() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")]
        )
        let highRevision: Int64 = 9_000_000_000_000_000_000
        XCTAssertEqual(
            try harness.run(
                scanRoots: [harness.scanRootURL],
                extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": String(highRevision)]
            ).exitCode,
            0
        )

        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "commit: second")
            ]
        )
        try harness.setReflogModificationDate(for: repoURL, to: Date().addingTimeInterval(2))

        let rollbackResult = try harness.run(scanRoots: [harness.scanRootURL])
        let encoded = try XCTUnwrap(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        let snapshot = try XCTUnwrap(GitTodayActivityTrustedSnapshotStore.decode(encoded))

        XCTAssertEqual(rollbackResult.exitCode, 0, rollbackResult.standardError)
        XCTAssertEqual(snapshot.revision, highRevision + 1)
        XCTAssertEqual(snapshot.activity.commitCount, 2)
    }

    func testScriptPublishesOneAtomicSnapshotAndRejectsNonNewerRefreshResults() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "commit: second")
            ]
        )

        let newerResult = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "300"]
        )
        let newerPlist = try harness.readPreferencesPlist()
        let newerEncoded = try XCTUnwrap(
            newerPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        let newerSnapshot = try XCTUnwrap(GitTodayActivityTrustedSnapshotStore.decode(newerEncoded))

        XCTAssertEqual(newerResult.exitCode, 0)
        XCTAssertEqual(newerSnapshot.revision, 300)
        XCTAssertEqual(newerSnapshot.activity.commitCount, 2)
        XCTAssertEqual(newerSnapshot.activity.focusBlockCount, 2)
        XCTAssertEqual(newerSnapshot.activity.recentProjectName, "ProjectAlpha")

        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 10, minute: 10, message: "commit: stale")]
        )
        try harness.setReflogModificationDate(for: repoURL, to: Date().addingTimeInterval(2))
        let sameRevisionResult = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "300"]
        )
        let sameRevisionPlist = try harness.readPreferencesPlist()
        let sameRevisionMetrics = try XCTUnwrap(
            harness.metrics(from: sameRevisionResult.standardOutput)
        )
        let sameRevisionEncoded = try XCTUnwrap(
            sameRevisionPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )

        XCTAssertEqual(sameRevisionResult.exitCode, 0)
        XCTAssertEqual(sameRevisionMetrics["refresh_outcome"], "skipped")
        XCTAssertTrue(sameRevisionResult.standardOutput.contains("skipped stale write"))
        XCTAssertEqual(sameRevisionEncoded, newerEncoded)
        XCTAssertEqual(sameRevisionPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(sameRevisionPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)

        let olderResult = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "200"]
        )
        let finalPlist = try harness.readPreferencesPlist()
        let olderMetrics = try XCTUnwrap(harness.metrics(from: olderResult.standardOutput))

        XCTAssertEqual(olderResult.exitCode, 0)
        XCTAssertEqual(olderMetrics["refresh_outcome"], "skipped")
        XCTAssertTrue(olderResult.standardOutput.contains("skipped stale write"))
        XCTAssertEqual(
            finalPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String,
            newerEncoded
        )
    }

    func testScriptRepairsAnInvalidTrustedRevisionEvenWhenPayloadIsUnchanged() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: current")]
        )
        XCTAssertEqual(try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "300"]
        ).exitCode, 0)

        var plist = try harness.readPreferencesPlist()
        let snapshot = try XCTUnwrap(
            plist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        let snapshotFields = snapshot.split(
            separator: "\t",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        XCTAssertEqual(snapshotFields.count, 2)
        let payload = String(snapshotFields[1])
        plist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] = "invalid\t\(payload)"
        try harness.seedPreferencesPlist(plist)

        let result = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_REFRESH_REVISION": "301"]
        )
        let repairedValue = try XCTUnwrap(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        let repaired = try XCTUnwrap(GitTodayActivityTrustedSnapshotStore.decode(repairedValue))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(repaired.revision, 301)
        XCTAssertEqual(repaired.activity.commitCount, 1)
        XCTAssertEqual(repaired.activity.focusBlockCount, 1)
    }

    func testScriptParsesTodayActivityFromRawHeadReflog() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "merge branch 'main': result"),
                harness.reflogLine(daysOffset: -1, hour: 11, minute: 5, message: "commit: yesterday")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.dayIdentifier"] as? String, harness.todayIdentifier)
    }

    func testScriptPublishesValidRepositoryWhenAnotherReflogIsNotARegularFile() throws {
        let harness = try ScriptHarness()
        let goodRepoURL = try harness.makeRepository(named: "ProjectGood")
        let badRepoURL = try harness.makeRepository(named: "ProjectBad")

        try harness.writeHeadReflog(
            for: goodRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 15, message: "commit: good")
            ]
        )
        try harness.makeUnreadableAsFileHeadReflog(for: badRepoURL)
        try harness.seedPreferencesPlist([
            "tinybuddy.gitTodayCommitCount.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayCommitCount.count": 99,
            "tinybuddy.gitTodayFocusBlockCount.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayFocusBlockCount.count": 77,
            "tinybuddy.gitTodayRecentProject.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayRecentProject.projectName": "PreviousProject"
        ])

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(
            result.standardError.contains("publishing other valid repositories"),
            "stderr did not describe partial publication: \(result.standardError)"
        )
        XCTAssertEqual(metrics["refresh_outcome"], "partial")
        XCTAssertEqual(metrics["invalid_repository_count"], "1")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectGood")
    }

    func testScriptRetainsLastValidRepositoryResultWhenCurrentReflogMetadataReadFails() throws {
        let harness = try ScriptHarness()
        let stableRepoURL = try harness.makeRepository(named: "ProjectStable")
        let failingRepoURL = try harness.makeRepository(named: "ProjectTemporarilyUnavailable")
        try harness.writeHeadReflog(
            for: stableRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: stable")]
        )
        try harness.writeHeadReflog(
            for: failingRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 10, minute: 10, message: "commit: retained")]
        )

        let firstResult = try harness.run(scanRoots: [harness.scanRootURL])
        XCTAssertEqual(firstResult.exitCode, 0, firstResult.standardError)
        let failingStatURL = try harness.makeStatProbeFailingHeadReflog(for: failingRepoURL)

        let partialResult = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_STAT_BIN": failingStatURL.path]
        )
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: partialResult.standardOutput))

        XCTAssertEqual(partialResult.exitCode, 0, partialResult.standardError)
        XCTAssertTrue(partialResult.standardError.contains("retained its last valid result"))
        XCTAssertEqual(metrics["refresh_outcome"], "partial")
        XCTAssertEqual(metrics["retained_repository_count"], "1")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
        XCTAssertEqual(
            plist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "ProjectTemporarilyUnavailable"
        )
    }

    func testScriptTimesOutSlowRepositoryMetadataAndRetainsItsLastValidResult() throws {
        let harness = try ScriptHarness()
        let stableRepoURL = try harness.makeRepository(named: "ProjectStable")
        let slowRepoURL = try harness.makeRepository(named: "ProjectSlow")
        try harness.writeHeadReflog(
            for: stableRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: stable")]
        )
        try harness.writeHeadReflog(
            for: slowRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 10, minute: 10, message: "commit: slow")]
        )
        _ = try harness.run(scanRoots: [harness.scanRootURL])
        let slowStatURL = try harness.makeStatProbeFailingHeadReflog(
            for: slowRepoURL,
            delaySeconds: 10
        )

        let startedAt = Date()
        let result = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: [
                "TINYBUDDY_STAT_BIN": slowStatURL.path,
                "TINYBUDDY_GIT_REPOSITORY_READ_TIMEOUT_SECONDS": "1"
            ]
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertLessThan(elapsed, 4)
        XCTAssertEqual(metrics["retained_repository_count"], "1")
        XCTAssertEqual(metrics["refresh_outcome"], "partial")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
    }

    func testScriptTimesOutSlowRepositoryParsingAndRetainsItsLastValidResult() throws {
        let harness = try ScriptHarness()
        let stableRepoURL = try harness.makeRepository(named: "ProjectStable")
        let slowRepoURL = try harness.makeRepository(named: "ProjectSlowParse")
        try harness.writeHeadReflog(
            for: stableRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: stable")]
        )
        try harness.writeHeadReflog(
            for: slowRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 10, minute: 10, message: "commit: cached")]
        )
        _ = try harness.run(scanRoots: [harness.scanRootURL])
        try harness.writeHeadReflog(
            for: slowRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 10, message: "commit: cached"),
                harness.reflogLine(daysOffset: 0, hour: 11, minute: 10, message: "commit: new")
            ]
        )
        let slowPerlURL = try harness.makeSlowPerlProbe()

        let startedAt = Date()
        let result = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: [
                "TINYBUDDY_PERL_BIN": slowPerlURL.path,
                "TINYBUDDY_GIT_REPOSITORY_PARSE_TIMEOUT_SECONDS": "1"
            ]
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertLessThan(elapsed, 4)
        XCTAssertEqual(metrics["retained_repository_count"], "1")
        XCTAssertEqual(metrics["refresh_outcome"], "partial")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
    }

    func testScriptReusesFingerprintsAcrossManyUnchangedRepositories() throws {
        let harness = try ScriptHarness()
        let repositoryCount = 20
        for index in 0..<repositoryCount {
            let repoURL = try harness.makeRepository(named: String(format: "Project-%03d", index))
            try harness.writeHeadReflog(
                for: repoURL,
                lines: [
                    harness.reflogLine(
                        daysOffset: 0,
                        hour: 9 + index / 6,
                        minute: (index % 6) * 10,
                        message: "commit: repository-\(index)"
                    )
                ]
            )
        }

        let firstResult = try harness.run(scanRoots: [harness.scanRootURL])
        let firstMetrics = try XCTUnwrap(harness.metrics(from: firstResult.standardOutput))
        XCTAssertEqual(firstResult.exitCode, 0, firstResult.standardError)
        XCTAssertEqual(firstMetrics["recomputed_repository_count"], "20")

        let incrementalResult = try harness.run(scanRoots: [harness.scanRootURL])
        let incrementalMetrics = try XCTUnwrap(harness.metrics(from: incrementalResult.standardOutput))
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(incrementalResult.exitCode, 0, incrementalResult.standardError)
        XCTAssertEqual(incrementalMetrics["repository_count"], "20")
        XCTAssertEqual(incrementalMetrics["cache_hit_count"], "20")
        XCTAssertEqual(incrementalMetrics["reflog_unchanged_skip_count"], "20")
        XCTAssertEqual(incrementalMetrics["recomputed_repository_count"], "0")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, repositoryCount)
    }

    func testScriptProcessesLargeReflogHistoryWithoutLosingEvents() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectWithLargeHistory")
        let eventCount = 600
        let lines = (0..<eventCount).map { index in
            harness.reflogLine(
                daysOffset: 0,
                hour: index / 60,
                minute: index % 60,
                message: "commit: history-\(index)"
            )
            .replacingOccurrences(
                of: "1111111111111111111111111111111111111111",
                with: String(format: "%040x", index + 1)
            )
        }
        try harness.writeHeadReflog(for: repoURL, lines: lines)

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(metrics["recomputed_repository_count"], "1")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, eventCount)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 20)
    }

    func testScriptPublishesReadableScanResultsWhenRepositoryScanIsPartialAndRecoversLater() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let failingFindURL = try harness.makeFailingRecursiveFindProbe()
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 10, minute: 15, message: "commit: current")]
        )
        try harness.seedPreferencesPlist([
            "tinybuddy.gitTodayCommitCount.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayCommitCount.count": 99,
            "tinybuddy.gitTodayFocusBlockCount.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayFocusBlockCount.count": 77,
            "tinybuddy.gitTodayRecentProject.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayRecentProject.projectName": "PreviousProject"
        ])

        let failedResult = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": failingFindURL.path
        ])
        let preservedPlist = try harness.readPreferencesPlist()
        let partialMetrics = try XCTUnwrap(harness.metrics(from: failedResult.standardOutput))

        XCTAssertEqual(failedResult.exitCode, 0, failedResult.standardError)
        XCTAssertTrue(
            failedResult.standardError.contains("continuing with readable results"),
            failedResult.standardError
        )
        XCTAssertEqual(partialMetrics["refresh_outcome"], "partial")
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")

        let recoveredResult = try harness.run(scanRoots: [harness.scanRootURL])
        let recoveredPlist = try harness.readPreferencesPlist()

        XCTAssertEqual(recoveredResult.exitCode, 0)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
    }

    func testScriptSkipsSharedDataRewriteWhenSnapshotDidNotChange() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "merge branch 'main': result")
            ]
        )
        _ = try harness.run(scanRoots: [harness.scanRootURL])

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("TinyBuddy git shared data unchanged; skipped plist rewrite"))
        XCTAssertEqual(metrics["repository_count"], "1")
        XCTAssertEqual(metrics["cache_hit_count"], "1")
        XCTAssertEqual(metrics["reflog_unchanged_skip_count"], "1")
        XCTAssertEqual(metrics["recomputed_repository_count"], "0")
        XCTAssertEqual(metrics["shared_data_written"], "0")
    }

    func testScriptParsesTodayActivityFromGitFileWorktreeMetadata() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepositoryWithExternalGitDir(named: "ProjectBeta")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 14, minute: 5, message: "commit: worktree")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectBeta")
    }

    func testScriptRewritesNumericStringsBackToIntegerSharedData() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "merge branch 'main': result")
            ]
        )
        try harness.seedPreferencesPlist([
            "tinybuddy.gitTodayCommitCount.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayCommitCount.count": "2",
            "tinybuddy.gitTodayFocusBlockCount.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayFocusBlockCount.count": "2",
            "tinybuddy.gitTodayRecentProject.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayRecentProject.projectName": "ProjectAlpha"
        ])

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(plist["tinybuddy.gitTodayCommitCount.count"] is Int)
        XCTAssertTrue(plist["tinybuddy.gitTodayFocusBlockCount.count"] is Int)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
    }

    func testScriptReusesCachedRepositoryListWithoutRecursiveRescan() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let findProbe = try harness.makeFindProbe()
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        let firstRecursiveScanCount = try harness.recursiveScanInvocationCount(from: findProbe.logURL)
        let retainedCacheDate = Date(timeIntervalSinceNow: -60)
        try harness.fileManager.setAttributes(
            [.modificationDate: retainedCacheDate],
            ofItemAtPath: harness.repositoryCacheFileURL.path
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        let secondRecursiveScanCount = try harness.recursiveScanInvocationCount(from: findProbe.logURL)
        let cacheAttributes = try harness.fileManager.attributesOfItem(
            atPath: harness.repositoryCacheFileURL.path
        )
        let cacheDateAfterReuse = try XCTUnwrap(cacheAttributes[.modificationDate] as? Date)

        XCTAssertEqual(firstRecursiveScanCount, 1)
        XCTAssertEqual(secondRecursiveScanCount, 1)
        XCTAssertEqual(
            Int(cacheDateAfterReuse.timeIntervalSince1970),
            Int(retainedCacheDate.timeIntervalSince1970)
        )
    }

    func testScriptSkipsReflogReparseWhenCachedMtimeDidNotChange() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let perlProbe = try harness.makePerlProbe()
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_PERL_BIN": perlProbe.scriptURL.path
        ])
        let firstParseCount = try harness.perlInvocationCount(from: perlProbe.logURL)

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_PERL_BIN": perlProbe.scriptURL.path
        ])
        let secondParseCount = try harness.perlInvocationCount(from: perlProbe.logURL)

        XCTAssertEqual(firstParseCount, 1)
        XCTAssertEqual(secondParseCount, 1)
    }

    func testScriptInvalidatesCachedEventsWhenReflogChangesWithinTheSameMtimeSecond() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let fixedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")]
        )
        try harness.setReflogModificationDate(for: repoURL, to: fixedModificationDate)
        XCTAssertEqual(try harness.run(scanRoots: [harness.scanRootURL]).exitCode, 0)

        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "commit: second")
            ]
        )
        try harness.setReflogModificationDate(for: repoURL, to: fixedModificationDate)

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(metrics["cache_hit_count"], "1")
        XCTAssertEqual(metrics["reflog_unchanged_skip_count"], "0")
        XCTAssertEqual(metrics["recomputed_repository_count"], "1")
    }

    func testScriptInvalidatesCachedEventsForSameSizeSameMtimeInPlaceReflogRewrite() throws {
        let harness = try ScriptHarness()
        let alphaURL = try harness.makeRepository(named: "ProjectAlpha")
        let betaURL = try harness.makeRepository(named: "ProjectBeta")
        let fixedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try harness.writeHeadReflog(
            for: alphaURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: alpha")]
        )
        try harness.writeHeadReflog(
            for: betaURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 10, minute: 10, message: "commit: beta")]
        )
        try harness.setReflogModificationDate(for: alphaURL, to: fixedModificationDate)
        XCTAssertEqual(try harness.run(scanRoots: [harness.scanRootURL]).exitCode, 0)
        XCTAssertEqual(
            (try harness.readPreferencesPlist())["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "ProjectBeta"
        )
        let metadataBeforeRewrite = try harness.headReflogMetadata(for: alphaURL)

        try harness.writeHeadReflogInPlace(
            for: alphaURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 11, minute: 10, message: "commit: alpha")]
        )
        try harness.setReflogModificationDate(for: alphaURL, to: fixedModificationDate)
        let metadataAfterRewrite = try harness.headReflogMetadata(for: alphaURL)

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(metadataAfterRewrite, metadataBeforeRewrite)
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
        XCTAssertEqual(metrics["reflog_unchanged_skip_count"], "1")
        XCTAssertEqual(metrics["recomputed_repository_count"], "1")
    }

    func testScriptRejectsShapeValidButChecksumMismatchedEventCacheAndRecomputesTheReflog() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")]
        )
        XCTAssertEqual(try harness.run(scanRoots: [harness.scanRootURL]).exitCode, 0)

        let cache = try String(contentsOf: harness.repositoryStatsCacheFileURL, encoding: .utf8)
        let corruptCache = cache
            .split(separator: "\n")
            .map { line -> String in
                var fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if fields.count == 15, fields[0] == "v3" {
                    fields[8] = "1700000000"
                }
                return fields.joined(separator: "\t")
            }
            .joined(separator: "\n")
            .appending("\n")
        try corruptCache.write(
            to: harness.repositoryStatsCacheFileURL,
            atomically: true,
            encoding: .utf8
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))
        let repairedCache = try String(contentsOf: harness.repositoryStatsCacheFileURL, encoding: .utf8)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(metrics["cache_hit_count"], "0")
        XCTAssertEqual(metrics["reflog_unchanged_skip_count"], "0")
        XCTAssertEqual(metrics["recomputed_repository_count"], "1")
        XCTAssertFalse(repairedCache.contains("\t1700000000\t"))
    }

    func testScriptReparsesOnlyRepositoryWhoseReflogMtimeChanged() throws {
        let harness = try ScriptHarness()
        let alphaURL = try harness.makeRepository(named: "ProjectAlpha")
        let betaURL = try harness.makeRepository(named: "ProjectBeta")
        let perlProbe = try harness.makePerlProbe()
        try harness.writeHeadReflog(
            for: alphaURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: alpha")
            ]
        )
        try harness.writeHeadReflog(
            for: betaURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 15, message: "commit: beta-first")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_PERL_BIN": perlProbe.scriptURL.path
        ])
        XCTAssertEqual(try harness.perlInvocationCount(from: perlProbe.logURL), 2)

        try harness.writeHeadReflog(
            for: betaURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 15, message: "commit: beta-first"),
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 45, message: "commit: beta-second")
            ]
        )
        try harness.setReflogModificationDate(for: betaURL, to: Date().addingTimeInterval(5))

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_PERL_BIN": perlProbe.scriptURL.path
        ])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try harness.perlInvocationCount(from: perlProbe.logURL), 3)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 3)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 3)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectBeta")
        XCTAssertEqual(metrics["repository_count"], "2")
        XCTAssertEqual(metrics["cache_hit_count"], "2")
        XCTAssertEqual(metrics["reflog_unchanged_skip_count"], "1")
        XCTAssertEqual(metrics["recomputed_repository_count"], "1")
        XCTAssertEqual(metrics["shared_data_written"], "1")
    }

    func testScriptDoesNotReuseCachedReflogStatsAcrossDayBoundary() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let perlProbe = try harness.makePerlProbe()
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_PERL_BIN": perlProbe.scriptURL.path,
            "TINYBUDDY_TODAY": harness.todayIdentifier
        ])
        XCTAssertEqual(try harness.perlInvocationCount(from: perlProbe.logURL), 1)

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_PERL_BIN": perlProbe.scriptURL.path,
            "TINYBUDDY_TODAY": harness.dayIdentifier(daysOffset: 1)
        ])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try harness.perlInvocationCount(from: perlProbe.logURL), 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.dayIdentifier"] as? String, harness.dayIdentifier(daysOffset: 1))
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 0)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 0)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "")
        XCTAssertEqual(metrics["reflog_unchanged_skip_count"], "0")
        XCTAssertEqual(metrics["recomputed_repository_count"], "1")
    }

    func testScriptRebuildsRepositoryCacheWhenAuthorizedDirectoryChanges() throws {
        let harness = try ScriptHarness()
        let firstRepoURL = try harness.makeRepository(named: "ProjectAlpha")
        let findProbe = try harness.makeFindProbe()
        try harness.writeHeadReflog(
            for: firstRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])

        let secondRepoURL = try harness.makeRepository(named: "ProjectBeta")
        try harness.writeHeadReflog(
            for: secondRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 15, message: "commit: second")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try harness.recursiveScanInvocationCount(from: findProbe.logURL), 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectBeta")
    }

    func testScriptDiscoversRepositoryCreatedBelowAnUnchangedFirstLevelDirectoryAfterCacheExpiry() throws {
        let harness = try ScriptHarness()
        let organizationURL = harness.scanRootURL.appendingPathComponent("Organization", isDirectory: true)
        let teamURL = organizationURL.appendingPathComponent("Team", isDirectory: true)
        try harness.fileManager.createDirectory(at: teamURL, withIntermediateDirectories: true)
        let firstRepoURL = try harness.makeRepository(atRelativePath: "Organization/Existing")
        let findProbe = try harness.makeFindProbe()
        try harness.writeHeadReflog(
            for: firstRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")
            ]
        )

        let first = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        XCTAssertEqual(first.exitCode, 0, first.standardError)

        let nestedRepoURL = try harness.makeRepository(atRelativePath: "Organization/Team/Nested")
        try harness.writeHeadReflog(
            for: nestedRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 15, message: "commit: nested")
            ]
        )
        try harness.fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: harness.repositoryCacheFileURL.path
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(try harness.recursiveScanInvocationCount(from: findProbe.logURL), 2)
        XCTAssertEqual(metrics["repository_count"], "2")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "Nested")
    }

    func testScriptRebuildsRepositoryCacheWhenCacheIsMissing() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let findProbe = try harness.makeFindProbe()
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        try FileManager.default.removeItem(at: harness.repositoryCacheFileURL)

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try harness.recursiveScanInvocationCount(from: findProbe.logURL), 2)
    }

    func testScriptPreservesPreviousSharedDataWhenCachedRepositoryBecomesUnavailable() throws {
        let harness = try ScriptHarness()
        let firstRepoURL = try harness.makeRepository(named: "ProjectAlpha")
        let findProbe = try harness.makeFindProbe()
        try harness.writeHeadReflog(
            for: firstRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])

        try FileManager.default.removeItem(at: firstRepoURL.appendingPathComponent(".git/logs/HEAD"))

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(metrics["refresh_outcome"], "failed")
        XCTAssertTrue(result.standardError.contains("preserving previous shared data"))
        XCTAssertEqual(try harness.recursiveScanInvocationCount(from: findProbe.logURL), 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")

    }

    func testScriptPartiallyRebuildsBadCachedRepositoryListThenRecoversOnNextInvocation() throws {
        let harness = try ScriptHarness()
        let alphaURL = try harness.makeRepository(named: "ProjectAlpha")
        let betaURL = try harness.makeRepository(named: "ProjectBeta")
        try harness.writeHeadReflog(
            for: alphaURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: alpha")]
        )
        try harness.writeHeadReflog(
            for: betaURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 10, minute: 15, message: "commit: beta")]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL])
        try FileManager.default.removeItem(at: alphaURL.appendingPathComponent(".git/logs/HEAD"))

        let partialResult = try harness.run(scanRoots: [harness.scanRootURL])
        let partialPlist = try harness.readPreferencesPlist()
        let partialMetrics = try XCTUnwrap(harness.metrics(from: partialResult.standardOutput))

        XCTAssertEqual(partialResult.exitCode, 0, partialResult.standardError)
        XCTAssertTrue(partialResult.standardError.contains("partial refresh"))
        XCTAssertEqual(partialMetrics["refresh_outcome"], "partial")
        XCTAssertEqual(partialMetrics["repository_count"], "2")
        XCTAssertEqual(partialMetrics["invalid_repository_count"], "1")
        XCTAssertEqual(partialPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(partialPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(partialPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectBeta")

        try harness.writeHeadReflog(
            for: alphaURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 11, minute: 20, message: "commit: restored")]
        )
        try harness.setReflogModificationDate(
            for: alphaURL,
            to: Date().addingTimeInterval(60)
        )
        let recoveredResult = try harness.run(scanRoots: [harness.scanRootURL])
        let recoveredPlist = try harness.readPreferencesPlist()

        XCTAssertEqual(recoveredResult.exitCode, 0)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
    }

    func testScriptPreservesPreviousSharedDataWhenSuccessfulRescanFindsNoRepositories() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: alpha")]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL])
        try FileManager.default.removeItem(at: repoURL)

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.standardError.contains("preserving previous shared data"))
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")

        let restoredRepoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: restoredRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 11, minute: 20, message: "commit: restored")]
        )

        let recoveredResult = try harness.run(scanRoots: [harness.scanRootURL])
        let recoveredPlist = try harness.readPreferencesPlist()

        XCTAssertEqual(recoveredResult.exitCode, 0)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
    }

    func testScriptPreservesPreviousSharedDataWhenCachedGitDirResolutionFailsWithoutErrTrapNoise() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepositoryWithExternalGitDir(named: "ProjectBeta")
        let findProbe = try harness.makeFindProbe()
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 14, minute: 5, message: "commit: worktree")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])

        try harness.repointExternalGitDir(
            for: repoURL,
            toMissingDirectoryNamed: "MissingProjectBetaGitDir"
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(
            result.standardError.contains("failed with exit code 1 at line"),
            "stderr unexpectedly contained ERR trap noise: \(result.standardError)"
        )
        XCTAssertEqual(try harness.recursiveScanInvocationCount(from: findProbe.logURL), 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectBeta")
    }

    func testScriptDoesNotReuseCachedStatsWhenGitDirEscapesAuthorizedRoots() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepositoryWithExternalGitDir(named: "ProjectBeta")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 14, minute: 5, message: "commit: worktree")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL])

        let escapedGitDirURL = harness.rootURL.appendingPathComponent("escaped-gitdir", isDirectory: true)
        try FileManager.default.createDirectory(
            at: escapedGitDirURL.appendingPathComponent("logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "gitdir: \(escapedGitDirURL.path)\n".write(
            to: repoURL.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try harness.writeHeadReflog(
            at: escapedGitDirURL.appendingPathComponent("logs/HEAD"),
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 15, minute: 10, message: "commit: escaped")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.standardError.contains("escaped authorized roots"))
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectBeta")
    }

    func testScriptSkipsNestedFixtureAndTemporaryRepositoriesWhenSelectingRecentProject() throws {
        let harness = try ScriptHarness()
        let primaryRepoURL = try harness.makeRepository(named: "ProjectAlpha")
        let fixtureRepoURL = try harness.makeRepository(atRelativePath: "Tests/Fixtures/FixtureRepo")
        let tempRepoURL = try harness.makeRepository(atRelativePath: "tmp/TempRepo")

        try harness.writeHeadReflog(
            for: primaryRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: primary")
            ]
        )
        try harness.writeHeadReflog(
            for: fixtureRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 11, minute: 20, message: "commit: fixture")
            ]
        )
        try harness.writeHeadReflog(
            for: tempRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 12, minute: 30, message: "commit: temp")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
        XCTAssertEqual(metrics["repository_count"], "1")
    }

    func testScriptSkipsInvalidWorktreeMetadataAndDoesNotLetItOverrideRecentProject() throws {
        let harness = try ScriptHarness()
        let validRepoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: validRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: valid")
            ]
        )

        _ = try harness.run(scanRoots: [harness.scanRootURL])

        let brokenWorktreeURL = try harness.makeRepositoryWithExternalGitDir(
            named: "BrokenWorktree",
            commonDirRelativePath: "../missing-common-dir"
        )

        try harness.writeHeadReflog(
            for: brokenWorktreeURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 12, minute: 45, message: "commit: broken")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("metadata is incomplete"))
        XCTAssertTrue(result.standardError.contains("partial refresh"))
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
        XCTAssertEqual(metrics["repository_count"], "1")
    }

    func testScriptPartiallyRecoversValidRepositoryWhenOneWorktreeIsInvalid() throws {
        let harness = try ScriptHarness()
        let validRepoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: validRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: initial")]
        )
        XCTAssertEqual(try harness.run(scanRoots: [harness.scanRootURL]).exitCode, 0)

        try harness.writeHeadReflog(
            for: validRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: initial"),
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 20, message: "commit: latest")
            ]
        )
        try harness.setReflogModificationDate(for: validRepoURL, to: Date().addingTimeInterval(60))
        _ = try harness.makeRepositoryWithExternalGitDir(
            named: "BrokenWorktree",
            commonDirRelativePath: "../missing-common-dir"
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("diagnostic=gitdir-layout-incomplete"), result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(metrics["repository_count"], "1")
        XCTAssertEqual(metrics["invalid_repository_count"], "1")
        XCTAssertEqual(metrics["refresh_outcome"], "partial")
    }

    func testScriptPreservesCacheAndTrustedSnapshotWhenOneDiscoveredRepositoryIsInvalid() throws {
        let harness = try ScriptHarness()
        let validRepoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: validRepoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: valid")]
        )

        let initialResult = try harness.run(scanRoots: [harness.scanRootURL])
        XCTAssertEqual(initialResult.exitCode, 0)
        let originalCache = try String(contentsOf: harness.repositoryCacheFileURL, encoding: .utf8)
        let originalStatsCache = try String(contentsOf: harness.repositoryStatsCacheFileURL, encoding: .utf8)
        let originalSnapshot = try XCTUnwrap(
            (try harness.readPreferencesPlist())["tinybuddy.gitTodayActivity.trustedSnapshot"] as? String
        )

        _ = try harness.makeRepositoryWithExternalGitDir(
            named: "BrokenWorktree",
            commonDirRelativePath: "../missing-common-dir"
        )

        let failedResult = try harness.run(scanRoots: [harness.scanRootURL])
        let failedPlist = try harness.readPreferencesPlist()

        XCTAssertEqual(failedResult.exitCode, 0)
        XCTAssertTrue(
            failedResult.standardError.contains("partial refresh"),
            failedResult.standardError
        )
        XCTAssertEqual(
            try String(contentsOf: harness.repositoryCacheFileURL, encoding: .utf8),
            originalCache
        )
        XCTAssertEqual(
            try String(contentsOf: harness.repositoryStatsCacheFileURL, encoding: .utf8),
            originalStatsCache
        )
        XCTAssertEqual(
            failedPlist["tinybuddy.gitTodayActivity.trustedSnapshot"] as? String,
            originalSnapshot
        )
        XCTAssertEqual(failedPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
    }

    func testScriptIdentifiesEachInvalidCandidateWithoutLeakingItsFullPath() throws {
        let harness = try ScriptHarness()
        _ = try harness.makeRepositoryWithExternalGitDir(
            named: "BrokenWorktreeA",
            commonDirRelativePath: "../missing-common-dir-a"
        )
        _ = try harness.makeRepositoryWithExternalGitDir(
            named: "BrokenWorktreeB",
            commonDirRelativePath: "../missing-common-dir-b"
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let repeatedResult = try harness.run(scanRoots: [harness.scanRootURL])
        let candidateIDs: (String) -> [String] = { standardError in
            standardError
                .split(separator: "\n")
                .filter { $0.contains("invalid repository candidate") }
                .compactMap { line in
                    line.split(separator: " ")
                        .first { $0.hasPrefix("candidate=") }
                        .map { String($0.dropFirst("candidate=".count)) }
                }
        }
        let identifiers = candidateIDs(result.standardError)
        let repeatedIdentifiers = candidateIDs(repeatedResult.standardError)

        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(Set(identifiers).count, 2)
        XCTAssertEqual(Set(repeatedIdentifiers), Set(identifiers))
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("repo-") })
        XCTAssertFalse(result.standardError.contains("BrokenWorktreeA"))
        XCTAssertFalse(result.standardError.contains("BrokenWorktreeB"))
        XCTAssertFalse(result.standardError.contains(harness.scanRootURL.path))
    }

    func testInvalidCandidateDiagnosticsRemainStableWhenPerlIsUnavailable() throws {
        let harness = try ScriptHarness()
        _ = try harness.makeRepositoryWithExternalGitDir(
            named: "PerlDeniedCandidateA",
            commonDirRelativePath: "../missing-perl-common-a"
        )
        _ = try harness.makeRepositoryWithExternalGitDir(
            named: "PerlDeniedCandidateB",
            commonDirRelativePath: "../missing-perl-common-b"
        )
        let source = try String(contentsOf: harness.scriptURL, encoding: .utf8)

        let result = try harness.run(
            scanRoots: [harness.scanRootURL],
            extraEnvironment: ["TINYBUDDY_PERL_BIN": "denied"]
        )
        let diagnostics = result.standardError
            .split(separator: "\n")
            .filter { $0.contains("invalid repository candidate") }
            .map(String.init)

        XCTAssertFalse(source.contains("/usr/bin/shasum"))
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertNotEqual(diagnostics[0], diagnostics[1])
        XCTAssertTrue(diagnostics.allSatisfy { $0.contains("candidate=") })
        XCTAssertFalse(result.standardError.contains(harness.scanRootURL.path))
    }

    func testScriptPreservesCommittedSnapshotAndCacheWhenReflogContainsFutureEvent() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: committed")]
        )
        XCTAssertEqual(try harness.run(scanRoots: [harness.scanRootURL]).exitCode, 0)
        let committedSnapshot = try XCTUnwrap(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        let committedCache = try String(contentsOf: harness.repositoryStatsCacheFileURL, encoding: .utf8)

        let futureEpoch = Int(Date().timeIntervalSince1970) + 86_400
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: committed"),
                harness.reflogLine(epoch: futureEpoch, message: "commit: future")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(metrics["refresh_outcome"], "failed")
        XCTAssertTrue(result.standardError.contains("future git reflog activity"))
        XCTAssertEqual(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String,
            committedSnapshot
        )
        XCTAssertEqual(
            try String(contentsOf: harness.repositoryStatsCacheFileURL, encoding: .utf8),
            committedCache
        )
    }

    func testScriptInvalidatesReflogCacheWhenTimeScopeChanges() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let perlProbe = try harness.makePerlProbe()
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: current")]
        )

        let initialEnvironment = [
            "TINYBUDDY_PERL_BIN": perlProbe.scriptURL.path,
            "TINYBUDDY_TIME_SCOPE_IDENTIFIER": "America/Los_Angeles"
        ]
        XCTAssertEqual(try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: initialEnvironment).exitCode, 0)
        XCTAssertEqual(try harness.perlInvocationCount(from: perlProbe.logURL), 1)
        let initialSnapshotValue = try XCTUnwrap(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        XCTAssertEqual(
            GitTodayActivityTrustedSnapshotStore.decode(initialSnapshotValue)?.timeScopeIdentifier,
            "America/Los_Angeles"
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_PERL_BIN": perlProbe.scriptURL.path,
            "TINYBUDDY_TIME_SCOPE_IDENTIFIER": "Asia/Shanghai"
        ])
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(try harness.perlInvocationCount(from: perlProbe.logURL), 2)
        XCTAssertEqual(metrics["reflog_unchanged_skip_count"], "0")
        XCTAssertEqual(metrics["recomputed_repository_count"], "1")
        let updatedSnapshotValue = try XCTUnwrap(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        XCTAssertEqual(
            GitTodayActivityTrustedSnapshotStore.decode(updatedSnapshotValue)?.timeScopeIdentifier,
            "Asia/Shanghai"
        )
    }

    func testScriptCountsDistinctUTCFocusBucketsAcrossLosAngelesDSTFallback() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let formatter = ISO8601DateFormatter()
        let firstEpoch = Int(try XCTUnwrap(formatter.date(from: "2026-11-01T01:10:00-07:00")).timeIntervalSince1970)
        let secondEpoch = Int(try XCTUnwrap(formatter.date(from: "2026-11-01T01:10:00-08:00")).timeIntervalSince1970)
        let refreshEpoch = Int(try XCTUnwrap(formatter.date(from: "2026-11-02T00:00:00-08:00")).timeIntervalSince1970)
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(epoch: firstEpoch, message: "commit: before fallback"),
                harness.reflogLine(epoch: secondEpoch, message: "commit: after fallback")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TZ": "America/Los_Angeles",
            "TINYBUDDY_TODAY": "2026-11-01",
            "TINYBUDDY_TIME_SCOPE_IDENTIFIER": "America/Los_Angeles",
            "TINYBUDDY_REFRESH_EPOCH": String(refreshEpoch)
        ])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
    }

    func testScriptSkipsAllWritesWhenTimeScopeTokenIsNoLongerCurrent() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let tokenURL = harness.rootURL.appendingPathComponent("time-scope-token")
        try "new-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: current")]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_TIME_SCOPE_FILE": tokenURL.path,
            "TINYBUDDY_TIME_SCOPE_TOKEN": "old-token"
        ])
        let metrics = try XCTUnwrap(harness.metrics(from: result.standardOutput))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(metrics["refresh_outcome"], "skipped")
        XCTAssertFalse(harness.fileManager.fileExists(atPath: harness.plistURL.path))
        XCTAssertFalse(harness.fileManager.fileExists(atPath: harness.repositoryCacheFileURL.path))
        XCTAssertFalse(harness.fileManager.fileExists(atPath: harness.repositoryStatsCacheFileURL.path))
    }

    func testScriptEmbedsCurrentLeaseTokenInTrustedSnapshot() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let tokenURL = harness.rootURL.appendingPathComponent("time-scope-token")
        try "current-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: current")]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_TIME_SCOPE_IDENTIFIER": "scope-current",
            "TINYBUDDY_TIME_SCOPE_FILE": tokenURL.path,
            "TINYBUDDY_TIME_SCOPE_TOKEN": "current-token"
        ])
        let encoded = try XCTUnwrap(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        let snapshot = try XCTUnwrap(GitTodayActivityTrustedSnapshotStore.decode(encoded))

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(snapshot.timeScopeIdentifier, "scope-current")
        XCTAssertEqual(snapshot.timeScopeToken, "current-token")
    }

    func testConcurrentScriptRefreshesLeaveReadableSnapshotAndStableThirdRun() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        let slowPerlURL = try harness.makeDelayingPerlProbe(delaySeconds: 1)
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "commit: second")
            ]
        )

        let environment = ["TINYBUDDY_PERL_BIN": slowPerlURL.path]
        let first = try harness.start(scanRoots: [harness.scanRootURL], extraEnvironment: environment)
        let second = try harness.start(scanRoots: [harness.scanRootURL], extraEnvironment: environment)
        let firstResult = first.wait()
        let secondResult = second.wait()
        let snapshotValue = try XCTUnwrap(
            (try harness.readPreferencesPlist())[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )
        let snapshot = try XCTUnwrap(GitTodayActivityTrustedSnapshotStore.decode(snapshotValue))
        let third = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: environment)
        let thirdMetrics = try XCTUnwrap(harness.metrics(from: third.standardOutput))

        XCTAssertEqual(firstResult.exitCode, 0, firstResult.standardError)
        XCTAssertEqual(secondResult.exitCode, 0, secondResult.standardError)
        XCTAssertEqual(snapshot.activity.commitCount, 2)
        XCTAssertEqual(snapshot.activity.focusBlockCount, 2)
        XCTAssertEqual(third.exitCode, 0, third.standardError)
        XCTAssertEqual(thirdMetrics["shared_data_written"], "0")
    }
}

private final class ScriptHarness {
    let fileManager = FileManager.default
    let rootURL: URL
    let homeURL: URL
    let scanRootURL: URL
    let plistURL: URL
    let scriptURL: URL
    let calendar: Calendar
    let todayIdentifier: String
    let cacheDirectoryURL: URL

    init() throws {
        let fixtureIdentifier = UUID().uuidString
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("TinyBuddyScriptTest-\(fixtureIdentifier)", isDirectory: true)
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        scanRootURL = rootURL.appendingPathComponent("scan-root", isDirectory: true)
        plistURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("TinyBuddyScriptPreferences-\(fixtureIdentifier)", isDirectory: true)
            .appendingPathComponent("group.plist")
        cacheDirectoryURL = rootURL.appendingPathComponent("repository-cache", isDirectory: true)
        scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/update_git_completion_count.sh", isDirectory: false)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        self.calendar = calendar
        todayIdentifier = Self.dayFormatter.string(from: Date())

        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scanRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    deinit {
        if fileManager.fileExists(atPath: rootURL.path) {
            try? fileManager.removeItem(at: rootURL)
        }
        let preferencesDirectoryURL = plistURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: preferencesDirectoryURL.path) {
            try? fileManager.removeItem(at: preferencesDirectoryURL)
        }
    }

    var repositoryCacheFileURL: URL {
        cacheDirectoryURL.appendingPathComponent("repositories.txt")
    }

    var repositoryStatsCacheFileURL: URL {
        cacheDirectoryURL.appendingPathComponent("repository-stats.tsv")
    }

    var snapshotWriteLockURL: URL {
        plistURL.deletingLastPathComponent()
            .appendingPathComponent(".tinybuddy-git-snapshot-write.lock", isDirectory: true)
    }

    func makeRepository(named name: String) throws -> URL {
        try makeRepository(atRelativePath: name)
    }

    func makeRepository(atRelativePath relativePath: String) throws -> URL {
        let repoURL = scanRootURL.appendingPathComponent(relativePath, isDirectory: true)
        let gitDirectoryURL = repoURL.appendingPathComponent(".git", isDirectory: true)
        let gitLogsURL = repoURL.appendingPathComponent(".git/logs", isDirectory: true)
        try fileManager.createDirectory(at: gitLogsURL, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: gitDirectoryURL.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        return repoURL
    }

    func makeRepositoryWithExternalGitDir(
        named name: String,
        commonDirRelativePath: String? = nil
    ) throws -> URL {
        let repoURL = scanRootURL.appendingPathComponent(name, isDirectory: true)
        let gitDirectoryURL = scanRootURL
            .appendingPathComponent(".tinybuddy-gitdirs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let gitLogsURL = gitDirectoryURL.appendingPathComponent("logs", isDirectory: true)

        try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: gitLogsURL, withIntermediateDirectories: true)
        try "gitdir: \(gitDirectoryURL.path)\n".write(
            to: repoURL.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/main\n".write(
            to: gitDirectoryURL.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        if let commonDirRelativePath {
            try commonDirRelativePath.appending("\n").write(
                to: gitDirectoryURL.appendingPathComponent("commondir"),
                atomically: true,
                encoding: .utf8
            )
        }

        return repoURL
    }

    func repointExternalGitDir(for repoURL: URL, toMissingDirectoryNamed name: String) throws {
        let gitDirectoryURL = rootURL.appendingPathComponent(name, isDirectory: true)
        try "gitdir: \(gitDirectoryURL.path)\n".write(
            to: repoURL.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeHeadReflog(for repoURL: URL, lines: [String]) throws {
        let reflogURL = try headReflogURL(for: repoURL)
        try writeHeadReflog(at: reflogURL, lines: lines)
    }

    func writeHeadReflog(at reflogURL: URL, lines: [String]) throws {
        try lines.joined(separator: "\n").appending("\n").write(to: reflogURL, atomically: true, encoding: .utf8)
    }

    func writeHeadReflogInPlace(for repoURL: URL, lines: [String]) throws {
        let reflogURL = try headReflogURL(for: repoURL)
        try lines.joined(separator: "\n").appending("\n").write(
            to: reflogURL,
            atomically: false,
            encoding: .utf8
        )
    }

    func headReflogMetadata(for repoURL: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: headReflogURL(for: repoURL).path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let size = try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value
        let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
        return "\(Int(modificationDate.timeIntervalSince1970)):\(size):\(inode)"
    }

    func setReflogModificationDate(for repoURL: URL, to date: Date) throws {
        let reflogURL = try headReflogURL(for: repoURL)
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: reflogURL.path)
    }

    func makeUnreadableAsFileHeadReflog(for repoURL: URL) throws {
        let reflogURL = repoURL.appendingPathComponent(".git/logs/HEAD", isDirectory: true)
        try fileManager.createDirectory(at: reflogURL, withIntermediateDirectories: true)
    }

    func seedPreferencesPlist(_ values: [String: Any]) throws {
        let dictionary = values as NSDictionary
        guard dictionary.write(to: plistURL, atomically: true) else {
            throw NSError(domain: "GitActivityRefreshScriptTests", code: 2)
        }
    }

    func readPreferencesPlist() throws -> [String: Any] {
        guard let dictionary = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw NSError(domain: "GitActivityRefreshScriptTests", code: 1)
        }
        return dictionary
    }

    func makeFindProbe() throws -> FindProbe {
        let scriptURL = rootURL.appendingPathComponent("find-probe.sh")
        let logURL = rootURL.appendingPathComponent("find-probe.log")
        let script = """
        #!/bin/bash
        printf '%s\\n' "$*" >> "\(logURL.path)"
        exec /usr/bin/find "$@"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return FindProbe(scriptURL: scriptURL, logURL: logURL)
    }

    func makeFailingRecursiveFindProbe() throws -> URL {
        let scriptURL = rootURL.appendingPathComponent("failing-find-probe.sh")
        let script = """
        #!/bin/bash
        /usr/bin/find "$@"
        case " $* " in
          *" -name .git "*) exit 1 ;;
        esac
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    func makeStatProbeFailingHeadReflog(for repoURL: URL, delaySeconds: Int = 0) throws -> URL {
        let scriptURL = rootURL.appendingPathComponent("failing-stat-probe.sh")
        let repositoryName = repoURL.lastPathComponent
        let failureCommand = delaySeconds > 0
            ? "exec /bin/sleep \(delaySeconds)"
            : "exit 1"
        let script = """
        #!/bin/bash
        for argument in "$@"; do
          case "$argument" in
            */\(repositoryName)/.git/logs/HEAD) \(failureCommand) ;;
          esac
        done
        exec /usr/bin/stat "$@"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    func makePerlProbe() throws -> PerlProbe {
        let scriptURL = rootURL.appendingPathComponent("perl-probe.sh")
        let logURL = rootURL.appendingPathComponent("perl-probe.log")
        let script = """
        #!/bin/bash
        printf 'perl\\n' >> "\(logURL.path)"
        exec /usr/bin/perl "$@"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return PerlProbe(scriptURL: scriptURL, logURL: logURL)
    }

    func makeSlowPerlProbe() throws -> URL {
        let scriptURL = rootURL.appendingPathComponent("slow-perl-probe.sh")
        let script = """
        #!/bin/bash
        exec /bin/sleep 30
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    func makeDelayingPerlProbe(delaySeconds: Int) throws -> URL {
        let scriptURL = rootURL.appendingPathComponent("delaying-perl-probe.sh")
        let script = """
        #!/bin/bash
        /bin/sleep \(delaySeconds)
        exec /usr/bin/perl "$@"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    func recursiveScanInvocationCount(from logURL: URL) throws -> Int {
        guard fileManager.fileExists(atPath: logURL.path) else {
            return 0
        }

        let content = try String(contentsOf: logURL, encoding: .utf8)
        return content
            .split(separator: "\n")
            .filter { $0.contains("-name .git") }
            .count
    }

    func perlInvocationCount(from logURL: URL) throws -> Int {
        guard fileManager.fileExists(atPath: logURL.path) else {
            return 0
        }

        let content = try String(contentsOf: logURL, encoding: .utf8)
        return content.split(separator: "\n").count
    }

    func metrics(from standardOutput: String) -> [String: String]? {
        guard let line = standardOutput
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("TINYBUDDY_REFRESH_METRICS\t") }) else {
            return nil
        }

        var values: [String: String] = [:]
        for field in line.split(separator: "\t").dropFirst() {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }
            values[parts[0]] = parts[1]
        }
        return values
    }

    func run(scanRoots: [URL], extraEnvironment: [String: String] = [:]) throws -> ScriptRunResult {
        try start(scanRoots: scanRoots, extraEnvironment: extraEnvironment).wait()
    }

    func start(scanRoots: [URL], extraEnvironment: [String: String] = [:]) throws -> RunningScriptRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeURL.path
        environment["TINYBUDDY_USER_HOME"] = homeURL.path
        environment["TINYBUDDY_APP_GROUP_CONTAINER"] = rootURL.appendingPathComponent("group-container", isDirectory: true).path
        environment["TINYBUDDY_APP_GROUP_PREFERENCES_DIR"] = plistURL.deletingLastPathComponent().path
        environment["TINYBUDDY_APP_GROUP_PREFERENCES_PLIST"] = plistURL.path
        environment["TINYBUDDY_GIT_REPOSITORY_CACHE_DIR"] = cacheDirectoryURL.path
        environment["TINYBUDDY_GIT_SCAN_ROOTS"] = scanRoots.map(\.path).joined(separator: "\n")
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        environment["TINYBUDDY_REFRESH_EPOCH"] = String(Int(nextDay.timeIntervalSince1970) - 1)
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        return RunningScriptRun(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    }

    func reflogLine(daysOffset: Int, hour: Int, minute: Int, message: String) -> String {
        let baseDate = calendar.startOfDay(for: Date())
        let date = calendar.date(
            byAdding: DateComponents(day: daysOffset, hour: hour, minute: minute),
            to: baseDate
        )!
        let epoch = Int(date.timeIntervalSince1970)
        let offsetSeconds = calendar.timeZone.secondsFromGMT(for: date)
        let offsetHours = offsetSeconds / 3600
        let offsetMinutes = abs(offsetSeconds / 60) % 60
        let offsetSign = offsetSeconds >= 0 ? "+" : "-"
        let timezoneOffset = String(format: "%@%02d%02d", offsetSign, abs(offsetHours), offsetMinutes)

        return "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 Tiny Buddy <tinybuddy@example.com> \(epoch) \(timezoneOffset)\t\(message)"
    }

    func reflogLine(epoch: Int, message: String) -> String {
        "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 Tiny Buddy <tinybuddy@example.com> \(epoch) +0000\t\(message)"
    }

    func dayIdentifier(daysOffset: Int) -> String {
        let date = calendar.date(byAdding: .day, value: daysOffset, to: Date())!
        return Self.dayFormatter.string(from: date)
    }

    private func headReflogURL(for repoURL: URL) throws -> URL {
        let dotGitURL = repoURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return dotGitURL.appendingPathComponent("logs/HEAD")
        }

        let gitdirDeclaration = try String(contentsOf: dotGitURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir: "
        guard gitdirDeclaration.hasPrefix(prefix) else {
            throw NSError(domain: "GitActivityRefreshScriptTests", code: 3)
        }

        let gitDirectoryPath = String(gitdirDeclaration.dropFirst(prefix.count))
        return URL(fileURLWithPath: gitDirectoryPath, isDirectory: true)
            .appendingPathComponent("logs/HEAD")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private final class RunningScriptRun {
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func wait() -> ScriptRunResult {
        process.waitUntilExit()
        return ScriptRunResult(
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
}

private struct ScriptRunResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private struct FindProbe {
    let scriptURL: URL
    let logURL: URL
}

private struct PerlProbe {
    let scriptURL: URL
    let logURL: URL
}
