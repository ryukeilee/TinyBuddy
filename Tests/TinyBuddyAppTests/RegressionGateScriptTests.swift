import Foundation
import XCTest

/// Covers `script/regression_gate.sh` resource sampling: a Darwin rusage probe
/// that fails or returns malformed counters must fail the resource-monitor
/// stage.  Replacing a failed probe with fabricated zero counters would leave
/// the disk-read and interrupt/idle-wakeup budgets unverified while still
/// reporting PASS.
final class RegressionGateScriptTests: XCTestCase {
    func testSourcingScriptExposesStageHelpersWithoutRunningTheCli() throws {
        let result = try runBash("""
        source "$GATE_SCRIPT"
        declare -F probe_counters >/dev/null || { echo "probe_counters is missing" >&2; exit 3; }
        echo "SOURCED"
        """)

        XCTAssertEqual(result.exitCode, 0, result.error)
        XCTAssertTrue(result.output.contains("SOURCED"), result.output)
    }

    func testProbeCountersAcceptsCumulativeCounters() throws {
        try withTemporaryDirectory { directory in
            let probe = try writeExecutable(
                "#!/bin/bash\nprintf '11,22,33,44\\n'\n",
                named: "probe-ok",
                in: directory
            )

            let result = try probeCounters(probe: probe, pid: "4242")

            XCTAssertEqual(result.exitCode, 0, result.error)
            XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "11,22,33,44")
            XCTAssertFalse(result.error.contains("resource probe"), result.error)
        }
    }

    func testProbeCountersRejectsFailingProbe() throws {
        try withTemporaryDirectory { directory in
            let probe = try writeExecutable(
                "#!/bin/bash\necho \"simulated probe failure\" >&2\nexit 1\n",
                named: "probe-fail",
                in: directory
            )

            let result = try probeCounters(probe: probe, pid: "4242")

            XCTAssertEqual(result.exitCode, 1, result.output)
            XCTAssertTrue(result.error.contains("resource probe failed for PID 4242"), result.error)
            XCTAssertTrue(result.error.contains("simulated probe failure"), result.error)
        }
    }

    func testProbeCountersRejectsIncompleteOrNonNumericCounters() throws {
        try withTemporaryDirectory { directory in
            let incomplete = try writeExecutable(
                "#!/bin/bash\nprintf '11,22,33\\n'\n",
                named: "probe-incomplete",
                in: directory
            )
            let nonNumeric = try writeExecutable(
                "#!/bin/bash\nprintf '11,22,33,four\\n'\n",
                named: "probe-non-numeric",
                in: directory
            )

            let incompleteResult = try probeCounters(probe: incomplete, pid: "4242")
            let nonNumericResult = try probeCounters(probe: nonNumeric, pid: "4242")

            XCTAssertEqual(incompleteResult.exitCode, 1, incompleteResult.output)
            XCTAssertTrue(
                incompleteResult.error.contains("malformed counters for PID 4242: 11,22,33"),
                incompleteResult.error
            )
            XCTAssertEqual(nonNumericResult.exitCode, 1, nonNumericResult.output)
            XCTAssertTrue(
                nonNumericResult.error.contains("malformed counters for PID 4242: 11,22,33,four"),
                nonNumericResult.error
            )
        }
    }

    func testResourceMonitorFailsClosedWhenProbeFails() throws {
        try withTemporaryDirectory { directory in
            let fakePS = try writeExecutable(
                """
                #!/bin/bash
                case "$*" in
                  *comm=*) printf '%s\\n' "$FAKE_PS_COMM" ;;
                  *) printf '1000 0.0\\n' ;;
                esac
                """,
                named: "fake-ps",
                in: directory
            )
            let failingProbe = try writeExecutable(
                "#!/bin/bash\necho \"simulated probe failure\" >&2\nexit 1\n",
                named: "probe-fail",
                in: directory
            )
            let evidence = directory.appendingPathComponent("evidence", isDirectory: true)
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)

            let result = try runBash(
                """
                source "$GATE_SCRIPT"
                init_evidence
                /bin/sleep 60 &
                stand_in_pid=$!
                trap '/bin/kill "$stand_in_pid" 2>/dev/null || true' EXIT
                APP_NAME="sleep"
                APP_BINARY="fake-app-binary"
                PS_BIN="$FAKE_PS"
                export FAKE_PS_COMM="fake-app-binary"
                PROBE_BINARY="$FAKE_PROBE"
                RESOURCE_DURATION=1
                stand_in_count="$(/usr/bin/pgrep -x sleep | /usr/bin/wc -l | /usr/bin/tr -d ' ' || true)"
                echo "STANDINS=${stand_in_count:-0}"
                if run_resource_monitor; then
                  echo "STAGE-RESULT=PASS"
                else
                  echo "STAGE-RESULT=FAIL"
                fi
                echo "OVERALL_STATUS=$OVERALL_STATUS"
                """,
                environment: [
                    "TINYBUDDY_REGRESSION_EVIDENCE_DIR": evidence.path,
                    "FAKE_PS": fakePS.path,
                    "FAKE_PROBE": failingProbe.path
                ]
            )

            XCTAssertEqual(result.exitCode, 0, result.error)
            XCTAssertGreaterThan(standInCount(in: result.output), 0, result.output)
            XCTAssertTrue(result.error.contains(">>> FAIL: resource-monitor"), result.error)
            XCTAssertTrue(result.error.contains("resource probe failed for PID"), result.error)
            XCTAssertTrue(result.output.contains("STAGE-RESULT=FAIL"), result.output)
            XCTAssertTrue(result.output.contains("OVERALL_STATUS=1"), result.output)
            XCTAssertTrue(result.error.contains("resource probe unavailable for PID"), result.error)

            let samples = try resourceSamples(in: evidence)
            XCTAssertEqual(samples.count, 1, samples.joined(separator: "\n"))
            XCTAssertEqual(samples.first, sampleHeader)
            XCTAssertFalse(
                samples.contains(where: { $0.contains("0,0,0,0") }),
                "resource monitor must not record fabricated zero probe counters"
            )
        }
    }

    func testScriptDoesNotFabricateZeroProbeSamples() throws {
        let script = try String(contentsOf: scriptURL(), encoding: .utf8)

        XCTAssertFalse(
            script.contains("\"0,0,0,0\""),
            "resource sampling must fail closed instead of substituting zero probe counters"
        )
        XCTAssertTrue(script.contains("probe_counters() {"), "the probe sampling helper is missing")
    }

    // MARK: - Helpers

    private func probeCounters(
        probe: URL,
        pid: String
    ) throws -> (exitCode: Int32, output: String, error: String) {
        try runBash(
            """
            source "$GATE_SCRIPT"
            PROBE_BINARY="$FAKE_PROBE"
            probe_counters "$PROBE_PID"
            """,
            environment: ["FAKE_PROBE": probe.path, "PROBE_PID": pid]
        )
    }

    private func standInCount(in output: String) -> Int {
        let line = output
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("STANDINS=") }
        return Int(line?.dropFirst("STANDINS=".count) ?? "") ?? 0
    }

    private func resourceSamples(in evidenceDirectory: URL) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(
            at: evidenceDirectory,
            includingPropertiesForKeys: nil
        )
        guard let samplesURL = files.first(where: { $0.lastPathComponent.hasSuffix("-resource.csv") }) else {
            XCTFail("the resource-monitor stage wrote no sample file into \(evidenceDirectory.path)")
            return []
        }
        return try String(contentsOf: samplesURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-regression-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @discardableResult
    private func writeExecutable(_ contents: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func runBash(
        _ body: String,
        environment: [String: String] = [:]
    ) throws -> (exitCode: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", body]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["GATE_SCRIPT": scriptURL().path]) { _, new in new }
            .merging(environment) { _, new in new }

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
            .appendingPathComponent("script/regression_gate.sh")
    }

    private let sampleHeader = "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state,cpu_time_ns,disk_read_bytes,interrupt_wakeups,idle_wakeups"
}
