import XCTest
@testable import TinyBuddyCore

final class GitActivityRefreshStatusStoreTests: XCTestCase {
    func testLoadsSavedRefreshStatus() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 12, minute: 34, second: 56)
        let store = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { refreshedAt }
        )

        store.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .timer,
                outcome: .succeeded
            )
        )

        XCTAssertEqual(
            store.load(),
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .timer,
                outcome: .succeeded
            )
        )
    }

    func testSaveTrimsBlankReasonsAndLoadRequiresCompleteRecord() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let store = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { refreshedAt }
        )

        store.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .becameActive,
                outcome: .skipped,
                reason: "  \n  "
            )
        )

        XCTAssertEqual(
            store.load(),
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .becameActive,
                outcome: .skipped
            )
        )

        defaults.removeObject(forKey: GitActivityRefreshStatusStore.Key.outcome)
        XCTAssertNil(store.load())
    }

    func testSaveAndLoadMetrics() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 9, minute: 1, second: 2)
        let diagnostic = GitActivityRefreshDiagnostic(
            source: .gitActivityRefresh,
            stage: .scriptExecution,
            reason: .scriptExecutionFailed
        )
        let store = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { refreshedAt }
        )

        store.save(
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .succeeded,
                diagnostic: diagnostic,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 4321,
                    authorizedRootCount: 2,
                    repositoryCount: 7,
                    cacheHitCount: 4,
                    reflogUnchangedSkipCount: 3,
                    recomputedRepositoryCount: 4,
                    sharedDataWritten: true,
                    widgetReloaded: false,
                    reason: diagnostic.stableIdentifier
                )
            )
        )

        XCTAssertEqual(
            store.load(),
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .succeeded,
                diagnostic: diagnostic,
                metrics: GitActivityRefreshMetrics(
                    durationMilliseconds: 4321,
                    authorizedRootCount: 2,
                    repositoryCount: 7,
                    cacheHitCount: 4,
                    reflogUnchangedSkipCount: 3,
                    recomputedRepositoryCount: 4,
                    sharedDataWritten: true,
                    widgetReloaded: false,
                    reason: diagnostic.stableIdentifier
                )
            )
        )
    }

    func testLoadMapsLegacyReasonToStructuredDiagnostic() {
        let defaults = makeDefaults()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 9, minute: 1, second: 2)
        defaults.set(refreshedAt, forKey: GitActivityRefreshStatusStore.Key.refreshedAt)
        defaults.set(GitTodayActivityRefreshTrigger.launch.rawValue, forKey: GitActivityRefreshStatusStore.Key.trigger)
        defaults.set(GitActivityRefreshOutcome.failed.rawValue, forKey: GitActivityRefreshStatusStore.Key.outcome)
        defaults.set(
            "refresh script exited with status 1:\n/Users/alice/Work/SecretRepo",
            forKey: GitActivityRefreshStatusStore.Key.reason
        )

        let store = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: makeCalendar(),
            dateProvider: { refreshedAt }
        )

        XCTAssertEqual(
            store.load(),
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .failed,
                diagnostic: GitActivityRefreshDiagnostic(
                    source: .gitActivityRefresh,
                    stage: .scriptExecution,
                    reason: .scriptExecutionFailed
                )
            )
        )
    }

    func testLoadDropsUnknownLegacyReasonFromReturnedAndPersistedFields() {
        let defaults = makeDefaults()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 10, minute: 1, second: 2)
        let sensitiveReason = "/Users/alice/Work/SecretRepo stderr: token=abc123"
        defaults.set(refreshedAt, forKey: GitActivityRefreshStatusStore.Key.refreshedAt)
        defaults.set(GitTodayActivityRefreshTrigger.launch.rawValue, forKey: GitActivityRefreshStatusStore.Key.trigger)
        defaults.set(GitActivityRefreshOutcome.failed.rawValue, forKey: GitActivityRefreshStatusStore.Key.outcome)
        defaults.set(sensitiveReason, forKey: GitActivityRefreshStatusStore.Key.reason)

        let store = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: makeCalendar(),
            dateProvider: { refreshedAt }
        )

        let status = store.load()

        XCTAssertEqual(
            status,
            GitActivityRefreshStatus(
                refreshedAt: refreshedAt,
                trigger: .launch,
                outcome: .failed
            )
        )
        XCTAssertNil(defaults.string(forKey: GitActivityRefreshStatusStore.Key.reason))
        XCTAssertFalse((status?.reason ?? "").contains("SecretRepo"))
        XCTAssertFalse((status?.reason ?? "").contains("alice"))
    }

    func testLoadDropsUnknownLegacyMetricsReasonAndPersistsCanonicalDiagnosticIdentifier() {
        let defaults = makeDefaults()
        let refreshedAt = makeDate(year: 2026, month: 7, day: 4, hour: 11, minute: 1, second: 2)
        let sensitiveReason = "/Users/alice/Work/SecretRepo stderr: token=abc123"
        let diagnostic = GitActivityRefreshDiagnostic(
            source: .gitActivityRefresh,
            stage: .scriptExecution,
            reason: .scriptExecutionFailed
        )
        defaults.set(refreshedAt, forKey: GitActivityRefreshStatusStore.Key.refreshedAt)
        defaults.set(GitTodayActivityRefreshTrigger.launch.rawValue, forKey: GitActivityRefreshStatusStore.Key.trigger)
        defaults.set(GitActivityRefreshOutcome.failed.rawValue, forKey: GitActivityRefreshStatusStore.Key.outcome)
        defaults.set(diagnostic.stableIdentifier, forKey: GitActivityRefreshStatusStore.Key.reason)
        defaults.set(diagnostic.source.rawValue, forKey: GitActivityRefreshStatusStore.Key.diagnosticSource)
        defaults.set(diagnostic.stage.rawValue, forKey: GitActivityRefreshStatusStore.Key.diagnosticStage)
        defaults.set(diagnostic.reason.rawValue, forKey: GitActivityRefreshStatusStore.Key.diagnosticReason)
        defaults.set(250, forKey: GitActivityRefreshStatusStore.Key.durationMilliseconds)
        defaults.set(sensitiveReason, forKey: GitActivityRefreshStatusStore.Key.metricsReason)

        let store = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: makeCalendar(),
            dateProvider: { refreshedAt }
        )

        let status = store.load()

        XCTAssertEqual(status?.metrics?.reason, diagnostic.stableIdentifier)
        XCTAssertEqual(defaults.string(forKey: GitActivityRefreshStatusStore.Key.metricsReason), diagnostic.stableIdentifier)
        XCTAssertFalse((status?.metrics?.reason ?? "").contains("SecretRepo"))
        XCTAssertFalse((defaults.string(forKey: GitActivityRefreshStatusStore.Key.metricsReason) ?? "").contains("SecretRepo"))
    }

    func testDoesNotLoadRefreshStatusFromPreviousLocalDay() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        let store = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate }
        )

        store.save(
            GitActivityRefreshStatus(
                refreshedAt: currentDate,
                trigger: .launch,
                outcome: .succeeded
            )
        )
        XCTAssertNotNil(store.load())

        currentDate = makeDate(year: 2026, month: 7, day: 5, hour: 8, minute: 0, second: 0)

        XCTAssertNil(store.load())
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitActivityRefreshStatusStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}
