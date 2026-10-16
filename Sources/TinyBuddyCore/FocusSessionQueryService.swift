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

/// One surviving project summary of a `projects(version:)` pass.
///
/// The summary keeps only the winner's sort fields and the resolved project,
/// so the pass can read scalar fields out of a slot instead of copying the
/// `FocusProjectContext` in and out of a dictionary for every row.
private struct ProjectSummarySlot {
    var startedAt: Date
    var id: UUID
    var project: FocusProjectContext
}

/// Display-order key for one row of a query pass.
///
/// The service sorts these 32-byte keys instead of the `FocusSession` rows
/// themselves: a row is 177 bytes and holds four reference-counted fields, so
/// sorting rows costs a copy-on-write copy of the whole snapshot plus retain
/// and release traffic on every swap, while a key carries only the two sort
/// components and the row's index in the snapshot.
private struct DisplayOrderKey {
    let startedAt: Date
    let id: UUID
    let index: Int

    /// The tie-break compares `UUID`s byte-wise, which orders exactly like the
    /// `id.uuidString` ascending key the display order specifies: canonical
    /// `uuidString` is fixed-width dashed hex whose digits order like their
    /// nibble values. `testDisplayOrderTieBreakMatchesUUIDStringOrdering` pins
    /// that equivalence, including at the hex digit boundaries.
    @inline(__always)
    static func precedes(_ a: DisplayOrderKey, _ b: DisplayOrderKey) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        return a.id < b.id
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

        // Every page performs one O(N) key-building pass over the history and
        // one O(N log N) sort of the 32-byte keys, then materialises only the
        // returned page's rows. Project identity is resolved while building the
        // keys only when the query has project predicates (`projectKey` or a
        // keyword), for each distinct context among the rows that pass the
        // row-local predicates; the returned page's rows are resolved in
        // `makePage`. Nothing is cached across pages: each request reads the
        // provider again, so no page can observe a stale history and no extra
        // full array is kept alive between requests.
        var resolution = ProjectResolutionMemo()
        let sessions = sessionProvider()
        var keys = matchingKeys(query: query, in: sessions, resolution: &resolution)
        keys.sort(by: DisplayOrderKey.precedes)

        return makePage(
            from: sessions,
            keys: keys,
            cursor: cursor,
            limit: limit,
            resolution: &resolution
        )
    }

    public func projects(version: Int) async -> [FocusProjectContext]? {
        guard version >= currentQueryVersion else { return nil }
        // Select the newest name deterministically if legacy rows disagree.
        // Return only project summaries; never fetch or accumulate extra pages.
        //
        // Grouping stays keyed by the *resolved* key (two historical contexts
        // that resolve to one key collapse into a single summary), while
        // resolution is memoised per exact input context for this pass only,
        // exactly like `ProjectResolutionMemo`; nothing is cached across calls.
        // One slot per canonical key, one index lookup per input context, and
        // no per-row dictionary write or `uuidString` allocation.
        var slots: [ProjectSummarySlot] = []
        // canonical key -> slot index; consulted only when a new context appears.
        var slotByKey: [String: Int] = [:]
        // input context -> (slot index, resolved context), so the same input
        // context cannot resolve twice within this pass.
        var slotByContext: [FocusProjectContext: (slot: Int, project: FocusProjectContext)] = [:]

        let sessions = sessionProvider()
        // Iterating the rows by value would copy ~177 bytes and retain/release
        // each row's reference-counted fields per row, which dominates this
        // pass; read only the fields the summary needs out of the buffer.
        sessions.withUnsafeBufferPointer { buffer in
            slots.reserveCapacity(Swift.min(buffer.count, 64))
            for index in buffer.indices {
                let context = buffer[index].project
                let slotIndex: Int
                let resolved: FocusProjectContext
                if let cached = slotByContext[context] {
                    slotIndex = cached.slot
                    resolved = cached.project
                } else {
                    resolved = projectResolver(context)
                    if let existing = slotByKey[resolved.key] {
                        // Another input context already represents this key.
                        slotIndex = existing
                    } else {
                        // This key's first row: seed the slot with it directly,
                        // so no sentinel timestamp is ever needed.
                        slotIndex = slots.count
                        slotByKey[resolved.key] = slotIndex
                        slots.append(ProjectSummarySlot(
                            startedAt: buffer[index].startedAt,
                            id: buffer[index].id,
                            project: resolved
                        ))
                        slotByContext[context] = (slotIndex, resolved)
                        continue
                    }
                    slotByContext[context] = (slotIndex, resolved)
                }

                let startedAt = buffer[index].startedAt
                let id = buffer[index].id
                // The newest start wins; on equal starts the winner is the row
                // the display order considers newest, i.e. the smallest
                // `id.uuidString` (exactly what the previous
                // `previous.id.uuidString < session.id.uuidString` keep-the-
                // earlier-row rule selected). `UUID`'s `<` compares bytes, which
                // orders exactly like `uuidString` ascending
                // (`DisplayOrderKey.precedes` documents the same equivalence),
                // so comparing ids directly replaces two per-comparison string
                // allocations.
                if slots[slotIndex].startedAt > startedAt
                    || (slots[slotIndex].startedAt == startedAt && slots[slotIndex].id < id) { continue }
                slots[slotIndex].startedAt = startedAt
                slots[slotIndex].id = id
                slots[slotIndex].project = resolved
            }
        }

        return slots.map(\.project).sorted {
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
        return matchingKeys(query: query, in: sessionProvider(), resolution: &resolution).count
    }

    /// Bumps the version so the next fetch reflects the changes. The
    /// changes themselves are applied automatically because the provider
    /// is read fresh each time.
    public func applyChanges(_ changes: [FocusSessionChangeType]) async {
        currentQueryVersion += 1
    }

    // MARK: - Helpers

    /// Locates the continuation point in display order and materialises the
    /// requested page.
    ///
    /// Cursor continuity is unchanged from the row-array implementation:
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
        from sessions: [FocusSession],
        keys: [DisplayOrderKey],
        cursor: FocusSessionCursor?,
        limit: Int,
        resolution: inout ProjectResolutionMemo
    ) -> FocusSessionQueryPage? {
        let totalCount = keys.count

        // Determine the start index based on the cursor.
        let startIndex: Int
        var cursorMissed = false
        if let cursor = cursor {
            // Find the first session after the cursor in the established sort order.
            var lowerBound = 0
            var upperBound = totalCount
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                let key = keys[middle]
                let comesBeforeOrAtCursor = key.startedAt > cursor.lastStartedAt
                    || (key.startedAt == cursor.lastStartedAt
                        && key.id <= cursor.lastID)
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
        // Only the requested page's rows leave the provider array, and only
        // those rows are resolved in this step and copied into the page. Rows
        // that a project or keyword predicate had to inspect were already
        // resolved while the keys were built.
        for offset in startIndex ..< endIndex {
            let session = sessions[keys[offset].index]
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
            ? FocusSessionCursor(
                lastStartedAt: keys[endIndex - 1].startedAt,
                lastID: keys[endIndex - 1].id
            )
            : nil

        return FocusSessionQueryPage(
            sessions: page,
            nextCursor: nextCursor,
            hasMore: hasMore,
            totalEstimatedCount: totalCount
        )
    }

    /// Filters the whole history in one pass and emits a display-order key per
    /// surviving row. The keys keep the row's index instead of the row itself,
    /// so neither this pass nor the sort copies rows. A `projectKey` or keyword
    /// query resolves each distinct context among the rows that pass the
    /// row-local predicates, exactly like the row-array implementation did; the
    /// returned page's rows are materialised and resolved by `makePage`.
    private func matchingKeys(
        query: FocusSessionQuery,
        in sessions: [FocusSession],
        resolution: inout ProjectResolutionMemo
    ) -> [DisplayOrderKey] {
        // Day bounds and status are row-local and cheap, so they are tested
        // before the memoised project lookup; the keyword is normalised once
        // for the whole pass instead of once per session.
        let loweredKeyword = query.keyword.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let needsProjectPredicates = query.projectKey != nil || loweredKeyword != nil
        var keys: [DisplayOrderKey] = []
        // Iterating the rows by value (`for session in sessions`) would copy
        // ~177 bytes and retain/release each row's reference-counted fields per
        // row, which is the dominant cost of this pass. Reading only the fields
        // the predicates and the key need out of the buffer avoids that copy.
        sessions.withUnsafeBufferPointer { buffer in
            keys.reserveCapacity(buffer.count)
            for index in buffer.indices {
                if let dayStart = query.dayStart, buffer[index].dayIdentifier < dayStart { continue }
                if let dayEnd = query.dayEnd, buffer[index].dayIdentifier > dayEnd { continue }
                if let status = query.status, buffer[index].status != status { continue }

                if needsProjectPredicates {
                    let project = resolution.resolve(buffer[index].project, using: projectResolver)
                    guard resolution.matchesFilters(
                        project,
                        query: query,
                        loweredKeyword: loweredKeyword
                    ) else { continue }
                }
                keys.append(DisplayOrderKey(
                    startedAt: buffer[index].startedAt,
                    id: buffer[index].id,
                    index: index
                ))
            }
        }
        return keys
    }
}
