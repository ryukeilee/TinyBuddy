import Foundation
import OSLog

// MARK: - Debug Log Manager

/// Manages detailed debug logging for TinyBuddy.
///
/// **Rules:**
/// - Debug logging is **disabled by default**.  It must be explicitly enabled
///   via `enable(expiration:)`, which accepts a mandatory expiration date.
/// - After the expiration date passes, all debug logs are automatically
///   purged and the manager reverts to a no-op state.
/// - Release builds (`DEBUG` not defined) always compile the no-op path.
///   The compiler eliminates the call site overhead.
/// - All log entries pass through `TinyBuddyPrivacyRedactor.sanitizeForDiagnostics`
///   before being written.
/// - Logs are stored in the app's Caches directory so the OS can reclaim space.
/// - A periodic cleanup task removes expired logs on each app launch.
public final class TinyBuddyDebugLogManager: @unchecked Sendable {
    // MARK: - Singleton

    public static let shared = TinyBuddyDebugLogManager()

    // MARK: - Configuration

    public struct Configuration: Equatable, Sendable {
        /// Maximum age of a log file before it is eligible for cleanup (seconds).
        public var maxLogAge: TimeInterval
        /// Maximum total size of all debug logs before rotation kicks in (bytes).
        public var maxTotalBytes: Int64
        /// Subdirectory name under Caches for debug logs.
        public var subdirectoryName: String
        /// Log level for OSLog wrapper.  `.debug` is typical.
        public var osLogType: OSLogType

        public static let `default` = Configuration(
            maxLogAge: 86_400 * 3,      // 3 days
            maxTotalBytes: 512_000,       // 512 KB
            subdirectoryName: "TinyBuddyDebugLogs",
            osLogType: .debug
        )

        public init(
            maxLogAge: TimeInterval = 86_400 * 3,
            maxTotalBytes: Int64 = 512_000,
            subdirectoryName: String = "TinyBuddyDebugLogs",
            osLogType: OSLogType = .debug
        ) {
            self.maxLogAge = maxLogAge
            self.maxTotalBytes = maxTotalBytes
            self.subdirectoryName = subdirectoryName
            self.osLogType = osLogType
        }
    }

    // MARK: - State

    private let lock = NSLock()
    private var isEnabled = false
    private var expirationDate: Date?
    private var config = Configuration.default
    private let osLogger = Logger(subsystem: "local.tinybuddy", category: "Debug")

    private init() {}

    // MARK: - Enable / Disable

    /// Enables detailed debug logging until the given expiration date.
    /// After `expiration`, all logs are purged and the manager becomes a no-op.
    ///
    /// Call this from a debug menu, a launch argument, or a settings toggle.
    /// Never enable debug logging in release production code paths.
    public func enable(expiration: Date, configuration: Configuration = .default) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        isEnabled = true
        expirationDate = expiration
        config = configuration
        osLogger.notice("🔧 Debug logging enabled until \(expiration, privacy: .public)")
        ensureLogDirectoryExists()
        cleanupExpiredLogs()
        #else
        osLogger.notice("Debug logging ignored in Release build")
        #endif
    }

    /// Disables debug logging and purges all stored logs.
    public func disable() {
        lock.lock()
        isEnabled = false
        expirationDate = nil
        lock.unlock()
        purgeAllLogs()
    }

    /// Whether debug logging is currently active.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled, let expiration = expirationDate else { return false }
        guard Date() < expiration else {
            // Lazy expiration: once past the date, auto-disable.
            isEnabled = false
            expirationDate = nil
            return false
        }
        return true
    }

    // MARK: - Writing

    /// Writes a sanitized debug log entry.  No-op when disabled or expired.
    /// All sensitive content is automatically redacted before storage.
    public func write(_ message: String, category: String = "General") {
        #if DEBUG
        guard isActive else { return }

        let sanitized = TinyBuddyPrivacyRedactor.sanitizeForDiagnostics(message)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(sanitized)\n"

        lock.lock()
        let logFileURL = currentLogFileURL
        lock.unlock()

        guard let url = logFileURL else { return }

        // Append atomically to avoid interleaved corruption.
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        } else {
            try? line.data(using: .utf8)?.write(to: url, options: .atomic)
        }

        osLogger.debug("\(sanitized, privacy: .public)")
        #else
        _ = message
        _ = category
        #endif
    }

    /// Convenience: writes an error entry with automatic redaction.
    public func writeError(_ error: Error, category: String = "Error") {
        let desc = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        write("[ERROR] \(desc)", category: category)
    }

    // MARK: - Paths

    private var currentLogFileURL: URL? {
        logDirectoryURL?.appendingPathComponent("debug.log")
    }

    private var logDirectoryURL: URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return caches.appendingPathComponent(config.subdirectoryName, isDirectory: true)
    }

    // MARK: - Cleanup

    /// Removes log files older than `maxLogAge` and rotates when total size
    /// exceeds `maxTotalBytes`.  Called automatically on enable and can be
    /// called manually from a periodic timer.
    public func runCleanup() {
        #if DEBUG
        lock.lock()
        let cfg = config
        lock.unlock()
        cleanupLogs(maxAge: cfg.maxLogAge, maxBytes: cfg.maxTotalBytes)
        #endif
    }

    /// Purges all debug logs immediately.
    public func purgeAllLogs() {
        #if DEBUG
        guard let dir = logDirectoryURL else { return }
        try? FileManager.default.removeItem(at: dir)
        osLogger.notice("All debug logs purged")
        #endif
    }

    /// Checks whether the currently configured log directory is active and
    /// cleans up expired entries. Must NOT call `isActive` because this method
    /// is called with the lock already held from `enable()`.
    private func cleanupExpiredLogs() {
        guard isEnabled, let expiration = expirationDate, Date() < expiration else {
            purgeAllLogs()
            return
        }
        cleanupLogs(maxAge: config.maxLogAge, maxBytes: config.maxTotalBytes)
    }

    private func cleanupLogs(maxAge: TimeInterval, maxBytes: Int64) {
        guard let dir = logDirectoryURL,
              FileManager.default.fileExists(atPath: dir.path) else { return }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)

        // Remove files by age first.
        for fileURL in contents {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate < cutoff else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }

        // Then rotate by total size.
        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        var totalSize: Int64 = 0
        var fileInfos: [(url: URL, size: Int64, modDate: Date)] = []
        for fileURL in remaining {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modDate = attrs[.modificationDate] as? Date ?? Date.distantPast
            totalSize += size
            fileInfos.append((fileURL, size, modDate))
        }

        if totalSize > maxBytes {
            // Remove oldest files until under limit.
            fileInfos.sort { $0.modDate < $1.modDate }
            for info in fileInfos {
                guard totalSize > maxBytes else { break }
                if (try? FileManager.default.removeItem(at: info.url)) != nil {
                    totalSize -= info.size
                }
            }
        }
    }

    private func ensureLogDirectoryExists() {
        guard let dir = logDirectoryURL else { return }
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}

// MARK: - Convenience free function

/// Writes a debug log entry through the shared manager.
/// No-op unless `TinyBuddyDebugLogManager.shared.isActive`.
/// - Parameters:
///   - message: The message to log (will be sanitized for diagnostics).
///   - category: Optional category label for filtering.
///   - file: Source file (auto-filled).
///   - line: Source line (auto-filled).
public func tinyBuddyDebugLog(
    _ message: @autoclosure () -> String,
    category: String = "General",
    file: StaticString = #file,
    line: UInt = #line
) {
    #if DEBUG
    guard TinyBuddyDebugLogManager.shared.isActive else { return }
    let fileName = URL(string: String(describing: file))?.lastPathComponent ?? "?"
    let prefixed = "[\(fileName):\(line)] \(message())"
    TinyBuddyDebugLogManager.shared.write(prefixed, category: category)
    #else
    _ = message
    _ = category
    _ = file
    _ = line
    #endif
}
