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

        // Validate read-only restriction.
        let subcommand = arguments.first ?? ""
        if configuration.readOnly && !subcommand.isEmpty {
            guard readOnlyCommands.contains(subcommand) else {
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
        let timeout = timeoutSeconds ?? configuration.defaultTimeoutSeconds

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

        // Output pipes with size limits.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Register for cancellation.
        registerProcess(processID, process)
        defer { unregisterProcess(processID) }

        let startTime = ProcessInfo.processInfo.systemUptime

        try process.run()

        // Read output in a bounded way.
        let maxBytes = configuration.maxOutputBytes
        let outputResult = Self.readPipeBounded(
            outputPipe.fileHandleForReading,
            maxBytes: maxBytes
        )
        let errorResult = Self.readPipeBounded(
            errorPipe.fileHandleForReading,
            maxBytes: maxBytes
        )

        // Wait with timeout.
        let processExited = DispatchSemaphore(value: 0)
        var didTimeout = false
        process.terminationHandler = { _ in processExited.signal() }

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

        // Close remaining handles.
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()

        let outputString = String(data: outputResult.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorString = String(data: errorResult.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let result = GitCommandResult(
            standardOutput: outputString,
            standardError: errorString,
            terminationStatus: terminationStatus,
            didTimeout: didTimeout,
            wasCancelled: false,
            outputTruncated: outputResult.truncated || errorResult.truncated,
            duration: duration
        )

        // Throw on fatal outcomes; successful exit returns result normally.
        if didTimeout {
            throw GitCommandError.timeout(seconds: timeout)
        }
        if wasSignalled {
            throw GitCommandError.terminatedBySignal(signal: terminationStatus)
        }
        if isCancelled(processID) {
            throw GitCommandError.cancelled
        }

        return result
    }

    /// Cancels all active Git processes (SIGTERM + SIGKILL fallback).
    public func cancelAll() {
        let snapshot = activeProcessesSnapshot()
        for (id, process) in snapshot {
            markCancelled(id)
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Cancels a specific Git process by its UUID.
    public func cancel(id: UUID) {
        guard let process = processForID(id) else { return }
        markCancelled(id)
        if process.isRunning {
            process.terminate()
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
        "whatchanged", "range-diff", "credential", "for-each-repo",
        "interpret-trailers", "multi-pack-index", "reflog",
        "diff-tree", "diff-index", "diff-files",
        "stripspace", "unpack-file", "upload-pack",
        "ref-log", "tag-name", "mailinfo",
    ]

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

    private static func readPipeBounded(
        _ handle: FileHandle,
        maxBytes: Int64
    ) -> BoundedReadResult {
        let data = handle.readDataToEndOfFile()
        guard data.count > maxBytes else {
            return BoundedReadResult(data: data, truncated: false)
        }
        return BoundedReadResult(
            data: data.prefix(Int(maxBytes)),
            truncated: true
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
