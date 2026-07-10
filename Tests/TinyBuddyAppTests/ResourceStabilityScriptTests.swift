import Foundation
import XCTest

final class ResourceStabilityScriptTests: XCTestCase {
    func testDryRunExposesDeterministicResourceBudgets() throws {
        let result = try runScript(arguments: ["--dry-run"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("duration_seconds,600"))
        XCTAssertTrue(result.output.contains("cycle_count,25"))
        XCTAssertTrue(result.output.contains("rss_delta_kb,16384"))
        XCTAssertTrue(result.output.contains("thread_delta,6"))
        XCTAssertTrue(result.output.contains("sustained_cpu_percent,15"))
    }

    func testDryRunRejectsFewerThanTwentyFiveLifecycleCycles() throws {
        let result = try runScript(
            arguments: ["--dry-run"],
            environment: ["TINYBUDDY_RESOURCE_CYCLE_COUNT": "24"]
        )

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.error.contains("must be at least 25"))
    }

    func testBudgetEvaluationPassesCompleteSyntheticSamples() throws {
        let result = try evaluateSamples([
            "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state",
            "0,1000,0.0,4,1,warm",
            "2,1100,0.0,4,1,post_cycles",
            "3,1200,1.0,5,1,sample"
        ])

        XCTAssertEqual(result.exitCode, 0, result.error)
        XCTAssertTrue(result.error.contains("PASS: final RSS delta=200 KB, max thread delta=1"), result.error)
    }

    func testBudgetEvaluationRejectsMissingMonitoringSamples() throws {
        let result = try evaluateSamples([
            "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state",
            "0,1000,0.0,4,1,warm",
            "2,1100,0.0,4,1,post_cycles"
        ])

        XCTAssertEqual(result.exitCode, 1, result.error)
        XCTAssertTrue(result.error.contains("expected at least 1 monitoring samples, got 0"), result.error)
    }

    func testBudgetEvaluationRejectsEmptySampleRow() throws {
        let result = try evaluateSamples([
            "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state",
            "0,1000,0.0,4,1,warm",
            "",
            "3,1200,1.0,4,1,sample"
        ])

        XCTAssertEqual(result.exitCode, 1, result.error)
        XCTAssertTrue(result.error.contains("malformed sample row 3"), result.error)
    }

    func testBudgetEvaluationExcludesPostCyclesCPUFromIdleRun() throws {
        let result = try evaluateSamples([
            "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state",
            "0,1000,0.0,4,1,warm",
            "2,1100,99.0,4,1,post_cycles",
            "3,1200,1.0,4,1,sample"
        ])

        XCTAssertEqual(result.exitCode, 0, result.error)
    }

    private func evaluateSamples(_ lines: [String]) throws -> (exitCode: Int32, output: String, error: String) {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-resource-samples-\(UUID().uuidString).csv")
        try lines.joined(separator: "\n").write(to: fixtureURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        return try runScript(
            arguments: ["--evaluate-samples", fixtureURL.path],
            environment: [
                "TINYBUDDY_RESOURCE_DURATION_SECONDS": "1",
                "TINYBUDDY_RESOURCE_SAMPLE_INTERVAL_SECONDS": "1"
            ]
        )
    }

    private func runScript(
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (exitCode: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL().path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func scriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/verify_resource_stability.sh")
    }
}
