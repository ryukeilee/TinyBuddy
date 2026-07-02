import Foundation

public struct GitTodayActivitySnapshot: Equatable, Sendable {
    public let focusBlockCount: Int?
    public let commitCount: Int?

    public init(focusBlockCount: Int?, commitCount: Int?) {
        self.focusBlockCount = focusBlockCount
        self.commitCount = commitCount
    }
}

public struct GitTodayActivityRefreshResult: Equatable, Sendable {
    public let previousSnapshot: GitTodayActivitySnapshot
    public let currentSnapshot: GitTodayActivitySnapshot

    public init(previousSnapshot: GitTodayActivitySnapshot, currentSnapshot: GitTodayActivitySnapshot) {
        self.previousSnapshot = previousSnapshot
        self.currentSnapshot = currentSnapshot
    }

    public var didChange: Bool {
        previousSnapshot != currentSnapshot
    }
}

public final class GitTodayActivityStore {
    private let focusBlockCountStore: GitTodayFocusBlockCountStore
    private let commitCountStore: GitTodayCommitCountStore

    public init(
        focusBlockCountStore: GitTodayFocusBlockCountStore = GitTodayFocusBlockCountStore(),
        commitCountStore: GitTodayCommitCountStore = GitTodayCommitCountStore()
    ) {
        self.focusBlockCountStore = focusBlockCountStore
        self.commitCountStore = commitCountStore
    }

    public func loadTodaySnapshot() -> GitTodayActivitySnapshot {
        GitTodayActivitySnapshot(
            focusBlockCount: focusBlockCountStore.loadTodayCount(),
            commitCount: commitCountStore.loadTodayCount()
        )
    }

    public func makeRefreshResult(
        previousSnapshot: GitTodayActivitySnapshot,
        currentSnapshot: GitTodayActivitySnapshot
    ) -> GitTodayActivityRefreshResult {
        GitTodayActivityRefreshResult(
            previousSnapshot: previousSnapshot,
            currentSnapshot: currentSnapshot
        )
    }
}
