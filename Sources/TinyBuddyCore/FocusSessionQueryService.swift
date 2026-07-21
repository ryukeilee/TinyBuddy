import Foundation

// MARK: - Query Service

/// Concrete actor implementation of `FocusSessionQuerying` that reads
/// sessions from an in-memory provider on each query.
public actor FocusSessionQueryService: FocusSessionQuerying {
    private let sessionProvider: @Sendable () -> [FocusSession]
    private var currentQueryVersion = 0

    // MARK: - Init

    /// - Parameter sessionProvider: A closure that returns the current set of
    ///   sessions. Called synchronously on each query; the list is expected to
    ///   be already in memory so the call is cheap.
    public init(sessionProvider: @escaping @Sendable () -> [FocusSession]) {
        self.sessionProvider = sessionProvider
    }

    // MARK: - FocusSessionQuerying

    public func execute(
        query: FocusSessionQuery,
        cursor: FocusSessionCursor?,
        limit: Int,
        version: Int
    ) async -> FocusSessionQueryPage? {
        guard version >= currentQueryVersion else { return nil }

        let sessions = sessionProvider()
        let filtered = applyFilters(sessions, query: query)
        let sorted = filtered.sorted { a, b in
            if a.startedAt != b.startedAt {
                return a.startedAt > b.startedAt
            }
            return a.id.uuidString < b.id.uuidString
        }

        let totalCount = sorted.count

        // Determine the start index based on the cursor.
        let startIndex: Int
        if let cursor = cursor {
            startIndex = sorted.firstIndex { session in
                session.startedAt < cursor.lastStartedAt
                    || (session.startedAt == cursor.lastStartedAt
                        && session.id.uuidString > cursor.lastID.uuidString)
            } ?? totalCount
        } else {
            startIndex = 0
        }

        guard startIndex < totalCount else {
            return FocusSessionQueryPage.empty
        }

        let endIndex = min(startIndex + limit, totalCount)
        let page = Array(sorted[startIndex ..< endIndex])
        let hasMore = endIndex < totalCount

        let nextCursor: FocusSessionCursor? = hasMore
            ? FocusSessionCursor(lastStartedAt: page.last!.startedAt, lastID: page.last!.id)
            : nil

        return FocusSessionQueryPage(
            sessions: page,
            nextCursor: nextCursor,
            hasMore: hasMore,
            totalEstimatedCount: totalCount
        )
    }

    public func invalidateQueries() async {
        currentQueryVersion += 1
    }

    public func estimatedCount(query: FocusSessionQuery) async -> Int {
        let sessions = sessionProvider()
        return applyFilters(sessions, query: query).count
    }

    /// Bumps the version so the next fetch reflects the changes. The
    /// changes themselves are applied automatically because the provider
    /// is read fresh each time.
    public func applyChanges(_ changes: [FocusSessionChangeType]) async {
        currentQueryVersion += 1
    }

    // MARK: - Helpers

    private func applyFilters(
        _ sessions: [FocusSession],
        query: FocusSessionQuery
    ) -> [FocusSession] {
        sessions.filter { session in
            if let dayStart = query.dayStart, session.dayIdentifier < dayStart {
                return false
            }
            if let dayEnd = query.dayEnd, session.dayIdentifier > dayEnd {
                return false
            }
            if let projectKey = query.projectKey, session.project.key != projectKey {
                return false
            }
            if let status = query.status, session.status != status {
                return false
            }
            if let keyword = query.keyword, !keyword.isEmpty {
                let lower = keyword.lowercased()
                guard session.project.displayName.lowercased().contains(lower)
                    || session.project.key.lowercased().contains(lower)
                else {
                    return false
                }
            }
            return true
        }
    }
}
