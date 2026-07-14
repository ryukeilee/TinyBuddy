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

    func testRunVerifyAndReleaseModesUseOptionalPreRefresh() throws {
        let script = try buildAndRunScript()

        XCTAssertTrue(modeBlock("run", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertTrue(modeBlock("--verify|verify", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertTrue(modeBlock("release-install|--release-install", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertTrue(modeBlock("release-verify|--release-verify", in: script).contains("run_optional_git_pre_refresh"))
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

    func testReleaseVerificationRequiresRunningAppAndWidgetFromInstalledBundle() throws {
        let script = try buildAndRunScript()
        let verificationFunction = try XCTUnwrap(
            shellFunction(named: "verify_release_app", in: script)
        )

        XCTAssertTrue(verificationFunction.contains("verify_installed_matches_build"))
        XCTAssertTrue(verificationFunction.contains("wait_for_running_bundle_process"))
        XCTAssertTrue(verificationFunction.contains("$APP_NAME"))
        XCTAssertTrue(verificationFunction.contains("$WIDGET_EXTENSION_NAME"))
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

    private func modeBlock(_ label: String, in script: String) -> String {
        let startMarker = "  \(label))"
        guard let start = script.range(of: startMarker, options: .backwards),
              let end = script.range(of: "    ;;", range: start.upperBound..<script.endIndex) else {
            return ""
        }
        return String(script[start.lowerBound..<end.upperBound])
    }

    private func runBash(_ script: String) throws -> (exitCode: Int32, standardError: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let standardError = Pipe()
        process.standardError = standardError
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
