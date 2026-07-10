import Foundation
import XCTest

final class GitActivityRefreshScriptTests: XCTestCase {
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

    func testScriptPreservesPreviousSharedDataWhenAnyReadableReflogFailsToParse() throws {
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

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.standardError.contains("preserving previous shared data"),
            "stderr did not mention preserving previous shared data: \(result.standardError)"
        )
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 99)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 77)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "PreviousProject")
    }

    func testScriptPreservesPreviousSharedDataWhenRepositoryScanFailsAndRecoversLater() throws {
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

        XCTAssertEqual(failedResult.exitCode, 1)
        XCTAssertTrue(failedResult.standardError.contains("preserving previous shared data"))
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 99)
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 77)
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "PreviousProject")

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

        _ = try harness.run(scanRoots: [harness.scanRootURL], extraEnvironment: [
            "TINYBUDDY_FIND_BIN": findProbe.scriptURL.path
        ])
        let secondRecursiveScanCount = try harness.recursiveScanInvocationCount(from: findProbe.logURL)

        XCTAssertEqual(firstRecursiveScanCount, 1)
        XCTAssertEqual(secondRecursiveScanCount, 1)
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

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.standardError.contains("preserving previous shared data"))
        XCTAssertEqual(try harness.recursiveScanInvocationCount(from: findProbe.logURL), 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")

    }

    func testScriptRebuildsBadCachedRepositoryListThenRecoversOnNextInvocation() throws {
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

        let failedResult = try harness.run(scanRoots: [harness.scanRootURL])
        let preservedPlist = try harness.readPreferencesPlist()

        XCTAssertEqual(failedResult.exitCode, 1)
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
        XCTAssertEqual(preservedPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectBeta")

        let recoveredResult = try harness.run(scanRoots: [harness.scanRootURL])
        let recoveredPlist = try harness.readPreferencesPlist()

        XCTAssertEqual(recoveredResult.exitCode, 0)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(recoveredPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectBeta")
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
        let brokenWorktreeURL = try harness.makeRepositoryWithExternalGitDir(
            named: "BrokenWorktree",
            commonDirRelativePath: "../missing-common-dir"
        )

        try harness.writeHeadReflog(
            for: validRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: valid")
            ]
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
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 1)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
        XCTAssertEqual(metrics["repository_count"], "1")
    }
}

private struct ScriptHarness {
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
        rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        scanRootURL = rootURL.appendingPathComponent("scan-root", isDirectory: true)
        plistURL = rootURL.appendingPathComponent("group.plist")
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
    }

    var repositoryCacheFileURL: URL {
        cacheDirectoryURL.appendingPathComponent("repositories.txt")
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

        let standardOutput = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let standardError = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ScriptRunResult(
            exitCode: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
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
