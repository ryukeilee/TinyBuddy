import Foundation

// MARK: - Query Types

/// Filter parameters for a focus-session query. All fields are optional;
/// when nil the filter does not constrain the result set.
public struct FocusSessionQuery: Equatable, Sendable {
    /// Inclusive lower bound on `dayIdentifier` (e.g. `"2026-07-01"`).
    public var dayStart: String?
    /// Inclusive upper bound on `dayIdentifier`.
    public var dayEnd: String?
    /// Only sessions whose `project.key` matches this value.
    public var projectKey: String?
    /// Only sessions whose `status` matches.
    public var status: FocusSessionStatus?
    /// Case-insensitive substring match against `project.displayName` or
    /// `project.key`. Empty strings are treated as no filter.
    public var keyword: String?

    public init(
        dayStart: String? = nil,
        dayEnd: String? = nil,
        projectKey: String? = nil,
        status: FocusSessionStatus? = nil,
        keyword: String? = nil
    ) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.projectKey = projectKey
        self.status = status
        self.keyword = keyword
    }

    /// Returns true when no filter constraints are active.
    public var isEmpty: Bool {
        dayStart == nil && dayEnd == nil && projectKey == nil
            && status == nil && (keyword?.isEmpty ?? true)
    }
}

// MARK: - Cursor

/// Stable cursor for deterministic, gap-free cursor-based pagination.
///
/// Sort order: `startedAt` descending, then `id` ascending for
/// tie-breaking. This produces a stable ordering across pages even
/// when new sessions are inserted or existing ones are modified.
public struct FocusSessionCursor: Equatable, Sendable, Hashable {
    /// The `startedAt` of the last session on the preceding page.
    public let lastStartedAt: Date
    /// The `id` of the last session on the preceding page.
    public let lastID: UUID

    public init(lastStartedAt: Date, lastID: UUID) {
        self.lastStartedAt = lastStartedAt
        self.lastID = lastID
    }
}

// MARK: - Page

/// A single page of query results.
public struct FocusSessionQueryPage: Equatable, Sendable {
    /// The sessions on this page.
    public let sessions: [FocusSession]
    /// Cursor to pass for fetching the next page. `nil` when the result
    /// is empty or there are no more pages.
    public let nextCursor: FocusSessionCursor?
    /// Whether additional pages exist beyond this one.
    public let hasMore: Bool
    /// Estimated total count of sessions matching the query (not just this
    /// page). `nil` when counting was too expensive.
    public let totalEstimatedCount: Int?

    public init(
        sessions: [FocusSession],
        nextCursor: FocusSessionCursor?,
        hasMore: Bool,
        totalEstimatedCount: Int? = nil
    ) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.totalEstimatedCount = totalEstimatedCount
    }

    /// A convenience empty page.
    public static let empty = FocusSessionQueryPage(
        sessions: [], nextCursor: nil, hasMore: false, totalEstimatedCount: nil
    )
}

// MARK: - Load State

/// Observable loading state for a session query.
public enum FocusSessionLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(FocusSessionQueryPage)
    case failure(String)

    /// Returns the current page when in `.loaded` state, nil otherwise.
    public var currentPage: FocusSessionQueryPage? {
        if case .loaded(let page) = self { return page }
        return nil
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var errorMessage: String? {
        if case .failure(let msg) = self { return msg }
        return nil
    }
}

// MARK: - Change Tracking

/// Describes the type of a single session change, used by the query
/// service to invalidate only affected pages.
public enum FocusSessionChangeType: Equatable, Sendable {
    case inserted(FocusSession)
    case updated(previous: FocusSession, current: FocusSession)
    case deleted(FocusSession)
}

// MARK: - Query Service Protocol

/// Interface for the paginated, filterable session query service.
/// The concrete implementation is an actor in `FocusSessionQueryService`.
public protocol FocusSessionQuerying: Sendable {
    /// Execute a query starting from an optional cursor.
    /// Returns nil when the query version is stale (superseded by a newer
    /// `invalidateQueries()` call).
    func execute(
        query: FocusSessionQuery,
        cursor: FocusSessionCursor?,
        limit: Int,
        version: Int
    ) async -> FocusSessionQueryPage?

    /// Bumps the version, causing all in-flight queries with an older
    /// version to return nil on completion.
    func invalidateQueries() async

    /// Returns the number of sessions matching the query (used for
    /// estimated total, can be approximate).
    func estimatedCount(query: FocusSessionQuery) async -> Int

    /// Applies changes and bumps version so the next fetch reflects them.
    func applyChanges(_ changes: [FocusSessionChangeType]) async
}
