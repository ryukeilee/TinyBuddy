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
        XCTAssertFalse(report.contains("allSessions"))
        XCTAssertFalse(report.contains("FocusHistoryAggregationCache"))

        XCTAssertTrue(hud.contains("committedSnapshot?.focusHistoryPublication"))
        XCTAssertTrue(widget.contains("combinedSnapshot.focusHistoryPublication"))
        XCTAssertFalse(widget.contains("FocusHistoryAggregationCache"))
    }

    func testUnknownHistoryIsNotReemittedOrReplacedByLegacyWidgetNumbers() throws {
        let report = try source("Sources/TinyBuddy/FocusHistoryView.swift")
        let widget = try source("Widget/TinyBuddyWidget/TinyBuddyWidget.swift")

        XCTAssertTrue(report.contains("publication = publicationProvider()"))
        XCTAssertFalse(report.contains("} { _ in\n            refreshHistory()"))
        XCTAssertTrue(widget.contains("return \"专注历史尚未就绪\""))
        XCTAssertFalse(widget.contains("guard let focus = entry.focusSessionSnapshot"))
        XCTAssertTrue(widget.contains("focusMetricIsKnown ? presentation.focusCountText : \"未知\""))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
