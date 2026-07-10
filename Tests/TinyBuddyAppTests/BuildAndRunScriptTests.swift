import Foundation
import XCTest

final class BuildAndRunScriptTests: XCTestCase {
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
}
