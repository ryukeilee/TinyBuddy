import Foundation
import OSLog
import TinyBuddyCore

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
    func refresh() async {
        let opID = nextOperationID()
        loadState = .loading
        allSessions.removeAll()

        let page = await queryService.execute(
            query: query,
            cursor: nil,
            limit: pageSize,
            version: opID
        )

        guard let page, isLatest(opID) else { return }
        allSessions = page.sessions
        loadState = .loaded(page)
    }

    /// Appends the next page when available.
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

        guard let page, isLatest(opID) else { return }
        allSessions.append(contentsOf: page.sessions)

        // Preserve original total estimate from first page.
        let merged = FocusSessionQueryPage(
            sessions: allSessions,
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            totalEstimatedCount: currentPage.totalEstimatedCount
        )
        loadState = .loaded(merged)
    }

    /// Updates the query filter and reloads from scratch, with debouncing.
    /// Pass `debounceSeconds: 0` for immediate execution.
    func updateQuery(_ newQuery: FocusSessionQuery, debounceSeconds: TimeInterval = 0.3) async {
        query = newQuery

        guard debounceSeconds > 0 else {
            await refresh()
            return
        }

        // Wait for the debounce interval. If another update arrives during
        // the wait, the cancelled Task will drop this continuation.
        do {
            try await Task.sleep(for: .seconds(debounceSeconds))
        } catch {
            // Task was cancelled — a newer update is pending.
            return
        }

        // Check that no newer update already completed.
        guard isLatest(operationID + 1) else { return }
        await refresh()
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
}
