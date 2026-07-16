import Foundation
@testable import TinyBuddyCore
import XCTest

final class GitActivityRealRepositoryFixtureTests: XCTestCase {
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

        let symlinkRoot = fixture.rootURL.appendingPathComponent("scan-root-link", isDirectory: true)
        try fixture.fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: fixture.scanRootURL)

        let first = try fixture.runScript(
            scanRoots: [fixture.scanRootURL, symlinkRoot, fixture.scanRootURL]
        )
        let firstPlist = try fixture.readPreferencesPlist()
        let firstMetrics = try XCTUnwrap(fixture.metrics(from: first.standardOutput))
        let firstSnapshot = try XCTUnwrap(
            firstPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String
        )

        XCTAssertEqual(first.exitCode, 0, first.standardError)
        XCTAssertEqual(firstMetrics["authorized_root_count"], "1")
        XCTAssertEqual(firstMetrics["repository_count"], "1")
        XCTAssertEqual(firstPlist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(firstPlist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
        XCTAssertEqual(
            firstPlist["tinybuddy.gitTodayRecentProject.projectName"] as? String,
            "ProjectAlpha"
        )

        let repeated = try fixture.runScript(scanRoots: [symlinkRoot, fixture.scanRootURL])
        let repeatedPlist = try fixture.readPreferencesPlist()
        let repeatedMetrics = try XCTUnwrap(fixture.metrics(from: repeated.standardOutput))

        XCTAssertEqual(repeated.exitCode, 0, repeated.standardError)
        XCTAssertEqual(repeatedMetrics["repository_count"], "1")
        XCTAssertEqual(repeatedMetrics["reflog_unchanged_skip_count"], "2")
        XCTAssertEqual(repeatedMetrics["shared_data_written"], "0")
        XCTAssertEqual(
            repeatedPlist[GitTodayActivityTrustedSnapshotStore.Key.snapshot] as? String,
            firstSnapshot
        )
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
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("TinyBuddyRealGit-\(UUID().uuidString)", isDirectory: true)
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        scanRootURL = rootURL.appendingPathComponent("scan-root", isDirectory: true)
        preferencesDirectoryURL = rootURL.appendingPathComponent("preferences", isDirectory: true)
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
    }

    deinit {
        try? fileManager.removeItem(at: rootURL)
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

    func runScript(scanRoots: [URL]) throws -> RealGitScriptResult {
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
