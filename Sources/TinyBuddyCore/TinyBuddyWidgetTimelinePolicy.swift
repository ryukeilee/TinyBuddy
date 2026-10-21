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
/// - A genuine snapshot read failure (`.readFailed`, e.g. a corrupt blob, a
///   denied sandbox read, or a persistence fault) retries on a bounded ladder
///   of 5 / 20 / 80 minutes, at most three probes per local day. A read
///   failure can be transient (the app commits a fresh snapshot, a container
///   gets repaired), so the Widget needs its own bounded recovery path; the
///   budget keeps a permanent failure from degenerating into polling.
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

    /// Bounded recovery ladder for a genuine snapshot read failure. Each
    /// element is the delay before the next in-day probe; the ladder is short
    /// (maximum three probes per local day) so an immediate transient failure
    /// recovers on its own while a permanent one stops asking for wakeups.
    public static let readFailureProbeIntervals: [TimeInterval] = [
        5 * 60,
        20 * 60,
        80 * 60,
    ]

    /// Hard cap on `.readFailed` self-healing probes per local day. Exhausting
    /// it leaves only app push reloads and the midnight rollover probe.
    public static var maximumReadFailureProbeCount: Int {
        readFailureProbeIntervals.count
    }

    /// Reasons that cannot heal by re-reading the snapshot. A version-
    /// incompatible payload needs the app (or a new build) to rewrite it, so
    /// the Widget must not spend its refresh budget probing for it.
    public static func isPermanentReadFailure(
        _ reason: TinyBuddySharedSnapshotReason?
    ) -> Bool {
        reason == .versionIncompatible
    }

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
    ///   - readFailureReason: The snapshot read-failure reason behind a
    ///     `.readFailed` state, if known. Only used to suppress probes for
    ///     permanent causes such as a version-incompatible payload.
    ///   - readFailureProbeCountUsed: How many `.readFailed` probes have
    ///     already been scheduled for the current local day. The caller owns
    ///     persistence; the policy stays a pure decision.
    ///   - now: The current timeline instant.
    ///   - dayBoundary: The next local-day boundary; the returned date is
    ///     clamped so it never reaches or passes it.
    public static func nextRefreshDate(
        state: TinyBuddyDisplayState,
        isFocusSessionActive: Bool,
        isFocusSessionPaused: Bool,
        hasRenderableData: Bool = true,
        readFailureReason: TinyBuddySharedSnapshotReason? = nil,
        readFailureProbeCountUsed: Int = 0,
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
            case .readFailed:
                // A read failure is not necessarily permanent: the app may
                // rewrite a corrupt or unreachable snapshot. Probe on the
                // bounded ladder, then stop for the rest of the local day.
                let usedProbeCount = max(0, readFailureProbeCountUsed)
                guard isPermanentReadFailure(readFailureReason) == false,
                      usedProbeCount < readFailureProbeIntervals.count else {
                    return nil
                }
                interval = readFailureProbeIntervals[usedProbeCount]
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

/// Pure bookkeeping for the bounded `.readFailed` probe ladder.
///
/// The budget is scoped to a local day: the first probe recorded for a new day
/// resets the count, so yesterday's exhausted ladder can never suppress today's
/// recovery probes. It holds no storage itself — the Widget extension persists
/// it in its own `UserDefaults` domain so a Widget process restart does not
/// reset the budget while a snapshot read keeps failing.
public struct TinyBuddyWidgetReadFailureProbeState: Equatable, Sendable {
    /// The local-day identifier the stored count belongs to.
    public let dayIdentifier: String
    /// Probes already scheduled for that day.
    public let probeCount: Int

    public init(dayIdentifier: String, probeCount: Int) {
        self.dayIdentifier = dayIdentifier
        self.probeCount = max(0, probeCount)
    }

    /// The probe count that applies to `dayIdentifier`. A different day means a
    /// fresh budget; a day change also discards a stored count from the past.
    public func probeCount(on dayIdentifier: String) -> Int {
        self.dayIdentifier == dayIdentifier ? probeCount : 0
    }

    /// Records one scheduled probe for `dayIdentifier`, resetting the day and
    /// therefore the count when the local day advanced.
    public func recordingProbe(on dayIdentifier: String) -> Self {
        Self(
            dayIdentifier: dayIdentifier,
            probeCount: probeCount(on: dayIdentifier) + 1
        )
    }
}
