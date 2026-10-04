import Foundation
import OSLog
import TinyBuddyCore

enum HistoryDateFilterField: Equatable {
    case start
    case end

    var label: String {
        switch self {
        case .start: return "开始日期"
        case .end: return "结束日期"
        }
    }
}

enum HistoryDateFilterValidationError: Error, Equatable {
    case invalidFormat(HistoryDateFilterField)
    case invalidDate(HistoryDateFilterField)
    case reversedRange

    var message: String {
        switch self {
        case .invalidFormat(let field):
            return "\(field.label)格式无效，请使用 yyyy-MM-dd。"
        case .invalidDate(let field):
            return "\(field.label)不是有效的日历日期。"
        case .reversedRange:
            return "开始日期不能晚于结束日期。"
        }
    }
}

/// Presets produce only the existing inclusive day bounds, with no persistent selection state.
enum HistoryDateFilterPreset: CaseIterable {
    case today
    case thisWeek
    case lastSevenDays

    var label: String {
        switch self {
        case .today: return "今天"
        case .thisWeek: return "本周"
        case .lastSevenDays: return "最近 7 天"
        }
    }

    func bounds(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> (start: String, end: String)? {
        guard let context = TinyBuddyTimeEnvironment(calendar: calendar, dateProvider: { now }).capture() else {
            return nil
        }
        // Business day keys are Gregorian; retain the user's local week convention.
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = context.timeZone
        localCalendar.firstWeekday = calendar.firstWeekday
        localCalendar.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        let today = localCalendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch self {
        case .today:
            start = today
            end = today
        case .thisWeek:
            guard let week = localCalendar.dateInterval(of: .weekOfYear, for: today),
                  let lastDay = localCalendar.date(byAdding: .day, value: -1, to: week.end) else { return nil }
            start = week.start
            end = lastDay
        case .lastSevenDays:
            guard let firstDay = localCalendar.date(byAdding: .day, value: -6, to: today) else { return nil }
            start = firstDay
            end = today
        }
        guard let dayStart = context.dayIdentifier(for: start),
              let dayEnd = context.dayIdentifier(for: end) else { return nil }
        return (dayStart, dayEnd)
    }
}

enum HistoryDateFilterValidator {
    static func validate(
        _ query: FocusSessionQuery
    ) -> Result<FocusSessionQuery, HistoryDateFilterValidationError> {
        var validatedQuery = query

        if let dayStart = query.dayStart, !dayStart.isEmpty {
            guard hasExpectedFormat(dayStart) else {
                return .failure(.invalidFormat(.start))
            }
            guard isRealGregorianDate(dayStart) else {
                return .failure(.invalidDate(.start))
            }
        } else {
            validatedQuery.dayStart = nil
        }

        if let dayEnd = query.dayEnd, !dayEnd.isEmpty {
            guard hasExpectedFormat(dayEnd) else {
                return .failure(.invalidFormat(.end))
            }
            guard isRealGregorianDate(dayEnd) else {
                return .failure(.invalidDate(.end))
            }
        } else {
            validatedQuery.dayEnd = nil
        }

        if let dayStart = validatedQuery.dayStart,
           let dayEnd = validatedQuery.dayEnd,
           dayStart > dayEnd {
            return .failure(.reversedRange)
        }

        return .success(validatedQuery)
    }

    private static func hasExpectedFormat(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else {
            return false
        }
        return bytes.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 || (48 ... 57).contains(byte)
        }
    }

    private static func isRealGregorianDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let year = Int(bytes[0] - 48) * 1_000
            + Int(bytes[1] - 48) * 100
            + Int(bytes[2] - 48) * 10
            + Int(bytes[3] - 48)
        let month = Int(bytes[5] - 48) * 10 + Int(bytes[6] - 48)
        let day = Int(bytes[8] - 48) * 10 + Int(bytes[9] - 48)
        guard year > 0, (1 ... 12).contains(month), (1 ... 31).contains(day),
              let timeZone = TimeZone(secondsFromGMT: 0) else {
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = timeZone
        guard let date = calendar.date(from: components) else { return false }

        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }
}

// MARK: - History Query Controller

/// `@Observable` controller that provides a SwiftUI-friendly, cancellable,
/// paginated interface over `FocusSessionQueryService`.
///
/// ## Stale-Query Prevention
///
/// Each `refresh()` / `loadMore()` call acquires a monotonic `operationID`.
/// When the async query completes, the result is only applied if the current
/// `operationID` still matches. This prevents old results from overwriting
/// newer ones when queries complete out of order.
///
/// ## Debouncing
///
/// `updateQuery(_:)` debounces rapid filter changes by waiting a short
/// interval before issuing the query. If a newer change arrives during the
/// wait, the previous query is implicitly discarded.
@MainActor
@Observable
final class HistoryQueryController {
    /// The current load state visible to the view.
    private(set) var loadState: FocusSessionLoadState = .idle

    /// All sessions accumulated across pages, in display order (newest first).
    private(set) var allSessions: [FocusSession] = []

    /// The currently active query filter.
    private(set) var query: FocusSessionQuery = .init()

    // MARK: - Private State

    /// Monotonic operation ID. Each new operation increments it;
    /// only the latest operation's result may update `loadState`.
    private var operationID = 0

    /// The underlying query service.
    private let queryService: FocusSessionQueryService

    /// Default page size.
    private let pageSize = 50

    /// How many times `refresh()` re-executes after the service invalidated
    /// the query mid-flight before surfacing a `.failure` state.
    private let maxRefreshAttempts = 3

    private let logger = Logger(
        subsystem: "com.ryukeili.TinyBuddy",
        category: "HistoryQueryController"
    )

    // MARK: - Init

    init(queryService: FocusSessionQueryService) {
        self.queryService = queryService
    }

    // MARK: - Public API

    /// Loads the first page. Resets accumulated state.
    ///
    /// When the service reports the query version as stale (data changed
    /// while the query was in flight), retries with a fresh operation ID —
    /// the service version only grows, so the same ID could never succeed.
    /// After exhausting the retry budget while still being the newest
    /// operation, surfaces `.failure` instead of leaving the UI stuck in
    /// `.loading`.
    func refresh() async {
        loadState = .loading
        allSessions.removeAll()

        var lastOpID = 0
        for _ in 0 ..< maxRefreshAttempts {
            lastOpID = nextOperationID()
            let page = await queryService.execute(
                query: query,
                cursor: nil,
                limit: pageSize,
                version: lastOpID
            )

            if let page {
                guard isLatest(lastOpID) else { return }
                allSessions = page.sessions
                loadState = .loaded(page)
                return
            }

            // Version was bumped while this query was in flight. A newer
            // operation owns the state; otherwise retry with a fresh ID.
            guard isLatest(lastOpID) else { return }
        }

        // Retries exhausted while remaining the newest operation: fail
        // visibly so the error view (with its retry button) becomes reachable.
        loadState = .failure("查询多次失效，请点击重试。")
    }

    /// Appends the next page when available.
    ///
    /// When the service returns nil (version bumped mid-pagination or the
    /// cursor no longer matches the current data set), restarts pagination
    /// from the first page instead of silently freezing the loading state.
    /// Appended pages are deduplicated by id and re-sorted into the canonical
    /// display order so data changed between pages cannot produce duplicate
    /// rows or order jumps.
    func loadMore() async {
        guard case .loaded(let currentPage) = loadState, currentPage.hasMore,
              let cursor = currentPage.nextCursor else { return }

        let opID = nextOperationID()
        loadState = .loading

        let page = await queryService.execute(
            query: query,
            cursor: cursor,
            limit: pageSize,
            version: opID
        )

        guard let page else {
            // Continuity broken: restart from the first page rather than
            // leaving the loading indicator stuck or truncating silently.
            guard isLatest(opID) else { return }
            await refresh()
            return
        }

        guard isLatest(opID) else { return }
        allSessions.append(contentsOf: page.sessions)

        // Guard against duplicates/order jumps when data changed between
        // pages without invalidating the query.
        let mergedSessions = deduplicatedAndSorted(allSessions)
        allSessions = mergedSessions

        // Preserve original total estimate from first page.
        let merged = FocusSessionQueryPage(
            sessions: mergedSessions,
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            totalEstimatedCount: currentPage.totalEstimatedCount
        )
        loadState = .loaded(merged)
    }

    /// Updates the query filter and reloads from scratch, with debouncing.
    /// Pass `debounceSeconds: 0` for immediate execution.
    ///
    /// The debounce wait claims the operation ID up front, so rapid filter
    /// changes supersede each other while still sleeping: stale continuations
    /// drop out without issuing redundant full queries.
    func updateQuery(_ newQuery: FocusSessionQuery, debounceSeconds: TimeInterval = 0.3) async {
        query = newQuery

        guard debounceSeconds > 0 else {
            await refresh()
            return
        }

        // Claim now so a newer update invalidates this one before the wait
        // finishes, even though this Task cannot be cancelled by the caller.
        let claimed = nextOperationID()

        // Wait for the debounce interval. If another update arrives during
        // the wait, the cancelled Task would drop this continuation.
        do {
            try await Task.sleep(for: .seconds(debounceSeconds))
        } catch {
            // Task was cancelled — a newer update is pending or the view left.
            return
        }

        // Only the most recent update survives the debounce wait.
        guard isLatest(claimed) else { return }
        await refresh()
    }

    /// Validates the App history date filter before changing the active query.
    /// Invalid dates leave both the current query and its loaded results intact.
    func updateQuery(
        validatingDateFilter proposedQuery: FocusSessionQuery,
        debounceSeconds: TimeInterval = 0
    ) async -> HistoryDateFilterValidationError? {
        switch HistoryDateFilterValidator.validate(proposedQuery) {
        case .success(let validatedQuery):
            await updateQuery(validatedQuery, debounceSeconds: debounceSeconds)
            return nil
        case .failure(let error):
            return error
        }
    }

    /// Clears only the date bounds while retaining the other supplied filters.
    func clearDateFilter(in proposedQuery: FocusSessionQuery) async {
        var clearedQuery = proposedQuery
        clearedQuery.dayStart = nil
        clearedQuery.dayEnd = nil
        await updateQuery(clearedQuery, debounceSeconds: 0)
    }

    /// Reloads the current query from scratch (used after edits).
    func reload() async {
        await refresh()
    }

    /// Tells the query service that underlying data has changed.
    func notifyChanges(_ changes: [FocusSessionChangeType]) async {
        await queryService.applyChanges(changes)
    }

    // MARK: - Private

    private func nextOperationID() -> Int {
        operationID += 1
        return operationID
    }

    private func isLatest(_ opID: Int) -> Bool {
        opID >= operationID
    }

    /// Removes duplicate sessions (by id) and restores the canonical display
    /// order (startedAt descending, then id.uuidString ascending) after pages
    /// accumulated across data mutations.
    private func deduplicatedAndSorted(_ sessions: [FocusSession]) -> [FocusSession] {
        var seen = Set<UUID>()
        seen.reserveCapacity(sessions.count)
        var unique: [FocusSession] = []
        unique.reserveCapacity(sessions.count)
        for session in sessions where seen.insert(session.id).inserted {
            unique.append(session)
        }

        // Static data keeps canonical order across pages; only re-sort when
        // the accumulation drifted (data changed between pages).
        if isCanonicallyOrdered(unique) {
            return unique
        }
        return unique.sorted { a, b in
            if a.startedAt != b.startedAt {
                return a.startedAt > b.startedAt
            }
            return a.id.uuidString < b.id.uuidString
        }
    }

    private func isCanonicallyOrdered(_ sessions: [FocusSession]) -> Bool {
        guard sessions.count > 1 else { return true }
        for i in 1 ..< sessions.count {
            let previous = sessions[i - 1]
            let current = sessions[i]
            if current.startedAt > previous.startedAt {
                return false
            }
            if current.startedAt == previous.startedAt,
               current.id.uuidString < previous.id.uuidString {
                return false
            }
        }
        return true
    }
}
