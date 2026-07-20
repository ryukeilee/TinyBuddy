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
        XCTAssertEqual(state.lastAffectedRootPaths, ["/Authorized/Project"])

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
            path: "/Authorized/Project/.git/config"
        ))
        XCTAssertFalse(GitRepositoryChangeMonitor.requiresRepositoryDiscoveryRescan(
            path: "/Authorized/Project/.git/logs/HEAD"
        ))
        XCTAssertEqual(
            GitRepositoryChangeMonitor.affectedRootPaths(
                for: ["/Authorized/Project/Nested/.git"],
                watchedRoots: ["/Authorized", "/Authorized/Project"]
            ),
            ["/Authorized/Project"]
        )
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
                state.lastAffectedRootPaths = impact.affectedRootPaths
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
    var lastAffectedRootPaths: [String] = []

    func makeAccessResult() -> GitScanRootAccessResult {
        rootAccessCount += 1
        return GitScanRootAccessResult(
            roots: [
                ScopedGitScanRoot(url: URL(fileURLWithPath: "/Authorized/Project")) { [weak self] in
                    self?.rootStopCount += 1
                }
            ],
            issue: nil
        )
    }
}
