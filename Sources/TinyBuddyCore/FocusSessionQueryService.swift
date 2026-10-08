import Foundation

// MARK: - Query Service

/// Resolves each distinct project context at most once for a single query
/// pass.
///
/// Project resolution is the dominant per-session cost of a history query:
/// the registry authority scans its identity graph (ids, aliases, case-folded
/// fallbacks) for every lookup, while a real history only contains a handful
/// of distinct projects.
///
/// The memo assumes a resolver that returns the same context for the same input
/// within one pass. The identity-authority projection only satisfies that while
/// the registry is unchanged; if the registry is mutated concurrently, the memo
/// fixes the first result seen for each exact input context (a per-row
/// implementation could instead observe two different values).
/// Its consistency unit is the exact input context, not the logical project: two
/// historical contexts of one project (for example an old alias and the current
/// canonical key) can each be resolved on either side of a concurrent registry
/// mutation, because no whole-query registry snapshot exists. What the memo does
/// guarantee is that the same input context cannot resolve twice within one
/// pass, and it never outlives the call, so it cannot serve a stale identity to
/// a later query.
private struct ProjectResolutionMemo {
    private var resolved: [FocusProjectContext: FocusProjectContext] = [:]
    /// Cached outcome of the project-identity predicates (`projectKey` match,
    /// keyword match) per resolved project, so a keyword query lowercases each
    /// project name once instead of once per session.
    private var matches: [FocusProjectContext: Bool] = [:]

    mutating func resolve(
        _ context: FocusProjectContext,
        using resolver: (FocusProjectContext) -> FocusProjectContext
    ) -> FocusProjectContext {
        if let cached = resolved[context] { return cached }
        let value = resolver(context)
        resolved[context] = value
        return value
    }

    mutating func matchesFilters(
        _ project: FocusProjectContext,
        query: FocusSessionQuery,
        loweredKeyword: String?
    ) -> Bool {
        if let cached = matches[project] { return cached }
        var result = true
        if let projectKey = query.projectKey, project.key != projectKey {
            result = false
        }
        if result, let loweredKeyword {
            result = project.displayName.lowercased().contains(loweredKeyword)
                || project.key.lowercased().contains(loweredKeyword)
        }
        matches[project] = result
        return result
    }
}

/// Concrete actor implementation of `FocusSessionQuerying` that reads
/// sessions from an in-memory provider on each query.
public actor FocusSessionQueryService: FocusSessionQuerying {
    private let sessionProvider: @Sendable () -> [FocusSession]
    private var currentQueryVersion = 0
    private let projectResolver: @Sendable (FocusProjectContext) -> FocusProjectContext

    // MARK: - Init

    /// - Parameter sessionProvider: A closure that returns the current set of
    ///   sessions. Called synchronously on each query; the list is expected to
    ///   be already in memory so the call is cheap.
    /// - Parameter projectResolver: A projection of the identity authority.
    ///   It must return the same context for the same input, so a query pass
    ///   can resolve each distinct project once instead of once per session.
    public init(
        sessionProvider: @escaping @Sendable () -> [FocusSession],
        projectResolver: @escaping @Sendable (FocusProjectContext) -> FocusProjectContext = { $0 }
    ) {
        self.sessionProvider = sessionProvider
        self.projectResolver = projectResolver
    }

    // MARK: - FocusSessionQuerying

    public func execute(
        query: FocusSessionQuery,
        cursor: FocusSessionCursor?,
        limit: Int,
        version: Int
    ) async -> FocusSessionQueryPage? {
        guard version >= currentQueryVersion else { return nil }
        // A caller-controlled non-positive page size previously produced an
        // invalid array range and could trap the query actor. Treat it as an
        // empty request, and calculate the upper bound without overflowing
        // when a very large limit is supplied.
        guard limit > 0 else { return .empty }

        // One pass resolves (memoised) and filters the history; the sort then
        // happens in place, so a query never copies the whole history more than
        // once, and only the rows of the returned page carry a resolved
        // project identity.
        var resolution = ProjectResolutionMemo()
        var sorted: [FocusSession]
        if query.isEmpty {
            // No filter constrains the result set, so the page is a slice of
            // the history in display order. Sorting the provider's own value in
            // place keeps copy-on-write from mutating the provider and avoids
            // materialising a second full array on every page request.
            sorted = sessionProvider()
            sorted.sort(by: Self.precedesInDisplayOrder)
        } else {
            sorted = matchingSessions(query: query, resolution: &resolution)
            sorted.sort(by: Self.precedesInDisplayOrder)
        }

        return makePage(from: sorted, cursor: cursor, limit: limit, resolution: &resolution)
    }

    public func projects(version: Int) async -> [FocusProjectContext]? {
        guard version >= currentQueryVersion else { return nil }
        // Select the newest name deterministically if legacy rows disagree.
        // Return only project summaries; never fetch or accumulate extra pages.
        // Resolution is memoised per distinct project, not per session.
        var resolution = ProjectResolutionMemo()
        var newest: [String: (startedAt: Date, id: UUID, project: FocusProjectContext)] = [:]
        for session in sessionProvider() {
            let project = resolution.resolve(session.project, using: projectResolver)
            if let previous = newest[project.key],
               previous.startedAt > session.startedAt
                || (previous.startedAt == session.startedAt
                    && previous.id.uuidString < session.id.uuidString) { continue }
            newest[project.key] = (session.startedAt, session.id, project)
        }
        return newest.values.map(\.project).sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
        }
    }

    public func invalidateQueries() async {
        currentQueryVersion += 1
    }

    public func estimatedCount(query: FocusSessionQuery) async -> Int {
        if query.isEmpty { return sessionProvider().count }
        var resolution = ProjectResolutionMemo()
        return matchingSessions(query: query, resolution: &resolution).count
    }

    /// Bumps the version so the next fetch reflects the changes. The
    /// changes themselves are applied automatically because the provider
    /// is read fresh each time.
    public func applyChanges(_ changes: [FocusSessionChangeType]) async {
        currentQueryVersion += 1
    }

    // MARK: - Helpers

    private static func precedesInDisplayOrder(_ a: FocusSession, _ b: FocusSession) -> Bool {
        if a.startedAt != b.startedAt {
            return a.startedAt > b.startedAt
        }
        return a.id.uuidString < b.id.uuidString
    }

    /// Locates the continuation point in display order and materialises the
    /// requested page.
    ///
    /// Cursor continuity is unchanged from the filtered-array implementation:
    /// the binary search finds the first row that sorts strictly after the
    /// cursor key, and `nil` is returned only when no row sorts strictly after
    /// it (the search lands at or past the end of the current result set), which
    /// tells the caller to restart pagination from the first page instead of
    /// truncating silently. A cursor whose own row was deleted while later
    /// matching rows survive therefore continues from the next surviving row;
    /// the service neither skips nor duplicates rows on that path. A row that
    /// was already loaded and is later deleted stays in the controller's
    /// accumulated list until the next `reload()`, which is true of every
    /// loaded row and not specific to the cursor.
    private func makePage(
        from sorted: [FocusSession],
        cursor: FocusSessionCursor?,
        limit: Int,
        resolution: inout ProjectResolutionMemo
    ) -> FocusSessionQueryPage? {
        let totalCount = sorted.count

        // Determine the start index based on the cursor.
        let startIndex: Int
        var cursorMissed = false
        if let cursor = cursor {
            // Find the first session after the cursor in the established sort order.
            var lowerBound = 0
            var upperBound = totalCount
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                let session = sorted[middle]
                let comesBeforeOrAtCursor = session.startedAt > cursor.lastStartedAt
                    || (session.startedAt == cursor.lastStartedAt
                        && session.id.uuidString <= cursor.lastID.uuidString)
                if comesBeforeOrAtCursor {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            if lowerBound < totalCount {
                startIndex = lowerBound
            } else {
                // The cursor key no longer matches the current result set
                // (sessions were deleted or reordered between pages).
                // Continuity is broken.
                startIndex = totalCount
                cursorMissed = true
            }
        } else {
            startIndex = 0
        }

        guard startIndex < totalCount else {
            if cursorMissed {
                // Signal the caller to restart pagination from the first page
                // instead of silently truncating the remaining sessions.
                return nil
            }
            return FocusSessionQueryPage.empty
        }

        let pageCount = min(limit, totalCount - startIndex)
        let endIndex = startIndex + pageCount
        var page: [FocusSession] = []
        page.reserveCapacity(pageCount)
        for session in sorted[startIndex ..< endIndex] {
            let project = resolution.resolve(session.project, using: projectResolver)
            if project == session.project {
                page.append(session)
            } else {
                var row = session
                row.project = project
                page.append(row)
            }
        }
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

    /// Resolves and filters the whole history in one pass. Rows keep their
    /// stored project identity here; only `makePage` resolves the returned rows.
    private func matchingSessions(
        query: FocusSessionQuery,
        resolution: inout ProjectResolutionMemo
    ) -> [FocusSession] {
        // Day bounds and status are row-local and cheap, so they are tested
        // before the memoised project lookup; the keyword is normalised once
        // for the whole pass instead of once per session.
        let loweredKeyword = query.keyword.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let needsProjectPredicates = query.projectKey != nil || loweredKeyword != nil
        let sessions = sessionProvider()
        var result: [FocusSession] = []
        result.reserveCapacity(sessions.count)
        for session in sessions {
            if let dayStart = query.dayStart, session.dayIdentifier < dayStart { continue }
            if let dayEnd = query.dayEnd, session.dayIdentifier > dayEnd { continue }
            if let status = query.status, session.status != status { continue }

            if needsProjectPredicates {
                let project = resolution.resolve(session.project, using: projectResolver)
                guard resolution.matchesFilters(
                    project,
                    query: query,
                    loweredKeyword: loweredKeyword
                ) else { continue }
            }
            result.append(session)
        }
        return result
    }
}
