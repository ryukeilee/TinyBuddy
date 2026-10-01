import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class ManualFocusProjectPickerTests: XCTestCase {
    func testCustomProjectIdentityPreservesNameCharactersInVersionedNamespace() {
        let spaced = ManualFocusProjectIdentityResolver.customProject(named: "Work Alpha")
        let hyphenated = ManualFocusProjectIdentityResolver.customProject(named: "Work-Alpha")
        let repeatedSpaces = ManualFocusProjectIdentityResolver.customProject(named: "Work  Alpha")
        let repeatedHyphens = ManualFocusProjectIdentityResolver.customProject(named: "Work--Alpha")

        XCTAssertEqual(spaced.key, "manual.custom-v2.Work Alpha")
        XCTAssertEqual(hyphenated.key, "manual.custom-v2.Work-Alpha")
        XCTAssertNotEqual(spaced.key, hyphenated.key)
        XCTAssertNotEqual(repeatedSpaces.key, repeatedHyphens.key)
        XCTAssertNotEqual(spaced.key, "manual.custom.Work-Alpha")
        XCTAssertNotEqual(hyphenated.key, "manual.custom.Work-Alpha")
        XCTAssertEqual(
            ManualFocusProjectIdentityResolver.customProject(named: "Work Alpha"),
            spaced
        )
    }

    func testCustomProjectIdentityKeepsTrimmingCaseAndUnicodeEquality() {
        let trimmed = ManualFocusProjectIdentityResolver.customProject(named: " \nWork Alpha\t ")
        let exact = ManualFocusProjectIdentityResolver.customProject(named: "Work Alpha")
        let lowercase = ManualFocusProjectIdentityResolver.customProject(named: "work alpha")
        let composed = ManualFocusProjectIdentityResolver.customProject(named: "Café")
        let decomposed = ManualFocusProjectIdentityResolver.customProject(named: "Cafe\u{301}")

        XCTAssertEqual(trimmed, exact)
        XCTAssertEqual(trimmed.displayName, "Work Alpha")
        XCTAssertNotEqual(exact.key, lowercase.key)
        XCTAssertEqual(composed.key, decomposed.key)
    }

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

    func testRecentProjectResolverRetainsCaseInsensitiveRegisteredMatch() {
        let registered = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-tinybuddy"),
            kind: .gitRepository,
            displayName: "TinyBuddy"
        )

        XCTAssertEqual(
            ManualFocusProjectIdentityResolver.recentProject(
                named: " tinybuddy ",
                registeredProjects: [registered]
            ),
            FocusProjectContext(key: "project-tinybuddy", displayName: "TinyBuddy")
        )
    }
}
