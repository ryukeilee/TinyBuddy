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
    private let trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore?
    private let focusBlockCountStore: GitTodayFocusBlockCountStore
    private let commitCountStore: GitTodayCommitCountStore
    private let recentProjectStore: GitTodayRecentProjectStore

    public convenience init() {
        self.init(
            trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore(),
            focusBlockCountStore: GitTodayFocusBlockCountStore(),
            commitCountStore: GitTodayCommitCountStore(),
            recentProjectStore: GitTodayRecentProjectStore()
        )
    }

    public init(
        trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore? = nil,
        focusBlockCountStore: GitTodayFocusBlockCountStore,
        commitCountStore: GitTodayCommitCountStore,
        recentProjectStore: GitTodayRecentProjectStore
    ) {
        self.trustedSnapshotStore = trustedSnapshotStore
        self.focusBlockCountStore = focusBlockCountStore
        self.commitCountStore = commitCountStore
        self.recentProjectStore = recentProjectStore
    }

    public func loadTodaySnapshot() -> GitTodayActivitySnapshot {
        if let trustedSnapshot = trustedSnapshotStore?.load(),
           trustedSnapshot.dayIdentifier == todayIdentifier() {
            return trustedSnapshot.activity
        }

        return GitTodayActivitySnapshot(
            focusBlockCount: focusBlockCountStore.loadTodayCount(),
            commitCount: commitCountStore.loadTodayCount(),
            recentProjectName: recentProjectStore.loadTodayProjectName()
        )
    }

    private func todayIdentifier() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
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
