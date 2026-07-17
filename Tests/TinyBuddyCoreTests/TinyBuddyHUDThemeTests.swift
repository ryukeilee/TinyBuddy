import AppKit
import SwiftUI
import XCTest
@testable import TinyBuddyCore

final class TinyBuddyHUDThemeTests: XCTestCase {
    func testStatusAccentMapsEveryDisplayAccentRole() {
        XCTAssertEqual(TinyBuddyHUDTheme.statusAccent(for: .neutral), TinyBuddyHUDTheme.hudGold)
        XCTAssertEqual(TinyBuddyHUDTheme.statusAccent(for: .focus), TinyBuddyHUDTheme.energyBlueWhite)
        XCTAssertEqual(TinyBuddyHUDTheme.statusAccent(for: .success), TinyBuddyHUDTheme.completedGold)
        XCTAssertEqual(TinyBuddyHUDTheme.statusAccent(for: .warning), TinyBuddyHUDTheme.warningAmber)
        XCTAssertEqual(TinyBuddyHUDTheme.statusAccent(for: .error), TinyBuddyHUDTheme.reactorRed)
        XCTAssertEqual(TinyBuddyHUDTheme.statusAccent(for: .loading), TinyBuddyHUDTheme.energyBlueWhite)
    }

    func testAdaptiveStatusAccentsAreDeterministicForHighContrast() {
        for role in [
            TinyBuddyDisplayAccentRole.neutral,
            .focus,
            .success,
            .warning,
            .error,
            .loading
        ] {
            XCTAssertEqual(
                TinyBuddyHUDTheme.statusAccent(for: role, increasedContrast: true),
                TinyBuddyHUDTheme.statusAccent(for: role, increasedContrast: true)
            )
            XCTAssertNotEqual(
                TinyBuddyHUDTheme.statusAccent(for: role),
                TinyBuddyHUDTheme.statusAccent(for: role, increasedContrast: true)
            )
        }
    }

    func testAdaptiveColorsAndFillsSupportBothColorSchemes() {
        for colorScheme in [ColorScheme.light, .dark] {
            XCTAssertNotNil(
                TinyBuddyHUDTheme.backgroundFill(for: colorScheme, increasedContrast: false)
            )
            XCTAssertNotNil(
                TinyBuddyHUDTheme.backgroundFill(for: colorScheme, increasedContrast: true)
            )
            XCTAssertNotNil(
                TinyBuddyHUDTheme.panelFill(for: colorScheme, increasedContrast: false)
            )
            XCTAssertNotNil(
                TinyBuddyHUDTheme.panelFill(for: colorScheme, increasedContrast: true)
            )
            XCTAssertEqual(
                TinyBuddyHUDTheme.primaryTextColor(for: colorScheme, increasedContrast: false),
                TinyBuddyHUDTheme.primaryTextColor(for: colorScheme, increasedContrast: false)
            )
            XCTAssertNotEqual(
                TinyBuddyHUDTheme.primaryTextColor(for: colorScheme, increasedContrast: false),
                TinyBuddyHUDTheme.primaryTextColor(for: colorScheme, increasedContrast: true)
            )
            XCTAssertEqual(
                TinyBuddyHUDTheme.secondaryTextColor(for: colorScheme, increasedContrast: true),
                TinyBuddyHUDTheme.secondaryTextColor(for: colorScheme, increasedContrast: true)
            )
            XCTAssertNotEqual(
                TinyBuddyHUDTheme.secondaryTextColor(for: colorScheme, increasedContrast: false),
                TinyBuddyHUDTheme.secondaryTextColor(for: colorScheme, increasedContrast: true)
            )
            XCTAssertEqual(
                TinyBuddyHUDTheme.panelBorder(for: colorScheme, increasedContrast: true),
                TinyBuddyHUDTheme.panelBorder(for: colorScheme, increasedContrast: true)
            )
            for role in TinyBuddyDisplayAccentRole.allCasesForTesting {
                XCTAssertNotEqual(
                    TinyBuddyHUDTheme.statusAccent(
                        for: role,
                        colorScheme: colorScheme,
                        increasedContrast: false
                    ),
                    TinyBuddyHUDTheme.statusAccent(
                        for: role,
                        colorScheme: colorScheme,
                        increasedContrast: true
                    )
                )
            }
        }

        for role in TinyBuddyDisplayAccentRole.allCasesForTesting {
            XCTAssertNotEqual(
                TinyBuddyHUDTheme.statusAccent(
                    for: role,
                    colorScheme: .light,
                    increasedContrast: true
                ),
                TinyBuddyHUDTheme.statusAccent(
                    for: role,
                    colorScheme: .dark,
                    increasedContrast: true
                )
            )
        }
    }

    func testTextAndStatusAccentsMeetWCAGContrastThresholds() {
        for colorScheme in [ColorScheme.light, .dark] {
            for increasedContrast in [false, true] {
                let backgrounds = TinyBuddyHUDTheme.backgroundColors(
                    for: colorScheme,
                    increasedContrast: increasedContrast
                ).map(resolvedColor)
                let panels = TinyBuddyHUDTheme.panelColors(
                    for: colorScheme,
                    increasedContrast: increasedContrast
                ).map(resolvedColor)
                let primaryText = resolvedColor(TinyBuddyHUDTheme.primaryTextColor(
                    for: colorScheme,
                    increasedContrast: increasedContrast
                ))
                let secondaryText = resolvedColor(TinyBuddyHUDTheme.secondaryTextColor(
                    for: colorScheme,
                    increasedContrast: increasedContrast
                ))
                let brandText = resolvedColor(TinyBuddyHUDTheme.brandTextColor(
                    for: colorScheme,
                    increasedContrast: increasedContrast
                ))

                for background in backgrounds {
                    assertContrast(
                        primaryText,
                        over: background,
                        minimum: 4.5,
                        description: "primary text on background (\(colorScheme), increased=\(increasedContrast))"
                    )
                    assertContrast(
                        secondaryText,
                        over: background,
                        minimum: 4.5,
                        description: "secondary text on background (\(colorScheme), increased=\(increasedContrast))"
                    )
                    assertContrast(
                        brandText,
                        over: background,
                        minimum: 4.5,
                        description: "brand text on background (\(colorScheme), increased=\(increasedContrast))"
                    )

                    for panel in panels {
                        let panelBackground = panel.composited(over: background)
                        assertContrast(
                            primaryText,
                            over: panelBackground,
                            minimum: 4.5,
                            description: "primary text on panel (\(colorScheme), increased=\(increasedContrast))"
                        )
                        assertContrast(
                            secondaryText,
                            over: panelBackground,
                            minimum: 4.5,
                            description: "secondary text on panel (\(colorScheme), increased=\(increasedContrast))"
                        )
                        assertContrast(
                            brandText,
                            over: panelBackground,
                            minimum: 4.5,
                            description: "brand text on panel (\(colorScheme), increased=\(increasedContrast))"
                        )

                        for role in TinyBuddyDisplayAccentRole.allCasesForTesting {
                            assertContrast(
                                resolvedColor(TinyBuddyHUDTheme.statusAccent(
                                    for: role,
                                    colorScheme: colorScheme,
                                    increasedContrast: increasedContrast
                                )),
                                over: panelBackground,
                                minimum: 3.0,
                                description: "\(role) accent on panel (\(colorScheme), increased=\(increasedContrast))"
                            )
                        }
                    }

                    for role in TinyBuddyDisplayAccentRole.allCasesForTesting {
                        assertContrast(
                            resolvedColor(TinyBuddyHUDTheme.statusAccent(
                                for: role,
                                colorScheme: colorScheme,
                                increasedContrast: increasedContrast
                            )),
                            over: background,
                            minimum: 3.0,
                            description: "\(role) accent on background (\(colorScheme), increased=\(increasedContrast))"
                        )
                    }
                }
            }
        }

    }

    func testStatusAccentUsesSharedSemanticPalette() {
        XCTAssertEqual(
            TinyBuddyHUDTheme.statusAccent(for: .idle),
            TinyBuddyHUDTheme.hudGold
        )
        XCTAssertEqual(
            TinyBuddyHUDTheme.statusAccent(for: .focusing),
            TinyBuddyHUDTheme.energyBlueWhite
        )
        XCTAssertEqual(
            TinyBuddyHUDTheme.statusAccent(for: .completed),
            TinyBuddyHUDTheme.completedGold
        )
        XCTAssertEqual(
            TinyBuddyHUDTheme.statusAccent(for: .active),
            TinyBuddyHUDTheme.completedGold
        )
    }
}

private struct ResolvedColor {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    func composited(over background: ResolvedColor) -> ResolvedColor {
        let outputAlpha = alpha + background.alpha * (1 - alpha)
        guard outputAlpha > 0 else {
            return ResolvedColor(red: 0, green: 0, blue: 0, alpha: 0)
        }

        return ResolvedColor(
            red: (red * alpha + background.red * background.alpha * (1 - alpha)) / outputAlpha,
            green: (green * alpha + background.green * background.alpha * (1 - alpha)) / outputAlpha,
            blue: (blue * alpha + background.blue * background.alpha * (1 - alpha)) / outputAlpha,
            alpha: outputAlpha
        )
    }
}

private func resolvedColor(_ color: Color) -> ResolvedColor {
    let nsColor = NSColor(color).usingColorSpace(.sRGB)
    guard let nsColor else {
        fatalError("Expected TinyBuddy HUD colors to resolve in sRGB")
    }

    return ResolvedColor(
        red: Double(nsColor.redComponent),
        green: Double(nsColor.greenComponent),
        blue: Double(nsColor.blueComponent),
        alpha: Double(nsColor.alphaComponent)
    )
}

private func assertContrast(
    _ foreground: ResolvedColor,
    over background: ResolvedColor,
    minimum: Double,
    description: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let ratio = contrastRatio(foreground.composited(over: background), background)
    XCTAssertGreaterThanOrEqual(
        ratio,
        minimum,
        "\(description): \(String(format: "%.2f", ratio)):1 < \(String(format: "%.1f", minimum)):1",
        file: file,
        line: line
    )
}

private func contrastRatio(_ first: ResolvedColor, _ second: ResolvedColor) -> Double {
    let lighter = max(relativeLuminance(first), relativeLuminance(second))
    let darker = min(relativeLuminance(first), relativeLuminance(second))
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(_ color: ResolvedColor) -> Double {
    0.2126 * linearized(color.red)
        + 0.7152 * linearized(color.green)
        + 0.0722 * linearized(color.blue)
}

private func linearized(_ component: Double) -> Double {
    component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
}

private extension TinyBuddyDisplayAccentRole {
    static let allCasesForTesting: [TinyBuddyDisplayAccentRole] = [
        .neutral,
        .focus,
        .success,
        .warning,
        .error,
        .loading
    ]
}
