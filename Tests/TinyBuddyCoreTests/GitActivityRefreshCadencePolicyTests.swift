import XCTest
@testable import TinyBuddyCore

final class GitActivityRefreshCadencePolicyTests: XCTestCase {
    func testCadenceCoversEveryPowerAndVisibilityCombination() {
        for isApplicationActive in [false, true] {
            for isInterfaceVisible in [false, true] {
                for isOnBatteryPower in [false, true] {
                    for isLowPowerModeEnabled in [false, true] {
                        let conditions = makeConditions(
                            isApplicationActive: isApplicationActive,
                            isInterfaceVisible: isInterfaceVisible,
                            isOnBatteryPower: isOnBatteryPower,
                            isLowPowerModeEnabled: isLowPowerModeEnabled,
                            unchangedRefreshStreak: 0
                        )
                        let cadence = GitTodayActivityRefreshPolicy.cadence(for: conditions)
                        let isForegroundVisible = isApplicationActive && isInterfaceVisible

                        XCTAssertEqual(
                            cadence.nextRefreshInterval,
                            expectedInitialInterval(
                                isForegroundVisible: isForegroundVisible,
                                isOnBatteryPower: isOnBatteryPower,
                                isLowPowerModeEnabled: isLowPowerModeEnabled
                            ),
                            "active=\(isApplicationActive) visible=\(isInterfaceVisible) battery=\(isOnBatteryPower) lowPower=\(isLowPowerModeEnabled)"
                        )
                        XCTAssertEqual(
                            cadence.allowsRepositoryEventListening,
                            isForegroundVisible && !isOnBatteryPower && !isLowPowerModeEnabled
                        )
                        XCTAssertLessThanOrEqual(
                            cadence.nextRefreshInterval,
                            GitTodayActivityRefreshPolicy.maximumRefreshInterval
                        )

                        let stableCadence = GitTodayActivityRefreshPolicy.cadence(
                            for: makeConditions(
                                isApplicationActive: isApplicationActive,
                                isInterfaceVisible: isInterfaceVisible,
                                isOnBatteryPower: isOnBatteryPower,
                                isLowPowerModeEnabled: isLowPowerModeEnabled,
                                unchangedRefreshStreak: 3
                            )
                        )
                        XCTAssertEqual(
                            stableCadence.nextRefreshInterval,
                            expectedStableInterval(
                                isForegroundVisible: isForegroundVisible,
                                isOnBatteryPower: isOnBatteryPower,
                                isLowPowerModeEnabled: isLowPowerModeEnabled
                            )
                        )
                    }
                }
            }
        }
    }

    func testUnchangedStreakSlowsForegroundACAndChangedResultRestoresFastCadence() {
        let initial = makeConditions(unchangedRefreshStreak: 0)
        XCTAssertEqual(GitTodayActivityRefreshPolicy.cadence(for: initial).nextRefreshInterval, 5 * 60)

        let onceUnchanged = GitTodayActivityRefreshPolicy.updatedUnchangedRefreshStreak(
            currentStreak: 0,
            result: .unchanged
        )
        XCTAssertEqual(
            GitTodayActivityRefreshPolicy.cadence(
                for: makeConditions(unchangedRefreshStreak: onceUnchanged)
            ).nextRefreshInterval,
            10 * 60
        )

        let repeatedlyUnchanged = GitTodayActivityRefreshPolicy.updatedUnchangedRefreshStreak(
            currentStreak: 2,
            result: .unchanged
        )
        XCTAssertEqual(
            GitTodayActivityRefreshPolicy.cadence(
                for: makeConditions(unchangedRefreshStreak: repeatedlyUnchanged)
            ).nextRefreshInterval,
            20 * 60
        )
        XCTAssertEqual(
            GitTodayActivityRefreshPolicy.updatedUnchangedRefreshStreak(
                currentStreak: repeatedlyUnchanged,
                result: .changed
            ),
            0
        )
    }

    func testUnknownResultKeepsBoundedStreakAndUnchangedGrowthIsBounded() {
        XCTAssertEqual(
            GitTodayActivityRefreshPolicy.updatedUnchangedRefreshStreak(
                currentStreak: -1,
                result: .unknown
            ),
            0
        )
        XCTAssertEqual(
            GitTodayActivityRefreshPolicy.updatedUnchangedRefreshStreak(
                currentStreak: GitTodayActivityRefreshPolicy.maximumUnchangedRefreshStreak,
                result: .unchanged
            ),
            GitTodayActivityRefreshPolicy.maximumUnchangedRefreshStreak
        )
    }

    func testTwentyFourHourSimulationReducesUnchangedBackgroundAndLowPowerWakeups() {
        let fixedFiveMinuteRefreshes = 24 * 60 / 5
        let foregroundAC = simulatedRefreshCount(
            for: makeConditions(),
            duration: 24 * 60 * 60
        )
        let backgroundAC = simulatedRefreshCount(
            for: makeConditions(isApplicationActive: false, isInterfaceVisible: false),
            duration: 24 * 60 * 60
        )
        let lowPowerBackground = simulatedRefreshCount(
            for: makeConditions(
                isApplicationActive: false,
                isInterfaceVisible: false,
                isLowPowerModeEnabled: true
            ),
            duration: 24 * 60 * 60
        )

        XCTAssertLessThan(foregroundAC, fixedFiveMinuteRefreshes / 2)
        XCTAssertLessThan(backgroundAC, fixedFiveMinuteRefreshes / 4)
        XCTAssertLessThan(lowPowerBackground, fixedFiveMinuteRefreshes / 4)
        XCTAssertEqual(backgroundAC, 25)
        XCTAssertEqual(lowPowerBackground, 24)

        // The runtime owns a dedicated day-boundary timer. This cadence is
        // deliberately bounded, so a 23:59 periodic scheduling decision never
        // prevents that independent boundary event from being delivered.
        let lastMinuteOfDay = Date(timeIntervalSince1970: 86_340)
        let nextDayBoundary = Date(timeIntervalSince1970: 86_400)
        let nextPeriodicRefresh = lastMinuteOfDay.addingTimeInterval(
            GitTodayActivityRefreshPolicy.cadence(
                for: makeConditions(
                    isApplicationActive: false,
                    isInterfaceVisible: false,
                    isLowPowerModeEnabled: true
                )
            ).nextRefreshInterval
        )
        XCTAssertLessThan(nextDayBoundary, nextPeriodicRefresh)
    }

    private func makeConditions(
        isApplicationActive: Bool = true,
        isInterfaceVisible: Bool = true,
        isOnBatteryPower: Bool = false,
        isLowPowerModeEnabled: Bool = false,
        unchangedRefreshStreak: Int = 0
    ) -> GitTodayActivityRefreshCadenceConditions {
        GitTodayActivityRefreshCadenceConditions(
            isApplicationActive: isApplicationActive,
            isInterfaceVisible: isInterfaceVisible,
            isOnBatteryPower: isOnBatteryPower,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            unchangedRefreshStreak: unchangedRefreshStreak
        )
    }

    private func expectedInitialInterval(
        isForegroundVisible: Bool,
        isOnBatteryPower: Bool,
        isLowPowerModeEnabled: Bool
    ) -> TimeInterval {
        if isLowPowerModeEnabled {
            return isForegroundVisible ? 30 * 60 : 60 * 60
        }
        if isOnBatteryPower {
            return isForegroundVisible ? 15 * 60 : 60 * 60
        }
        return isForegroundVisible ? 5 * 60 : 30 * 60
    }

    private func expectedStableInterval(
        isForegroundVisible: Bool,
        isOnBatteryPower: Bool,
        isLowPowerModeEnabled: Bool
    ) -> TimeInterval {
        if isLowPowerModeEnabled {
            return isForegroundVisible ? 30 * 60 : 60 * 60
        }
        if isOnBatteryPower {
            return isForegroundVisible ? 30 * 60 : 60 * 60
        }
        return isForegroundVisible ? 20 * 60 : 60 * 60
    }

    private func simulatedRefreshCount(
        for baseConditions: GitTodayActivityRefreshCadenceConditions,
        duration: TimeInterval
    ) -> Int {
        var elapsed: TimeInterval = 0
        var streak = baseConditions.unchangedRefreshStreak
        var count = 0

        while elapsed < duration {
            let cadence = GitTodayActivityRefreshPolicy.cadence(
                for: GitTodayActivityRefreshCadenceConditions(
                    isApplicationActive: baseConditions.isApplicationActive,
                    isInterfaceVisible: baseConditions.isInterfaceVisible,
                    isOnBatteryPower: baseConditions.isOnBatteryPower,
                    isLowPowerModeEnabled: baseConditions.isLowPowerModeEnabled,
                    unchangedRefreshStreak: streak
                )
            )
            XCTAssertLessThanOrEqual(
                cadence.nextRefreshInterval,
                GitTodayActivityRefreshPolicy.maximumRefreshInterval
            )
            elapsed += cadence.nextRefreshInterval
            count += 1
            streak = GitTodayActivityRefreshPolicy.updatedUnchangedRefreshStreak(
                currentStreak: streak,
                result: .unchanged
            )
        }
        return count
    }
}
