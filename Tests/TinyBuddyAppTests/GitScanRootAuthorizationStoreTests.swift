import Foundation
import XCTest
@testable import TinyBuddy

final class GitScanRootAuthorizationStoreTests: XCTestCase {
    func testReplaceAuthorizedRootsPersistsUniqueStandardizedBookmarks() throws {
        let defaults = makeDefaults()
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { _ in nil }
        )

        try store.replaceAuthorizedRoots([
            URL(fileURLWithPath: "/Authorized/TinyBuddyProject"),
            URL(fileURLWithPath: "/Authorized/TinyBuddyProject/."),
            URL(fileURLWithPath: "/Authorized/AnotherProject")
        ])

        let bookmarkData = defaults.array(
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        ) as? [Data]
        let paths = bookmarkData?.compactMap { String(data: $0, encoding: .utf8) }

        XCTAssertEqual(paths, ["/Authorized/TinyBuddyProject", "/Authorized/AnotherProject"])
        XCTAssertTrue(store.hasAuthorizedRoots)
    }

    func testReplaceAuthorizedRootsSkipsBroadScanRoots() throws {
        let defaults = makeDefaults()
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { _ in nil }
        )

        try store.replaceAuthorizedRoots([
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/Users"),
            homeURL,
            URL(fileURLWithPath: "/Authorized/Project")
        ])

        let bookmarkData = defaults.array(
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        ) as? [Data]
        let paths = bookmarkData?.compactMap { String(data: $0, encoding: .utf8) }

        XCTAssertEqual(paths, ["/Authorized/Project"])
    }

    func testReplaceAuthorizedRootsSkipsSymlinkThatResolvesToHomeDirectory() throws {
        let defaults = makeDefaults()
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { _ in nil }
        )
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let symlinkURL = tempDirectory.appendingPathComponent("home-link", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
        )

        try store.replaceAuthorizedRoots([
            symlinkURL,
            URL(fileURLWithPath: "/Authorized/Project")
        ])

        let bookmarkData = defaults.array(
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        ) as? [Data]
        let paths = bookmarkData?.compactMap { String(data: $0, encoding: .utf8) }

        XCTAssertEqual(paths, ["/Authorized/Project"])
    }

    func testReplaceAuthorizedRootsSkipsRootsContainingLineBreaks() throws {
        let defaults = makeDefaults()
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { _ in nil }
        )

        try store.replaceAuthorizedRoots([
            URL(fileURLWithPath: "/Authorized/Project\nInjected"),
            URL(fileURLWithPath: "/Authorized/Project")
        ])

        let bookmarkData = defaults.array(
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        ) as? [Data]
        let paths = bookmarkData?.compactMap { String(data: $0, encoding: .utf8) }

        XCTAssertEqual(paths, ["/Authorized/Project"])
    }

    func testAccessAuthorizedRootsResolvesSavedBookmarksAndStopsAccess() throws {
        let defaults = makeDefaults()
        var stoppedPaths: [String] = []
        let rootA = try makeTemporaryDirectory(named: "ProjectA")
        let rootB = try makeTemporaryDirectory(named: "ProjectB")
        defer {
            try? FileManager.default.removeItem(at: rootA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: rootB.deletingLastPathComponent())
        }
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { bookmarkData in
                guard let path = String(data: bookmarkData, encoding: .utf8) else {
                    return nil
                }

                return ScopedGitScanRoot(url: URL(fileURLWithPath: path)) {
                    stoppedPaths.append(path)
                }
            }
        )

        try store.replaceAuthorizedRoots([
            rootA,
            rootB
        ])

        let roots = store.accessAuthorizedRoots()
        roots.forEach { $0.stopAccessing() }

        XCTAssertEqual(roots.map(\.url), [rootA, rootB])
        XCTAssertEqual(stoppedPaths, [rootA.path, rootB.path])
    }

    func testAccessAuthorizedRootsSkipsUnresolvedBookmarks() throws {
        let defaults = makeDefaults()
        let staleRoot = try makeTemporaryDirectory(named: "StaleProject")
        let liveRoot = try makeTemporaryDirectory(named: "LiveProject")
        defer {
            try? FileManager.default.removeItem(at: staleRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: liveRoot.deletingLastPathComponent())
        }
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { bookmarkData in
                guard let path = String(data: bookmarkData, encoding: .utf8),
                      path != staleRoot.path else {
                    return nil
                }

                return ScopedGitScanRoot(url: URL(fileURLWithPath: path))
            }
        )

        try store.replaceAuthorizedRoots([
            staleRoot,
            liveRoot
        ])

        let roots = store.accessAuthorizedRoots()

        XCTAssertEqual(roots.map(\.url), [liveRoot])
    }

    func testAccessAuthorizedRootsRemovesUnresolvedBookmarksFromPersistence() throws {
        let defaults = makeDefaults()
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { _ in nil }
        )

        try store.replaceAuthorizedRoots([
            URL(fileURLWithPath: "/Authorized/StaleProject")
        ])

        let roots = store.accessAuthorizedRoots()

        XCTAssertTrue(roots.isEmpty)
        XCTAssertFalse(store.hasAuthorizedRoots)
    }

    func testAccessAuthorizedRootResultMarksMissingSavedDirectoryAsInvalidAuthorization() throws {
        let defaults = makeDefaults()
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { bookmarkData in
                guard let path = String(data: bookmarkData, encoding: .utf8) else {
                    return nil
                }

                return ScopedGitScanRoot(url: URL(fileURLWithPath: path))
            }
        )
        let deletedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: deletedDirectory, withIntermediateDirectories: true)
        try store.replaceAuthorizedRoots([deletedDirectory])
        try FileManager.default.removeItem(at: deletedDirectory)

        let accessResult = store.accessAuthorizedRootResult()

        XCTAssertTrue(accessResult.roots.isEmpty)
        XCTAssertEqual(accessResult.issue, .authorizationInvalid)
        XCTAssertFalse(store.hasAuthorizedRoots)
    }

    func testAccessAuthorizedRootResultMarksMissingAuthorizationWhenNothingSaved() {
        let store = GitScanRootAuthorizationStore(
            userDefaults: makeDefaults(),
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { _ in nil }
        )

        let accessResult = store.accessAuthorizedRootResult()

        XCTAssertTrue(accessResult.roots.isEmpty)
        XCTAssertEqual(accessResult.issue, .authorizationRequired)
    }

    func testAccessAuthorizedRootsRemovesBroadResolvedBookmarksFromPersistence() {
        let defaults = makeDefaults()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = temporaryRoot.appendingPathComponent("Project", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        defaults.set(
            [Data("/Users".utf8), Data(projectURL.path.utf8)],
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        )
        var stoppedPaths: [String] = []
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { bookmarkData in
                guard let path = String(data: bookmarkData, encoding: .utf8) else {
                    return nil
                }

                return ScopedGitScanRoot(url: URL(fileURLWithPath: path)) {
                    stoppedPaths.append(path)
                }
            }
        )

        let roots = store.accessAuthorizedRoots()
        let persistedBookmarkData = defaults.array(
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        ) as? [Data]
        let persistedPaths = persistedBookmarkData?.compactMap { String(data: $0, encoding: .utf8) }

        XCTAssertEqual(roots.map(\.url), [projectURL])
        XCTAssertEqual(persistedPaths, [projectURL.path])
        XCTAssertEqual(stoppedPaths, ["/Users"])
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitScanRootAuthorizationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
