import Foundation
import XCTest

final class WidgetTimelinePolicySourceTests: XCTestCase {
    func testWidgetPrebuildsMidnightRolloverWithoutPeriodicTimelineWakeups() throws {
        let source = try String(contentsOf: widgetSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("timeContext.nextDayBoundary"))
        XCTAssertTrue(source.contains("policy: .never"))
        XCTAssertFalse(source.contains("nextRefreshDate(maxInterval:"))
        XCTAssertFalse(source.contains("policy: .after"))
    }

    func testFutureRolloverEntryRejectsPreviousDayStatusAndFallbackSnapshot() throws {
        let source = try String(contentsOf: widgetSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("timeContext.dayIdentifier(for: status.refreshedAt)"))
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
