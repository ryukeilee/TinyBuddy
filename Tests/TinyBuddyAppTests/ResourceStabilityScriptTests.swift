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

    func testThreadCountProbeReturnsPositiveCountForCurrentProcess() throws {
        let result = try runScript(arguments: ["--thread-count", String(ProcessInfo.processInfo.processIdentifier)])

        XCTAssertEqual(result.exitCode, 0, result.error)
        XCTAssertGreaterThan(Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 0)
    }

    func testRuntimeSampleHeaderIsPersistedForBudgetEvaluation() throws {
        let script = try String(contentsOf: scriptURL(), encoding: .utf8)

        XCTAssertTrue(script.contains("SAMPLE_HEADER=\"elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state,cpu_time_ns,disk_read_bytes,interrupt_wakeups,idle_wakeups\""))
        XCTAssertTrue(script.contains("printf '%s\\n' \"$SAMPLE_HEADER\" | /usr/bin/tee \"$SAMPLES_FILE\""))
    }

    func testBudgetEvaluationPassesCompleteSyntheticSamples() throws {
        let result = try evaluateSamples([
            sampleHeader,
            "0,1000,0.0,4,1,warm,100,10,2,1",
            "2,1100,0.0,4,1,post_cycles,120,20,3,2",
            "3,1200,1.0,5,1,sample,130,30,4,3"
        ])

        XCTAssertEqual(result.exitCode, 0, result.error)
        XCTAssertTrue(result.error.contains("PASS: final RSS delta=200 KB, max thread delta=1"), result.error)
    }

    func testBudgetEvaluationReportsZeroThreadDelta() throws {
        let result = try evaluateSamples([
            sampleHeader,
            "0,1000,0.0,4,1,warm,100,10,2,1",
            "2,1100,0.0,4,1,post_cycles,120,20,3,2",
            "3,1200,1.0,4,1,sample,130,30,4,3"
        ])

        XCTAssertEqual(result.exitCode, 0, result.error)
        XCTAssertTrue(result.error.contains("PASS: final RSS delta=200 KB, max thread delta=0"), result.error)
    }

    func testBudgetEvaluationRejectsMissingMonitoringSamples() throws {
        let result = try evaluateSamples([
            sampleHeader,
            "0,1000,0.0,4,1,warm,100,10,2,1",
            "2,1100,0.0,4,1,post_cycles,120,20,3,2"
        ])

        XCTAssertEqual(result.exitCode, 1, result.error)
        XCTAssertTrue(result.error.contains("expected at least 1 monitoring samples, got 0"), result.error)
    }

    func testBudgetEvaluationRejectsEmptySampleRow() throws {
        let result = try evaluateSamples([
            sampleHeader,
            "0,1000,0.0,4,1,warm,100,10,2,1",
            "",
            "3,1200,1.0,4,1,sample,130,30,4,3"
        ])

        XCTAssertEqual(result.exitCode, 1, result.error)
        XCTAssertTrue(result.error.contains("malformed sample row 3"), result.error)
    }

    func testBudgetEvaluationExcludesPostCyclesCPUFromIdleRun() throws {
        let result = try evaluateSamples([
            sampleHeader,
            "0,1000,0.0,4,1,warm,0,0,0,0",
            "2,1100,99.0,4,1,post_cycles,9000000000,0,0,0",
            "3,1200,1.0,4,1,sample,9000000001,0,0,0"
        ])

        XCTAssertEqual(result.exitCode, 0, result.error)
    }

    func testBudgetEvaluationRejectsDiskReadGrowthBeyondWarmBaseline() throws {
        let result = try evaluateSamples(
            [
                sampleHeader,
                "0,1000,0.0,4,1,warm,0,0,0,0",
                "1,1000,0.0,4,1,sample,1,101,0,0"
            ],
            environment: ["TINYBUDDY_RESOURCE_DISK_READ_DELTA_BYTES": "100"]
        )

        XCTAssertEqual(result.exitCode, 1, result.error)
        XCTAssertTrue(result.error.contains("disk read delta 101 bytes exceeds 100"), result.error)
    }

    func testBudgetEvaluationRejectsInterruptWakeupRateBeyondBudget() throws {
        let result = try evaluateSamples(
            [
                sampleHeader,
                "0,1000,0.0,4,1,warm,0,0,0,0",
                "60,1000,0.0,4,1,sample,1,0,31,0"
            ],
            environment: ["TINYBUDDY_RESOURCE_INTERRUPT_WAKEUPS_PER_MINUTE": "30"]
        )

        XCTAssertEqual(result.exitCode, 1, result.error)
        XCTAssertTrue(result.error.contains("interrupt wakeups 31/minute exceeds 30"), result.error)
    }

    func testProbeProcessReturnsCumulativeDarwinCountersForCurrentProcess() throws {
        let result = try runScript(arguments: ["--probe-process", String(ProcessInfo.processInfo.processIdentifier)])
        let rows = result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        XCTAssertEqual(result.exitCode, 0, result.error)
        XCTAssertEqual(rows.first, "cpu_time_ns,disk_read_bytes,interrupt_wakeups,idle_wakeups")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.split(separator: ",").count, 4)
        XCTAssertTrue(rows.last?.split(separator: ",").allSatisfy { UInt64($0) != nil } ?? false)
    }

    func testCompareSummariesRejectsSamplesWithMissingCounters() throws {
        let validSamples = [
            sampleHeader,
            "0,1000,0.0,4,1,warm,0,0,0,0",
            "1,1000,0.0,4,1,sample,1,2,3,4"
        ]
        let missingCounterSamples = [
            "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state",
            "0,1000,0.0,4,1,warm",
            "1,1000,0.0,4,1,sample"
        ]

        let result = try compareSamples(validSamples, missingCounterSamples)

        XCTAssertEqual(result.exitCode, 1, result.error)
        XCTAssertTrue(result.error.contains("unexpected sample header"), result.error)
    }

    private func evaluateSamples(
        _ lines: [String],
        environment: [String: String] = [:]
    ) throws -> (exitCode: Int32, output: String, error: String) {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-resource-samples-\(UUID().uuidString).csv")
        try lines.joined(separator: "\n").write(to: fixtureURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        return try runScript(
            arguments: ["--evaluate-samples", fixtureURL.path],
            environment: [
                "TINYBUDDY_RESOURCE_DURATION_SECONDS": "1",
                "TINYBUDDY_RESOURCE_SAMPLE_INTERVAL_SECONDS": "1"
            ].merging(environment) { _, new in new }
        )
    }

    private func compareSamples(
        _ beforeLines: [String],
        _ afterLines: [String]
    ) throws -> (exitCode: Int32, output: String, error: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-resource-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let beforeURL = directory.appendingPathComponent("before.csv")
        let afterURL = directory.appendingPathComponent("after.csv")
        try beforeLines.joined(separator: "\n").write(to: beforeURL, atomically: true, encoding: .utf8)
        try afterLines.joined(separator: "\n").write(to: afterURL, atomically: true, encoding: .utf8)
        return try runScript(arguments: ["--compare-summaries", beforeURL.path, afterURL.path])
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

    private let sampleHeader = "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state,cpu_time_ns,disk_read_bytes,interrupt_wakeups,idle_wakeups"
}
