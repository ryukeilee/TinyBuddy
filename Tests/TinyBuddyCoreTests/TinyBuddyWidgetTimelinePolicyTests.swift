import Foundation
import XCTest
@testable import TinyBuddyCore

final class TinyBuddyWidgetTimelinePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let dayBoundary = Date(timeIntervalSince1970: 1_700_000_000 + 86_400)

    // MARK: - Live focus self-scheduling

    func testActiveFocusSessionSchedulesBoundedLiveRefresh() {
        XCTAssertEqual(TinyBuddyWidgetTimelinePolicy.liveFocusRefreshInterval, 120)
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .focusing,
            isFocusSessionActive: true,
            isFocusSessionPaused: false,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(date, now.addingTimeInterval(120))
    }

    func testPausedLiveSessionStillSchedulesRefresh() {
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .paused,
            isFocusSessionActive: false,
            isFocusSessionPaused: true,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(date, now.addingTimeInterval(TinyBuddyWidgetTimelinePolicy.liveFocusRefreshInterval))
    }

    func testLiveFocusRefreshWinsOverOtherStates() {
        // A live session always self-schedules even when the resolved state is
        // a data-quality state that would otherwise stay push-only.
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .stale,
            isFocusSessionActive: true,
            isFocusSessionPaused: false,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(date, now.addingTimeInterval(TinyBuddyWidgetTimelinePolicy.liveFocusRefreshInterval))
    }

    // MARK: - Recoverable stale/loading retry

    func testStaleStateRetriesOnSlowCadence() {
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .stale,
            isFocusSessionActive: false,
            isFocusSessionPaused: false,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(date, now.addingTimeInterval(TinyBuddyWidgetTimelinePolicy.staleRecoveryRefreshInterval))
    }

    func testLoadingStateRetriesOnSlowCadence() {
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .loading,
            isFocusSessionActive: false,
            isFocusSessionPaused: false,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(date, now.addingTimeInterval(TinyBuddyWidgetTimelinePolicy.staleRecoveryRefreshInterval))
    }

    // MARK: - Stable states stay push-only

    func testStableStatesReturnNilForPushOnlyRefresh() {
        let stableStates: [TinyBuddyDisplayState] = [
            .idle,
            .completedToday,
            .noActivity,
            .noRepositories,
            .authorizationRequired,
            .authorizationInvalid,
            .partial,
        ]
        for state in stableStates {
            let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: state,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                now: now,
                dayBoundary: dayBoundary
            )
            XCTAssertNil(date, "state \(state.rawValue) must not self-schedule a refresh")
        }
    }

    // MARK: - Bounded read-failure self-healing

    func testReadFailureProbeLadderIsBoundedAndDocumented() {
        XCTAssertEqual(
            TinyBuddyWidgetTimelinePolicy.readFailureProbeIntervals,
            [5 * 60, 20 * 60, 80 * 60]
        )
        XCTAssertEqual(TinyBuddyWidgetTimelinePolicy.maximumReadFailureProbeCount, 3)
        for interval in TinyBuddyWidgetTimelinePolicy.readFailureProbeIntervals {
            XCTAssertGreaterThanOrEqual(
                interval,
                TinyBuddyWidgetTimelinePolicy.minimumRefreshInterval
            )
        }
    }

    func testReadFailedStateSchedulesOneProbePerLadderStep() {
        for (usedProbeCount, expectedInterval) in
            TinyBuddyWidgetTimelinePolicy.readFailureProbeIntervals.enumerated() {
            let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .readFailed,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                readFailureProbeCountUsed: usedProbeCount,
                now: now,
                dayBoundary: dayBoundary
            )
            XCTAssertEqual(
                date,
                now.addingTimeInterval(expectedInterval),
                "probe \(usedProbeCount) must use its documented ladder step"
            )
        }
    }

    func testExhaustedReadFailureBudgetStopsInDayProbes() {
        // The ladder is a budget, not a poll: once all probes are spent the
        // Widget waits for an app push reload or the midnight rollover probe.
        XCTAssertNil(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .readFailed,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                readFailureProbeCountUsed: TinyBuddyWidgetTimelinePolicy
                    .maximumReadFailureProbeCount,
                now: now,
                dayBoundary: dayBoundary
            )
        )
        XCTAssertNil(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .readFailed,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                readFailureProbeCountUsed: TinyBuddyWidgetTimelinePolicy
                    .maximumReadFailureProbeCount + 5,
                now: now,
                dayBoundary: dayBoundary
            )
        )
    }

    func testPermanentReadFailureNeverSchedulesProbes() {
        // A version-incompatible payload cannot heal from re-reading it, so no
        // step of the ladder is available for it.
        XCTAssertTrue(
            TinyBuddyWidgetTimelinePolicy.isPermanentReadFailure(.versionIncompatible)
        )
        for usedProbeCount in 0..<TinyBuddyWidgetTimelinePolicy.maximumReadFailureProbeCount {
            XCTAssertNil(
                TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                    state: .readFailed,
                    isFocusSessionActive: false,
                    isFocusSessionPaused: false,
                    readFailureReason: .versionIncompatible,
                    readFailureProbeCountUsed: usedProbeCount,
                    now: now,
                    dayBoundary: dayBoundary
                ),
                "probe \(usedProbeCount) must not be spent on a permanent failure"
            )
        }
        // Transient causes keep the ladder.
        XCTAssertFalse(
            TinyBuddyWidgetTimelinePolicy.isPermanentReadFailure(.snapshotCorrupt)
        )
        XCTAssertNotNil(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .readFailed,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                readFailureReason: .snapshotCorrupt,
                now: now,
                dayBoundary: dayBoundary
            )
        )
    }

    func testPersistentReadFailureSchedulesAtMostThreeProbesPerLocalDay() {
        // Simulate a full local day of Widget timeline rebuilds that keep
        // failing: the ladder must terminate instead of polling forever.
        var probeState = TinyBuddyWidgetReadFailureProbeState(
            dayIdentifier: "2026-10-21",
            probeCount: 0
        )
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let simulatedDayBoundary = dayStart.addingTimeInterval(86_400)
        var instant = dayStart
        var scheduledProbes: [Date] = []

        for _ in 0..<200 {
            let used = probeState.probeCount(on: "2026-10-21")
            guard let next = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .readFailed,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                readFailureProbeCountUsed: used,
                now: instant,
                dayBoundary: simulatedDayBoundary
            ) else {
                break
            }
            probeState = probeState.recordingProbe(on: "2026-10-21")
            scheduledProbes.append(next)
            instant = next
        }

        XCTAssertEqual(
            scheduledProbes.count,
            TinyBuddyWidgetTimelinePolicy.maximumReadFailureProbeCount
        )
        XCTAssertEqual(
            scheduledProbes,
            [
                dayStart.addingTimeInterval(5 * 60),
                dayStart.addingTimeInterval(25 * 60),
                dayStart.addingTimeInterval(105 * 60),
            ]
        )
        XCTAssertEqual(probeState.probeCount(on: "2026-10-21"), 3)
        for probe in scheduledProbes {
            XCTAssertLessThan(probe, simulatedDayBoundary)
        }
    }

    func testReadFailureBudgetResetsOnNewLocalDay() {
        let yesterday = TinyBuddyWidgetReadFailureProbeState(
            dayIdentifier: "2026-10-20",
            probeCount: TinyBuddyWidgetTimelinePolicy.maximumReadFailureProbeCount
        )

        XCTAssertEqual(yesterday.probeCount(on: "2026-10-21"), 0)
        XCTAssertEqual(
            yesterday.probeCount(on: "2026-10-20"),
            TinyBuddyWidgetTimelinePolicy.maximumReadFailureProbeCount
        )

        let today = yesterday.recordingProbe(on: "2026-10-21")
        XCTAssertEqual(today.dayIdentifier, "2026-10-21")
        XCTAssertEqual(today.probeCount, 1)
        XCTAssertEqual(today.probeCount(on: "2026-10-20"), 0)

        // An exhausted yesterday therefore cannot suppress today's recovery.
        XCTAssertEqual(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .readFailed,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                readFailureProbeCountUsed: yesterday.probeCount(on: "2026-10-21"),
                now: now,
                dayBoundary: dayBoundary
            ),
            now.addingTimeInterval(5 * 60)
        )
    }

    func testReadFailureProbeNeverCrossesDayBoundary() {
        let lateNow = dayBoundary.addingTimeInterval(-60)
        XCTAssertNil(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .readFailed,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                now: lateNow,
                dayBoundary: dayBoundary
            )
        )
    }

    func testLiveFocusRefreshDoesNotConsumeReadFailureProbeBudget() {
        // A live session keeps its own cadence; the read-failure ladder is only
        // consulted when no session is open, so its budget cannot be burned by
        // live-focus refreshes.
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .readFailed,
            isFocusSessionActive: true,
            isFocusSessionPaused: false,
            readFailureProbeCountUsed: TinyBuddyWidgetTimelinePolicy
                .maximumReadFailureProbeCount,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(
            date,
            now.addingTimeInterval(TinyBuddyWidgetTimelinePolicy.liveFocusRefreshInterval)
        )
    }

    // MARK: - Day-boundary clamping

    func testSelfScheduledRefreshNeverCrossesDayBoundary() {
        // 30s before midnight: a 60s live-focus refresh would cross into the
        // next day. The prebuilt rollover entry owns that boundary, so the
        // policy declines to self-schedule.
        let lateNow = dayBoundary.addingTimeInterval(-30)
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .focusing,
            isFocusSessionActive: true,
            isFocusSessionPaused: false,
            now: lateNow,
            dayBoundary: dayBoundary
        )
        XCTAssertNil(date)
    }

    func testStaleRetryAlsoHonorsDayBoundary() {
        let lateNow = dayBoundary.addingTimeInterval(-10)
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .stale,
            isFocusSessionActive: false,
            isFocusSessionPaused: false,
            now: lateNow,
            dayBoundary: dayBoundary
        )
        XCTAssertNil(date)
    }

    // MARK: - Neutral placeholder entries self-heal

    func testNeutralIdleEntryWithoutDataRetriesOnSlowCadence() {
        // A neutral placeholder (prebuilt rollover, first launch, or a
        // pet-slice-only snapshot before activity/history are published)
        // must re-read the authoritative snapshot instead of staying on
        // `.never` until an app-side reload arrives.
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .idle,
            isFocusSessionActive: false,
            isFocusSessionPaused: false,
            hasRenderableData: false,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(
            date,
            now.addingTimeInterval(TinyBuddyWidgetTimelinePolicy.staleRecoveryRefreshInterval)
        )
    }

    func testIdleEntryWithDataStaysPushOnly() {
        // A genuinely empty day still renders its zero metrics and must stay
        // on `.never`; only the no-data placeholder self-schedules.
        XCTAssertNil(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .idle,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                hasRenderableData: true,
                now: now,
                dayBoundary: dayBoundary
            )
        )
    }

    func testNeutralPlaceholderHonorsDayBoundary() {
        let lateNow = dayBoundary.addingTimeInterval(-10)
        XCTAssertNil(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .idle,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                hasRenderableData: false,
                now: lateNow,
                dayBoundary: dayBoundary
            )
        )
    }

    // MARK: - Post-midnight rollover re-probe

    func testNeutralRolloverSchedulesBoundedPostMidnightProbe() {
        let probe = TinyBuddyWidgetTimelinePolicy.nextRolloverProbeDate(
            dayBoundary: dayBoundary,
            hasRenderableData: false
        )
        XCTAssertEqual(
            probe,
            dayBoundary.addingTimeInterval(TinyBuddyWidgetTimelinePolicy.staleRecoveryRefreshInterval)
        )
    }

    func testRolloverWithDataNeedsNoProbe() {
        XCTAssertNil(
            TinyBuddyWidgetTimelinePolicy.nextRolloverProbeDate(
                dayBoundary: dayBoundary,
                hasRenderableData: true
            )
        )
    }

    // MARK: - Determinism

    func testPolicyIsDeterministicForIdenticalInput() {
        let first = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .stale,
            isFocusSessionActive: false,
            isFocusSessionPaused: false,
            now: now,
            dayBoundary: dayBoundary
        )
        let second = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .stale,
            isFocusSessionActive: false,
            isFocusSessionPaused: false,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(first, second)
    }
}
