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

    private func widgetSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Widget/TinyBuddyWidget/TinyBuddyWidget.swift")
    }
}
