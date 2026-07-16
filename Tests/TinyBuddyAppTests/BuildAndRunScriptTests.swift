import Foundation
import XCTest

final class BuildAndRunScriptTests: XCTestCase {
    func testAppConfigurationProhibitsConcurrentSemanticWriters() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistData = try Data(contentsOf: repositoryURL
            .appendingPathComponent("Resources/TinyBuddyApp/Info.plist"))
        let infoPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoPlistData, format: nil)
                as? [String: Any]
        )
        let project = try String(
            contentsOf: repositoryURL.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertEqual(infoPlist["LSMultipleInstancesProhibited"] as? Bool, true)
        XCTAssertTrue(project.contains("LSMultipleInstancesProhibited: true"))
    }

    func testOptionalGitPreRefreshWarnsAndReturnsSuccessWhenRefreshFails() throws {
        let script = try buildAndRunScript()
        let function = try XCTUnwrap(
            shellFunction(named: "run_optional_git_pre_refresh", in: script),
            "build_and_run.sh must define an optional pre-refresh wrapper"
        )
        let probe = """
        update_git_completion_count() { return 23; }
        \(function)
        run_optional_git_pre_refresh
        """

        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("warning: git pre-refresh failed with exit code 23"))
        XCTAssertTrue(result.standardError.contains("continuing"))
    }

    func testRunModesUseOptionalPreRefreshButReleaseModesRelyOnSandboxApp() throws {
        let script = try buildAndRunScript()

        XCTAssertTrue(modeBlock("run", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertTrue(modeBlock("--verify|verify", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertFalse(modeBlock("release-install|--release-install", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertFalse(modeBlock("release-verify|--release-verify", in: script).contains("run_optional_git_pre_refresh"))
    }

    func testXcodeBuildDefaultsToBoundedSummaryOutputWithVerboseOptOut() throws {
        let script = try buildAndRunScript()
        let function = try XCTUnwrap(
            shellFunction(named: "run_xcode_build", in: script)
        )

        XCTAssertTrue(script.contains("BUILD_LOG_MODE=\"${TINYBUDDY_BUILD_LOG_MODE:-summary}\""))
        XCTAssertTrue(function.contains("verbose)"))
        XCTAssertTrue(function.contains(">\"$log_file\" 2>&1"))
        XCTAssertTrue(function.contains("/usr/bin/tail -n 80"))
        XCTAssertTrue(function.contains("$BUILD_FAILURE_TAIL_LINES"))
        XCTAssertTrue(function.contains("full log:"))
    }

    func testXcodeBuildSummaryKeepsFullLogButBoundsFailureOutput() throws {
        let function = try XCTUnwrap(
            shellFunction(named: "run_xcode_build", in: try buildAndRunScript())
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyBuildLogTests.\(UUID().uuidString)")
        let fakeXcodebuild = temporaryDirectory.appendingPathComponent("fake-xcodebuild.sh")
        let logDirectory = temporaryDirectory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeCommand = """
        #!/bin/bash
        index=1
        while [ "$index" -le 200 ]; do
          echo "build-line-$index"
          index=$((index + 1))
        done
        echo "error: focused diagnostic" >&2
        exit 37
        """
        try Data(fakeCommand.utf8).write(to: fakeXcodebuild)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeXcodebuild.path
        )

        let probe = """
        set -euo pipefail
        XCODEBUILD_BIN=\(shellQuote(fakeXcodebuild.path))
        BUILD_CONFIGURATION=Debug
        DERIVED_DATA_DIR=\(shellQuote(temporaryDirectory.appendingPathComponent("derived-data").path))
        SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
        BUILD_LOG_MODE=summary
        BUILD_FAILURE_TAIL_LINES=3
        BUILD_LOG_DIR=\(shellQuote(logDirectory.path))
        APP_NAME=TinyBuddy
        \(function)
        run_xcode_build
        """

        let result = try runBash(probe)
        let logFiles = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)

        XCTAssertEqual(result.exitCode, 37)
        XCTAssertTrue(result.standardError.contains("error: focused diagnostic"))
        XCTAssertTrue(result.standardError.contains("build-line-200"))
        XCTAssertFalse(result.standardError.contains("build-line-100"))
        XCTAssertEqual(logFiles.count, 1)
        XCTAssertTrue(
            try String(contentsOf: XCTUnwrap(logFiles.first), encoding: .utf8)
                .contains("build-line-100")
        )
    }

    func testReleaseInstallRollsBackPreviousBundleWhenActivationFails() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(
            shellFunction(named: "rollback_release_install", in: script)
        )
        let installFunction = try XCTUnwrap(
            shellFunction(named: "install_release_app", in: script)
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyReleaseInstallTests.\(UUID().uuidString)")
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        try FileManager.default.createDirectory(at: candidateApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: candidateApp.appendingPathComponent("marker"))
        try Data("old".utf8).write(to: installedApp.appendingPathComponent("marker"))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let probe = """
        set -euo pipefail
        APP_NAME=TinyBuddy
        APP_BUNDLE=\(shellQuote(candidateApp.path))
        INSTALL_DIR=\(shellQuote(installedApp.deletingLastPathComponent().path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        RELEASE_TRANSACTION_DIR=""
        RELEASE_STAGED_APP=""
        RELEASE_BACKUP_APP=""
        RELEASE_HAD_PREVIOUS=0
        RELEASE_SWITCHED=0
        RELEASE_PREVIOUS_APP_WAS_RUNNING=0
        verify_release_bundle() { return 0; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        activate_and_verify_release_app() { return 47; }
        restore_release_runtime() { return 0; }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """

        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 47)
        XCTAssertEqual(
            try String(contentsOf: installedApp.appendingPathComponent("marker"), encoding: .utf8),
            "old"
        )
        XCTAssertTrue(result.standardError.contains("rolled back"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: installedApp.deletingLastPathComponent().path
            ).contains(where: { $0.hasPrefix(".TinyBuddy.install.") })
        )
    }

    func testResolveSavedGitScanRootsUsesValidV2RecordsWithoutLegacyFallback() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyGitScanRootTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let authorizedRoot = temporaryDirectory.appendingPathComponent("authorized-root")
        try FileManager.default.createDirectory(at: authorizedRoot, withIntermediateDirectories: true)
        let validBookmark = try bookmarkData(for: authorizedRoot)
        let preferencesPlist = temporaryDirectory.appendingPathComponent("preferences.plist")
        try writePropertyList([
            "tinybuddy.gitScanRoots.records.v2": [
                [
                    "id": "valid-root",
                    "bookmarkData": validBookmark,
                    "displayName": "Authorized Root",
                    "lastKnownPath": authorizedRoot.path
                ],
                [
                    "id": "corrupt-root",
                    "bookmarkData": "not-bookmark-data",
                    "displayName": "Corrupt Root",
                    "lastKnownPath": "/not-used"
                ]
            ],
            "tinybuddy.gitScanRoots.bookmarkData": [Data("legacy-must-not-be-read".utf8)]
        ], to: preferencesPlist)

        let result = try runBash(resolveSavedGitScanRootsProbe(preferencesPlist))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, normalizedPath(for: authorizedRoot))
    }

    func testResolveSavedGitScanRootsFallsBackToLegacyOnlyWhenV2IsMissing() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyGitScanRootTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let authorizedRoot = temporaryDirectory.appendingPathComponent("legacy-root")
        try FileManager.default.createDirectory(at: authorizedRoot, withIntermediateDirectories: true)
        let preferencesPlist = temporaryDirectory.appendingPathComponent("preferences.plist")
        try writePropertyList([
            "tinybuddy.gitScanRoots.bookmarkData": [try bookmarkData(for: authorizedRoot)]
        ], to: preferencesPlist)

        let result = try runBash(resolveSavedGitScanRootsProbe(preferencesPlist))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, normalizedPath(for: authorizedRoot))
    }

    func testResolveSavedGitScanRootsReturnsEmptyForMalformedPlist() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyGitScanRootTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let preferencesPlist = temporaryDirectory.appendingPathComponent("preferences.plist")
        try Data("not a property list".utf8).write(to: preferencesPlist)

        let result = try runBash(resolveSavedGitScanRootsProbe(preferencesPlist))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "")
    }

    func testReleaseInstallSucceedsForFirstAndReplacementInstallWithoutTransactionResidue() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(
            shellFunction(named: "rollback_release_install", in: script)
        )
        let installFunction = try XCTUnwrap(
            shellFunction(named: "install_release_app", in: script)
        )

        try assertSuccessfulReleaseInstall(
            rollbackFunction: rollbackFunction,
            installFunction: installFunction,
            previousMarker: nil
        )
        try assertSuccessfulReleaseInstall(
            rollbackFunction: rollbackFunction,
            installFunction: installFunction,
            previousMarker: "old"
        )
    }

    func testReleaseVerificationRequiresRunningAppAndWidgetFromInstalledBundle() throws {
        let script = try buildAndRunScript()
        let verificationFunction = try XCTUnwrap(
            shellFunction(named: "verify_release_app", in: script)
        )

        XCTAssertTrue(verificationFunction.contains("verify_installed_matches_build"))
        XCTAssertTrue(verificationFunction.contains("wait_for_running_bundle_process"))
        XCTAssertTrue(verificationFunction.contains("$APP_NAME"))
        XCTAssertTrue(verificationFunction.contains("$WIDGET_EXTENSION_NAME"))
        XCTAssertTrue(verificationFunction.contains("verify_installed_sandbox_bookmark_recovery"))
    }

    func testSandboxBookmarkRecoveryVerificationRequiresFreshSuccessfulSandboxStatus() throws {
        let statusDate = Date(timeIntervalSince1970: 1_700_000_100)
        let successful = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: Date(timeIntervalSince1970: 1_700_000_050),
            outcome: "partial",
            authorizedRootCount: 2,
            savedRecordCount: 2
        )

        XCTAssertEqual(successful.exitCode, 0)
        XCTAssertTrue(successful.standardOutput.contains("verified sandbox bookmark recovery"))
        XCTAssertTrue(successful.standardOutput.contains("authorized_roots=2"))
        XCTAssertTrue(successful.standardOutput.contains("outcome=partial"))

        let reusedBaseline = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: statusDate,
            outcome: "succeeded",
            authorizedRootCount: 2,
            savedRecordCount: 2
        )

        XCTAssertEqual(reusedBaseline.exitCode, 1)
        XCTAssertTrue(reusedBaseline.standardError.contains("did not publish a fresh"))

        let corruptSavedAuthorization = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: Date(timeIntervalSince1970: 1_700_000_050),
            outcome: "failed",
            authorizedRootCount: 0,
            savedRecordCount: 1
        )

        XCTAssertEqual(corruptSavedAuthorization.exitCode, 1)
        XCTAssertFalse(corruptSavedAuthorization.standardOutput.contains("check skipped"))
    }

    func testSavedGitScanRootRecordCountIncludesMalformedPersistedEntries() throws {
        let preferences = try makeTemporaryDirectory(named: "TinyBuddySavedRootRecordCountTests")
            .appendingPathComponent("preferences.plist")
        defer { try? FileManager.default.removeItem(at: preferences.deletingLastPathComponent()) }
        try writePropertyList([
            "tinybuddy.gitScanRoots.records.v2": [
                ["bookmarkData": Data("valid-shape-not-required".utf8)],
                "malformed-record"
            ]
        ], to: preferences)

        let function = try XCTUnwrap(
            scriptSection(
                startingAt: "saved_git_scan_root_record_count() {",
                endingBefore: "\ngit_refresh_status_value() {",
                in: try buildAndRunScript()
            )
        )
        let probe = """
        set -euo pipefail
        APP_PREFERENCES_PLIST=\(shellQuote(preferences.path))
        GIT_SCAN_ROOT_RECORDS_KEY=tinybuddy.gitScanRoots.records.v2
        GIT_SCAN_ROOT_BOOKMARK_KEY=tinybuddy.gitScanRoots.bookmarkData
        \(function)
        saved_git_scan_root_record_count
        """

        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    private func buildAndRunScript() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/build_and_run.sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func shellFunction(named name: String, in script: String) -> String? {
        let startMarker = "\(name)() {"
        guard let start = script.range(of: startMarker),
              let end = script.range(of: "\n}\n", range: start.lowerBound..<script.endIndex) else {
            return nil
        }
        return String(script[start.lowerBound..<end.upperBound])
    }

    private func resolveSavedGitScanRootsProbe(_ preferencesPlist: URL) throws -> String {
        let function = try XCTUnwrap(
            scriptSection(
                startingAt: "resolve_saved_git_scan_roots() {",
                endingBefore: "\nSIGNING_ARGS=()",
                in: try buildAndRunScript()
            )
        )
        return """
        set -euo pipefail
        APP_PREFERENCES_PLIST=\(shellQuote(preferencesPlist.path))
        GIT_SCAN_ROOT_RECORDS_KEY=tinybuddy.gitScanRoots.records.v2
        GIT_SCAN_ROOT_BOOKMARK_KEY=tinybuddy.gitScanRoots.bookmarkData
        \(function)
        resolve_saved_git_scan_roots
        """
    }

    private func runSandboxRecoveryProbe(
        executableDate: Date,
        statusDate: Date,
        baselineDate: Date,
        outcome: String,
        authorizedRootCount: Int,
        savedRecordCount: Int
    ) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
        let script = try buildAndRunScript()
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddySandboxRecoveryTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let installedApp = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let executable = installedApp.appendingPathComponent("Contents/MacOS/TinyBuddy")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("binary".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.modificationDate: executableDate],
            ofItemAtPath: executable.path
        )

        let groupPreferences = temporaryDirectory.appendingPathComponent("group.plist")
        try writePropertyList([
            "tinybuddy.gitRefreshStatus.refreshedAt": statusDate,
            "tinybuddy.gitRefreshStatus.outcome": outcome,
            "tinybuddy.gitRefreshStatus.metrics.authorizedRootCount": authorizedRootCount,
            "tinybuddy.gitRefreshStatus.metrics.repositoryCount": 3
        ], to: groupPreferences)

        let functions = try [
            "git_refresh_status_value",
            "git_refresh_status_epoch",
            "verify_installed_sandbox_bookmark_recovery"
        ].map { name in
            try XCTUnwrap(shellFunction(named: name, in: script))
        }.joined(separator: "\n")
        let probe = """
        set -euo pipefail
        APP_NAME=TinyBuddy
        INSTALLED_APP=\(shellQuote(installedApp.path))
        APP_GROUP_PREFERENCES_PLIST=\(shellQuote(groupPreferences.path))
        GIT_REFRESH_STATUS_DATE_KEY=tinybuddy.gitRefreshStatus.refreshedAt
        GIT_REFRESH_STATUS_OUTCOME_KEY=tinybuddy.gitRefreshStatus.outcome
        GIT_REFRESH_STATUS_AUTHORIZED_ROOT_COUNT_KEY=tinybuddy.gitRefreshStatus.metrics.authorizedRootCount
        GIT_REFRESH_STATUS_REPOSITORY_COUNT_KEY=tinybuddy.gitRefreshStatus.metrics.repositoryCount
        SANDBOX_RECOVERY_TIMEOUT=0
        \(functions)
        verify_installed_sandbox_bookmark_recovery \
          \(savedRecordCount) \
          \(Int(baselineDate.timeIntervalSince1970)) \
          \(Int(executableDate.timeIntervalSince1970))
        """
        return try runBash(probe)
    }

    private func assertSuccessfulReleaseInstall(
        rollbackFunction: String,
        installFunction: String,
        previousMarker: String?
    ) throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseInstallTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        let preferencesSentinel = temporaryDirectory
            .appendingPathComponent("container/Library/Preferences/com.ryukeili.TinyBuddy.plist")
        try FileManager.default.createDirectory(at: candidateApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: installedApp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: preferencesSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: candidateApp.appendingPathComponent("marker"))
        let initialPreferences = Data("authorized-bookmark-sentinel".utf8)
        try initialPreferences.write(to: preferencesSentinel)
        if let previousMarker {
            try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
            try Data(previousMarker.utf8).write(to: installedApp.appendingPathComponent("marker"))
        }

        let probe = """
        set -euo pipefail
        APP_NAME=TinyBuddy
        APP_BUNDLE=\(shellQuote(candidateApp.path))
        INSTALL_DIR=\(shellQuote(installedApp.deletingLastPathComponent().path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        RELEASE_TRANSACTION_DIR=""
        RELEASE_STAGED_APP=""
        RELEASE_BACKUP_APP=""
        RELEASE_HAD_PREVIOUS=0
        RELEASE_SWITCHED=0
        RELEASE_PREVIOUS_APP_WAS_RUNNING=0
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        activate_and_verify_release_app() { return 0; }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: installedApp.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertEqual(try Data(contentsOf: preferencesSentinel), initialPreferences)
        XCTAssertTrue(result.standardOutput.contains("transactionally installed"))
        XCTAssertFalse(result.standardError.contains("rolled back"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: installedApp.deletingLastPathComponent().path)
                .contains(where: { $0.hasPrefix(".TinyBuddy.install.") })
        )
    }

    private func scriptSection(startingAt startMarker: String, endingBefore endMarker: String, in script: String) -> String? {
        guard let start = script.range(of: startMarker),
              let end = script.range(of: endMarker, range: start.upperBound..<script.endIndex) else {
            return nil
        }
        return String(script[start.lowerBound..<end.lowerBound])
    }

    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix).\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func writePropertyList(_ propertyList: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try data.write(to: url)
    }

    private func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func modeBlock(_ label: String, in script: String) -> String {
        let startMarker = "  \(label))"
        guard let start = script.range(of: startMarker, options: .backwards),
              let end = script.range(of: "    ;;", range: start.upperBound..<script.endIndex) else {
            return ""
        }
        return String(script[start.lowerBound..<end.upperBound])
    }

    private func runBash(_ script: String) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let standardError = Pipe()
        let standardOutput = Pipe()
        process.standardError = standardError
        process.standardOutput = standardOutput
        try process.run()
        process.waitUntilExit()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: outputData, encoding: .utf8) ?? "",
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
