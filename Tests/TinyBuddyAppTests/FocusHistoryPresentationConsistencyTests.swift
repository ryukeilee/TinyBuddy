import Foundation
import XCTest

/// Guards the architectural boundary rather than reproducing SwiftUI layout
/// tests: Core proves the shared payload's values, while these assertions keep
/// every presentation entry on that one payload instead of raw sessions.
final class FocusHistoryPresentationConsistencyTests: XCTestCase {
    func testSettingsHUDAndWidgetConsumeTheCommittedHistoryPublication() throws {
        let app = try source("Sources/TinyBuddy/TinyBuddyApp.swift")
        let report = try source("Sources/TinyBuddy/FocusHistoryView.swift")
        let hud = try source("Sources/TinyBuddy/PetViewModel.swift")
        let widget = try source("Widget/TinyBuddyWidget/TinyBuddyWidget.swift")

        XCTAssertTrue(app.contains("combinedSnapshotStore.updateFocusHistorySlice("))
        XCTAssertTrue(app.contains("engine.republishFocusHistory()"))

        XCTAssertTrue(report.contains("let publicationProvider: () -> FocusHistoryPublication?"))
        XCTAssertTrue(report.contains("TimelineView(.periodic(from: .now, by: 60))"))
        XCTAssertTrue(report.contains("currentDayDuration(at: now)"))
        XCTAssertTrue(report.contains("currentWeekDuration(at: now)"))
        XCTAssertFalse(report.contains("allSessions"))
        XCTAssertFalse(report.contains("FocusHistoryAggregationCache"))

        XCTAssertTrue(hud.contains("committedSnapshot?.focusHistoryPublication"))
        XCTAssertTrue(widget.contains("combinedSnapshot.focusHistoryPublication"))
        XCTAssertFalse(widget.contains("FocusHistoryAggregationCache"))
    }

    func testUnknownHistoryNeverFallsBackToLegacyWidgetCounts() throws {
        let report = try source("Sources/TinyBuddy/FocusHistoryView.swift")
        let hud = try source("Sources/TinyBuddy/PetView.swift")
        let widget = try source("Widget/TinyBuddyWidget/TinyBuddyWidget.swift")

        XCTAssertTrue(report.contains("publication = publicationProvider()"))
        XCTAssertFalse(report.contains("} { _ in\n            refreshHistory()"))
        XCTAssertTrue(hud.contains("FocusHistoryDurationFormatter.text(for: focusMetricDuration(at: now))"))
        XCTAssertTrue(widget.contains("FocusHistoryDurationFormatter.text(for: focusMetricDuration)"))
        XCTAssertFalse(hud.contains("presentation.focusCountText"))
        XCTAssertFalse(widget.contains("presentation.focusCountText"))
        XCTAssertFalse(widget.contains("presentation.focusCount > 0"))
    }

    func testCommittedSessionStateRefreshesHUDAndMenuBarFromTheSameEngine() throws {
        let app = try source("Sources/TinyBuddy/TinyBuddyApp.swift")
        let menu = try source("Sources/TinyBuddy/ManualFocusMenuBarController.swift")

        XCTAssertTrue(app.contains("committedReminderEvaluationHandler"))
        XCTAssertTrue(app.contains("self.petViewModel.refreshManualControlState()"))
        XCTAssertTrue(app.contains("self.manualFocusMenuBarController.refresh()"))
        XCTAssertTrue(menu.contains("func refresh()"))
        XCTAssertTrue(menu.contains("let state = engine.manualControlState"))
    }

    func testLiveDurationProjectsFromCommittedAnchorWithoutMinuteSnapshotRepublish() throws {
        let bridge = try source("Sources/TinyBuddy/FocusSessionAppBridge.swift")
        let hud = try source("Sources/TinyBuddy/PetView.swift")
        let widget = try source("Widget/TinyBuddyWidget/TinyBuddyWidget.swift")
        let viewModel = try source("Sources/TinyBuddy/PetViewModel.swift")
        let app = try source("Sources/TinyBuddy/TinyBuddyApp.swift")

        XCTAssertTrue(bridge.contains("private var wasIdle: Bool = true"))
        // Live elapsed time is projected from the committed anchor at read time.
        XCTAssertFalse(bridge.contains("engine.republishFocusHistory(shouldReloadWidget: false)"))
        XCTAssertFalse(bridge.contains("lastPublishedFocusMinute"))
        XCTAssertFalse(bridge.contains("Timer("))
        XCTAssertTrue(hud.contains("TimelineView(.periodic(from: .now, by: 60))"))
        XCTAssertTrue(hud.contains("currentWeekDuration(at: now)"))
        XCTAssertTrue(widget.contains("currentDayDuration(at: entry.date)"))
        XCTAssertTrue(widget.contains("currentWeekDuration(at: entry.date)"))

        XCTAssertTrue(app.contains("liveMinuteRepublishHandler"))
        XCTAssertTrue(app.contains("reloadWidget: false"))
        XCTAssertTrue(app.contains("status: nil"))

        XCTAssertTrue(viewModel.contains("let previousHistory = focusHistoryPublication"))
        XCTAssertTrue(viewModel.contains("func focusSessionStatsDidChange(reloadWidget: Bool = true)"))
        XCTAssertTrue(viewModel.contains("if reloadWidget, didChange || focusHistoryPublication != previousHistory"))
        XCTAssertTrue(viewModel.contains("func synchronizeFocusSessionStatus(_ status: PetStatus)"))
        XCTAssertTrue(viewModel.contains("func applyFocusStatusForPublication(_ status: PetStatus)"))
        // The handler now uses the lightweight status update + combined write
        // instead of a separate combined-snapshot-write in synchronizeFocusSessionStatus.
        XCTAssertTrue(app.contains("self.petViewModel.applyFocusStatusForPublication(status)"))
        XCTAssertTrue(app.contains("self.synchronizeFocusHistoryPublication(publication, status: status)"))
        XCTAssertTrue(app.contains("FocusHistoryPublicationStatus.status(for: publication)"))
        XCTAssertTrue(app.contains("status: FocusHistoryPublicationStatus.status(for: history)"))
        XCTAssertFalse(app.contains("petViewModel.synchronizeFocusSessionStatus("))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
