import Foundation
import XCTest

final class WidgetUnifiedDisplaySourceTests: XCTestCase {
    func testWidgetConsumesOnlySharedDisplayPresentationAndLayoutPolicy() throws {
        let source = try widgetSource()

        XCTAssertTrue(source.contains("let presentation: TinyBuddyDisplayPresentation"))
        XCTAssertTrue(source.contains("presentation: TinyBuddyDisplayPresentation("))
        XCTAssertTrue(source.contains("TinyBuddyDisplayLayout("))
        XCTAssertTrue(source.contains("presentation.focusCountText"))
        XCTAssertTrue(source.contains("presentation.completionCountText"))
        XCTAssertTrue(source.contains("presentation.recentProjectName"))
        XCTAssertTrue(source.contains("presentation.dataDateText"))
        XCTAssertTrue(source.contains("presentation.systemImage"))
        XCTAssertTrue(source.contains("presentation.accentRole"))
        XCTAssertFalse(source.contains("GitActivityExperienceState"))
        XCTAssertFalse(source.contains("stateContent"))
        XCTAssertFalse(source.contains("switch presentation.state"))
    }

    func testWidgetSizeAndAccessibilityDegradationContractIsExplicit() throws {
        let source = try widgetSource()

        XCTAssertTrue(source.contains("case .systemMedium:"))
        XCTAssertTrue(source.contains(".supportedFamilies([.systemSmall, .systemMedium])"))
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize)"))
        XCTAssertTrue(source.contains("@Environment(\\.colorSchemeContrast)"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(source.contains("@Environment(\\.colorScheme)"))
        XCTAssertTrue(source.contains("ProcessInfo.processInfo.isLowPowerModeEnabled"))
        XCTAssertTrue(source.contains("transaction.disablesAnimations = true"))
        XCTAssertTrue(source.contains("size: family == .systemMedium ? .expanded : .compact"))
        XCTAssertTrue(source.contains("if layout.showsBrandLabel"))
        XCTAssertTrue(source.contains(".lineLimit(layout.titleLineLimit)"))
        XCTAssertFalse(source.contains("ScrollView(.vertical)"))
        XCTAssertFalse(source.contains("Timer("))
        XCTAssertFalse(source.contains(".animation("))
    }

    func testWidgetProviderPublishesDataQualityAndSharedOnboardingState() throws {
        let source = try widgetSource()

        XCTAssertTrue(source.contains("TinyBuddyDisplayDataAvailability("))
        XCTAssertTrue(source.contains("dataAvailability: .stale"))
        XCTAssertTrue(source.contains("TinyBuddyDisplaySharedState.onboardingCompleted("))
        XCTAssertTrue(source.contains("status.isForDisplayDay(in: timeContext)"))
        XCTAssertTrue(source.contains("Timeline(entries: entries, policy: .never)"))
    }

    func testMediumWidgetRecentProjectMatchesHUDSingleLineMiddleTruncation() throws {
        let source = try widgetSource()

        XCTAssertTrue(source.contains("""
                            Text(recentProjectName)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
"""))
        XCTAssertTrue(source.contains("HStack(spacing: 8)"))
    }

    private func widgetSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root
                .appendingPathComponent("Widget")
                .appendingPathComponent("TinyBuddyWidget")
                .appendingPathComponent("TinyBuddyWidget.swift"),
            encoding: .utf8
        )
    }
}
