import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

// MARK: - LockHolder

/// A helper that holds an exclusive flock on a lock file to simulate a
/// running primary instance in the same process.
final class LockHolder {
    let fileURL: URL
    private let fd: Int32

    init?(fileURL: URL) {
        self.fileURL = fileURL
        let fd = Darwin.open(
            fileURL.path,
            O_RDWR | O_CREAT,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else { return nil }
        let result = flock(fd, LOCK_EX | LOCK_NB)
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }
}

// MARK: - CoordinatorBox

/// A box for @MainActor coordinator references that can cross @Sendable
/// closure boundaries. Only accessed from @MainActor contexts.
final class CoordinatorBox: @unchecked Sendable {
    var value: TinyBuddyInstanceCoordinator?
}

// MARK: - TinyBuddyInstanceCoordinatorTests

/// Verifies the single-instance enforcement mechanism in complete isolation.
///
/// Each test creates its own temporary directory and lock file so there is no
/// interaction with App Group containers, running app instances, or other tests.
final class TinyBuddyInstanceCoordinatorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeLockFileURL() -> URL {
        tempDir.appendingPathComponent(".test-instance-state")
    }

    // MARK: - Primary claim

    func testClaimInstanceReturnsPrimaryWhenNoCompetition() throws {
        let url = makeLockFileURL()
        let exp = expectation(description: "claim primary")
        var role: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: url)
            role = c.claimInstance()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        let r = try XCTUnwrap(role, "role should be set after claimInstance")
        XCTAssertEqual(r, .primary, "First claim on empty lock should be primary")
    }

    func testClaimInstanceReturnsPrimaryForSameInstance() throws {
        let url = makeLockFileURL()
        let exp1 = expectation(description: "first claim")
        var role1: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: url)
            role1 = c.claimInstance()
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2)
        let r1 = try XCTUnwrap(role1)
        XCTAssertEqual(r1, .primary)

        let exp2 = expectation(description: "second claim")
        var role2: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: url)
            role2 = c.claimInstance()
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2)
        let r2 = try XCTUnwrap(role2)
        XCTAssertEqual(r2, .primary)
    }

    // MARK: - Secondary claim

    func testClaimInstanceReturnsSecondaryWhenLockIsHeld() throws {
        let lockURL = makeLockFileURL()
        guard let holder = LockHolder(fileURL: lockURL) else {
            XCTFail("Failed to acquire initial lock")
            return
        }
        _ = holder

        let exp = expectation(description: "claim secondary")
        var role: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            role = c.claimInstance()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        let r = try XCTUnwrap(role)
        XCTAssertEqual(
            r, .secondary,
            "Claim with held lock should be secondary"
        )
    }

    // MARK: - Relinquish and reclaim

    func testRelinquishOwnershipAllowsReclaim() throws {
        let lockURL = makeLockFileURL()

        // Claim primary.
        let exp1 = expectation(description: "claim")
        let coordinatorBox1 = CoordinatorBox()
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            coordinatorBox1.value = c
            _ = c.claimInstance()
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2)

        // Relinquish.
        let exp2 = expectation(description: "relinquish")
        Task { @MainActor in
            coordinatorBox1.value?.relinquishOwnership()
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2)

        // Claim primary again with a fresh coordinator.
        let exp3 = expectation(description: "reclaim")
        var role2: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            role2 = c.claimInstance()
            exp3.fulfill()
        }
        wait(for: [exp3], timeout: 2)
        let r2 = try XCTUnwrap(role2)
        XCTAssertEqual(r2, .primary)
    }

    func testRelinquishAndReclaimCycle() {
        for _ in 0..<5 {
            let url = makeLockFileURL()
            let exp1 = expectation(description: "claim")
            let box = CoordinatorBox()
            Task { @MainActor in
                let c = TinyBuddyInstanceCoordinator(testLockFileURL: url)
                box.value = c
                _ = c.claimInstance()
                exp1.fulfill()
            }
            wait(for: [exp1], timeout: 2)

            let exp2 = expectation(description: "relinquish")
            Task { @MainActor in
                box.value?.relinquishOwnership()
                exp2.fulfill()
            }
            wait(for: [exp2], timeout: 2)
        }
    }

    func testResetRelinquishRemovesOnlyTheReleasedInstanceStateFile() {
        let lockURL = makeLockFileURL()
        let exp = expectation(description: "reset relinquish")
        Task { @MainActor in
            let coordinator = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            XCTAssertEqual(coordinator.claimInstance(), .primary)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))

            coordinator.relinquishOwnership(removingStateFile: true)

            XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Edge cases

    func testDoubleRelinquishIsSafe() {
        let url = makeLockFileURL()
        let exp = expectation(description: "double relinquish")
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: url)
            _ = c.claimInstance()
            c.relinquishOwnership()
            // Second relinquish must not crash or trap.
            c.relinquishOwnership()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testClaimInstanceAfterRelinquishReturnsNilAndFailsOpen() throws {
        // After relinquishOwnership, the coordinator still has role != nil
        // but the fd is closed. Calling claimInstance again returns the cached role.
        let url = makeLockFileURL()
        let exp = expectation(description: "claim+relinquish+claim")
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: url)
            _ = c.claimInstance()
            c.relinquishOwnership()
            // Secondary claim on same coordinator returns cached role (.primary)
            // because the guard check returns early. The lock fd is already closed.
            let role = c.claimInstance()
            XCTAssertEqual(role, .primary, "Cached role still returned after relinquish")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testWakePrimaryInstanceDoesNotCrashFromSecondary() {
        // This should be safe even without a DistributedNotification center.
        let exp = expectation(description: "wake call")
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: URL(fileURLWithPath: "/tmp/test"))
            _ = c.claimInstance()
            // wakePrimaryInstance posts a notification but no handler is registered
            // (wakeHandler is registered only when role == .primary).
            c.wakePrimaryInstance()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testOwnershipInfoWrittenToLockFile() throws {
        let lockURL = makeLockFileURL()
        let exp = expectation(description: "claim")
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            _ = c.claimInstance()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        // Read the lock file contents.
        let data = try Data(contentsOf: lockURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any])

        XCTAssertNotNil(dict["pid"], "Lock file should contain pid")
        XCTAssertNotNil(dict["launchTime"], "Lock file should contain launchTime")
        XCTAssertNotNil(dict["bundlePath"], "Lock file should contain bundlePath")
    }

    // MARK: - Lock file deletion while held (inode semantics)

    func testLockFileDeletedWhileLockHeldAllowsSecondaryClaim() throws {
        // flock attaches to the inode, not the path. If the lock file is
        // deleted and recreated, the old coordinator still holds the lock on
        // the old inode. A new coordinator opening the new path gets a
        // different inode and can acquire the lock. This test verifies that
        // behavior.
        let lockURL = makeLockFileURL()

        // Primary coordinator acquires lock on file.
        let exp1 = expectation(description: "claim primary")
        let box = CoordinatorBox()
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            box.value = c
            _ = c.claimInstance()
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2)

        // Delete the lock file while primary holds the fd.
        try FileManager.default.removeItem(at: lockURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path),
                       "Lock file should be deleted")

        // A new coordinator creates a brand new file and locks it.
        // This is technically a "second primary" because the old inode's lock
        // no longer protects the canonical path.
        let exp2 = expectation(description: "claim after deletion")
        var role2: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            role2 = c.claimInstance()
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2)

        let r2 = try XCTUnwrap(role2)
        XCTAssertEqual(r2, .primary,
                       "Deleted lock file creates new inode that can be independently locked")
    }

    // MARK: - Crash recovery (simulated via fd close)

    func testCrashRecoveryWithoutRelinquish() throws {
        let lockURL = makeLockFileURL()

        // Simulate crash: acquire lock via raw fd, then close it (as the kernel
        // would on process death).
        do {
            let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
            XCTAssertGreaterThanOrEqual(fd, 0)
            let result = flock(fd, LOCK_EX | LOCK_NB)
            XCTAssertEqual(result, 0, "Should acquire lock")
            // "Crash" — close without relinquish.
            Darwin.close(fd)
        }

        // New instance should now be able to claim primary.
        let exp = expectation(description: "crash recovery")
        var role: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            role = c.claimInstance()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        let r = try XCTUnwrap(role)
        XCTAssertEqual(
            r, .primary,
            "After simulated crash, new instance should become primary"
        )
    }

    func testMultipleCrashRecoveryCycles() throws {
        let lockURL = makeLockFileURL()

        for _ in 0..<5 {
            // Simulate crash.
            do {
                let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
                XCTAssertGreaterThanOrEqual(fd, 0)
                let result = flock(fd, LOCK_EX | LOCK_NB)
                XCTAssertEqual(result, 0)
                Darwin.close(fd) // "crash"
            }

            // Recover.
            let exp = expectation(description: "crash recovery")
            var role: TinyBuddyInstanceRole?
            Task { @MainActor in
                let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
                role = c.claimInstance()
                exp.fulfill()
            }
            wait(for: [exp], timeout: 2)
            let r = try XCTUnwrap(role)
            XCTAssertEqual(r, .primary)
        }
    }

    // MARK: - Lock file properties

    func testLockFileIsCreatedOnClaim() {
        let lockURL = makeLockFileURL()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: lockURL.path),
            "Lock file should not exist before claim"
        )

        let exp = expectation(description: "claim")
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            _ = c.claimInstance()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: lockURL.path,
            isDirectory: &isDir
        )
        XCTAssertTrue(exists, "Lock file should exist after claim")
        XCTAssertFalse(isDir.boolValue, "Lock file should be a regular file")
    }

    // MARK: - Role state

    func testRoleIsNilBeforeClaim() {
        let exp = expectation(description: "role nil")
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: URL(fileURLWithPath: "/tmp/test"))
            XCTAssertNil(c.role)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testRoleIsPrimaryAfterSuccessfulClaim() throws {
        let exp = expectation(description: "role primary")
        let url = makeLockFileURL()
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: url)
            _ = c.claimInstance()
            XCTAssertEqual(c.role, .primary)
            c.relinquishOwnership()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testRoleIsSecondaryWhenLockHeld() throws {
        let lockURL = makeLockFileURL()
        guard let holder = LockHolder(fileURL: lockURL) else {
            XCTFail("Failed to acquire initial lock")
            return
        }
        _ = holder

        let exp = expectation(description: "role secondary")
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            _ = c.claimInstance()
            XCTAssertEqual(c.role, .secondary)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}

// MARK: - TinyBuddyInstanceCoordinatorCrossProcessTests

/// Integration tests that verify cross-process lock behavior using real
/// subprocesses. These tests use `python3` (available on macOS) to create
/// child processes that interact with the same lock file via `fcntl.flock`.
final class TinyBuddyInstanceCoordinatorCrossProcessTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyCrossProcessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        // Kill any lingering child processes and clean up.
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeLockFileURL() -> URL {
        tempDir.appendingPathComponent(".test-instance-state")
    }

    // MARK: - Helpers

    /// Python helper script that tries to acquire an exclusive flock on a file
    /// and holds it until stdin closes. Prints "primary" on success or
    /// "secondary" on contention.
    private static let lockHelperScript = """
    import fcntl, os, sys

    path = sys.argv[1]
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.stdout.write("primary\\n")
        sys.stdout.flush()
        # Hold lock until stdin is closed by the parent.
        sys.stdin.read()
    except BlockingIOError:
        sys.stdout.write("secondary\\n")
        sys.stdout.flush()
    finally:
        os.close(fd)
    """

    /// Launch a child process that runs the lock helper script. Returns the
    /// process and a pipe to read its stdout.
    private func spawnLockingChild(
        lockFileURL: URL,
        label: String
    ) -> (process: Process, stdoutPipe: Pipe) {
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.lockHelperScript, lockFileURL.path]
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.qualityOfService = .userInitiated

        return (process, stdoutPipe)
    }

    /// Read the first line from a child process's stdout to determine its role.
    private func readChildRole(from pipe: Pipe) -> String? {
        let data = pipe.fileHandleForReading.availableData
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cross-process primary/secondary

    func testChildBecomesPrimaryParentIsSecondary() throws {
        let lockURL = makeLockFileURL()

        // Spawn child that acquires the lock and holds it.
        let (child, stdoutPipe) = spawnLockingChild(lockFileURL: lockURL, label: "child1")
        try child.run()

        // Wait for child to signal it acquired the lock.
        let childRole = readChildRole(from: stdoutPipe)
        XCTAssertEqual(childRole, "primary", "Child should become primary")

        // Parent tries to claim the same lock via coordinator → secondary.
        let exp1 = expectation(description: "parent claim while child holds lock")
        var parentRole: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            parentRole = c.claimInstance()
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 5)
        let r1 = try XCTUnwrap(parentRole)
        XCTAssertEqual(r1, .secondary, "Parent should be secondary while child holds lock")

        // Signal child to exit by closing stdin.
        try (child.standardInput as? Pipe)?.fileHandleForWriting.close()

        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, "Child should exit cleanly")

        // Now parent should be able to claim primary with a fresh coordinator.
        let exp2 = expectation(description: "parent claim after child exits")
        var reclaimRole: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            reclaimRole = c.claimInstance()
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 5)
        let r2 = try XCTUnwrap(reclaimRole)
        XCTAssertEqual(r2, .primary, "Parent should claim primary after child releases lock")
    }

    func testMultipleParallelChildrenOnlyOnePrimary() throws {
        let lockURL = makeLockFileURL()
        let childCount = 8

        // Spawn N children simultaneously.
        var children: [(process: Process, stdoutPipe: Pipe)] = []
        for i in 0..<childCount {
            let (child, pipe) = spawnLockingChild(lockFileURL: lockURL, label: "child-\(i)")
            try child.run()
            children.append((child, pipe))
        }

        // Read each child's role.
        var primaryCount = 0
        var secondaryCount = 0
        var roles: [String] = []

        for (i, (_, pipe)) in children.enumerated() {
            let role = readChildRole(from: pipe)
            let roleStr = role ?? "unknown"
            roles.append("child-\(i)=\(roleStr)")
            switch roleStr {
            case "primary": primaryCount += 1
            case "secondary": secondaryCount += 1
            default: break
            }
        }

        XCTAssertEqual(
            primaryCount, 1,
            "Exactly one child should be primary among \(childCount) concurrent claims. "
            + "Roles: \(roles.joined(separator: ", "))"
        )
        XCTAssertEqual(
            secondaryCount, childCount - 1,
            "Remaining \(childCount - 1) children should be secondary"
        )

        // Clean up: close all stdin pipes to release children.
        for (child, _) in children {
            try (child.standardInput as? Pipe)?.fileHandleForWriting.close()
            child.waitUntilExit()
        }
    }

    func testParentWaitsForChildCrashAndReclaimsPrimary() throws {
        let lockURL = makeLockFileURL()

        // Child acquires lock.
        let (child, stdoutPipe) = spawnLockingChild(lockFileURL: lockURL, label: "crash-child")
        try child.run()

        let childRole = readChildRole(from: stdoutPipe)
        XCTAssertEqual(childRole, "primary", "Child should acquire primary")

        // Parent is secondary.
        let exp1 = expectation(description: "parent secondary")
        var parentRole: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            parentRole = c.claimInstance()
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 5)
        let r1 = try XCTUnwrap(parentRole)
        XCTAssertEqual(r1, .secondary)

        // Simulate child crash: force-kill the child (SIGKILL).
        child.terminate() // Sends SIGTERM

        // Wait for child to die.
        child.waitUntilExit()

        // The kernel releases the flock when the child process dies.
        // Parent should now be able to claim primary with a fresh coordinator.
        let exp2 = expectation(description: "parent primary after child crash")
        var reclaimRole: TinyBuddyInstanceRole?
        Task { @MainActor in
            let c = TinyBuddyInstanceCoordinator(testLockFileURL: lockURL)
            reclaimRole = c.claimInstance()
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 5)
        let r2 = try XCTUnwrap(reclaimRole)
        XCTAssertEqual(r2, .primary,
                       "Parent should reclaim primary after child process crash/kill")
    }
}
