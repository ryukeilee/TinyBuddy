import AppKit
import Foundation
import XCTest
@testable import TinyBuddy

@MainActor
final class GitScanRootAuthorizationControllerTests: XCTestCase {
    func testRequestAuthorizationIfNeededDoesNotPresentPanelWhenAuthorizedRootResolves() throws {
        let defaults = makeDefaults()
        var stopAccessCount = 0
        let rootURL = try makeTemporaryDirectory(named: "TinyBuddyProject")
        defer {
            try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
        }
        let store = makeStore(
            userDefaults: defaults,
            resolvedPaths: [rootURL.standardizedFileURL.path],
            stopAccessAction: {
                stopAccessCount += 1
            }
        )
        try store.replaceAuthorizedRoots([rootURL])

        var panelProviderCallCount = 0
        let controller = GitScanRootAuthorizationController(store: store) {
            panelProviderCallCount += 1
            return PanelSpyOpenPanel(modalResponse: .cancel)
        }

        controller.requestAuthorizationIfNeeded()

        XCTAssertEqual(panelProviderCallCount, 0)
        XCTAssertEqual(stopAccessCount, 1)
    }

    func testRequestAuthorizationIfNeededPresentsPanelWhenNoAuthorizedRootResolves() throws {
        let defaults = makeDefaults()
        let staleRootURL = URL(fileURLWithPath: "/Authorized/StaleProject")
        let store = makeStore(userDefaults: defaults, resolvedPaths: [])
        try store.replaceAuthorizedRoots([staleRootURL])

        var panelProviderCallCount = 0
        let panel = PanelSpyOpenPanel(modalResponse: .cancel)
        let controller = GitScanRootAuthorizationController(store: store) {
            panelProviderCallCount += 1
            return panel
        }

        controller.requestAuthorizationIfNeeded()

        XCTAssertEqual(panelProviderCallCount, 1)
        XCTAssertEqual(panel.runModalCallCount, 1)
    }

    private func makeStore(
        userDefaults: UserDefaults,
        resolvedPaths: Set<String>,
        stopAccessAction: @escaping () -> Void = {}
    ) -> GitScanRootAuthorizationStore {
        GitScanRootAuthorizationStore(
            userDefaults: userDefaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { bookmarkData -> ScopedGitScanRoot? in
                guard let path = String(data: bookmarkData, encoding: .utf8),
                      resolvedPaths.contains(path) else {
                    return nil
                }

                return ScopedGitScanRoot(url: URL(fileURLWithPath: path), stopAccessingAction: stopAccessAction)
            }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitScanRootAuthorizationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class PanelSpyOpenPanel: NSOpenPanel {
    let modalResponse: NSApplication.ModalResponse
    private(set) var runModalCallCount = 0

    init(modalResponse: NSApplication.ModalResponse) {
        self.modalResponse = modalResponse
        super.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func runModal() -> NSApplication.ModalResponse {
        runModalCallCount += 1
        return modalResponse
    }
}
