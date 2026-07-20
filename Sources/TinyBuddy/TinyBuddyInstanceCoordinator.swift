import AppKit
import Foundation
import OSLog
import TinyBuddyCore

// MARK: - Instance Role

/// The role assigned to this process after claiming ownership.
public enum TinyBuddyInstanceRole: Equatable, Sendable {
    /// This process holds the exclusive instance lock and should run as the
    /// primary app with all timers, monitors, Git processes, and snapshot writes.
    case primary

    /// Another process already holds the instance lock. This instance must
    /// exit without creating any timers, monitors, or writing any state.
    case secondary
}

// MARK: - Instance Coordinator

/// Cross-process single-instance enforcement for TinyBuddy.
///
/// ## Mechanism
///
/// Uses `flock(LOCK_EX | LOCK_NB)` on a well-known file inside the App Group
/// container as the canonical ownership signal:
///
///   `<AppGroup>/Library/Preferences/.tinybuddy-instance-state`
///
/// - The first process to open and lock the file becomes **primary**.
/// - Any subsequent process that fails to acquire the lock becomes **secondary**,
///   sends a `DistributedNotification` wake request to the primary, then exits.
/// - When the primary exits or crashes, the kernel releases the `flock` and the
///   next launch attempt becomes primary.
/// - `O_CLOEXEC` prevents the lock file descriptor from leaking to Git refresh
///   script subprocesses.
///
/// ## Component Ownership
///
/// | Component | Role |
/// |---|---|
/// | Main App (primary) | Owns timers, FSEvent monitors, Git subprocesses, snapshots writes |
/// | Main App (secondary) | Wakes primary and exits, no resources created |
/// | HUD Window | Owned by primary app process |
/// | Widget Extension | Read-only consumer of shared snapshot, no lock interaction |
/// | Login Item | Launches the main app bundle (becomes primary or secondary) |
///
/// ## Crash Recovery
///
/// On crash or force-quit, the kernel releases the exclusive `flock`. The next
/// instance that launches successfully acquires the lock and becomes the new
/// primary. The combined snapshot store's committed revision marker prevents
/// version regression even if a stale snapshot write was in flight.
///
@MainActor
public final class TinyBuddyInstanceCoordinator {
    public static let shared = TinyBuddyInstanceCoordinator()

    /// The role determined by the most recent call to `claimInstance()`.
    /// Returns `nil` before `claimInstance()` is called.
    public private(set) var role: TinyBuddyInstanceRole?

    // MARK: - Private State

    private var fileDescriptor: Int32 = -1
    private var wakeObserver: NSObjectProtocol?

    /// Optional test-only lock file URL. When nil, the coordinator uses the
    /// standard App Group container path.
    private var testLockFileURL: URL?

    private static let lockFileName = ".tinybuddy-instance-state"
    private static let wakeNotificationName = Notification.Name("com.ryukeili.TinyBuddy.wakePrimaryInstance")
    private static let logger = Logger(subsystem: "local.tinybuddy", category: "InstanceCoordinator")

    private init() {}

    /// Test-only initializer that redirects the lock file to a custom path.
    /// This allows isolated unit tests without App Group container access.
    /// - Parameter testLockFileURL: A file URL for the lock file, typically
    ///   inside a temporary directory created by the test.
    init(testLockFileURL: URL) {
        self.testLockFileURL = testLockFileURL
    }

    // MARK: - Public API

    /// Attempt to become the primary instance.
    ///
    /// Must be called **once** from `applicationDidFinishLaunching` before any
    /// timers, monitors, or snapshot stores are set up. The `wakeHandler` is
    /// registered on the primary and invoked when a secondary requests a wake.
    ///
    /// - Parameter wakeHandler: An optional closure invoked on the primary when
    ///   a secondary instance requests foreground activation.
    /// - Returns: `.primary` if this process should run normally, `.secondary`
    ///   if the caller should exit immediately.
    public func claimInstance(
        wakeHandler: (@MainActor @Sendable () -> Void)? = nil
    ) -> TinyBuddyInstanceRole {
        guard role == nil else {
            return role!
        }

        guard let fileURL = lockFileURL() else {
            Self.logger.warning("Cannot determine lock file URL, assuming primary")
            role = .primary
            registerWakeHandler(wakeHandler: wakeHandler)
            return .primary
        }

        // Ensure parent directory exists.
        let parentDir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let fd = Darwin.open(fileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            Self.logger.warning("Cannot open lock file fd=\(fd) errno=\(errno), assuming primary")
            role = .primary
            registerWakeHandler(wakeHandler: wakeHandler)
            return .primary
        }

        // Use BSD flock for cross-process advisory lock.
        // Note: `Darwin.flock` is a different symbol (Foundation overlay type);
        // use the unqualified `flock` which resolves to the POSIX function.
        let result = flock(CInt(fd), CInt(LOCK_EX | LOCK_NB))
        if result == 0 {
            // We hold the exclusive lock — become primary.
            fileDescriptor = fd
            role = .primary
            writeOwnershipInfo(fd: fd)
            registerWakeHandler(wakeHandler: wakeHandler)
            let pid = ProcessInfo.processInfo.processIdentifier
            Self.logger.notice("Acquired primary instance ownership pid=\(pid, privacy: .public)")
            return .primary
        }

        // Lock acquisition failed — another instance holds it.
        Darwin.close(fd)
        role = .secondary
        let pid = ProcessInfo.processInfo.processIdentifier
        Self.logger.notice("Another instance holds the lock, acting as secondary pid=\(pid, privacy: .public)")
        return .secondary
    }

    /// Relinquish primary ownership. Called on graceful app termination.
    public func relinquishOwnership(removingStateFile: Bool = false) {
        let stateFileURL = removingStateFile ? lockFileURL() : nil
        if let observer = wakeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            wakeObserver = nil
        }
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        role = nil
        if let stateFileURL {
            try? FileManager.default.removeItem(at: stateFileURL)
        }
        Self.logger.notice("Relinquished primary instance ownership")
    }

    /// Send a wake request to the primary instance from a secondary.
    /// The secondary should exit after calling this.
    public func wakePrimaryInstance() {
        let pid = ProcessInfo.processInfo.processIdentifier
        Self.logger.notice("Sending wake request to primary from pid=\(pid, privacy: .public)")
        DistributedNotificationCenter.default().postNotificationName(
            Self.wakeNotificationName,
            object: nil,
            userInfo: ["senderPID": pid],
            deliverImmediately: true
        )
    }

    // MARK: - Wake Handler Registration

    private func registerWakeHandler(wakeHandler: (@MainActor @Sendable () -> Void)?) {
        guard wakeObserver == nil else { return }

        // Use a Sendable-safe box to transport the optional closure.
        let handlerBox = SendableBox(wakeHandler)

        wakeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.wakeNotificationName,
            object: nil,
            queue: .main
        ) { [handlerBox] _ in
            // Log from a nonisolated context.
            Logger(subsystem: "local.tinybuddy", category: "InstanceCoordinator")
                .notice("Received wake request from secondary instance")

            // Dispatch to MainActor for all UI work.
            Task { @MainActor in
                handlerBox.value?()
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { w in
                    w.identifier?.rawValue == "TinyBuddy.HUDWindow"
                }) {
                    if window.isMiniaturized {
                        window.deminiaturize(nil)
                    }
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    // MARK: - Lock File

    private func lockFileURL() -> URL? {
        if let testURL = testLockFileURL {
            return testURL
        }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
        )?
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Preferences", isDirectory: true)
        .appendingPathComponent(Self.lockFileName)
    }

    // MARK: - Ownership Info

    /// Writes the current process identity into the lock file for diagnostic
    /// purposes. Failure to write does not affect ownership semantics.
    private func writeOwnershipInfo(fd: Int32) {
        let info: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "launchTime": ISO8601DateFormatter().string(from: Date()),
            "bundlePath": Bundle.main.bundlePath,
            "bundleVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: info, format: .binary, options: 0
        ) else { return }

        Darwin.ftruncate(fd, 0)
        Darwin.lseek(fd, 0, SEEK_SET)
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            Darwin.write(fd, base, ptr.count)
        }
    }

    // MARK: - Lifecycle

    deinit {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
        }
    }
}

// MARK: - Sendable Box

/// A reference type that boxes a value, safe for capture in Sendable closures
/// because it is explicitly `@unchecked Sendable`. The wrapped value is only
/// accessed from `@MainActor` contexts.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T?
    init(_ value: T?) { self.value = value }
}
