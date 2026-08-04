import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class FocusGoalPersistenceTests: XCTestCase {

    func testSaveConfigurationPersistsAndReloads() {
        let suite = "FocusGoalPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = FocusGoalPreferencesStore(userDefaults: defaults)

        let config = FocusGoalConfiguration(
            dailyFocusGoalMinutes: 180,
            continuousFocusThresholdMinutes: 30,
            breakDurationMinutes: 5,
            isBreakReminderEnabled: false,
            isGoalCompletionEnabled: true,
            quietModeStartHour: 2,
            quietModeEndHour: 23
        )

        // The write result must be propagated so a failure can be surfaced
        // instead of silently discarding the user's edits.
        XCTAssertTrue(store.saveConfiguration(config))
        XCTAssertEqual(store.loadConfiguration(), config)

        defaults.removePersistentDomain(forName: suite)
    }

    func testFocusGoalConfigurationClampsQuietHoursOutOfRange() {
        let config = FocusGoalConfiguration(
            dailyFocusGoalMinutes: 240,
            continuousFocusThresholdMinutes: 50,
            breakDurationMinutes: 10,
            isBreakReminderEnabled: true,
            isGoalCompletionEnabled: true,
            quietModeStartHour: 42,
            quietModeEndHour: -3
        )
        // Invalid persisted values must fall back to a valid interval.
        XCTAssertEqual(config.quietModeStartHour, 23)
        XCTAssertEqual(config.quietModeEndHour, 0)
    }

    func testFocusGoalConfigurationPreservesNilQuietHours() {
        let config = FocusGoalConfiguration(
            quietModeStartHour: nil,
            quietModeEndHour: nil
        )
        XCTAssertNil(config.quietModeStartHour)
        XCTAssertNil(config.quietModeEndHour)
    }
}