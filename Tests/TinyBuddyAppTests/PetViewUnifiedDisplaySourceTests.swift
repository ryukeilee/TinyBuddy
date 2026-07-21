import Foundation
import XCTest

final class PetViewUnifiedDisplaySourceTests: XCTestCase {
    func testHUDConsumesUnifiedDisplayPresentationWithoutLegacyBusinessState() throws {
        let source = try petViewSource()

        XCTAssertTrue(source.contains("private var presentation: TinyBuddyDisplayPresentation"))
        XCTAssertTrue(source.contains("viewModel.displayPresentation"))
        XCTAssertTrue(source.contains("TinyBuddyDisplayLayout("))
        XCTAssertTrue(source.contains("presentation: presentation"))
        XCTAssertTrue(source.contains("UnifiedDisplayStateView("))
        XCTAssertTrue(source.contains("if displayLayout.showsMetrics"))
        XCTAssertFalse(source.contains("gitActivityExperience"))
        XCTAssertFalse(source.contains("hudPresentation"))
        XCTAssertFalse(source.contains("viewModel.displayState"))
        XCTAssertFalse(source.contains("switch presentation."))
    }

    func testHUDAccessibilityAndStableLayoutContractIsExplicit() throws {
        let source = try petViewSource()

        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize)"))
        XCTAssertTrue(source.contains("@Environment(\\.colorSchemeContrast)"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(source.contains("@Environment(\\.colorScheme)"))
        XCTAssertTrue(source.contains("ProcessInfo.processInfo.isLowPowerModeEnabled"))
        XCTAssertTrue(source.contains("ScrollView(.vertical)"))
        XCTAssertTrue(source.contains(".frame(width: fixedWidth, height: hudHeight"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: hudHeight"))
        XCTAssertTrue(source.contains("transaction.disablesAnimations = true"))
    }

    func testHUDUpdatesLowPowerLayoutInputFromPowerStateNotifications() throws {
        let source = try petViewSource()

        XCTAssertTrue(source.contains("@State private var lowPowerModeEnabled: Bool"))
        XCTAssertTrue(source.contains("initialValue: ProcessInfo.processInfo.isLowPowerModeEnabled"))
        XCTAssertTrue(source.contains("lowPower: lowPowerModeEnabled"))
        XCTAssertTrue(source.contains("for: .NSProcessInfoPowerStateDidChange"))
        XCTAssertTrue(source.contains("updateLowPowerMode()"))
        XCTAssertTrue(source.contains("guard lowPowerModeEnabled != currentValue else"))
        XCTAssertTrue(source.contains("lowPowerModeEnabled = currentValue"))
    }

    func testHUDBrandLabelsUseSharedSemanticTextColor() throws {
        let source = try petViewSource()

        XCTAssertEqual(source.components(separatedBy: "HUDTheme.brandTextColor(").count - 1, 3)
        XCTAssertTrue(source.contains(".fill(HUDTheme.hudGold.opacity"))
    }

    func testHUDUsesSemanticTransitionsWithoutContinuousLoadingAnimation() throws {
        let source = try petViewSource()

        XCTAssertTrue(source.contains("private var semanticAnimation: Animation?"))
        XCTAssertTrue(source.contains("displayLayout.allowsMotion ? .easeOut"))
        XCTAssertTrue(source.contains(".animation(semanticAnimation, value: presentation.transitionIdentity)"))
        XCTAssertTrue(source.contains(".id(presentation.transitionIdentity)"))
        XCTAssertTrue(source.contains(".contentTransition(.numericText())"))
        XCTAssertTrue(source.contains(".opacity(presentation.isRefreshing ? 1 : 0)"))
        XCTAssertFalse(source.contains("if presentation.isRefreshing"))
        XCTAssertFalse(source.contains("ProgressView"))
        XCTAssertFalse(source.contains("Timer("))
        XCTAssertFalse(source.contains(".repeatForever("))
        XCTAssertFalse(source.contains(".repeatCount("))
    }

    func testHUDRecentProjectUsesSingleLineMiddleTruncation() throws {
        let source = try petViewSource()

        XCTAssertTrue(source.contains("""
                    Text(recentProjectName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
"""))
    }

    private func petViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root
                .appendingPathComponent("Sources")
                .appendingPathComponent("TinyBuddy")
                .appendingPathComponent("PetView.swift"),
            encoding: .utf8
        )
    }
}
