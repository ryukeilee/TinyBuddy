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
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let timeScopeTokenProvider: () -> String?

    public convenience init(
        timeEnvironment: TinyBuddyTimeEnvironment = TinyBuddyTimeEnvironment()
    ) {
        self.init(
            trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore(),
            focusBlockCountStore: GitTodayFocusBlockCountStore(timeEnvironment: timeEnvironment),
            commitCountStore: GitTodayCommitCountStore(timeEnvironment: timeEnvironment),
            recentProjectStore: GitTodayRecentProjectStore(timeEnvironment: timeEnvironment),
            timeEnvironment: timeEnvironment,
            timeScopeTokenProvider: { TinyBuddyTimeScopeState.shared.currentToken() }
        )
    }

    public init(
        trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore? = nil,
        focusBlockCountStore: GitTodayFocusBlockCountStore,
        commitCountStore: GitTodayCommitCountStore,
        recentProjectStore: GitTodayRecentProjectStore,
        timeEnvironment: TinyBuddyTimeEnvironment = TinyBuddyTimeEnvironment(),
        timeScopeTokenProvider: @escaping () -> String? = {
            TinyBuddyTimeScopeState.shared.currentToken()
        }
    ) {
        self.trustedSnapshotStore = trustedSnapshotStore
        self.focusBlockCountStore = focusBlockCountStore
        self.commitCountStore = commitCountStore
        self.recentProjectStore = recentProjectStore
        self.timeEnvironment = timeEnvironment
        self.timeScopeTokenProvider = timeScopeTokenProvider
    }

    public convenience init(
        trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore? = nil,
        focusBlockCountStore: GitTodayFocusBlockCountStore,
        commitCountStore: GitTodayCommitCountStore,
        recentProjectStore: GitTodayRecentProjectStore,
        calendar: Calendar,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.init(
            trustedSnapshotStore: trustedSnapshotStore,
            focusBlockCountStore: focusBlockCountStore,
            commitCountStore: commitCountStore,
            recentProjectStore: recentProjectStore,
            timeEnvironment: TinyBuddyTimeEnvironment(
                calendar: calendar,
                dateProvider: dateProvider
            ),
            timeScopeTokenProvider: { TinyBuddyTimeScopeState.shared.currentToken() }
        )
    }

    public func loadTodaySnapshot() -> GitTodayActivitySnapshot {
        loadTodaySnapshotRead().snapshot
    }

    public func loadTodaySnapshotRead() -> GitTodayActivitySnapshotRead {
        guard let context = timeEnvironment.capture() else {
            let trustedSnapshot = trustedSnapshotStore?.load()
            return GitTodayActivitySnapshotRead(
                snapshot: trustedSnapshot?.activity ?? GitTodayActivitySnapshot(
                    focusBlockCount: focusBlockCountStore.loadTodayCount(),
                    commitCount: commitCountStore.loadTodayCount(),
                    recentProjectName: recentProjectStore.loadTodayProjectName()
                ),
                trustedRevision: trustedSnapshot?.revision
            )
        }
        let timeScopeToken = timeScopeTokenProvider()
        if let trustedSnapshot = trustedSnapshotStore?.load(
            dayIdentifier: context.dayIdentifier,
            timeScopeIdentifier: context.signature.portableScopeIdentifier,
            timeScopeToken: timeScopeToken
        ) {
            return GitTodayActivitySnapshotRead(
                snapshot: trustedSnapshot.activity,
                trustedRevision: trustedSnapshot.revision
            )
        }

        if trustedSnapshotStore?.containsEnvironmentScopedSnapshot(
            dayIdentifier: context.dayIdentifier
        ) == true {
            return GitTodayActivitySnapshotRead(
                snapshot: GitTodayActivitySnapshot(
                    focusBlockCount: nil,
                    commitCount: nil,
                    recentProjectName: nil
                ),
                trustedRevision: nil
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
