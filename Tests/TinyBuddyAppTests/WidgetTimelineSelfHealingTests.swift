import Foundation
import TinyBuddyCore
import XCTest

final class WidgetTimelineSelfHealingTests: XCTestCase {
    func testWidgetProviderChecksPostUpgradeRebuildFlag() throws {
        let source = try widgetSource()
        XCTAssertTrue(source.contains("TinyBuddyVersionUpgradeTracker.isPostUpgradeRebuildRequired()"))
    }

    func testWidgetProviderFallsBackToAnyDaySnapshotDuringPostUpgradeRebuild() throws {
        let source = try widgetSource()
        XCTAssertTrue(source.contains("combinedSnapshotStore.loadReadOnly()"))
        XCTAssertTrue(source.contains("widget self-healing accepted any-day snapshot"))
        XCTAssertTrue(source.contains("dataAvailability: .stale"))
    }

    func testWidgetProviderSelfHealingUsesStaleAvailabilityNotFailed() throws {
        let source = try widgetSource()
        // Ensure the self-healing entry uses .stale, not .failed or neutral.
        let healingRange = try XCTUnwrap(source.range(of: "Post-upgrade self-healing"))
        let endIndex = source.index(healingRange.lowerBound, offsetBy: min(900, source.count - source.distance(from: source.startIndex, to: healingRange.lowerBound)))
        let healingBlock = String(source[healingRange.lowerBound..<endIndex])
        XCTAssertTrue(healingBlock.contains("dataAvailability: .stale"))
    }

    func testPrebuiltRolloverEntryDoesNotClaimAvailableData() throws {
        let source = try widgetSource()
        // The rollover entry owns the local-day boundary before the new day's
        // snapshot can exist. Claiming `.available` for its neutral snapshot
        // resolves to `.idle`, which renders "待机" and reports a settled empty
        // day instead of "today's data is not read yet". It must stay
        // `.loading` so the placeholder is honest and keeps self-healing.
        let rolloverRange = try XCTUnwrap(source.range(of: "private func makeRolloverEntry"))
        let endIndex = source.index(
            rolloverRange.lowerBound,
            offsetBy: min(
                900,
                source.count - source.distance(from: source.startIndex, to: rolloverRange.lowerBound)
            )
        )
        let rolloverBlock = String(source[rolloverRange.lowerBound..<endIndex])
        XCTAssertTrue(rolloverBlock.contains("dataAvailability: .loading"))
        XCTAssertFalse(rolloverBlock.contains("dataAvailability: .available"))
    }

    func testAppDelegateRegistersPostUpgradeReloadObserver() throws {
        let source = try appSource()
        XCTAssertTrue(source.contains("registerPostUpgradeWidgetReloadObserver()"))
        XCTAssertTrue(source.contains("gitActivityRefreshStatusDidChange"))
        XCTAssertTrue(source.contains("Post-upgrade rebuild completed; reloading widget timelines"))
        XCTAssertTrue(source.contains("TinyBuddyVersionUpgradeTracker.clearPostUpgradeRebuildRequired()"))
    }

    func testAppDelegateDoesNotReloadWidgetImmediatelyOnUpgradeDetection() throws {
        let source = try appSource()
        // The old immediate reload was removed; now the reload happens via
        // the observer after a refresh commits.
        let upgradeBlock = source[source.range(of: "Version upgrade detected")!.lowerBound..<source.index(source.range(of: "Version upgrade detected")!.lowerBound, offsetBy: 800)]
        XCTAssertFalse(upgradeBlock.contains("WidgetCenter.shared.reloadAllTimelines()"))
    }

    func testVersionUpgradeTrackerSetsAndClearsRebuildFlag() throws {
        let source = try trackerSource()
        XCTAssertTrue(source.contains("needsPostUpgradeRebuild"))
        XCTAssertTrue(source.contains("isPostUpgradeRebuildRequired"))
        XCTAssertTrue(source.contains("setPostUpgradeRebuildRequired"))
        XCTAssertTrue(source.contains("clearPostUpgradeRebuildRequired"))
        XCTAssertTrue(source.contains("if isUpgrade {"))
        XCTAssertTrue(source.contains("setPostUpgradeRebuildRequired(userDefaults: userDefaults)"))
    }

    // MARK: - Bounded read-failure self-healing

    func testWidgetPersistsReadFailureProbeBudgetInItsOwnDefaultsDomain() throws {
        let source = try widgetSource()

        XCTAssertTrue(source.contains("private let widgetDefaults: UserDefaults"))
        XCTAssertTrue(source.contains("self.widgetDefaults = UserDefaults.standard"))
        XCTAssertTrue(source.contains("tinybuddy.widget.readFailureProbe.day.v1"))
        XCTAssertTrue(source.contains("tinybuddy.widget.readFailureProbe.count.v1"))
        XCTAssertTrue(
            source.contains("widgetDefaults.set(state.dayIdentifier, forKey: Self.readFailureProbeDayKey)")
        )
        XCTAssertTrue(
            source.contains("widgetDefaults.set(state.probeCount, forKey: Self.readFailureProbeCountKey)")
        )
        XCTAssertTrue(source.contains("storedReadFailureProbeState("))

        // The budget must never live in the App Group shared domain.
        for key in ["readFailureProbe.day.v1", "readFailureProbe.count.v1"] {
            for line in source.split(separator: "\n") where line.contains(key) {
                XCTAssertFalse(
                    line.contains("sharedDefaults"),
                    "read-failure budget must not use the shared domain: \(line)"
                )
            }
        }
    }

    func testWidgetPassesLocalDayProbeBudgetAndReasonToTimelinePolicy() throws {
        let source = try widgetSource()

        XCTAssertTrue(source.contains("readFailureReason: entry.presentation.readFailureReason"))
        XCTAssertTrue(source.contains("readFailureProbeCountUsed: readFailureProbeCountUsed"))
        XCTAssertTrue(source.contains("readFailureProbeState.probeCount("))
        XCTAssertTrue(source.contains("recordingProbe(on: timeContext.dayIdentifier)"))
        XCTAssertTrue(
            source.contains("dayIdentifier: timeContext.dayIdentifier"),
            "the probe budget must be keyed by the local display day"
        )
    }

    func testBoundedProbeRecoversTransientReadFailureWithoutAppReload() throws {
        let suiteName = "TinyBuddyWidgetReadFailureRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let statsStore = DailyStatsStore(userDefaults: defaults)
        let combinedSnapshotStore = statsStore.makeCombinedSnapshotStore()
        let dayIdentifier = statsStore.loadSnapshot().stats.dayIdentifier
        let now = Date()
        let dayBoundary = now.addingTimeInterval(86_400)

        // The first timeline read cannot use the committed snapshot.
        let failed = TinyBuddyDisplayPresentation(
            snapshot: statsStore.loadSnapshot(),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            ),
            dataAvailability: .failed(.snapshotCorrupt)
        )
        XCTAssertEqual(failed.state, .readFailed)
        XCTAssertEqual(failed.readFailureReason, .snapshotCorrupt)

        var probeState = TinyBuddyWidgetReadFailureProbeState(
            dayIdentifier: dayIdentifier,
            probeCount: 0
        )
        let firstProbe = try XCTUnwrap(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: failed.state,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                hasRenderableData: false,
                readFailureReason: failed.readFailureReason,
                readFailureProbeCountUsed: probeState.probeCount(on: dayIdentifier),
                now: now,
                dayBoundary: dayBoundary
            )
        )
        XCTAssertEqual(firstProbe, now.addingTimeInterval(5 * 60))
        probeState = probeState.recordingProbe(on: dayIdentifier)

        // The self-scheduled probe fires with no app-side reload: the app has
        // committed a fresh same-day snapshot in the meantime, so the Widget's
        // next read of the authoritative store must render the data state.
        let activity = GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 2,
            recentProjectName: "TinyBuddy"
        )
        let commit = combinedSnapshotStore.updateActivitySlice(
            activity,
            fallbackSnapshot: statsStore.loadSnapshot()
        )
        XCTAssertTrue(commit.didPersist)

        let recoveryRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: dayIdentifier
        )
        let committedSnapshot = try XCTUnwrap(recoveryRead.snapshot)
        XCTAssertEqual(committedSnapshot.dayIdentifier, dayIdentifier)
        let recovered = TinyBuddyDisplayPresentation(
            snapshot: committedSnapshot.snapshot,
            activitySnapshot: committedSnapshot.activitySnapshot,
            refreshStatus: GitActivityRefreshStatus(
                refreshedAt: firstProbe,
                trigger: .timer,
                outcome: .succeeded,
                metrics: GitActivityRefreshMetrics(
                    authorizedRootCount: 1,
                    repositoryCount: 1
                )
            ),
            dataAvailability: TinyBuddyDisplayDataAvailability(
                observation: recoveryRead.observation,
                hasSnapshot: true
            )
        )

        XCTAssertEqual(recovered.state, .completedToday)
        XCTAssertEqual(recovered.focusCount, 1)
        XCTAssertEqual(recovered.completionCount, 2)
        XCTAssertTrue(recovered.showsActivityMetrics)
        XCTAssertNil(recovered.refreshNotice)
        XCTAssertNil(recovered.readFailureReason)
        XCTAssertNil(
            TinyBuddyWidgetTimelinePolicy.nextRefreshDate(
                state: recovered.state,
                isFocusSessionActive: false,
                isFocusSessionPaused: false,
                readFailureReason: recovered.readFailureReason,
                readFailureProbeCountUsed: probeState.probeCount(on: dayIdentifier),
                now: firstProbe,
                dayBoundary: dayBoundary
            ),
            "recovered data must not keep the read-failure probe cadence"
        )
    }

    func testExhaustedYesterdayProbeBudgetDoesNotAffectNewDayDisplay() {
        let yesterday = TinyBuddyWidgetReadFailureProbeState(
            dayIdentifier: "2026-10-20",
            probeCount: TinyBuddyWidgetTimelinePolicy.maximumReadFailureProbeCount
        )
        XCTAssertEqual(
            yesterday.probeCount(on: "2026-10-20"),
            TinyBuddyWidgetTimelinePolicy.maximumReadFailureProbeCount
        )
        XCTAssertEqual(yesterday.probeCount(on: "2026-10-21"), 0)

        // The new day's committed snapshot renders immediately, without a
        // read-failure notice, because yesterday's status is filtered by
        // display day and the probe budget resets on the day change.
        let today = TinyBuddyDisplayPresentation(
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-10-21",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 2,
                commitCount: 3,
                recentProjectName: "TinyBuddy"
            ),
            refreshStatus: nil,
            dataAvailability: .available
        )
        XCTAssertEqual(today.state, .completedToday)
        XCTAssertTrue(today.showsActivityMetrics)
        XCTAssertNil(today.refreshNotice)
    }
    private func widgetSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Widget/TinyBuddyWidget/TinyBuddyWidget.swift"),
            encoding: .utf8
        )
    }

    private func appSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Sources/TinyBuddy/TinyBuddyApp.swift"),
            encoding: .utf8
        )
    }

    private func trackerSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Sources/TinyBuddyCore/TinyBuddyVersionUpgradeTracker.swift"),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
