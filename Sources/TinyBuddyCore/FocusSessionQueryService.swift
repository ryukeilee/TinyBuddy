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
    ///
    /// Rows may also share both sort components — a provider holding the same id
    /// twice with different fields. Those rows then have no order of their own,
    /// and the previous implementation left it to the sort: it emitted the
    /// snapshot in index order and `sort(by:)` is stable on this toolchain, so
    /// the earlier row won. The snapshot is read backwards here, so ordering by
    /// the row's own index keeps that outcome without depending on the sort
    /// being stable. The comparison only runs for rows whose time and id are
    /// both equal, so it costs nothing on real histories.
    @inline(__always)
    static func precedes(_ a: DisplayOrderKey, _ b: DisplayOrderKey) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        if a.id != b.id { return a.id < b.id }
        return a.index < b.index
    }
}

/// The row predicates of one query pass, normalised once instead of once per
/// row: the day window and status are row-local, while the keyword is lowered
/// a single time for the whole pass.
///
/// `matchingKeys` and `selectPage` must agree on which rows a query matches, so
/// both go through `rowMatches` instead of repeating the predicate order.
private struct QueryRowFilter {
    let query: FocusSessionQuery
    let dayStart: String?
    let dayEnd: String?
    let status: FocusSessionStatus?
    /// `nil` for a query without a keyword or with an empty one.
    let loweredKeyword: String?
    /// A query without project predicates must not resolve a single row: a
    /// project lookup scans the registry's identity graph.
    let needsProjectPredicates: Bool

    init(_ query: FocusSessionQuery) {
        self.query = query
        dayStart = query.dayStart
        dayEnd = query.dayEnd
        status = query.status
        let loweredKeyword = query.keyword.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.loweredKeyword = loweredKeyword
        needsProjectPredicates = query.projectKey != nil || loweredKeyword != nil
    }
}

/// Why a bounded page selection did not produce a page.
///
/// The two failures must stay distinct: a cursor that no longer matches any row
/// tells the caller to restart pagination from the first page, while a selection
/// that could not be decided by this pass only means the request has to be
/// answered by the key-array path. Collapsing both into one `nil` would silently
/// truncate a result set whenever the fallback fired.
private enum PageSelectionOutcome {
    case page(FocusSessionQueryPage)
    /// No matching row sorts strictly after the cursor: the caller restarts
    /// pagination (the unchanged `nil` result of `execute`).
    case cursorMiss
    /// Answer the request through the key-array path, which is the previous
    /// implementation and therefore cannot change any observable result.
    ///
    /// Two triggers, both of them about this pass rather than about the query:
    /// a non-finite `startedAt` on a scanned row or on the cursor, which the
    /// pass's comparisons are not defined for, and a replacement work budget
    /// that was exceeded, which would make the pass cost more than the path it
    /// replaces.
    case fallbackToKeyArray
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

        // Project identity is resolved only when the query has project
        // predicates (`projectKey` or a keyword), for each distinct context
        // among the rows that pass the row-local predicates; the returned
        // page's rows are resolved through the same memo. Nothing is cached
        // across pages: each request reads the provider again, so no page can
        // observe a stale history and no extra full array is kept alive between
        // requests.
        var resolution = ProjectResolutionMemo()
        let sessions = sessionProvider()
        // A page for at least half of the snapshot keeps the key-array path:
        // selection cannot beat sorting when the page is the size of the
        // history, and that also keeps the empty and single-row histories on
        // unchanged code.
        if limit >= sessions.count / 2 {
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
        // A normal page makes one O(N) pass over the history and sorts at most
        // `limit` 32-byte keys, then materialises only the returned page's
        // rows. A pass that cannot decide the request itself — a non-finite
        // timestamp or cursor interval, or a replacement work budget it
        // exceeded — answers the same request through the key-array path above
        // instead, which reuses the resolution memo this pass warmed, so it
        // neither resolves a project twice nor re-derives a different result
        // set.
        switch selectPage(
            query: query,
            from: sessions,
            cursor: cursor,
            limit: limit,
            resolution: &resolution
        ) {
        case .page(let page):
            return page
        case .cursorMiss:
            return nil
        case .fallbackToKeyArray:
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
            appendResolved(sessions[keys[offset].index], to: &page, resolution: &resolution)
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
    ///
    /// The snapshot is walked backwards. An append-only archive
    /// (`FocusSessionEngine` appends each session when it starts) is stored oldest
    /// first, so this emits the newest rows first — close to the display order
    /// for an archive that was never rewritten. The sort still runs
    /// unconditionally (there is no cached or assumed order); it just receives
    /// input that is one descending run in the common case, which measured 1.13×
    /// cheaper per page than sorting the same rows emitted in provider order
    /// (16,000 rows; 1.07× on a rewritten archive). The row index the sort key carries makes the resulting order
    /// identical either way, not merely equivalent for distinct keys.
    private func matchingKeys(
        query: FocusSessionQuery,
        in sessions: [FocusSession],
        resolution: inout ProjectResolutionMemo
    ) -> [DisplayOrderKey] {
        let filter = QueryRowFilter(query)
        var keys: [DisplayOrderKey] = []
        // Iterating the rows by value (`for session in sessions`) would copy
        // ~177 bytes and retain/release each row's reference-counted fields per
        // row, which is the dominant cost of this pass. Reading only the fields
        // the predicates and the key need out of the buffer avoids that copy.
        sessions.withUnsafeBufferPointer { buffer in
            keys.reserveCapacity(buffer.count)
            for index in buffer.indices.reversed() {
                guard rowMatches(filter, in: buffer, at: index, resolution: &resolution) else { continue }
                keys.append(DisplayOrderKey(
                    startedAt: buffer[index].startedAt,
                    id: buffer[index].id,
                    index: index
                ))
            }
        }
        return keys
    }

    /// Selects one page in a single pass without building or sorting a key array
    /// for the whole result set.
    ///
    /// Every matching row still counts towards `totalEstimatedCount`, and every
    /// matching row that sorts strictly after the cursor counts towards
    /// `hasMore`, but only the `limit` rows that sort earliest among those are
    /// kept: the pass holds their keys in one bounded array, so it uses O(limit)
    /// key storage and sorts at most `limit` keys. A later row that sorts before
    /// the current worst kept key takes its slot, and the slot of that worst key
    /// is tracked alongside it, so nothing else has to be maintained.
    ///
    /// Scan order carries more than either comparison: the snapshot is walked
    /// backwards, which for an append-only archive emits the newest rows first,
    /// so a full page is usually final after its first `limit` matching rows and
    /// every remaining row is rejected by one raw `Double` comparison.
    ///
    /// Cursor continuity is the same rule `makePage` applies: a row continues
    /// the walk only when its `(startedAt, id)` sorts strictly after the
    /// cursor's, so rows sharing both components with the cursor row stay
    /// unreachable through that cursor. When no matching row sorts strictly
    /// after the cursor the caller is told to restart pagination instead of
    /// silently truncating the remaining sessions.
    ///
    /// The pass answers a request itself only while its comparisons are defined
    /// and its replacement work stays bounded: a non-finite timestamp or cursor
    /// interval has no place in the fast reject's finite-value premise, and a
    /// work budget that is exceeded would cost more than the key-array path this
    /// pass exists to avoid. Both hand the request to that path
    /// (`.fallbackToKeyArray`) instead of being decided here, so the page, its
    /// counts and its cursor are exactly what they would have been without this
    /// method.
    private func selectPage(
        query: FocusSessionQuery,
        from sessions: [FocusSession],
        cursor: FocusSessionCursor?,
        limit: Int,
        resolution: inout ProjectResolutionMemo
    ) -> PageSelectionOutcome {
        // A non-finite cursor interval must be answered by the previous path,
        // which is also how it was always treated: the binary search finds no
        // row that sorts after a `NaN` key and lands on the first page, while the
        // scan below would find no row "strictly after" it at all and report
        // `.cursorMiss` instead. `-infinity` and `+infinity` are equally outside
        // the comparator's strict total order, so no non-finite cursor is
        // decided here either.
        if let cursor, !cursor.lastStartedAt.timeIntervalSinceReferenceDate.isFinite {
            return .fallbackToKeyArray
        }
        let filter = QueryRowFilter(query)
        // Every matching row, for `totalEstimatedCount`.
        var totalCount = 0
        // Matching rows that sort strictly after the cursor.
        var remainingCount = 0
        // The best `limit` keys seen so far, in scan order rather than display
        // order: only these are sorted, once, at the end of the pass.
        var kept: [DisplayOrderKey] = []
        kept.reserveCapacity(limit)
        // The slot and value of the key that sorts last among `kept`.
        //
        // `worstKey` is read only once the page is full, and reaching that state
        // always assigns it from `worstOf` first, so its initialiser is never
        // observed: it is a placeholder that keeps the declaration a plain
        // non-optional, so the per-row comparison needs no unwrap. `.distantPast`
        // is what "no worst key yet" would mean anyway, and the id and index are
        // what any unwritten value would carry.
        var worstIndex = 0
        var worstKey = DisplayOrderKey(startedAt: .distantPast, id: UUID(), index: .max)
        // `worstKey.startedAt` as the raw interval the reject below compares, so
        // the per-row test touches one stored `Double` instead of calling into
        // Foundation. `-infinity` is the "page not full yet" sentinel: no
        // finite interval is strictly older than it, so every row is offered
        // until `kept` holds `limit` keys. A non-finite row never reaches this
        // comparison, because the guard above the cursor test routes it to the
        // key-array path.
        var worstInterval = -Double.infinity
        // Beating the worst kept key is rare on a real layout, but each
        // replacement rescans `kept`, so a layout that keeps beating it would
        // turn this pass into O(N × limit) work while never exceeding a budget
        // that counted replacements. The budget therefore counts the work those
        // rescans cost: every replacement adds the `limit`-sized rescan it pays
        // for, so total selection work stays within `4 × rows` — a layout that
        // keeps beating the worst kept key costs at most one bounded extra pass
        // plus the previous key-array path, and the page result is identical
        // either way, because that path is the previous implementation.
        //
        // For scale: a real archive replaces nothing at all, and the `shuffled`
        // random-order proxy needs ≈ `limit·ln(N/limit)` comparisons — ≈ 14,350
        // at 16,000 rows and ≈ 12,650 at 8,000, both well under `4 × N`, so the
        // fast path stays in use there. A 2,000-row shuffled snapshot (≈ 9,200
        // against a 8,000 budget) falls back instead, which is acceptable.
        // `sessions.count` is the provider's row count, so the bound is
        // proportional to the snapshot and not to the page size.
        let workBudget = sessions.count > Int.max / 4 ? Int.max : sessions.count * 4
        var replacementWork = 0
        var fellBackToKeyArray = false
        // Iterating the rows by value (`for session in sessions`) would copy
        // ~177 bytes and retain/release each row's reference-counted fields per
        // row, which is the dominant cost of this pass. Reading only the fields
        // the predicates and the key need out of the buffer avoids that copy.
        sessions.withUnsafeBufferPointer { buffer in
            for index in buffer.indices.reversed() {
                guard rowMatches(filter, in: buffer, at: index, resolution: &resolution) else { continue }
                let startedAt = buffer[index].startedAt
                let id = buffer[index].id
                let interval = startedAt.timeIntervalSinceReferenceDate
                // The finiteness guard runs before the cursor test rather than
                // in the fast reject: every `startedAt` comparison against a
                // `NaN` row is false, so a cursor test placed first would
                // `continue` past that row and the fallback would never be
                // decided for it — the pass would then answer a request whose
                // order the comparator does not define. Testing it here means
                // every matching row that reaches the cursor test, and so every
                // row the selection below sees, has a finite interval.
                guard interval.isFinite else {
                    fellBackToKeyArray = true
                    return
                }
                totalCount += 1
                if let cursor {
                    let afterCursor = startedAt < cursor.lastStartedAt
                        || (startedAt == cursor.lastStartedAt && id > cursor.lastID)
                    guard afterCursor else { continue }
                }
                remainingCount += 1
                // Fast reject. `Date` stores its interval as one `Double` and
                // `<` compares exactly that stored value, so for finite
                // intervals `interval < worstInterval` holds exactly when
                // `key.startedAt < worstKey.startedAt`: this row sorts after the
                // worst kept key, so it cannot be on this page and
                // `DisplayOrderKey.precedes` would reject it too. One raw
                // `Double` comparison replaces the cross-module `Date` and
                // `UUID` operations `precedes` performs, which is what makes an
                // already ordered scan cheap.
                //
                // A false answer decides nothing: the row still goes through the
                // full `precedes` comparison below. So a row whose timestamp
                // equals the worst key's is not rejected here (the `UUID`
                // tie-break, then the row index, still decide it), and an equal
                // `UUID` is not rejected.
                //
                // The premise is finite intervals: only then does `a < b` imply
                // `Date(a) != Date(b)` and that `Date(a) > Date(b)` is false,
                // i.e. that the row sorts strictly after the worst kept key.
                // Non-finite values break exactly that (`-infinity < 0` is true,
                // and `NaN` makes every comparison false, so the bounded
                // selection would decide rows the comparator gives no order
                // for), so such a row is routed to the previous key-array path
                // instead of being decided by a comparison that does not mean
                // what the reject assumes. That guard therefore sits before the
                // cursor test, precisely so that a non-finite row cannot be
                // dropped by a cursor comparison — all of its comparisons are
                // false — before the fallback is decided, and the reject below
                // consequently only ever sees finite intervals.
                //
                // The premise itself rests on `Date` storing its interval as one
                // `Double` and comparing exactly that value, which is the current
                // Foundation implementation: a representation change that kept
                // the ordering relation would only cost speed (the reject stops
                // firing and `precedes` still decides), while one that changed
                // the relation would cost correctness — which is why non-finite
                // input is excluded here rather than reasoned about.
                if interval < worstInterval { continue }
                let key = DisplayOrderKey(startedAt: startedAt, id: id, index: index)
                if kept.count < limit {
                    kept.append(key)
                    if kept.count == limit {
                        let worst = worstOf(kept)
                        worstIndex = worst.index
                        worstKey = worst.key
                        worstInterval = worst.key.startedAt.timeIntervalSinceReferenceDate
                    }
                    continue
                }
                guard DisplayOrderKey.precedes(key, worstKey) else { continue }
                // The replacement is about to pay for one `limit`-sized rescan.
                replacementWork += kept.count
                guard replacementWork <= workBudget else {
                    fellBackToKeyArray = true
                    return
                }
                kept[worstIndex] = key
                let worst = worstOf(kept)
                worstIndex = worst.index
                worstKey = worst.key
                worstInterval = worst.key.startedAt.timeIntervalSinceReferenceDate
            }
        }

        if fellBackToKeyArray { return .fallbackToKeyArray }
        guard remainingCount > 0 else {
            // No matching row sorts strictly after the cursor: a cursor request
            // signals a restart, a cursor-free request is an empty result set.
            return cursor == nil ? .page(.empty) : .cursorMiss
        }
        let selected = kept.sorted(by: DisplayOrderKey.precedes)
        var page: [FocusSession] = []
        page.reserveCapacity(selected.count)
        for key in selected {
            appendResolved(sessions[key.index], to: &page, resolution: &resolution)
        }
        // The last kept key is the one the cursor continues from; it exists
        // whenever the page is not the last one, because `limit` is positive.
        let hasMore = remainingCount > selected.count
        let last = selected.last
        return .page(FocusSessionQueryPage(
            sessions: page,
            nextCursor: hasMore
                ? last.map { FocusSessionCursor(lastStartedAt: $0.startedAt, lastID: $0.id) }
                : nil,
            hasMore: hasMore,
            totalEstimatedCount: totalCount
        ))
    }

    /// The slot and value of the key that sorts last in display order among
    /// `keys`, i.e. the one every other kept key precedes.
    ///
    /// A replacement re-derives it in O(limit) instead of running one
    /// logarithmic comparison per offered row: the page is full after `limit`
    /// rows, replacements are rare on a real layout, and this scan only reads
    /// keys that already won a page slot.
    /// `DisplayOrderKey.precedes` is a strict total order within one snapshot
    /// (the row index breaks the remaining ties), so the last key is unique.
    /// `keys` must not be empty.
    @inline(__always)
    private func worstOf(_ keys: [DisplayOrderKey]) -> (index: Int, key: DisplayOrderKey) {
        var worstIndex = 0
        var worstKey = keys[0]
        for index in keys.indices.dropFirst() where DisplayOrderKey.precedes(worstKey, keys[index]) {
            worstIndex = index
            worstKey = keys[index]
        }
        return (worstIndex, worstKey)
    }

    /// The one definition of which rows a query matches, shared by both page
    /// paths so they cannot diverge: the day window, then the status, then — only
    /// for a query with project predicates — the memoised project identity.
    ///
    /// The row-local tests come first because they are cheap: a project lookup
    /// scans the registry's identity graph, so it must not run for a row that
    /// already failed them. The project context is read out of the buffer only on
    /// that path, because copying it would retain two strings per row.
    @inline(__always)
    private func rowMatches(
        _ filter: QueryRowFilter,
        in buffer: UnsafeBufferPointer<FocusSession>,
        at index: Int,
        resolution: inout ProjectResolutionMemo
    ) -> Bool {
        if let dayStart = filter.dayStart, buffer[index].dayIdentifier < dayStart { return false }
        if let dayEnd = filter.dayEnd, buffer[index].dayIdentifier > dayEnd { return false }
        if let status = filter.status, buffer[index].status != status { return false }
        guard filter.needsProjectPredicates else { return true }
        let project = resolution.resolve(buffer[index].project, using: projectResolver)
        return resolution.matchesFilters(
            project,
            query: filter.query,
            loweredKeyword: filter.loweredKeyword
        )
    }

    /// Appends one row to a page with the pass's resolved project identity.
    ///
    /// The row is copied only when resolution changed its project; the common
    /// case (an identity-authority projection that returns the stored context)
    /// appends the snapshot's own value.
    @inline(__always)
    private func appendResolved(
        _ session: FocusSession,
        to page: inout [FocusSession],
        resolution: inout ProjectResolutionMemo
    ) {
        let project = resolution.resolve(session.project, using: projectResolver)
        if project == session.project {
            page.append(session)
        } else {
            var row = session
            row.project = project
            page.append(row)
        }
    }
}
