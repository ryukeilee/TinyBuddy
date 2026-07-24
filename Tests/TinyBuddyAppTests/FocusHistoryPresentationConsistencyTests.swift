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
        // Widget 在 publication 不可用时回退到 Git 活动数据而非显示"未知"
        XCTAssertFalse(widget.contains("guard let focus = entry.focusSessionSnapshot"))
        XCTAssertTrue(widget.contains("focusMetricIsKnown ? presentation.focusCountText : \"未知\""))
        // 回退逻辑使用 Git 活动数据中的专注块计数
        XCTAssertTrue(widget.contains("presentation.focusCount > 0"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
