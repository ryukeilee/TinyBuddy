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
            URL(fileURLWithPath: "/Authorized/ProjectA"),
            URL(fileURLWithPath: "/Authorized/ProjectB")
        ])

        let roots = store.accessAuthorizedRoots()
        roots.forEach { $0.stopAccessing() }

        XCTAssertEqual(roots.map { $0.url.path }, ["/Authorized/ProjectA", "/Authorized/ProjectB"])
        XCTAssertEqual(stoppedPaths, ["/Authorized/ProjectA", "/Authorized/ProjectB"])
    }

    func testAccessAuthorizedRootsSkipsUnresolvedBookmarks() throws {
        let defaults = makeDefaults()
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                Data(url.standardizedFileURL.path.utf8)
            },
            scopedRootResolver: { bookmarkData in
                guard let path = String(data: bookmarkData, encoding: .utf8),
                      path != "/Authorized/StaleProject" else {
                    return nil
                }

                return ScopedGitScanRoot(url: URL(fileURLWithPath: path))
            }
        )

        try store.replaceAuthorizedRoots([
            URL(fileURLWithPath: "/Authorized/StaleProject"),
            URL(fileURLWithPath: "/Authorized/LiveProject")
        ])

        let roots = store.accessAuthorizedRoots()

        XCTAssertEqual(roots.map { $0.url.path }, ["/Authorized/LiveProject"])
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

    func testAccessAuthorizedRootsRemovesBroadResolvedBookmarksFromPersistence() {
        let defaults = makeDefaults()
        defaults.set(
            [Data("/Users".utf8), Data("/Authorized/Project".utf8)],
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

        XCTAssertEqual(roots.map { $0.url.path }, ["/Authorized/Project"])
        XCTAssertEqual(persistedPaths, ["/Authorized/Project"])
        XCTAssertEqual(stoppedPaths, ["/Users"])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitScanRootAuthorizationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
