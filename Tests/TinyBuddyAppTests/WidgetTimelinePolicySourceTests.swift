import Foundation
import XCTest

final class WidgetTimelinePolicySourceTests: XCTestCase {
    func testWidgetPrebuildsMidnightRolloverWithoutUnconditionalPeriodicWakeups() throws {
        let source = try String(contentsOf: widgetSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("timeContext.nextDayBoundary"))
        // Stable states stay on `.never`: an unchanged Widget never asks for a
        // periodic wakeup. Self-scheduling is opt-in per state, not global.
        XCTAssertTrue(source.contains("policy: .never"))
        XCTAssertTrue(source.contains("policy: .after("))
        XCTAssertTrue(source.contains("TinyBuddyWidgetTimelinePolicy.nextRefreshDate("))
        XCTAssertFalse(source.contains("nextRefreshDate(maxInterval:"))
    }

    func testFutureRolloverEntryRejectsPreviousDayStatusAndFallbackSnapshot() throws {
        let source = try String(contentsOf: widgetSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("status.isForDisplayDay(in: timeContext) ? status : nil"))
        XCTAssertTrue(source.contains("fallbackSnapshot.stats.dayIdentifier == expectedDayIdentifier"))
    }

    func testWidgetPublishesSanitizedCommittedSnapshotConsumptionTelemetry() throws {
        let source = try String(contentsOf: widgetSourceURL(), encoding: .utf8)
        let marker = try XCTUnwrap(source.range(of: "snapshot consumed schema="))
        let line = source[marker.lowerBound...].split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""

        XCTAssertTrue(line.contains("currentSchemaVersion"))
        XCTAssertTrue(line.contains("combinedSnapshot.revision"))
        XCTAssertTrue(line.contains("combinedSnapshot.dayIdentifier"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("project"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("path"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("bookmark"))
    }

    private func widgetSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Widget/TinyBuddyWidget/TinyBuddyWidget.swift")
    }
}
