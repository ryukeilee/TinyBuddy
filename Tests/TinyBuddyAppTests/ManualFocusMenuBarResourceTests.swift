import AppKit
import Darwin
import XCTest
import TinyBuddyCore
@testable import TinyBuddy

private final class MenuResourceStore: FocusSessionPersisting, @unchecked Sendable {
    private var sessions: [FocusSession] = []
    func load() -> [FocusSession]? { sessions }
    func save(_ sessions: [FocusSession]) -> Bool {
        self.sessions = sessions
        return true
    }
}

/// Opt-in steady-state measurement of the real controller, using isolated sessions.
final class ManualFocusMenuBarResourceTests: XCTestCase {
    @MainActor
    func testSteadyStateResources() async throws {
        guard ProcessInfo.processInfo.environment["TINYBUDDY_MENU_BENCHMARK"] == "1" else {
            throw XCTSkip("Set TINYBUDDY_MENU_BENCHMARK=1 for the 3 x 65s steady-state measurement")
        }
        _ = NSApplication.shared
        for scenario in ["idle", "focus", "inactive-paused"] {
            let engine = FocusSessionEngine(
                clock: SystemFocusClock(), persisting: MenuResourceStore(),
                dayIdentifier: { _ in "2026-10-06" }
            )
            if scenario != "idle" {
                _ = engine.startManualFocus(
                    project: FocusProjectContext(key: "benchmark", displayName: "Benchmark"),
                    at: Date(), commandToken: UUID()
                )
            }
            if scenario == "inactive-paused" {
                _ = engine.pauseManualFocus(at: Date(), commandToken: UUID())
            }
            var executions = 0
            let controller = ManualFocusMenuBarController(scheduleRefresh: { interval, repeats, action in
                Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
                    MainActor.assumeIsolated {
                        executions += 1
                        action()
                    }
                }
            })
            controller.start(with: engine)
            try await Task.sleep(for: .seconds(5))
            let startExecutions = executions
            let before = try resourceSample()
            try await Task.sleep(for: .seconds(65))
            let after = try resourceSample()
            print("MENU_STEADY_STATE scenario=\(scenario) seconds=65 executions=\(executions - startExecutions) cpu_ns=\(after.ri_user_time + after.ri_system_time - before.ri_user_time - before.ri_system_time) wakeups=\(after.ri_interrupt_wkups - before.ri_interrupt_wkups) footprint_delta=\(Int64(after.ri_phys_footprint) - Int64(before.ri_phys_footprint)) footprint=\(after.ri_phys_footprint)")
            controller.stop()
        }
    }

    private func resourceSample() throws -> rusage_info_v4 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: MemoryLayout<rusage_info_v4>.size / MemoryLayout<rusage_info_t?>.size
            ) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return usage
    }
}
