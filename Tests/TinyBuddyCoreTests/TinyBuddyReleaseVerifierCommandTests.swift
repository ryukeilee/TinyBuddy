import Foundation
import XCTest
@testable import TinyBuddyCore

final class TinyBuddyReleaseVerifierCommandTests: XCTestCase {
    func testSharedSnapshotCommandPrintsCommittedFieldsWithoutProjectName() throws {
        let projectName = "Private Project Name Must Not Escape"
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-17", projectName: projectName)
        let result = try runVerifier(
            plist: validPlist(for: snapshot),
            expectedDayIdentifier: snapshot.dayIdentifier
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertTrue(result.standardOutput.contains("TINYBUDDY_RELEASE_SNAPSHOT"))
        XCTAssertTrue(result.standardOutput.contains("schema=3"))
        XCTAssertTrue(result.standardOutput.contains("revision=42"))
        XCTAssertTrue(result.standardOutput.contains("day=2026-07-17"))
        XCTAssertTrue(result.standardOutput.contains("status=completedOnce"))
        XCTAssertTrue(result.standardOutput.contains("focus_count=3"))
        XCTAssertTrue(result.standardOutput.contains("completion_count=2"))
        XCTAssertTrue(result.standardOutput.contains("activity_focus_blocks=5"))
        XCTAssertTrue(result.standardOutput.contains("activity_commits=7"))
        XCTAssertTrue(result.standardOutput.contains("activity_revision=18"))
        XCTAssertFalse(result.standardOutput.contains(projectName))
        XCTAssertFalse(result.standardError.contains(projectName))
    }

    func testCommandRejectsInvalidArgumentsWithStableReason() throws {
        let result = try runCommand(arguments: ["not-shared-snapshot"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.standardError, "TINYBUDDY_RELEASE_SNAPSHOT_ERROR reason=invalid_arguments\n")
    }

    func testCommandRejectsUnreadableAndInvalidPropertyListsWithStableReasons() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let unreadableURL = temporaryDirectory.appendingPathComponent("missing.plist")
        let invalidURL = temporaryDirectory.appendingPathComponent("invalid.plist")
        try Data("not a plist".utf8).write(to: invalidURL)

        let unreadable = try runCommand(arguments: commandArguments(
            plistURL: unreadableURL,
            expectedDayIdentifier: "2026-07-17"
        ))
        XCTAssertEqual(unreadable.exitCode, 1)
        XCTAssertEqual(
            unreadable.standardError,
            "TINYBUDDY_RELEASE_SNAPSHOT_ERROR reason=plist_unreadable\n"
        )

        let invalid = try runCommand(arguments: commandArguments(
            plistURL: invalidURL,
            expectedDayIdentifier: "2026-07-17"
        ))
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertEqual(invalid.standardError, "TINYBUDDY_RELEASE_SNAPSHOT_ERROR reason=plist_invalid\n")
    }

    func testCommandRejectsCrossDayAndDamagedSnapshotsWithStableSafeReasons() throws {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-17", projectName: "Private Project")

        let crossDay = try runVerifier(
            plist: validPlist(for: snapshot),
            expectedDayIdentifier: "2026-07-18"
        )
        XCTAssertEqual(crossDay.exitCode, 1)
        XCTAssertEqual(
            crossDay.standardError,
            "TINYBUDDY_RELEASE_SNAPSHOT_ERROR reason=committedSnapshotMissing\n"
        )
        XCTAssertFalse(crossDay.standardError.contains("Private Project"))

        var damaged = validPlist(for: snapshot)
        damaged[TinyBuddyCombinedSnapshotStore.Key.schemaVersion] = "2\\tbroken"
        let damagedResult = try runVerifier(
            plist: damaged,
            expectedDayIdentifier: snapshot.dayIdentifier
        )
        XCTAssertEqual(damagedResult.exitCode, 1)
        XCTAssertEqual(
            damagedResult.standardError,
            "TINYBUDDY_RELEASE_SNAPSHOT_ERROR reason=schemaInvalid\n"
        )
        XCTAssertFalse(damagedResult.standardError.contains("Private Project"))
    }

    private func runVerifier(
        plist: [String: Any],
        expectedDayIdentifier: String
    ) throws -> CommandResult {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let plistURL = temporaryDirectory.appendingPathComponent("shared-snapshot.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(to: plistURL)
        return try runCommand(arguments: commandArguments(
            plistURL: plistURL,
            expectedDayIdentifier: expectedDayIdentifier
        ))
    }

    private func commandArguments(plistURL: URL, expectedDayIdentifier: String) -> [String] {
        [
            "shared-snapshot",
            "--plist", plistURL.path,
            "--expected-day", expectedDayIdentifier
        ]
    }

    private func runCommand(arguments: [String]) throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = try releaseVerifierURL()
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func releaseVerifierURL() throws -> URL {
        let fileManager = FileManager.default
        let testBundleURL = Bundle(for: Self.self).bundleURL
        let candidates = [
            testBundleURL.deletingLastPathComponent()
                .appendingPathComponent("TinyBuddyReleaseVerifier"),
            testBundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("TinyBuddyReleaseVerifier")
        ]
        return try XCTUnwrap(
            candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }),
            "TinyBuddyReleaseVerifier must be built beside the XCTest bundle"
        )
    }

    private func validPlist(for snapshot: TinyBuddyCombinedSnapshot) -> [String: Any] {
        [
            TinyBuddyCombinedSnapshotStore.Key.schemaVersion:
                TinyBuddyCombinedSnapshotStore.encodeSchemaVersion()!,
            TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2:
                TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(snapshot.revision)!,
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA:
                TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB:
                TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            TinyBuddyCombinedSnapshotStore.Key.snapshot:
                TinyBuddyCombinedSnapshotStore.encode(snapshot)
        ]
    }

    private func makeSnapshot(
        dayIdentifier: String,
        projectName: String
    ) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: 42,
            dayIdentifier: dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(
                    dayIdentifier: dayIdentifier,
                    focusCount: 3,
                    completionCount: 2
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 5,
                commitCount: 7,
                recentProjectName: projectName
            ),
            activityRevision: 18
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyReleaseVerifierCommandTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct CommandResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}
