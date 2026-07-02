import Foundation

public struct GitTodayActivitySnapshot: Equatable, Sendable {
    public let focusBlockCount: Int?
    public let commitCount: Int?
    public let recentProjectName: String?

    public init(focusBlockCount: Int?, commitCount: Int?, recentProjectName: String? = nil) {
        self.focusBlockCount = focusBlockCount
        self.commitCount = commitCount
        self.recentProjectName = recentProjectName
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
    private let recentProjectStore: GitTodayRecentProjectStore

    public init(
        focusBlockCountStore: GitTodayFocusBlockCountStore = GitTodayFocusBlockCountStore(),
        commitCountStore: GitTodayCommitCountStore = GitTodayCommitCountStore(),
        recentProjectStore: GitTodayRecentProjectStore = GitTodayRecentProjectStore()
    ) {
        self.focusBlockCountStore = focusBlockCountStore
        self.commitCountStore = commitCountStore
        self.recentProjectStore = recentProjectStore
    }

    public func loadTodaySnapshot() -> GitTodayActivitySnapshot {
        GitTodayActivitySnapshot(
            focusBlockCount: focusBlockCountStore.loadTodayCount(),
            commitCount: commitCountStore.loadTodayCount(),
            recentProjectName: recentProjectStore.loadTodayProjectName()
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
