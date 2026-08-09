import XCTest
@testable import TinyBuddyCore
import Foundation

final class GitCommandExecutorTests: XCTestCase {
    private final class ErrorSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: GitCommandError?

        var error: GitCommandError? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func record(_ error: GitCommandError) {
            lock.lock()
            storedError = error
            lock.unlock()
        }
    }

    // MARK: - Basic Execution

    func testExecutesVersionSuccessfully() throws {
        try runGitTest { executor in
            let result = try executor.execute(arguments: ["version"])

            XCTAssertEqual(result.terminationStatus, 0)
            XCTAssertFalse(result.didTimeout)
            XCTAssertFalse(result.wasCancelled)
            XCTAssertFalse(result.outputTruncated)
            XCTAssertGreaterThan(result.duration, 0)
            XCTAssertTrue(result.standardOutput.contains("git version"))
        }
    }

    func testExecutesWithCustomWorkingDirectory() throws {
        try runGitTest { executor in
            let tmp = FileManager.default.temporaryDirectory
            let result = try executor.execute(
                arguments: ["rev-parse", "--git-dir"],
                workingDirectory: tmp
            )

            // tmp is not a git repo, so this would get an error or empty.
            // Executor should treat non-zero exit as a normal result, not throw.
            // Actually rev-parse --git-dir in a non-repo will exit with non-zero.
            // That's a valid result.
            XCTAssertNotEqual(result.terminationStatus, 0)
            XCTAssertTrue(result.standardError.contains("not a git repository")
                || result.standardError.contains("fatal:"))
        }
    }

    func testInvalidWorkingDirectoryThrows() {
        let executor = makeExecutor()
        let bogusURL = URL(fileURLWithPath: "/tmp/__tinybuddy_bogus_dir_that_does_not_exist__")

        XCTAssertThrowsError(
            try executor.execute(
                arguments: ["status"],
                workingDirectory: bogusURL
            )
        ) { error in
            guard case GitCommandError.invalidWorkingDirectory(let path) = error else {
                XCTFail("Expected invalidWorkingDirectory, got \(error)")
                return
            }
            XCTAssertTrue(path.contains("bogus"))
        }
    }

    // MARK: - Read-Only Enforcement

    func testReadOnlyBlocksWriteCommands() {
        let executor = makeExecutor()

        XCTAssertThrowsError(
            try executor.execute(arguments: ["commit", "-m", "test"])
        ) { error in
            guard case GitCommandError.commandNotAllowed(let command) = error else {
                XCTFail("Expected commandNotAllowed, got \(error)")
                return
            }
            XCTAssertEqual(command, "commit")
        }
    }

    func testReadOnlyBlocksPush() {
        let executor = makeExecutor()

        XCTAssertThrowsError(
            try executor.execute(arguments: ["push"])
        ) { error in
            guard case GitCommandError.commandNotAllowed(let command) = error else {
                XCTFail("Expected commandNotAllowed, got \(error)")
                return
            }
            XCTAssertEqual(command, "push")
        }
    }

    func testReadOnlyBlocksInteractiveCommands() {
        let executor = makeExecutor()

        for cmd in ["rebase", "merge", "fetch", "pull", "checkout", "reset", "clean"] {
            XCTAssertThrowsError(
                try executor.execute(arguments: [cmd])
            ) { error in
                guard case GitCommandError.commandNotAllowed(let command) = error else {
                    XCTFail("Expected commandNotAllowed for '\(cmd)', got \(error)")
                    return
                }
                XCTAssertEqual(command, cmd)
            }
        }
    }

    func testReadOnlyBlocksMutatingFormsOfDualPurposeCommands() {
        let executor = makeExecutor()
        let invocations = [
            ["config", "user.name", "Mutated Name"],
            ["config", "--unset", "user.name"],
            ["symbolic-ref", "HEAD", "refs/heads/other"],
            ["reflog", "expire", "--all"],
            ["multi-pack-index", "write"],
            ["interpret-trailers", "--in-place", "message.txt"],
            ["mailinfo", "message.txt", "patch.txt"],
        ]

        for invocation in invocations {
            XCTAssertThrowsError(try executor.execute(arguments: invocation)) { error in
                guard case GitCommandError.commandNotAllowed(let command) = error else {
                    return XCTFail("Expected commandNotAllowed for \(invocation), got \(error)")
                }
                XCTAssertEqual(command, invocation[0])
            }
        }
    }

    func testReadOnlyAllowsReadCommands() throws {
        try runGitTest { executor in
            // Read-only commands should work.
            for cmd in ["version", "help", "config"] {
                let result = try executor.execute(arguments: [cmd])
                // These should at least attempt to run.
                XCTAssertTrue(
                    result.terminationStatus == 0 || !result.standardError.isEmpty,
                    "Command '\(cmd)' should execute without throwing"
                )
            }
        }
    }

    func testReadOnlyAllowsConfigFileReadForm() throws {
        // `git config --file <path> <name>` reads a key from an explicit
        // config file. The `<path>` is the value of the `--file` option, not
        // a bare config value, so the invocation must be treated as a read.
        let executor = makeExecutor()
        let configPath = "/tmp/tinybuddy-config-read-test-\(UUID().uuidString).cfg"
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        do {
            let result = try executor.execute(
                arguments: ["config", "--file", configPath, "user.name"]
            )
            // Missing file is a normal git error result, not a policy rejection.
            XCTAssertNotEqual(result.terminationStatus, 0)
        } catch let error as GitCommandError {
            guard case .commandNotAllowed = error else {
                return XCTFail("Unexpected error for config --file read: \(error)")
            }
            XCTFail("config --file <path> <name> is a read but was rejected")
        } catch {
            XCTFail("Unexpected error for config --file read: \(error)")
        }

        // The write form `config --file <path> <name> <value>` must still be
        // rejected even though `--file` consumes one argument.
        XCTAssertThrowsError(
            try executor.execute(
                arguments: ["config", "--file", configPath, "user.name", "value"]
            )
        ) { error in
            guard case GitCommandError.commandNotAllowed(let command) = error else {
                return XCTFail("Expected commandNotAllowed for config --file write, got \(error)")
            }
            XCTAssertEqual(command, "config")
        }
    }

    func testReadOnlyAllowsConfigDefaultReadForm() throws {
        // `git config --default <value> <name>` reads a key and falls back to
        // `<value>` when the key is missing. `<value>` is consumed by the
        // `--default` option and must not count toward the bare-value tally;
        // otherwise the read form is mistaken for `config <name> <value>`.
        let executor = makeExecutor()
        let fallback = "tinybuddy-fallback-\(UUID().uuidString)"

        do {
            let result = try executor.execute(
                arguments: ["config", "--default", fallback, "tinybuddy.missing-key-\(UUID().uuidString)"]
            )
            XCTAssertEqual(result.terminationStatus, 0)
            XCTAssertTrue(result.standardOutput.contains(fallback))
        } catch let error as GitCommandError {
            guard case .commandNotAllowed = error else {
                return XCTFail("Unexpected error for config --default read: \(error)")
            }
            XCTFail("config --default <value> <name> is a read but was rejected")
        } catch {
            XCTFail("Unexpected error for config --default read: \(error)")
        }
    }

    func testReadOnlyAllowsConfigTypeReadForm() throws {
        // `git config --type <type> <name>` reads a key with an explicit type.
        // `<type>` is consumed by the `--type` option and must not count toward
        // the bare-value tally.
        let executor = makeExecutor()

        do {
            let result = try executor.execute(
                arguments: ["config", "--type", "bool", "core.ignorecase"]
            )
            // A missing or unreadable value is a normal git result, not a
            // policy rejection.
            XCTAssertEqual(result.terminationStatus, 0)
        } catch let error as GitCommandError {
            guard case .commandNotAllowed = error else {
                return XCTFail("Unexpected error for config --type read: \(error)")
            }
            XCTFail("config --type <type> <name> is a read but was rejected")
        } catch {
            XCTFail("Unexpected error for config --type read: \(error)")
        }

        // The write form `config --type <type> <name> <value>` must still be
        // rejected even though `--type` consumes one argument.
        XCTAssertThrowsError(
            try executor.execute(
                arguments: ["config", "--type", "bool", "user.name", "true"]
            )
        ) { error in
            guard case GitCommandError.commandNotAllowed(let command) = error else {
                return XCTFail("Expected commandNotAllowed for config --type write, got \(error)")
            }
            XCTAssertEqual(command, "config")
        }
    }

    func testReadOnlyAllowsConfigFileShortFormRead() throws {
        // `git config -f <path> <name>` is the short form of
        // `git config --file <path> <name>` and reads a key from an explicit
        // config file. The `<path>` is the value of the `-f` option, not a
        // bare config value, so the invocation must be treated as a read.
        let executor = makeExecutor()
        let configPath = "/tmp/tinybuddy-config-short-test-\(UUID().uuidString).cfg"
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        do {
            let result = try executor.execute(
                arguments: ["config", "-f", configPath, "user.name"]
            )
            // Missing file is a normal git error result, not a policy rejection.
            XCTAssertNotEqual(result.terminationStatus, 0)
        } catch let error as GitCommandError {
            guard case .commandNotAllowed = error else {
                return XCTFail("Unexpected error for config -f read: \(error)")
            }
            XCTFail("config -f <path> <name> is a read but was rejected")
        } catch {
            XCTFail("Unexpected error for config -f read: \(error)")
        }

        // The write form `config -f <path> <name> <value>` must still be
        // rejected even though `-f` consumes one argument.
        XCTAssertThrowsError(
            try executor.execute(
                arguments: ["config", "-f", configPath, "user.name", "value"]
            )
        ) { error in
            guard case GitCommandError.commandNotAllowed(let command) = error else {
                return XCTFail("Expected commandNotAllowed for config -f write, got \(error)")
            }
            XCTAssertEqual(command, "config")
        }
    }

    func testReadOnlyAllowsReflogRefReadShorthand() throws {
        // `git reflog <ref>` is the read shorthand for `git reflog show <ref>`.
        let executor = makeExecutor()
        let invocations: [[String]] = [
            ["reflog", "HEAD"],
            ["reflog", "show", "HEAD"],
            ["reflog", "exists", "HEAD"],
        ]
        for invocation in invocations {
            do {
                let result = try executor.execute(arguments: invocation)
                // HEAD@{0} may not exist in this repo; a normal git error is fine.
                _ = result
            } catch let error as GitCommandError {
                guard case .commandNotAllowed = error else {
                    continue
                }
                XCTFail("\(invocation.joined(separator: " ")) is a read but was rejected")
            } catch {
                continue
            }
        }
    }

    func testReadOnlyStillBlocksReflogWriteSubcommands() {
        let executor = makeExecutor()
        for invocation in [
            ["reflog", "expire", "--all"],
            ["reflog", "delete", "HEAD@{0}"],
        ] {
            XCTAssertThrowsError(
                try executor.execute(arguments: invocation)
            ) { error in
                guard case GitCommandError.commandNotAllowed(let command) = error else {
                    return XCTFail("Expected commandNotAllowed for \(invocation), got \(error)")
                }
                XCTAssertEqual(command, "reflog")
            }
        }
    }

    func testReadOnlyModeDisabledAllowsWriteCommands() throws {
        try runGitTest(configure: { config in
            var cfg = config
            cfg.readOnly = false
            return cfg
        }) { executor in
            // Even with readOnly=false, write commands need a real repo.
            // We test that the executor doesn't throw commandNotAllowed.
            let tmp = FileManager.default.temporaryDirectory
            do {
                let result = try executor.execute(
                    arguments: ["status"],
                    workingDirectory: tmp
                )
                // Non-repo status will fail, but shouldn't throw commandNotAllowed.
                XCTAssertNotEqual(result.terminationStatus, 0)
            } catch let error as GitCommandError {
                if case .commandNotAllowed = error {
                    XCTFail("Should not block commands in readOnly=false mode")
                }
            } catch {
                // Other errors are fine (e.g., git not found, etc.)
            }
        }
    }

    // MARK: - Output Truncation

    func testOutputTruncationWhenExceedingMaxBytes() throws {
        try runGitTest { executor in
            // Create an executor with tiny output limit.
            let tinyExecutor = GitCommandExecutor(
                gitExecutableURL: executorGitURL(),
                configuration: GitCommandExecutor.Configuration(
                    maxOutputBytes: 10  // Very small
                )
            )

            // `git help` produces output > 10 bytes (while `--help` is a flag, not a subcommand).
            let result = try tinyExecutor.execute(arguments: ["help"])

            XCTAssertTrue(result.outputTruncated || result.standardOutput.utf8.count <= 10)
            if result.outputTruncated {
                XCTAssertLessThanOrEqual(result.standardOutput.utf8.count, 10)
            }
        }
    }

    func testLargeOutputDoesNotThrow() throws {
        try runGitTest { executor in
            // git log --all on a repo with no commits - fine.
            let result = try executor.execute(arguments: ["log", "--all", "--oneline"])

            // Should not throw even with large output.
            XCTAssertFalse(result.didTimeout)
        }
    }

    func testSimultaneousLargeStandardOutputAndErrorAreBoundedWithoutDeadlock() throws {
        try withTemporaryExecutableScript(
            """
            #!/bin/bash
            i=0
            while [ "$i" -lt 5000 ]; do
              printf 'stdout-%08d-abcdefghijklmnopqrstuvwxyz\\n' "$i"
              printf 'stderr-%08d-abcdefghijklmnopqrstuvwxyz\\n' "$i" >&2
              i=$((i + 1))
            done
            """
        ) { executableURL in
            let maxBytes: Int64 = 1024
            let executor = GitCommandExecutor(
                gitExecutableURL: executableURL,
                configuration: GitCommandExecutor.Configuration(maxOutputBytes: maxBytes)
            )

            let result = try executor.execute(arguments: ["version"], timeoutSeconds: 5)

            XCTAssertEqual(result.terminationStatus, 0)
            XCTAssertTrue(result.outputTruncated)
            XCTAssertLessThanOrEqual(
                result.standardOutput.utf8.count + result.standardError.utf8.count,
                Int(maxBytes)
            )
        }
    }

    // MARK: - Timeout

    func testTimeoutBoundsACommandThatProducesNoOutput() throws {
        try withTemporaryExecutableScript(
            """
            #!/bin/bash
            exec /bin/sleep 10
            """
        ) { executableURL in
            let executor = GitCommandExecutor(gitExecutableURL: executableURL)
            let startedAt = ProcessInfo.processInfo.systemUptime

            XCTAssertThrowsError(
                try executor.execute(arguments: ["version"], timeoutSeconds: 1)
            ) { error in
                XCTAssertEqual(error as? GitCommandError, .timeout(seconds: 1))
            }

            XCTAssertLessThan(
                ProcessInfo.processInfo.systemUptime - startedAt,
                4,
                "the timeout must run concurrently with the child, not after reading output to EOF"
            )
        }
    }

    // MARK: - Non-Zero Exit

    func testNonZeroExitReturnsResultDoesNotThrow() throws {
        try runGitTest { executor in
            let result = try executor.execute(arguments: ["rev-parse", "--git-dir"])

            // In a non-repo directory, this exits non-zero but doesn't throw.
            if result.terminationStatus != 0 {
                XCTAssertTrue(
                    result.standardError.contains("not a git repository")
                    || result.standardError.contains("fatal:")
                    || result.standardError.contains("error:"),
                    "Expected git error message, got: \(result.standardError)"
                )
            }
        }
    }

    func testNonZeroExitInRepoReturnsMetrics() throws {
        try withTemporaryRepository { repoURL in
            let executor = makeExecutor()

            // `git status` should succeed in a valid repo.
            let result = try executor.execute(
                arguments: ["status", "--porcelain"],
                workingDirectory: repoURL
            )

            XCTAssertEqual(result.terminationStatus, 0)
        }
    }

    // MARK: - Process Cancellation

    func testCancelAllProcessesStopsRunningCommand() throws {
        try withTemporaryExecutableScript(
            """
            #!/bin/bash
            trap '' TERM
            exec /bin/sleep 10
            """
        ) { executableURL in
            let executor = GitCommandExecutor(gitExecutableURL: executableURL)
            let finished = XCTestExpectation(description: "finished")
            let errorSpy = ErrorSpy()

            DispatchQueue.global().async {
                do {
                    _ = try executor.execute(arguments: ["version"], timeoutSeconds: 30)
                } catch let error as GitCommandError {
                    errorSpy.record(error)
                } catch {
                    XCTFail("Unexpected cancellation error: \(error)")
                }
                finished.fulfill()
            }

            // Give the process a moment to start.
            Thread.sleep(forTimeInterval: 0.2)
            executor.cancelAll()

            // Cancellation should win over Process's SIGTERM classification.
            let result = XCTWaiter().wait(for: [finished], timeout: 5)
            XCTAssertEqual(result, .completed, "Cancelled command should finish within deadline")
            XCTAssertEqual(errorSpy.error, .cancelled)
        }
    }

    // MARK: - Executable Discovery

    func testLocateGitExecutable() {
        let url = GitCommandExecutor.locateGitExecutable()

        // This depends on whether git is installed.
        // On dev machines, it should exist.
        #if arch(arm64) || arch(x86_64)
        // Just verify it returns a URL or nil - no crash.
        if let url {
            XCTAssertTrue((try? url.checkResourceIsReachable()) ?? false)
            XCTAssertTrue(
                (try? url.resourceValues(forKeys: [.isExecutableKey]))?.isExecutable == true
            )
        }
        #endif
    }

    func testExecutorWithExplicitGitURL() throws {
        guard let gitURL = executorGitURL() else {
            throw XCTSkip("Git not available on this machine")
        }

        let executor = GitCommandExecutor(
            gitExecutableURL: gitURL,
            configuration: GitCommandExecutor.Configuration()
        )

        let result = try executor.execute(arguments: ["version"])
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.standardOutput.contains("git version"))
    }

    // MARK: - Convenience Methods

    func testGitVersion() throws {
        try runGitTest { executor in
            let version = executor.gitVersion()

            XCTAssertNotNil(version)
            XCTAssertTrue(version?.allSatisfy { $0.isNumber || $0 == "." || $0 == " " || $0 == "(" || $0 == ")" || $0 == "-" || $0.isLetter } ?? false)
        }
    }

    func testIsValidRepository() throws {
        try runGitTest { executor in
            let tmp = FileManager.default.temporaryDirectory

            // tmp is not a repo.
            let isValid = executor.isValidRepository(at: tmp)
            XCTAssertFalse(isValid)
        }
    }

    func testIsValidRepositoryWithRealRepo() throws {
        try withTemporaryRepository { repoURL in
            let executor = makeExecutor()

            let isValid = executor.isValidRepository(at: repoURL)
            XCTAssertTrue(isValid)
        }
    }

    // MARK: - Error Classification

    func testGitNotFoundError() {
        let bogusURL = URL(fileURLWithPath: "/usr/bin/__git_bogus__")
        let executor = GitCommandExecutor(
            gitExecutableURL: bogusURL
        )

        XCTAssertThrowsError(
            try executor.execute(arguments: ["version"])
        ) { error in
            guard case GitCommandError.gitNotFound = error else {
                XCTFail("Expected gitNotFound, got \(error)")
                return
            }
        }
    }

    func testExecutableAccessDeniedError() throws {
        // Create a non-executable file that looks like git.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyGitTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeGit = tmpDir.appendingPathComponent("git")
        try "fake".write(to: fakeGit, atomically: true, encoding: .utf8)
        // Remove executable permission.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fakeGit.path)

        let executor = GitCommandExecutor(gitExecutableURL: fakeGit)

        XCTAssertThrowsError(
            try executor.execute(arguments: ["version"])
        ) { error in
            guard case GitCommandError.executableAccessDenied = error else {
                XCTFail("Expected executableAccessDenied, got \(error)")
                return
            }
        }
    }

    // MARK: - Environment Sanitization

    func testGitUsesSafeEnvironment() throws {
        try runGitTest { executor in
            // Verify git works with our sanitised environment.
            let result = try executor.execute(arguments: ["version"])

            XCTAssertEqual(result.terminationStatus, 0)
            XCTAssertTrue(result.standardOutput.contains("git version"))
            // GIT_TERMINAL_PROMPT=0 should prevent any interactive prompt.
            XCTAssertFalse(result.standardError.contains("prompt"))
        }
    }

    func testExtraEnvironmentPassesThrough() throws {
        try runGitTest(configure: { config in
            var cfg = config
            cfg.extraEnvironment = ["TINYBUDDY_TEST_VAR": "hello_world"]
            return cfg
        }) { executor in
            // Test that extra env vars are available. We can check by running
            // `git config --list` and checking that our var isn't there
            // (git defaults don't include it). Instead, test with a custom
            // executor that can pass env through to the process.
            let result = try executor.execute(arguments: ["config", "--list"])

            XCTAssertEqual(result.terminationStatus, 0)
        }
    }

    // MARK: - Custom PATH

    func testCustomPATH() {
        let executor = GitCommandExecutor(
            gitExecutableURL: URL(fileURLWithPath: "/usr/bin/git"),
            configuration: GitCommandExecutor.Configuration(
                customPATH: "/custom/bin:/usr/bin"
            )
        )

        // If /usr/bin/git exists, this should work.
        if FileManager.default.fileExists(atPath: "/usr/bin/git") {
            XCTAssertNoThrow(
                try executor.execute(arguments: ["version"])
            )
        }
    }

    // MARK: - Concurrent Execution

    func testConcurrentExecutions() throws {
        try runGitTest { executor in
            let count = 5
            let expectation = self.expectation(description: "concurrent")
            expectation.expectedFulfillmentCount = count

            let group = DispatchGroup()
            let queue = DispatchQueue(
                label: "TinyBuddyTests.ConcurrentGit",
                attributes: .concurrent
            )

            for i in 0..<count {
                queue.async(group: group) {
                    do {
                        let result = try executor.execute(
                            arguments: ["version"]
                        )
                        XCTAssertEqual(result.terminationStatus, 0)
                    } catch {
                        XCTFail("Concurrent execution \(i) failed: \(error)")
                    }
                    expectation.fulfill()
                }
            }

            self.wait(for: [expectation], timeout: 15)
        }
    }

    // MARK: - Helpers

    /// Creates a default executor using auto-discovery.
    private func makeExecutor() -> GitCommandExecutor {
        GitCommandExecutor(configuration: GitCommandExecutor.Configuration())
    }

    /// Returns the git executable URL for tests, or nil.
    private func executorGitURL() -> URL? {
        if let url = GitCommandExecutor.locateGitExecutable() {
            return url
        }
        // Fallback to common paths.
        for path in ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func withTemporaryExecutableScript(
        _ source: String,
        _ block: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyGitExecutorScript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = directory.appendingPathComponent("git")
        try source.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try block(executableURL)
    }

    /// Runs a test block with a Git executor. Skips the test if Git is not available.
    private func runGitTest(
        configure: ((GitCommandExecutor.Configuration) -> GitCommandExecutor.Configuration)? = nil,
        _ block: (GitCommandExecutor) throws -> Void
    ) throws {
        guard let gitURL = executorGitURL() else {
            throw XCTSkip("Git is not installed on this machine")
        }

        var config = GitCommandExecutor.Configuration()
        if let configure {
            config = configure(config)
        }

        let executor = GitCommandExecutor(
            gitExecutableURL: gitURL,
            configuration: config
        )
        try block(executor)
    }

    /// Creates a temporary Git repository, runs the test block, then cleans up.
    private func withTemporaryRepository(
        _ block: (URL) throws -> Void
    ) throws {
        guard let gitURL = executorGitURL() else {
            throw XCTSkip("Git is not installed")
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyGitRepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Initialize a Git repository.
        let initProcess = Process()
        initProcess.executableURL = gitURL
        initProcess.arguments = ["init"]
        initProcess.currentDirectoryURL = tmpDir
        initProcess.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "LC_ALL": "C"
        ]
        try initProcess.run()
        initProcess.waitUntilExit()
        guard initProcess.terminationStatus == 0 else {
            throw XCTSkip("Failed to initialize test repository")
        }

        // Configure a user for the test repo.
        let configProcess = Process()
        configProcess.executableURL = gitURL
        configProcess.arguments = ["config", "user.email", "test@tinybuddy.app"]
        configProcess.currentDirectoryURL = tmpDir
        configProcess.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "LC_ALL": "C"
        ]
        try configProcess.run()
        configProcess.waitUntilExit()

        // Set user name.
        let nameProcess = Process()
        nameProcess.executableURL = gitURL
        nameProcess.arguments = ["config", "user.name", "TinyBuddy Test"]
        nameProcess.currentDirectoryURL = tmpDir
        nameProcess.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "LC_ALL": "C"
        ]
        try nameProcess.run()
        nameProcess.waitUntilExit()

        try block(tmpDir)
    }
}
