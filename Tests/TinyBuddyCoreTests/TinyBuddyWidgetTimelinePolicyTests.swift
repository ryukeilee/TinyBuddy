import Foundation
import XCTest
@testable import TinyBuddyCore

final class TinyBuddyWidgetTimelinePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let dayBoundary = Date(timeIntervalSince1970: 1_700_000_000 + 86_400)

    // MARK: - Live focus self-scheduling

    func testActiveFocusSessionSchedulesBoundedLiveRefresh() {
        let date = TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
            state: .focusing,
            isFocusSessionActive: true,
            isFocusSessionPaused: false,
            now: now,
            dayBoundary: dayBoundary
        )
        XCTAssertEqual(date, now.addingTimeInterval(TinyBuddyWidgetTimelinePolicy.liveFocusRefreshInterval))
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
            .readFailed,
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

    func testNoSelfScheduledRefreshWhenDataIsFailedPersistently() {
        // `.readFailed` is deliberately excluded from the retry set: a corrupt
        // or version-incompatible source does not heal from polling, so the
        // Widget must not burn WidgetKit budget on it.
        XCTAssertNil(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: .readFailed,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                now: now,
                dayBoundary: dayBoundary
            )
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
