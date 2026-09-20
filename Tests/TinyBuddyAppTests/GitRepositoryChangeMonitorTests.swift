import Foundation
import XCTest
@testable import TinyBuddy

final class GitRepositoryChangeMonitorTests: XCTestCase {
    func testStartAndStopAreIdempotentAndReleaseScopesOnce() {
        let state = State()
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)

        XCTAssertTrue(monitor.start())
        XCTAssertTrue(monitor.start())
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(state.rootAccessCount, 1)
        XCTAssertEqual(stream.startCount, 1)

        monitor.stop()
        monitor.stop()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertEqual(stream.invalidateCount, 1)
        XCTAssertEqual(state.rootStopCount, 1)
    }

    func testFactoryFailureReleasesScopesWithoutStarting() {
        let state = State()
        let monitor = GitRepositoryChangeMonitor(
            authorizedRootsProvider: { state.makeAccessResult() },
            changeHandler: { _ in state.changeCount += 1 },
            eventStreamFactory: { _, _ in nil }
        )

        XCTAssertFalse(monitor.start())
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(state.rootAccessCount, 1)
        XCTAssertEqual(state.rootStopCount, 1)
    }

    func testStartFailureInvalidatesStreamAndReleasesScopes() {
        let state = State()
        let stream = FakeEventStream(startResult: false)
        let monitor = makeMonitor(state: state, stream: stream)

        XCTAssertFalse(monitor.start())
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(stream.startCount, 1)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertEqual(stream.invalidateCount, 1)
        XCTAssertEqual(state.rootStopCount, 1)
    }

    func testDeinitStopsStreamAndReleasesScopesOnce() {
        let state = State()
        let stream = FakeEventStream()
        weak var weakMonitor: GitRepositoryChangeMonitor?

        do {
            let monitor = makeMonitor(state: state, stream: stream)
            XCTAssertTrue(monitor.start())
            weakMonitor = monitor
        }

        XCTAssertNil(weakMonitor)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertEqual(stream.invalidateCount, 1)
        XCTAssertEqual(state.rootStopCount, 1)
    }

    func testRelevantEventBatchCallsHandlerOnceAndIgnoresUnrelatedPaths() {
        let state = State()
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)
        XCTAssertTrue(monitor.start())

        stream.emit([
            "/Authorized/Project/README.md",
            "/Authorized/Project/.git/config",
            "/Authorized/Project/.git/logs/HEAD",
            "/Authorized/Project/.git/refs/heads/main",
            "/Authorized/Project/.git/index.lock"
        ])

        XCTAssertEqual(state.changeCount, 1)
        XCTAssertTrue(state.lastChangeRequiredDiscoveryRescan)
        XCTAssertEqual(state.lastAffectedRepositoryPaths, ["/Authorized/Project"])

        stream.emit([
            "/Authorized/Project/Sources/App.swift",
            "/Authorized/Project/.git/config"
        ])
        XCTAssertEqual(state.changeCount, 2)
        monitor.stop()
    }

    func testConsecutiveRelevantBatchesEachTriggerHandler() {
        let state = State()
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)
        XCTAssertTrue(monitor.start())

        stream.emit(["/Authorized/Project/.git/logs/HEAD"])
        stream.emit(["/Authorized/Project/.git/refs/heads/main"])
        stream.emit(["/Authorized/Project/.git/index"])

        XCTAssertEqual(state.changeCount, 3)
        XCTAssertFalse(state.lastChangeRequiredDiscoveryRescan)
        monitor.stop()
    }

    func testStopMarksMonitorAsStoppedAndReleasesStreamResources() {
        let state = State()
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)
        XCTAssertTrue(monitor.start())

        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertEqual(stream.invalidateCount, 1)
        XCTAssertEqual(state.rootStopCount, 1)
    }

    func testEmitWithOnlyRelevantGitMetadataTriggersHandler() {
        let state = State()
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)
        XCTAssertTrue(monitor.start())

        stream.emit(["/Authorized/Project/.git/logs/refs/heads/feature"])
        XCTAssertEqual(state.changeCount, 1)
        monitor.stop()
    }

    func testEmitWithoutGitDirectoryDoesNotTriggerHandler() {
        let state = State()
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)
        XCTAssertTrue(monitor.start())

        stream.emit(["/Authorized/Project/Sources/App.swift"])
        stream.emit(["/Authorized/Project/Tests/Test.swift"])
        stream.emit(["/Authorized/Project/README.md"])

        XCTAssertEqual(state.changeCount, 0)
        monitor.stop()
    }

    func testStopDuringActiveMonitoringReleasesStreamAndScopes() {
        let state = State()
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)
        XCTAssertTrue(monitor.start())
        XCTAssertEqual(state.rootAccessCount, 1)

        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertEqual(stream.invalidateCount, 1)
        XCTAssertEqual(state.rootStopCount, 1)
    }

    func testRestartAfterStopCreatesFreshMonitoringSession() {
        let state = State()
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)

        XCTAssertTrue(monitor.start())
        let firstStreamStartCount = stream.startCount
        let firstRootAccessCount = state.rootAccessCount

        stream.emit(["/Authorized/Project/.git/logs/HEAD"])
        XCTAssertEqual(state.changeCount, 1)

        monitor.stop()
        monitor.start()

        XCTAssertEqual(stream.startCount, firstStreamStartCount + 1)
        XCTAssertEqual(state.rootAccessCount, firstRootAccessCount + 1)
        stream.emit(["/Authorized/Project/.git/refs/heads/main"])
        XCTAssertEqual(state.changeCount, 2)
        monitor.stop()
    }

    func testGitMetadataPathFilterIncludesOnlyRefreshRelevantMetadata() {
        XCTAssertTrue(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Project/.git"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Project/.git/HEAD.lock"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Project/.git/logs/refs/heads/main"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Project/.git/index"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Project/.git/config"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Project/.gitmodules"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Archives/Project.git/refs/heads/main"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Archives/Project.git/HEAD"
        ))
        XCTAssertFalse(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Project.git/README.md"
        ))
        XCTAssertFalse(GitRepositoryChangeMonitor.isRelevantGitMetadataChange(
            path: "/Authorized/Project/Sources/App.swift"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.requiresRepositoryDiscoveryRescan(
            path: "/Authorized/Project/.gitmodules"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.requiresRepositoryDiscoveryRescan(
            path: "/Authorized/Project/.git"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.requiresRepositoryDiscoveryRescan(
            path: "/Authorized/Project/Sub/.gitmodules"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.requiresRepositoryDiscoveryRescan(
            path: "/Authorized/Archives/Project.git/config"
        ))
        XCTAssertTrue(GitRepositoryChangeMonitor.requiresRepositoryDiscoveryRescan(
            path: "/Authorized/Project/.git/config"
        ))
        XCTAssertFalse(GitRepositoryChangeMonitor.requiresRepositoryDiscoveryRescan(
            path: "/Authorized/Project/.git/logs/HEAD"
        ))
        XCTAssertFalse(GitRepositoryChangeMonitor.requiresRepositoryDiscoveryRescan(
            path: "/Authorized/Project/.git/refs/heads/main"
        ))
    }

    func testAffectedRepositoryPathsResolveRepositoryRootsInsteadOfScanRoots() {
        let watchedRoots = ["/Authorized/Workspace"]
        let alwaysExists: (String) -> Bool = { _ in true }

        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Authorized/Workspace/Alpha/.git/config"],
                watchedRoots: watchedRoots,
                directoryExists: alwaysExists
            ),
            ["/Authorized/Workspace/Alpha"]
        )
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Authorized/Workspace/Beta/.git"],
                watchedRoots: watchedRoots,
                directoryExists: alwaysExists
            ),
            ["/Authorized/Workspace/Beta"]
        )
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Authorized/Workspace/Gamma/.gitmodules"],
                watchedRoots: watchedRoots,
                directoryExists: alwaysExists
            ),
            ["/Authorized/Workspace/Gamma"]
        )
        // A path inside `.git` still belongs to the repository that owns it, and
        // a nested repository keeps its own directory instead of its parent.
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: [
                    "/Authorized/Workspace/Delta/.git/modules/sub/logs/HEAD",
                    "/Authorized/Workspace/Delta/Nested/.git/config"
                ],
                watchedRoots: watchedRoots,
                directoryExists: alwaysExists
            ),
            ["/Authorized/Workspace/Delta", "/Authorized/Workspace/Delta/Nested"]
        )
        // A `<name>.git` component may be a bare repository itself or a separate
        // Git directory for a work tree elsewhere, so the parent directory is the
        // narrowest unambiguous scope.
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Authorized/Workspace/Archives/Project.git/refs/heads/main"],
                watchedRoots: watchedRoots,
                directoryExists: alwaysExists
            ),
            ["/Authorized/Workspace/Archives"]
        )
        // An event on the scan root's own `.git` entry cannot narrow further.
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Authorized/Workspace/.git/config"],
                watchedRoots: watchedRoots,
                directoryExists: alwaysExists
            ),
            ["/Authorized/Workspace"]
        )
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Authorized/Workspace/Alpha/.git/config"],
                watchedRoots: ["/Authorized/Workspace", "/Authorized/Workspace/Alpha"],
                directoryExists: alwaysExists
            ),
            ["/Authorized/Workspace/Alpha"]
        )
    }

    func testAffectedRepositoryPathsFallBackToWatchedRootWhenRepositoryIsUnresolvable() {
        let watchedRoots = ["/Authorized/Workspace"]
        let missingRepository: (String) -> Bool = { $0 != "/Authorized/Workspace/Alpha" }

        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Authorized/Workspace/Alpha/.git/config"],
                watchedRoots: watchedRoots,
                directoryExists: missingRepository
            ),
            ["/Authorized/Workspace"]
        )
        // Events outside every watched root cannot be attributed at all; the
        // coordinator falls back to its global discovery cache invalidation.
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Elsewhere/Project/.git/config"],
                watchedRoots: watchedRoots,
                directoryExists: { _ in true }
            ),
            []
        )
        // A repository directory that cannot be confirmed falls back to its
        // watched root even for a `.gitmodules` change.
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: ["/Authorized/Workspace/Alpha/.gitmodules"],
                watchedRoots: watchedRoots,
                directoryExists: { _ in false }
            ),
            ["/Authorized/Workspace"]
        )
    }

    func testAffectedRepositoryPathsUseRealDirectoryEvidence() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("TinyBuddyChangeImpact-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("Repository", isDirectory: true)
        let removedRepositoryURL = rootURL.appendingPathComponent("Removed", isDirectory: true)
        try fileManager.createDirectory(
            at: repositoryURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: rootURL) }

        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: [repositoryURL.appendingPathComponent(".git/config").path],
                watchedRoots: [rootURL.path]
            ),
            [repositoryURL.standardizedFileURL.path]
        )
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRepositoryPaths(
                for: [removedRepositoryURL.appendingPathComponent(".git/config").path],
                watchedRoots: [rootURL.path]
            ),
            [rootURL.standardizedFileURL.path]
        )
    }

    func testDiscoveryEventEmitsNarrowedRepositoryPathToChangeHandler() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("TinyBuddyChangeMonitor-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("Alpha", isDirectory: true)
        try fileManager.createDirectory(
            at: repositoryURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: rootURL) }

        let state = State(rootPaths: [rootURL.path])
        let stream = FakeEventStream()
        let monitor = makeMonitor(state: state, stream: stream)
        XCTAssertTrue(monitor.start())

        stream.emit([repositoryURL.appendingPathComponent(".git/config").path])

        XCTAssertEqual(state.changeCount, 1)
        XCTAssertTrue(state.lastChangeRequiredDiscoveryRescan)
        XCTAssertEqual(state.lastAffectedRepositoryPaths, [repositoryURL.standardizedFileURL.path])
        monitor.stop()
    }

    private func makeMonitor(
        state: State,
        stream: FakeEventStream
    ) -> GitRepositoryChangeMonitor {
        GitRepositoryChangeMonitor(
            authorizedRootsProvider: { state.makeAccessResult() },
            changeHandler: { impact in
                state.changeCount += 1
                state.lastChangeRequiredDiscoveryRescan = impact.requiresRepositoryDiscoveryRescan
                state.lastAffectedRepositoryPaths = impact.affectedRepositoryPaths
            },
            eventStreamFactory: { _, handler in
                stream.eventHandler = handler
                return stream
            }
        )
    }
}

private final class FakeEventStream: GitRepositoryChangeEventStream {
    var startResult: Bool
    var startCount = 0
    var stopCount = 0
    var invalidateCount = 0
    var eventHandler: (([String]) -> Void)?

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    @discardableResult
    func start() -> Bool {
        startCount += 1
        return startResult
    }

    func stop() {
        stopCount += 1
    }

    func invalidate() {
        invalidateCount += 1
    }

    func emit(_ paths: [String]) {
        eventHandler?(paths)
    }
}

private final class State {
    var rootAccessCount = 0
    var rootStopCount = 0
    var changeCount = 0
    var lastChangeRequiredDiscoveryRescan = false
    var lastAffectedRepositoryPaths: [String] = []
    let rootPaths: [String]

    init(rootPaths: [String] = ["/Authorized/Project"]) {
        self.rootPaths = rootPaths
    }

    func makeAccessResult() -> GitScanRootAccessResult {
        rootAccessCount += 1
        return GitScanRootAccessResult(
            roots: rootPaths.map { path in
                ScopedGitScanRoot(url: URL(fileURLWithPath: path)) { [weak self] in
                    self?.rootStopCount += 1
                }
            },
            issue: nil
        )
    }
}
