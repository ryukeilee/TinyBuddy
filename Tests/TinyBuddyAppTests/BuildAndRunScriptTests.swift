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
