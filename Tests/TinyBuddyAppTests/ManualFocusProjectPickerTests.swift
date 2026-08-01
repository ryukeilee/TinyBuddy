import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class ManualFocusProjectPickerTests: XCTestCase {
    func testRecentProjectUsesUniqueRegisteredIdentity() {
        let registered = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-tinybuddy"),
            kind: .gitRepository,
            displayName: "TinyBuddy"
        )

        let context = ManualFocusProjectIdentityResolver.recentProject(
            named: "TinyBuddy",
            registeredProjects: [registered]
        )

        XCTAssertEqual(
            context,
            FocusProjectContext(
                key: "project-tinybuddy",
                displayName: "TinyBuddy"
            )
        )
    }

    func testAmbiguousRecentProjectKeepsIsolatedManualIdentity() {
        let projects = [
            TinyBuddyProject(
                id: TinyBuddyProjectID(rawValue: "project-one"),
                kind: .gitRepository,
                displayName: "Shared Name"
            ),
            TinyBuddyProject(
                id: TinyBuddyProjectID(rawValue: "project-two"),
                kind: .application,
                displayName: "Shared Name"
            )
        ]

        let context = ManualFocusProjectIdentityResolver.recentProject(
            named: "Shared Name",
            registeredProjects: projects
        )

        XCTAssertEqual(
            context,
            FocusProjectContext(
                key: "manual.recent.Shared Name",
                displayName: "Shared Name"
            )
        )
    }
}
