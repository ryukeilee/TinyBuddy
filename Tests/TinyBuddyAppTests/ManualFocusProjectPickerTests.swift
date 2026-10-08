import SwiftUI
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

final class FocusSessionReviewProjectSelectionTests: XCTestCase {
    func testReviewViewWiresRegisteredPickerAndExplicitCustomFallback() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let reviewView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/TinyBuddy/FocusSessionReviewView.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/TinyBuddy/TinyBuddyApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(reviewView.contains("Picker(\"项目归属\", selection: $projectSelection)"))
        XCTAssertTrue(reviewView.contains("Text(\"自定义项目兜底\")"))
        XCTAssertTrue(reviewView.contains("TextField(\"项目标识\", text: $projectKey)"))
        XCTAssertTrue(reviewView.contains("TextField(\"项目名称\", text: $projectName)"))
        XCTAssertTrue(app.contains("registeredProjectsProvider: { appDelegate.activeManualFocusProjects }"))
    }

    func testReviewProjectOptionsOnlyIncludeUsableActiveProjects() {
        let active = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-active"),
            kind: .gitRepository,
            displayName: "TinyBuddy"
        )
        let temporarilyUnavailable = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-unavailable"),
            kind: .gitRepository,
            displayName: "Unavailable",
            state: .temporarilyUnavailable
        )
        let archived = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-archived"),
            kind: .manual,
            displayName: "Archived",
            state: .archived
        )
        let removed = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-removed"),
            kind: .application,
            displayName: "Removed",
            state: .removed
        )
        let malformed = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "  "),
            kind: .manual,
            displayName: "   "
        )

        XCTAssertEqual(
            FocusSessionReviewProjectResolver.selectableProjects([
                temporarilyUnavailable, removed, malformed, active, archived
            ]),
            [active]
        )
    }

    func testRegisteredReviewSelectionSavesCanonicalStableIdentity() throws {
        let registered = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-tinybuddy"),
            kind: .gitRepository,
            displayName: "TinyBuddy Renamed",
            aliases: ["legacy/repository-key"]
        )
        let oldSessionProject = FocusProjectContext(
            key: "legacy/repository-key",
            displayName: "Old Name"
        )

        let selection = FocusSessionReviewProjectResolver.selection(
            for: oldSessionProject,
            registeredProjects: [registered]
        )
        let resolved = try XCTUnwrap(FocusSessionReviewProjectResolver.context(
            for: selection,
            registeredProjects: [registered],
            customProjectKey: "ignored.custom.key",
            customDisplayName: "Ignored Custom Name"
        ))

        XCTAssertEqual(selection, .registered(registered.id))
        XCTAssertEqual(
            resolved,
            FocusProjectContext(key: "project-tinybuddy", displayName: "TinyBuddy Renamed")
        )
    }

    func testReviewSelectionRejectsUnavailableAndAmbiguousRegisteredProjects() throws {
        let unavailable = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-offline"),
            kind: .gitRepository,
            displayName: "Offline",
            state: .temporarilyUnavailable
        )
        XCTAssertNil(FocusSessionReviewProjectResolver.context(
            for: .registered(unavailable.id),
            registeredProjects: [unavailable],
            customProjectKey: "custom.key",
            customDisplayName: "Custom"
        ))

        let first = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-one"),
            kind: .gitRepository,
            displayName: "First",
            aliases: ["shared/legacy-key"]
        )
        let second = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "project-two"),
            kind: .gitRepository,
            displayName: "Second",
            aliases: ["shared/legacy-key"]
        )

        XCTAssertEqual(
            FocusSessionReviewProjectResolver.selection(
                for: FocusProjectContext(key: "shared/legacy-key", displayName: "Legacy"),
                registeredProjects: [first, second]
            ),
            .custom
        )
    }

    func testCustomReviewProjectInputRemainsAvailableWithoutRewritingItsIdentity() throws {
        let resolved = try XCTUnwrap(FocusSessionReviewProjectResolver.context(
            for: .custom,
            registeredProjects: [],
            customProjectKey: "manual.custom-v2.Work Alpha",
            customDisplayName: "Work Alpha"
        ))

        XCTAssertEqual(
            resolved,
            FocusProjectContext(key: "manual.custom-v2.Work Alpha", displayName: "Work Alpha")
        )
    }
}

final class ManualFocusProjectFilterTests: XCTestCase {
    private func project(
        _ id: String,
        _ name: String,
        kind: TinyBuddyProjectKind = .gitRepository
    ) -> TinyBuddyProject {
        TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: id),
            kind: kind,
            displayName: name
        )
    }

    private var sampleProjects: [TinyBuddyProject] {
        [
            project("p-alpha", "Alpha Service"),
            project("p-beta", "Beta Tool", kind: .application),
            project("p-cafe", "Café Notes"),
            project("p-gamma", "Gamma Lab"),
            project("p-delta", "Delta API"),
            project("p-epsilon", "Epsilon Shell")
        ]
    }

    func testSearchFieldOnlyAppearsOnceTheProjectListIsLongEnough() {
        let threshold = ManualFocusProjectFilter.searchFieldMinimumProjectCount

        XCTAssertFalse(ManualFocusProjectFilter.shouldShowSearchField(registeredProjectCount: 0))
        XCTAssertFalse(ManualFocusProjectFilter.shouldShowSearchField(registeredProjectCount: threshold - 1))
        XCTAssertTrue(ManualFocusProjectFilter.shouldShowSearchField(registeredProjectCount: threshold))
        XCTAssertTrue(ManualFocusProjectFilter.shouldShowSearchField(registeredProjectCount: 40))
    }

    func testEmptyOrWhitespaceQueryKeepsEveryProjectInRegistryOrder() {
        let projects = sampleProjects

        XCTAssertEqual(ManualFocusProjectFilter.projects(projects, query: ""), projects)
        XCTAssertEqual(ManualFocusProjectFilter.projects(projects, query: "   \n\t "), projects)
        XCTAssertFalse(ManualFocusProjectFilter.isSearching(" \t "))
        XCTAssertTrue(ManualFocusProjectFilter.isSearching("a"))
    }

    func testQueryMatchesPartialDisplayNameCaseInsensitively() {
        XCTAssertEqual(
            ManualFocusProjectFilter.projects(sampleProjects, query: "  alpha ").map(\.id.rawValue),
            ["p-alpha"]
        )
        XCTAssertEqual(
            ManualFocusProjectFilter.projects(sampleProjects, query: "TA").map(\.id.rawValue),
            ["p-beta", "p-delta"]
        )
    }

    func testQueryIgnoresDiacriticsInEitherDirection() {
        XCTAssertEqual(
            ManualFocusProjectFilter.projects(sampleProjects, query: "cafe").map(\.id.rawValue),
            ["p-cafe"]
        )
        XCTAssertEqual(
            ManualFocusProjectFilter.projects(sampleProjects, query: "CAFÉ Notes").map(\.id.rawValue),
            ["p-cafe"]
        )
    }

    func testNonMatchingQueryReturnsNoProjectsAndNoMatches() {
        XCTAssertTrue(ManualFocusProjectFilter.projects(sampleProjects, query: "zzz").isEmpty)
        XCTAssertFalse(ManualFocusProjectFilter.matches("Alpha Service", query: "zzz"))
    }

    func testFilteredRowsRetainStableRegistryIdentityWithoutDuplication() {
        let projects = sampleProjects
        let filtered = ManualFocusProjectFilter.projects(projects, query: "lab")

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, TinyBuddyProjectID(rawValue: "p-gamma"))
        XCTAssertEqual(filtered.first, projects.first { $0.id.rawValue == "p-gamma" })
        XCTAssertEqual(
            Set(filtered.map(\.id.rawValue)).count,
            filtered.count,
            "filtering must not duplicate rows"
        )
    }

    func testRecentProjectRecommendationFollowsTheSameNameFilter() {
        XCTAssertTrue(ManualFocusProjectFilter.matches("TinyBuddy", query: ""))
        XCTAssertTrue(ManualFocusProjectFilter.matches("TinyBuddy", query: "tiny"))
        XCTAssertFalse(ManualFocusProjectFilter.matches("TinyBuddy", query: "alpha"))
    }

    func testPickerWiresSearchFieldAndClearAction() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let picker = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/TinyBuddy/ManualFocusProjectPicker.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(picker.contains("TextField(\"搜索项目名称\", text: $searchQuery)"))
        XCTAssertTrue(picker.contains("searchQuery = \"\""))
        XCTAssertTrue(picker.contains(".accessibilityLabel(\"清除搜索\")"))
        XCTAssertTrue(picker.contains("ForEach(visibleProjects)"))
    }
}

@MainActor
final class ManualFocusProjectPickerRenderingTests: XCTestCase {
    private func render(projectCount: Int) throws -> CGImage {
        let projects = (1...max(projectCount, 1)).map { index in
            TinyBuddyProject(
                id: TinyBuddyProjectID(rawValue: "p-\(index)"),
                kind: .gitRepository,
                displayName: "Project \(index)"
            )
        }
        let picker = ManualFocusProjectPicker(
            recentProjectName: "Project 1",
            registeredProjects: projectCount == 0 ? [] : projects,
            onSubmit: { _ in }
        )
        let renderer = ImageRenderer(content: picker)
        renderer.proposedSize = ProposedViewSize(width: 260, height: nil)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    func testPickerWithSearchFieldRendersANonUniformImageTallerThanTheCompactLayout() throws {
        let compact = try render(projectCount: 2)
        let searchable = try render(projectCount: 6)

        XCTAssertEqual(compact.width, 260)
        XCTAssertEqual(searchable.width, 260)
        XCTAssertGreaterThan(
            searchable.height,
            compact.height,
            "the search field and extra project rows must add visible height"
        )

        let imageData = try XCTUnwrap(searchable.dataProvider?.data)
        let byteCount = CFDataGetLength(imageData)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(imageData))
        XCTAssertGreaterThan(byteCount, 0)
        XCTAssertTrue(
            (1..<byteCount).contains { bytes[$0] != bytes[0] },
            "the searchable picker rendered a uniform image"
        )
    }
}
