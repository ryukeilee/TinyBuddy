#!/usr/bin/env python3
"""Instrument an exported source tree, never the current production tree."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source_tree", type=Path)
parser.add_argument("--transition-trace", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
tree = args.source_tree.resolve()
if tree == root:
    parser.error("use an exported temporary source tree")
path = tree / "Sources/TinyBuddy/TinyBuddyApp.swift"
source = path.read_text()
anchor = """        revealHUDWhenStartupStateIsRestored()
        scheduleDeferredStartupFallback()
        schedulePostHUDStartupIfReady()
    }"""
if source.count(anchor) != 1 or "startResourceScenario" in source:
    parser.error("startup anchor must match exactly once in an uninstrumented tree")

driver = r'''
    // Local measurement only: use the existing command/persistence/UI paths.
    private func startResourceScenario() {
        for (delay, scene) in [(60.0, "idle-start"), (125.0, "idle-end"),
                               (140.0, "focus-start"), (205.0, "focus-end"),
                               (220.0, "paused-start"), (285.0, "paused-end"),
                               (296.0, "resumed"), (301.0, "ended")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.recordResourceScenario(scene)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 135) { [weak self] in
            guard let self else { return }
            let registered = self.projectRegistry?.currentSnapshot.projects.first {
                $0.displayName == "TinyBuddy" && $0.state == .active
            }
            let project = FocusProjectContext(
                key: registered?.id.rawValue ?? "tinybuddy-resource-verification",
                displayName: registered?.displayName ?? "TinyBuddy 性能验证"
            )
            self.petViewModel.startManualFocus(project: project)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 215) { [weak self] in
            self?.petViewModel.pauseManualFocus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 295) { [weak self] in
            self?.petViewModel.resumeManualFocus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.petViewModel.endManualFocus()
        }
    }

    private func recordResourceScenario(_ scene: String) {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: MemoryLayout<rusage_info_v4>.size / MemoryLayout<rusage_info_t?>.size
            ) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else {
            FileHandle.standardOutput.write(Data("APP_RESOURCE_ERROR errno=\(errno)\n".utf8))
            return
        }
        let state = focusSessionEngine?.manualControlState.transitionIdentity ?? "unavailable"
        let hud = petViewModel.manualControlState.transitionIdentity
        let history = petViewModel.focusHistoryPublication
        let line = "APP_RESOURCE uptime=\(ProcessInfo.processInfo.systemUptime) scene=\(scene) engine=\(state) hud=\(hud) interface_active=\(NSApp.isActive) active=\(history?.isFocusSessionActive ?? false) paused=\(history?.isFocusSessionPaused ?? false) revision=\(history?.revision ?? -1) rss=\(usage.ri_resident_size) footprint=\(usage.ri_phys_footprint) cpu_ns=\(usage.ri_user_time + usage.ri_system_time + usage.ri_child_user_time + usage.ri_child_system_time) wakeups=\(usage.ri_interrupt_wkups + usage.ri_child_interrupt_wkups) idle_wakeups=\(usage.ri_pkg_idle_wkups + usage.ri_child_pkg_idle_wkups)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
'''
if args.transition_trace:
    driver = driver.replace('(205.0, "focus-end")', '(141.0, "focus-end")')
    driver = driver.replace('(220.0, "paused-start")', '(146.0, "paused-start")')
    driver = driver.replace('(285.0, "paused-end")', '(147.0, "paused-end")')
    driver = driver.replace('(296.0, "resumed")', '(156.0, "resumed")')
    driver = driver.replace('(301.0, "ended")', '(166.0, "ended")')
    for previous, next_delay, action in [(215, 145, "pause"), (295, 155, "resume"), (300, 165, "end")]:
        driver = driver.replace(f".now() + {previous}", f".now() + {next_delay}")
        driver = driver.replace(
            f"            self?.petViewModel.{action}ManualFocus()",
            f'            resourceTrace("command-{action}")\n            self?.petViewModel.{action}ManualFocus()',
        )
    driver = driver.replace("            self.petViewModel.startManualFocus(project: project)",
                            '            resourceTrace("command-start")\n            self.petViewModel.startManualFocus(project: project)')
    driver = driver.replace("        let line =", """        let durable = combinedSnapshotStore.loadReadOnly()?.focusHistoryPublication
        let engineRevision = focusSessionEngine?.focusHistoryPublication()?.revision ?? -1
        let line =""")
    driver = driver.replace(' revision=\\(history?.revision ?? -1)',
                            ' revision=\\(history?.revision ?? -1) engine_revision=\\(engineRevision) durable_revision=\\(durable?.revision ?? -1) durable_active=\\(durable?.isFocusSessionActive ?? false) durable_paused=\\(durable?.isFocusSessionPaused ?? false)')
    start = source.index("focusBridge?.sessionEngine.committedHistorySnapshotHandler =")
    end = source.index("// Periodic live-minute", start)
    handler = source[start:end].replace(
        "            DispatchQueue.main.async {",
        '            resourceTrace("history-emitted", revision: publication.revision)\n            DispatchQueue.main.async {\n                resourceTrace("history-main-enter", revision: publication.revision)',
        1,
    )
    source = source[:start] + handler + source[end:]
    anchor_update = """        let update = combinedSnapshotStore.updateFocusHistorySlice(
            publication,
            fallbackSnapshot: current,
            snapshotOverride: snapshotOverride
        )"""
    assert source.count(anchor_update) == 1
    source = source.replace(anchor_update, anchor_update + '\n        resourceTrace("combined-return", revision: publication.revision, outcome: String(describing: update.outcome))')
    source = source.replace("        petViewModel.focusSessionStatsDidChange(reloadWidget: reloadWidget)",
                            '        petViewModel.focusSessionStatsDidChange(reloadWidget: reloadWidget)\n        resourceTrace("hud-refresh-return", revision: petViewModel.focusHistoryPublication?.revision ?? -1)', 1)
    source = source.replace("    private func requestWidgetTimelineReload() {",
                            '    private func requestWidgetTimelineReload() {\n        resourceTrace("widget-reload-request")', 1)
    source += r'''
private func resourceTrace(_ event: String, revision: Int64 = -1, outcome: String = "-") {
    let line = "APP_TRACE uptime=\(ProcessInfo.processInfo.systemUptime) event=\(event) revision=\(revision) outcome=\(outcome)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}
'''
source = source.replace("import AppKit\n", "import AppKit\nimport Darwin\n", 1)
source = source.replace(anchor, anchor[:-5] + "        startResourceScenario()\n    }\n" + driver, 1)
path.write_text(source)
