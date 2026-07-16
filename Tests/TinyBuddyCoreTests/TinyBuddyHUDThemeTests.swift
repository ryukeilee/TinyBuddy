import SwiftUI
import XCTest
@testable import TinyBuddyCore

final class TinyBuddyHUDThemeTests: XCTestCase {
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
