import Foundation
import XCTest
@testable import TinyBuddy

final class GitScanRootAuthorizationStoreTests: XCTestCase {
    func testScopedRootStopsExactlyOnceAcrossExplicitStopAndDeinit() {
        var stopCount = 0
        weak var weakRoot: ScopedGitScanRoot?

        do {
            let root = ScopedGitScanRoot(url: URL(fileURLWithPath: "/Authorized/Project")) {
                stopCount += 1
            }
            weakRoot = root
            root.stopAccessing()
            root.stopAccessing()
            XCTAssertEqual(stopCount, 1)
        }

        XCTAssertNil(weakRoot)
        XCTAssertEqual(stopCount, 1)
    }

    func testScopedRootDeinitStopsWhenCallerReturnsEarly() {
        var stopCount = 0

        do {
            _ = ScopedGitScanRoot(url: URL(fileURLWithPath: "/Authorized/Project")) {
                stopCount += 1
            }
        }

        XCTAssertEqual(stopCount, 1)
    }

    func testRecordsKeyMatchesTheCrossProcessReleaseHelperContract() {
        XCTAssertEqual(
            GitScanRootAuthorizationStore.Constants.authorizationRecordsKey,
            "tinybuddy.gitScanRoots.records.v2"
        )
    }

    private enum TestError: Error {
        case corruptBookmark
        case refreshFailed
    }

    func testReplaceAuthorizedRootsPersistsAtomicRecordsAndRejectsBroadRoots() throws {
        let defaults = makeDefaults()
        let store = makePathStore(defaults: defaults)

        XCTAssertTrue(try store.replaceAuthorizedRoots([
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/Users"),
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Authorized/Project\nInjected"),
            URL(fileURLWithPath: "/Authorized/Project"),
            URL(fileURLWithPath: "/Authorized/Project/.")
        ]))

        let records = persistedRecords(defaults)
        XCTAssertEqual(records.count, 1)
        XCTAssertNotNil(records[0]["id"] as? String)
        XCTAssertEqual(records[0]["bookmarkData"] as? Data, Data("/Authorized/Project".utf8))
        XCTAssertEqual(records[0]["displayName"] as? String, "Project")
        XCTAssertEqual(records[0]["lastKnownPath"] as? String, "/Authorized/Project")
        XCTAssertNil(defaults.object(forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey))
    }

    func testLegacyBookmarksMigrateWithoutLosingValidEntriesWhenMixedWithMalformedValues() throws {
        let defaults = makeDefaults()
        let liveRoot = try makeTemporaryDirectory(named: "LiveProject")
        defer { try? FileManager.default.removeItem(at: liveRoot.deletingLastPathComponent()) }
        defaults.set(
            [Data(liveRoot.path.utf8), "not bookmark data", Data("corrupt".utf8)] as [Any],
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        )
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                guard let path = String(data: data, encoding: .utf8), path == liveRoot.path else {
                    throw TestError.corruptBookmark
                }
                return resolution(path: path)
            },
            rootUsabilityChecker: { _ in nil }
        )

        let statuses = store.authorizationStatuses()

        XCTAssertEqual(statuses.count, 3)
        XCTAssertEqual(statuses.filter { $0.state == .available }.count, 1)
        XCTAssertEqual(
            statuses.filter { $0.state == .unavailable(.bookmarkCorruptOrRevoked) }.count,
            2
        )
        XCTAssertEqual(statuses.first?.lastKnownPath, liveRoot.path)
        XCTAssertEqual(persistedRecords(defaults).count, 3)
        XCTAssertNil(defaults.object(forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey))
    }

    func testReplacingAfterLegacyMigrationPerformsFullReplacement() throws {
        let defaults = makeDefaults()
        defaults.set(
            [Data("/Authorized/Old".utf8)],
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        )
        let store = makePathStore(defaults: defaults)

        XCTAssertTrue(try store.replaceAuthorizedRoots([URL(fileURLWithPath: "/Authorized/New")]))

        let records = persistedRecords(defaults)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["lastKnownPath"] as? String, "/Authorized/New")
    }

    func testAllCorruptBookmarksRemainVisibleAndCanBeRemovedOrReauthorized() throws {
        let defaults = makeDefaults()
        defaults.set(
            [Data("corrupt".utf8)],
            forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey
        )
        let replacementRoot = try makeTemporaryDirectory(named: "Replacement")
        defer { try? FileManager.default.removeItem(at: replacementRoot.deletingLastPathComponent()) }
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                guard let path = String(data: data, encoding: .utf8), path == replacementRoot.path else {
                    throw TestError.corruptBookmark
                }
                return resolution(path: path)
            },
            rootUsabilityChecker: { _ in nil }
        )

        let invalid = try XCTUnwrap(store.authorizationStatuses().first)
        XCTAssertEqual(invalid.state, .unavailable(.bookmarkCorruptOrRevoked))
        XCTAssertTrue(try store.replaceAuthorizedRoot(id: invalid.id, with: replacementRoot))

        let repaired = try XCTUnwrap(store.authorizationStatuses().first)
        XCTAssertEqual(repaired.id, invalid.id)
        XCTAssertEqual(repaired.state, .available)
        XCTAssertEqual(repaired.lastKnownPath, replacementRoot.path)
        XCTAssertTrue(store.removeAuthorizedRoot(id: repaired.id))
        XCTAssertFalse(store.hasAuthorizedRoots)
    }

    func testStaleBookmarkRefreshesInPlaceAndContinuesUsingResolvedRoot() throws {
        let defaults = makeDefaults()
        let oldRoot = URL(fileURLWithPath: "/Authorized/OldLocation")
        let movedRoot = URL(fileURLWithPath: "/Authorized/NewLocation")
        let oldBookmark = Data("old bookmark".utf8)
        let refreshedBookmark = Data("refreshed bookmark".utf8)
        var creatorCalls: [URL] = []
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                creatorCalls.append(url)
                return url.path == oldRoot.path ? oldBookmark : refreshedBookmark
            },
            scopedRootResolver: { data in
                if data == oldBookmark {
                    return resolution(path: movedRoot.path, isStale: true)
                }
                return resolution(path: movedRoot.path)
            },
            rootUsabilityChecker: { _ in nil }
        )
        try store.replaceAuthorizedRoots([oldRoot])
        let originalID = try XCTUnwrap(persistedRecords(defaults).first?["id"] as? String)

        let result = store.accessAuthorizedRootResult()

        XCTAssertEqual(result.roots.map(\.url.path), [movedRoot.path])
        XCTAssertEqual(result.authorizations.first?.id, originalID)
        XCTAssertEqual(result.authorizations.first?.state, .available)
        XCTAssertEqual(result.authorizations.first?.lastKnownPath, movedRoot.path)
        XCTAssertEqual(persistedRecords(defaults).first?["bookmarkData"] as? Data, refreshedBookmark)
        XCTAssertEqual(creatorCalls, [oldRoot, movedRoot])
        result.roots.forEach { $0.stopAccessing() }
    }

    func testFoundationBookmarkFollowsRenamedDirectoryAndUpdatesStoredPath() throws {
        let defaults = makeDefaults()
        let originalRoot = try makeTemporaryDirectory(named: "OriginalProject")
        let parent = originalRoot.deletingLastPathComponent()
        let movedRoot = parent.appendingPathComponent("RenamedProject", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            },
            scopedRootResolver: { data in
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: data,
                    options: [.withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return ResolvedScopedGitScanRoot(
                    root: ScopedGitScanRoot(url: resolvedURL),
                    bookmarkDataIsStale: isStale
                )
            },
            rootUsabilityChecker: { url in
                var isDirectory = ObjCBool(false)
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue ? nil : .directoryUnavailable
            }
        )
        try store.replaceAuthorizedRoots([originalRoot])
        try FileManager.default.moveItem(at: originalRoot, to: movedRoot)

        let result = store.accessAuthorizedRootResult()

        XCTAssertEqual(result.roots.map(\.url.standardizedFileURL.path), [movedRoot.path])
        XCTAssertEqual(result.authorizations.first?.lastKnownPath, movedRoot.path)
        XCTAssertEqual(result.authorizations.first?.displayName, "RenamedProject")
        XCTAssertEqual(result.authorizations.first?.state, .available)
        result.roots.forEach { $0.stopAccessing() }
    }

    func testStaleBookmarkRefreshFailurePausesOnlyThatAuthorization() throws {
        let defaults = makeDefaults()
        let staleRoot = URL(fileURLWithPath: "/Authorized/Stale")
        let liveRoot = URL(fileURLWithPath: "/Authorized/Live")
        var failRefresh = false
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { url in
                if failRefresh, url.path == staleRoot.path {
                    throw TestError.refreshFailed
                }
                return Data(url.path.utf8)
            },
            scopedRootResolver: { data in
                let path = try XCTUnwrap(String(data: data, encoding: .utf8))
                return resolution(path: path, isStale: path == staleRoot.path)
            },
            rootUsabilityChecker: { _ in nil }
        )
        try store.replaceAuthorizedRoots([staleRoot, liveRoot])
        failRefresh = true

        let result = store.accessAuthorizedRootResult()

        XCTAssertEqual(result.roots.map(\.url.path), [liveRoot.path])
        XCTAssertEqual(result.authorizations.map(\.state), [
            .unavailable(.bookmarkRefreshFailed),
            .available
        ])
        XCTAssertEqual(result.issue, .authorizationInvalid)
        result.roots.forEach { $0.stopAccessing() }
    }

    func testDirectoryUnavailableCanRecoverWithoutReauthorization() throws {
        let defaults = makeDefaults()
        let root = URL(fileURLWithPath: "/Authorized/Recovering")
        var isAvailable = false
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                resolution(path: try XCTUnwrap(String(data: data, encoding: .utf8)))
            },
            rootUsabilityChecker: { _ in isAvailable ? nil : .directoryUnavailable }
        )
        try store.replaceAuthorizedRoots([root])

        XCTAssertEqual(store.authorizationStatuses().first?.state, .unavailable(.directoryUnavailable))
        isAvailable = true
        XCTAssertEqual(store.authorizationStatuses().first?.state, .available)
    }

    func testPermissionDeniedRootRecoversWhenReadAccessReturns() throws {
        let defaults = makeDefaults()
        let root = URL(fileURLWithPath: "/Authorized/PermissionRecovery")
        var isReadable = false
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                resolution(path: try XCTUnwrap(String(data: data, encoding: .utf8)))
            },
            rootUsabilityChecker: { _ in isReadable ? nil : .permissionDenied }
        )
        try store.replaceAuthorizedRoots([root])

        let deniedResult = store.accessAuthorizedRootResult()
        XCTAssertTrue(deniedResult.roots.isEmpty)
        XCTAssertEqual(deniedResult.authorizations.first?.state, .unavailable(.permissionDenied))
        XCTAssertEqual(deniedResult.issue, .authorizationInvalid)

        isReadable = true
        let restoredResult = store.accessAuthorizedRootResult()
        XCTAssertEqual(restoredResult.roots.map(\.url.path), [root.path])
        XCTAssertEqual(restoredResult.authorizations.first?.state, .available)
        XCTAssertNil(restoredResult.issue)
        restoredResult.roots.forEach { $0.stopAccessing() }
    }

    func testPartialValidAndInvalidBookmarksPublishOnlyValidRoot() throws {
        let defaults = makeDefaults()
        let invalidRoot = URL(fileURLWithPath: "/Authorized/Invalid")
        let liveRoot = URL(fileURLWithPath: "/Authorized/Live")
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                let path = try XCTUnwrap(String(data: data, encoding: .utf8))
                if path == invalidRoot.path {
                    throw TestError.corruptBookmark
                }
                return resolution(path: path)
            },
            rootUsabilityChecker: { _ in nil }
        )
        try store.replaceAuthorizedRoots([invalidRoot, liveRoot])

        let result = store.accessAuthorizedRootResult()

        XCTAssertEqual(result.roots.map(\.url.path), [liveRoot.path])
        XCTAssertEqual(result.authorizations.map(\.state), [
            .unavailable(.bookmarkCorruptOrRevoked),
            .available
        ])
        XCTAssertEqual(result.issue, .authorizationInvalid)
        result.roots.forEach { $0.stopAccessing() }
    }

    func testSingleRootReauthorizationPreservesOtherAuthorizationsAndID() throws {
        let defaults = makeDefaults()
        let first = URL(fileURLWithPath: "/Authorized/First")
        let second = URL(fileURLWithPath: "/Authorized/Second")
        let replacement = URL(fileURLWithPath: "/Authorized/Replacement")
        let store = makePathStore(defaults: defaults)
        try store.replaceAuthorizedRoots([first, second])
        let originalRecords = persistedRecords(defaults)
        let firstID = try XCTUnwrap(originalRecords[0]["id"] as? String)
        let secondID = try XCTUnwrap(originalRecords[1]["id"] as? String)

        XCTAssertTrue(try store.replaceAuthorizedRoot(id: firstID, with: replacement))

        let records = persistedRecords(defaults)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["id"] as? String, firstID)
        XCTAssertEqual(records[0]["lastKnownPath"] as? String, replacement.path)
        XCTAssertEqual(records[1]["id"] as? String, secondID)
        XCTAssertEqual(records[1]["lastKnownPath"] as? String, second.path)
    }

    func testAddMergesAndRemoveOperationsReportWhetherStateChanged() throws {
        let defaults = makeDefaults()
        let first = URL(fileURLWithPath: "/Authorized/First")
        let second = URL(fileURLWithPath: "/Authorized/Second")
        let store = makePathStore(defaults: defaults)
        try store.replaceAuthorizedRoots([first])
        let firstID = try XCTUnwrap(persistedRecords(defaults).first?["id"] as? String)

        XCTAssertTrue(try store.addAuthorizedRoots([first, second]))
        XCTAssertEqual(persistedRecords(defaults).count, 2)
        XCTAssertFalse(try store.addAuthorizedRoots([second]))
        XCTAssertTrue(store.removeAuthorizedRoot(id: firstID))
        XCTAssertFalse(store.removeAuthorizedRoot(id: firstID))
        XCTAssertTrue(store.removeAllAuthorizedRoots())
        XCTAssertFalse(store.removeAllAuthorizedRoots())
    }

    func testPersistedRecordsAreImmediatelyVisibleToNewStoreInstance() throws {
        let defaults = makeDefaults()
        let root = URL(fileURLWithPath: "/Authorized/Persisted")
        let firstStore = makePathStore(defaults: defaults)
        try firstStore.replaceAuthorizedRoots([root])
        let firstStatus = try XCTUnwrap(firstStore.authorizationStatuses().first)

        let restoredStore = makePathStore(defaults: defaults)
        let restoredStatus = try XCTUnwrap(restoredStore.authorizationStatuses().first)

        XCTAssertEqual(restoredStatus.id, firstStatus.id)
        XCTAssertEqual(restoredStatus.lastKnownPath, root.path)
        XCTAssertEqual(restoredStatus.state, .available)
    }

    func testResolvedBroadScopeIsRejectedAndStopped() throws {
        let defaults = makeDefaults()
        var stopCount = 0
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { _ in Data("bookmark".utf8) },
            scopedRootResolver: { _ in
                ResolvedScopedGitScanRoot(
                    root: ScopedGitScanRoot(url: URL(fileURLWithPath: "/Users")) { stopCount += 1 },
                    bookmarkDataIsStale: false
                )
            },
            rootUsabilityChecker: { url in
                GitScanRootAuthorizationStore.isAllowedScanRoot(url) ? nil : .scopeTooBroad
            }
        )
        try store.replaceAuthorizedRoots([URL(fileURLWithPath: "/Authorized/Project")])

        let result = store.accessAuthorizedRootResult()

        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertEqual(result.authorizations.first?.state, .unavailable(.scopeTooBroad))
        XCTAssertEqual(stopCount, 1)
    }

    func testAuthorizationStatusesBalancesSuccessfulScopedAccess() throws {
        let defaults = makeDefaults()
        let root = URL(fileURLWithPath: "/Authorized/Balanced")
        var stopCount = 0
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                let path = try XCTUnwrap(String(data: data, encoding: .utf8))
                return ResolvedScopedGitScanRoot(
                    root: ScopedGitScanRoot(url: URL(fileURLWithPath: path)) {
                        stopCount += 1
                    },
                    bookmarkDataIsStale: false
                )
            },
            rootUsabilityChecker: { _ in nil }
        )
        try store.replaceAuthorizedRoots([root])

        XCTAssertEqual(store.authorizationStatuses().first?.state, .available)
        XCTAssertEqual(stopCount, 1)
    }

    private func makePathStore(defaults: UserDefaults) -> GitScanRootAuthorizationStore {
        GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                guard let path = String(data: data, encoding: .utf8), !path.isEmpty else {
                    throw TestError.corruptBookmark
                }
                return resolution(path: path)
            },
            rootUsabilityChecker: { _ in nil }
        )
    }

    private func persistedRecords(_ defaults: UserDefaults) -> [[String: Any]] {
        defaults.array(forKey: GitScanRootAuthorizationStore.Constants.authorizationRecordsKey)
            as? [[String: Any]] ?? []
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

private func resolution(path: String, isStale: Bool = false) -> ResolvedScopedGitScanRoot {
    ResolvedScopedGitScanRoot(
        root: ScopedGitScanRoot(url: URL(fileURLWithPath: path)),
        bookmarkDataIsStale: isStale
    )
}
