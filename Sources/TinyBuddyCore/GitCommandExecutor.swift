import Foundation

// MARK: - Git Command Result

/// Result from executing a Git command.
public struct GitCommandResult: Sendable, Equatable {
    public let standardOutput: String
    public let standardError: String
    public let terminationStatus: Int32
    public let didTimeout: Bool
    public let wasCancelled: Bool
    public let outputTruncated: Bool
    public let duration: TimeInterval

    public init(
        standardOutput: String,
        standardError: String,
        terminationStatus: Int32,
        didTimeout: Bool,
        wasCancelled: Bool,
        outputTruncated: Bool,
        duration: TimeInterval
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
        self.didTimeout = didTimeout
        self.wasCancelled = wasCancelled
        self.outputTruncated = outputTruncated
        self.duration = duration
    }
}

// MARK: - Git Command Error

/// Errors from Git command execution.
public enum GitCommandError: Error, Sendable, Equatable {
    case gitNotFound(searchPaths: [String])
    case permissionDenied(path: String)
    case timeout(seconds: Int)
    case outputTooLarge(maxBytes: Int64, actualBytes: Int64)
    case terminatedBySignal(signal: Int32)
    case invalidWorkingDirectory(path: String)
    case commandNotAllowed(command: String)
    case cancelled
    case executableAccessDenied(path: String)
}

// MARK: - Git Command Executor

/// Safe Git command execution with timeout, cancellation, output limits,
/// read-only enforcement, and comprehensive error classification.
///
/// Thread-safe: all mutable state is protected by an NSLock.
public final class GitCommandExecutor: @unchecked Sendable {
    // MARK: Configuration

    public struct Configuration: Sendable {
        /// Maximum seconds to wait before sending SIGTERM.
        public var defaultTimeoutSeconds: Int
        /// Soft ceiling for captured stdout+stderr (bytes). Output beyond this
        /// is truncated; the result reports `outputTruncated = true`.
        public var maxOutputBytes: Int64
        /// When true, only read-only Git subcommands are allowed.
        public var readOnly: Bool
        /// Extra read-only subcommand names appended to the default set.
        public var extraAllowedCommands: Set<String>
        /// Custom PATH for the Git subprocess. When nil, a secure default is used.
        public var customPATH: String?
        /// Additional environment variables merged into the subprocess.
        public var extraEnvironment: [String: String]?

        public init(
            defaultTimeoutSeconds: Int = 30,
            maxOutputBytes: Int64 = 1_048_576,  // 1 MiB
            readOnly: Bool = true,
            extraAllowedCommands: Set<String> = [],
            customPATH: String? = nil,
            extraEnvironment: [String: String]? = nil
        ) {
            self.defaultTimeoutSeconds = defaultTimeoutSeconds
            self.maxOutputBytes = maxOutputBytes
            self.readOnly = readOnly
            self.extraAllowedCommands = extraAllowedCommands
            self.customPATH = customPATH
            self.extraEnvironment = extraEnvironment
        }
    }

    // MARK: Public API

    /// Creates an executor.
    /// - Parameters:
    ///   - gitExecutableURL: Explicit Git executable URL. When nil, auto-discovers.
    ///   - configuration: Execution configuration.
    public init(
        gitExecutableURL: URL? = nil,
        configuration: Configuration = Configuration()
    ) {
        if let url = gitExecutableURL {
            self.gitExecutableURL = url
        } else {
            self.gitExecutableURL = Self.locateGitExecutable()
        }
        self.configuration = configuration
        self.readOnlyCommands = Self.defaultReadOnlyCommands
            .union(configuration.extraAllowedCommands)
    }

    /// Runs a Git command and returns the result.
    ///
    /// - Parameters:
    ///   - arguments: Git subcommand and its arguments (e.g. `["rev-list", "--count", "HEAD"]`).
    ///   - workingDirectory: Repository or working directory.
    ///   - timeoutSeconds: Per-call timeout override. Uses `configuration.defaultTimeoutSeconds` when nil.
    ///   - environment: Extra environment variables merged into the standard Git environment.
    /// - Returns: `GitCommandResult` with captured output, status, and timing.
    /// - Throws: `GitCommandError` on failure before the process starts or for fatal outcomes.
    public func execute(
        arguments: [String],
        workingDirectory: URL? = nil,
        timeoutSeconds: Int? = nil,
        environment: [String: String]? = nil
    ) throws -> GitCommandResult {
        guard let gitExecutableURL else {
            throw GitCommandError.gitNotFound(searchPaths: Self.defaultSearchPaths)
        }

        // Validate working directory before launching.
        if let wd = workingDirectory {
            guard (try? wd.checkResourceIsReachable()) ?? false else {
                throw GitCommandError.invalidWorkingDirectory(path: wd.path)
            }
        }

        // Validate the complete invocation, not just the subcommand name.
        // Several nominally read-oriented Git commands also have mutating
        // forms (`config key value`, `symbolic-ref <name> <ref>`,
        // `reflog expire`, ...). A name-only allowlist let those forms bypass
        // the read-only contract.
        let subcommand = arguments.first ?? ""
        if configuration.readOnly && !subcommand.isEmpty {
            guard isReadOnlyInvocation(arguments) else {
                throw GitCommandError.commandNotAllowed(command: subcommand)
            }
        }

        // Validate git executable is reachable and executable.
        guard (try? gitExecutableURL.checkResourceIsReachable()) ?? false else {
            throw GitCommandError.gitNotFound(searchPaths: Self.defaultSearchPaths)
        }
        guard (try? gitExecutableURL.resourceValues(forKeys: [.isExecutableKey]))?.isExecutable == true else {
            throw GitCommandError.executableAccessDenied(path: gitExecutableURL.path)
        }

        let process = Process()
        let processID = UUID()
        let timeout = max(0, timeoutSeconds ?? configuration.defaultTimeoutSeconds)

        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        // Safe environment: no pager, no prompts, known PATH.
        var env = Self.baseEnvironment
        if let customPATH = configuration.customPATH {
            env["PATH"] = customPATH
        }
        if let extra = configuration.extraEnvironment {
            for (key, value) in extra {
                env[key] = value
            }
        }
        if let callers = environment {
            for (key, value) in callers {
                env[key] = value
            }
        }
        process.environment = env

        // Redirect both streams to private temporary files. Reading a Pipe to
        // EOF before waiting made the timeout start only after the child had
        // already exited, and reading stdout/stderr sequentially could deadlock
        // when the child filled the other pipe. Files let both streams drain
        // independently while the parent enforces the real wall-clock bound.
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyGitCommand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        try Data().write(to: outputURL, options: .atomic)
        try Data().write(to: errorURL, options: .atomic)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let processExited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processExited.signal() }

        // Register before launch so cancellation cannot miss a process between
        // `run()` and registration. If cancellation lands in that narrow
        // pre-launch window, terminate immediately after the spawn succeeds.
        registerProcess(processID, process)
        defer { unregisterProcess(processID) }

        let startTime = ProcessInfo.processInfo.systemUptime
        try process.run()
        if isCancelled(processID), process.isRunning {
            process.terminate()
        }

        var didTimeout = false
        let waitResult = processExited.wait(timeout: .now().advanced(by: .seconds(timeout)))
        if waitResult == .timedOut {
            didTimeout = true
            process.terminate()
            // Give it 2 seconds to exit gracefully then force-kill.
            if processExited.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                processExited.wait()
            }
        }

        let duration = ProcessInfo.processInfo.systemUptime - startTime
        let terminationStatus = process.terminationStatus
        let wasSignalled = process.terminationReason == .uncaughtSignal
        let wasCancelled = isCancelled(processID)

        try outputHandle.close()
        try errorHandle.close()

        // Enforce one combined capture budget. Read stdout first for command
        // results and use the remainder for stderr; truncation still records
        // that either file contained more data than was retained.
        let maxBytes = max(0, configuration.maxOutputBytes)
        let outputResult = try Self.readFileBounded(outputURL, maxBytes: maxBytes)
        let remainingBytes = max(0, maxBytes - Int64(outputResult.data.count))
        let errorResult = try Self.readFileBounded(errorURL, maxBytes: remainingBytes)

        let outputString = String(data: outputResult.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorString = String(data: errorResult.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let result = GitCommandResult(
            standardOutput: outputString,
            standardError: errorString,
            terminationStatus: terminationStatus,
            didTimeout: didTimeout,
            wasCancelled: wasCancelled,
            outputTruncated: outputResult.truncated || errorResult.truncated,
            duration: duration
        )

        // Cancellation is the caller's intent even when Process reports the
        // resulting SIGTERM as an uncaught signal.
        if wasCancelled {
            throw GitCommandError.cancelled
        }
        if didTimeout {
            throw GitCommandError.timeout(seconds: timeout)
        }
        if wasSignalled {
            throw GitCommandError.terminatedBySignal(signal: terminationStatus)
        }

        return result
    }

    /// Cancels all active Git processes (SIGTERM + SIGKILL fallback).
    public func cancelAll() {
        let snapshot = activeProcessesSnapshot()
        for (id, process) in snapshot {
            markCancelled(id)
            requestTermination(of: process)
        }
    }

    /// Cancels a specific Git process by its UUID.
    public func cancel(id: UUID) {
        guard let process = processForID(id) else { return }
        markCancelled(id)
        requestTermination(of: process)
    }

    private func requestTermination(of process: Process) {
        guard process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()
        // A Git helper may ignore SIGTERM. Keep cancellation bounded just like
        // timeout handling instead of making the caller wait for the original
        // (possibly long) command timeout.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard process.isRunning,
                  process.processIdentifier == processIdentifier else { return }
            Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    // MARK: Internal State

    private let gitExecutableURL: URL?
    private let configuration: Configuration
    private let readOnlyCommands: Set<String>

    private let lock = NSLock()
    private var activeProcesses: [UUID: Process] = [:]
    private var cancelledIDs: Set<UUID> = []

    // MARK: Git Executable Discovery

    private static let defaultSearchPaths = [
        "/usr/bin/git",
        "/usr/local/bin/git",
        "/opt/homebrew/bin/git",
        "/opt/local/bin/git",
    ]

    private static let baseEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
        "LC_ALL": "C",
        "GIT_PAGER": "cat",
        "GIT_TERMINAL_PROMPT": "0",
        "PAGER": "cat",
        "GIT_EDITOR": "true",
        "EDITOR": "true",
        "GIT_SEQUENCE_EDITOR": "true",
        "GIT_MERGE_AUTOEDIT": "no",
        "GIT_ASKPASS": "",
        "SSH_ASKPASS": "",
        "GIT_SSH_COMMAND": "",
        "HOME": NSHomeDirectory(),
    ]

    /// Locates the Git executable by checking known paths and common installations.
    /// - Returns: URL to the Git executable, or nil if not found.
    public static func locateGitExecutable() -> URL? {
        for path in defaultSearchPaths {
            let url = URL(fileURLWithPath: path)
            if (try? url.checkResourceIsReachable()) ?? false,
               (try? url.resourceValues(forKeys: [.isExecutableKey]))?.isExecutable == true {
                return url
            }
        }

        // Fallback: use `which git` through a safe limited PATH.
        return Self.locateViaWhich()
    }

    private static func locateViaWhich() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["git"]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:/opt/local/bin"
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            guard (try? url.checkResourceIsReachable()) ?? false else { return nil }
            return url
        } catch {
            return nil
        }
    }

    // MARK: Read-Only Command Allowlist

    private static let defaultReadOnlyCommands: Set<String> = [
        "rev-list", "log", "show-ref", "rev-parse", "config", "status",
        "diff", "ls-files", "ls-tree", "cat-file", "symbolic-ref",
        "for-each-ref", "describe", "merge-base", "shortlog",
        "help", "version", "ls-remote", "show", "blame", "annotate",
        "grep", "name-rev", "show-branch", "count-objects",
        "check-attr", "check-ignore", "check-mailmap", "check-ref-format",
        "var", "verify-commit", "verify-pack", "verify-tag",
        "whatchanged", "range-diff", "interpret-trailers", "multi-pack-index",
        "reflog", "diff-tree", "diff-index", "diff-files", "stripspace",
        "upload-pack", "ref-log", "tag-name",
    ]

    private func isReadOnlyInvocation(_ arguments: [String]) -> Bool {
        guard let command = arguments.first,
              readOnlyCommands.contains(command) else {
            return false
        }
        let commandArguments = Array(arguments.dropFirst())
        switch command {
        case "config":
            return Self.isReadOnlyConfigInvocation(commandArguments)
        case "symbolic-ref":
            let forbidden = ["--delete", "-d", "-m", "--reason"]
            guard !commandArguments.contains(where: { argument in
                forbidden.contains { argument == $0 || argument.hasPrefix($0 + "=") }
            }) else { return false }
            return commandArguments.filter { !$0.hasPrefix("-") }.count <= 1
        case "reflog":
            let action = commandArguments.first { !$0.hasPrefix("-") }
            // `expire` and `delete` are the only mutating reflog subcommands.
            // Everything else is a read: `show`, `exists`, or the bare
            // `<ref>` shorthand for `show <ref>`.
            return action != "expire" && action != "delete"
        case "multi-pack-index":
            return commandArguments.contains("verify")
                && !commandArguments.contains(where: { ["write", "expire", "repack"].contains($0) })
        case "interpret-trailers":
            return !commandArguments.contains(where: {
                $0 == "--in-place" || $0.hasPrefix("--in-place=")
            })
        default:
            return true
        }
    }

    private static func isReadOnlyConfigInvocation(_ arguments: [String]) -> Bool {
        let writeOptions = [
            "--add", "--replace-all", "--unset", "--unset-all",
            "--rename-section", "--remove-section", "--edit", "-e"
        ]
        guard !arguments.contains(where: { argument in
            writeOptions.contains { argument == $0 || argument.hasPrefix($0 + "=") }
        }) else { return false }

        let readActions = [
            "--get", "--get-all", "--get-regexp", "--get-urlmatch",
            "--get-color", "--get-colorbool", "--list", "-l"
        ]
        if arguments.contains(where: { argument in
            readActions.contains { argument == $0 || argument.hasPrefix($0 + "=") }
        }) {
            return true
        }

        // `git config` and `git config <name>` are reads. Two or more bare
        // values form the write syntax `git config <name> <value>`. Option
        // values that follow a value-taking option (`--file <path>` / `-f`,
        // `--blob <oid>`, `--type <type>`, `--default <value>`) are not
        // config values and must not count toward the bare-value tally.
        var bareValueCount = 0
        var index = 0
        let valueTakingOptions: Set<String> = ["--file", "-f", "--blob", "--type", "--default"]
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-") {
                if valueTakingOptions.contains(argument),
                   index + 1 < arguments.count {
                    // Skip the option and its consumed value.
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            bareValueCount += 1
            index += 1
        }
        return bareValueCount <= 1
    }

    // MARK: Process Registration & Cancellation

    private func registerProcess(_ id: UUID, _ process: Process) {
        lock.lock()
        activeProcesses[id] = process
        cancelledIDs.remove(id)
        lock.unlock()
    }

    private func unregisterProcess(_ id: UUID) {
        lock.lock()
        activeProcesses.removeValue(forKey: id)
        cancelledIDs.remove(id)
        lock.unlock()
    }

    private func activeProcessesSnapshot() -> [(UUID, Process)] {
        lock.lock()
        let snapshot = activeProcesses.map { ($0.key, $0.value) }
        lock.unlock()
        return snapshot
    }

    private func processForID(_ id: UUID) -> Process? {
        lock.lock()
        let process = activeProcesses[id]
        lock.unlock()
        return process
    }

    private func markCancelled(_ id: UUID) {
        lock.lock()
        cancelledIDs.insert(id)
        lock.unlock()
    }

    private func isCancelled(_ id: UUID) -> Bool {
        lock.lock()
        let cancelled = cancelledIDs.contains(id)
        lock.unlock()
        return cancelled
    }

    // MARK: Bounded Pipe Reading

    private struct BoundedReadResult {
        let data: Data
        let truncated: Bool
    }

    private static func readFileBounded(
        _ url: URL,
        maxBytes: Int64
    ) throws -> BoundedReadResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = max(0, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
        let boundedLimit = max(0, maxBytes)
        let requestedBytes = min(fileSize, boundedLimit)
        let requestedCount = requestedBytes >= Int64(Int.max)
            ? Int.max
            : Int(requestedBytes)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data: Data
        if requestedCount == 0 {
            data = Data()
        } else {
            data = try handle.read(upToCount: requestedCount) ?? Data()
        }
        return BoundedReadResult(
            data: data,
            truncated: fileSize > Int64(data.count)
        )
    }
}

// MARK: - Convenience Extensions

extension GitCommandExecutor {
    /// Returns the installed Git version string (e.g. "2.43.0").
    /// - Returns: Version string or nil if Git is unavailable.
    public func gitVersion() -> String? {
        guard let result = try? execute(arguments: ["version"]) else { return nil }
        // Typical output: "git version 2.43.0"
        let parts = result.standardOutput
            .split(separator: " ")
            .map(String.init)
        return parts.last
    }

    /// Checks whether a directory is a valid Git repository.
    public func isValidRepository(at url: URL) -> Bool {
        guard let result = try? execute(
            arguments: ["rev-parse", "--git-dir"],
            workingDirectory: url
        ) else { return false }
        return result.terminationStatus == 0 && !result.standardOutput.isEmpty
    }
}
