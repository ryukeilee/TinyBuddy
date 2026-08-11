import Foundation

/// Decides when the Widget should schedule its own next timeline refresh,
/// independent of app-side push reloads.
///
/// The Widget historically used `policy: .never` and relied entirely on the
/// app calling `reloadAllTimelines()` after every semantic change. That works
/// while the app is running, but it leaves the Widget frozen when the app is
/// not reloading it: a live focus session's elapsed minutes stop advancing if
/// the app's per-minute reload is coalesced or dropped, and a stale snapshot
/// never recovers until the app happens to reload.
///
/// This policy keeps the budget-conscious `.never` behavior for stable states
/// (idle with data, completed, authorization errors, …) while scheduling a
/// bounded `.after` refresh only when a state actually needs one:
///
/// - A live (active or paused) focus session schedules a bounded refresh so
///   the elapsed metric advances on the Widget's own cadence instead of the
///   app reloading every minute.
/// - A stale or still-loading snapshot retries on a slow cadence so the
///   Widget self-heals toward the authoritative combined snapshot once fresh
///   data is committed, even when the app is not running.
/// - A neutral idle entry that carries no renderable data (no Git activity
///   fields and no focus-history publication) retries on the same slow
///   cadence. Such an entry is a placeholder built before the app published
///   today's data — the prebuilt midnight rollover and the first-launch
///   fallback are the canonical examples — so the Widget must re-read the
///   authoritative snapshot instead of staying on `.never` until an app-side
///   reload happens to arrive.
///
/// In-day self-scheduling never passes the local-day boundary: the prebuilt
/// midnight rollover entry owns that transition. `nextRolloverProbeDate`
/// covers the other half of the gap: when the rollover entry itself carries
/// no data, a single bounded re-probe shortly after the boundary lets the
/// Widget pick up the new day's committed snapshot on its own cadence if the
/// app-side reload is missing or failed.
public enum TinyBuddyWidgetTimelinePolicy {
    /// Cadence while a session is live. Bounded so a multi-hour focus session
    /// stays inside WidgetKit's daily refresh budget, leaving room for the
    /// start/stop/pause transition reloads that must stay timely. A 2-minute
    /// cadence keeps the displayed elapsed whole minutes within ~2 minutes of
    /// the HUD without burning the budget on a per-minute self-refresh.
    public static let liveFocusRefreshInterval: TimeInterval = 2 * 60

    /// Retry cadence for recoverable stale/loading states. Slow enough to stay
    /// inside WidgetKit's refresh budget while still self-healing promptly
    /// once the app (or a dropped reload) makes fresh data visible.
    public static let staleRecoveryRefreshInterval: TimeInterval = 5 * 60

    /// Absolute floor enforced before any self-scheduled refresh, so a
    /// transient state can never turn into a tight refresh loop.
    public static let minimumRefreshInterval: TimeInterval = 30

    /// Returns the date of the next self-scheduled widget refresh, or `nil`
    /// when the widget should stay on `policy: .never` (push reloads plus the
    /// prebuilt midnight rollover entry are enough).
    ///
    /// - Parameters:
    ///   - state: The resolved cross-surface display state.
    ///   - isFocusSessionActive: Whether the authoritative publication has a
    ///     running session (from `FocusHistoryPublication.isFocusSessionActive`).
    ///   - isFocusSessionPaused: Whether the authoritative publication has an
    ///     open-but-paused session.
    ///   - hasRenderableData: Whether the current entry carries any data the
    ///     view could render (a Git activity field or a focus-history
    ///     publication). A neutral idle entry without data is a placeholder
    ///     and must re-probe; a genuinely empty day still renders its zero
    ///     metrics and stays push-only.
    ///   - now: The current timeline instant.
    ///   - dayBoundary: The next local-day boundary; the returned date is
    ///     clamped so it never reaches or passes it.
    public static func nextRefreshDate(
        state: TinyBuddyDisplayState,
        isFocusSessionActive: Bool,
        isFocusSessionPaused: Bool,
        hasRenderableData: Bool = true,
        now: Date,
        dayBoundary: Date
    ) -> Date? {
        let interval: TimeInterval
        if isFocusSessionActive || isFocusSessionPaused {
            // A live session advances its elapsed whole-minute display. The
            // Widget owns this bounded cadence; the app only reloads on
            // transitions, keeping WidgetKit's refresh budget for the
            // start/stop/pause reloads that must stay timely.
            interval = liveFocusRefreshInterval
        } else {
            switch state {
            case .stale, .loading:
                // Recoverable unavailability: keep probing the authoritative
                // combined snapshot so the Widget aligns once conditions heal.
                interval = staleRecoveryRefreshInterval
            case .idle where hasRenderableData == false:
                // Neutral placeholder (prebuilt rollover, first launch, or a
                // pet-slice-only snapshot before the activity/history slices
                // are published): re-read the authoritative snapshot on the
                // recovery cadence so committed data starts rendering without
                // waiting for an app-side reload.
                interval = staleRecoveryRefreshInterval
            default:
                return nil
            }
        }

        guard interval >= minimumRefreshInterval,
              now.addingTimeInterval(interval) < dayBoundary else {
            return nil
        }
        return now.addingTimeInterval(interval)
    }

    /// Returns the date of a single bounded re-probe after the local-day
    /// boundary, or `nil` when the prebuilt rollover entry already carries
    /// data (then the rollover itself is the correct display and stays
    /// push-only). The rollover entry is built before the new day's data can
    /// exist, so when it is a neutral placeholder the Widget must re-read the
    /// authoritative snapshot shortly after the boundary instead of waiting
    /// indefinitely for an app-side reload.
    ///
    /// - Parameters:
    ///   - dayBoundary: The local-day boundary the rollover entry owns.
    ///   - hasRenderableData: Whether the rollover entry carries any data the
    ///     view could render.
    public static func nextRolloverProbeDate(
        dayBoundary: Date,
        hasRenderableData: Bool
    ) -> Date? {
        guard hasRenderableData == false else {
            return nil
        }
        return dayBoundary.addingTimeInterval(staleRecoveryRefreshInterval)
    }
}
