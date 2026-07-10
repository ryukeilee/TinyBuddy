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

public struct GitTodayActivitySnapshotRead: Equatable, Sendable {
    public let snapshot: GitTodayActivitySnapshot
    public let trustedRevision: Int64?

    public init(snapshot: GitTodayActivitySnapshot, trustedRevision: Int64?) {
        self.snapshot = snapshot
        self.trustedRevision = trustedRevision
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
    private let calendar: Calendar
    private let dateProvider: () -> Date

    public convenience init() {
        let calendar = Calendar.current
        let dateProvider: () -> Date = { Date() }
        self.init(
            trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore(),
            focusBlockCountStore: GitTodayFocusBlockCountStore(calendar: calendar, dateProvider: dateProvider),
            commitCountStore: GitTodayCommitCountStore(calendar: calendar, dateProvider: dateProvider),
            recentProjectStore: GitTodayRecentProjectStore(calendar: calendar, dateProvider: dateProvider),
            calendar: calendar,
            dateProvider: dateProvider
        )
    }

    public init(
        trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore? = nil,
        focusBlockCountStore: GitTodayFocusBlockCountStore,
        commitCountStore: GitTodayCommitCountStore,
        recentProjectStore: GitTodayRecentProjectStore,
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.trustedSnapshotStore = trustedSnapshotStore
        self.focusBlockCountStore = focusBlockCountStore
        self.commitCountStore = commitCountStore
        self.recentProjectStore = recentProjectStore
        self.calendar = calendar
        self.dateProvider = dateProvider
    }

    public func loadTodaySnapshot() -> GitTodayActivitySnapshot {
        loadTodaySnapshotRead().snapshot
    }

    public func loadTodaySnapshotRead() -> GitTodayActivitySnapshotRead {
        if let trustedSnapshot = trustedSnapshotStore?.load(),
           trustedSnapshot.dayIdentifier == todayIdentifier() {
            return GitTodayActivitySnapshotRead(
                snapshot: trustedSnapshot.activity,
                trustedRevision: trustedSnapshot.revision
            )
        }

        return GitTodayActivitySnapshotRead(
            snapshot: GitTodayActivitySnapshot(
                focusBlockCount: focusBlockCountStore.loadTodayCount(),
                commitCount: commitCountStore.loadTodayCount(),
                recentProjectName: recentProjectStore.loadTodayProjectName()
            ),
            trustedRevision: nil
        )
    }

    private func todayIdentifier() -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: dateProvider())
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
