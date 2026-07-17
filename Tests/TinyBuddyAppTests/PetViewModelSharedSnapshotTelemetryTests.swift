import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

@MainActor
final class PetViewModelSharedSnapshotTelemetryTests: XCTestCase {
    func testOSLogContractUsesExactPublicSharedSnapshotMessage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Sources/TinyBuddy/PetViewModel.swift"))

        XCTAssertTrue(source.contains(#"subsystem: "local.tinybuddy""#))
        XCTAssertTrue(source.contains(#"category: "SharedSnapshot""#))
        XCTAssertTrue(source.contains(
            #""HUD consumed schema=\(consumption.schemaVersion, privacy: .public) revision=\(consumption.revision, privacy: .public) day=\(consumption.dayIdentifier, privacy: .public)""#
        ))
    }

    func testRecordsCommittedSnapshotOnInitialLoadAndReload() async throws {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 17, hour: 9)
        let timeEnvironment = TinyBuddyTimeEnvironment(
            calendar: calendar,
            dateProvider: { today }
        )
        let notificationCenter = NotificationCenter()
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let activityStore = makeActivityStore(
            defaults: defaults,
            calendar: calendar,
            today: today
        )
        let combinedSnapshotStore = store.makeCombinedSnapshotStore()
        _ = combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(
                focusBlockCount: 1,
                commitCount: 2,
                recentProjectName: "Initial Project"
            ),
            fallbackSnapshot: store.loadSnapshot()
        )
        var consumptions: [TinyBuddyHUDSnapshotConsumption] = []

        let viewModel = PetViewModel(
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: notificationCenter,
            timeEnvironment: timeEnvironment,
            widgetReloader: {},
            hudSnapshotConsumptionRecorder: { consumptions.append($0) }
        )
        let initialCommittedSnapshot = try XCTUnwrap(combinedSnapshotStore.readValidated(
            expectedDayIdentifier: store.loadSnapshot().stats.dayIdentifier
        ).snapshot)

        XCTAssertEqual(viewModel.hudPresentation.focusCount, 1)
        XCTAssertEqual(viewModel.hudPresentation.completionCount, 2)
        XCTAssertEqual(consumptions, [evidence(for: initialCommittedSnapshot)])

        let reloadUpdate = combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(
                focusBlockCount: 4,
                commitCount: 7,
                recentProjectName: "Reloaded Project"
            ),
            fallbackSnapshot: store.loadSnapshot()
        )
        let reloadedCommittedSnapshot = try XCTUnwrap(reloadUpdate.snapshot)
        notificationCenter.post(name: .gitActivitySnapshotDidChange, object: nil)

        let reloadExpectation = expectation(description: "committed HUD reload recorded")
        Task { @MainActor in
            while consumptions.count < 2 || viewModel.hudPresentation.completionCount != 7 {
                await Task.yield()
            }
            reloadExpectation.fulfill()
        }
        await fulfillment(of: [reloadExpectation], timeout: 1.0)

        XCTAssertEqual(consumptions, [
            evidence(for: initialCommittedSnapshot),
            evidence(for: reloadedCommittedSnapshot)
        ])
        XCTAssertEqual(viewModel.hudPresentation.focusCount, 4)
        XCTAssertEqual(viewModel.hudPresentation.statusDisplayTitle, "今日完成 · Reloaded Project")
    }

    func testDoesNotRecordWhenNoCombinedSnapshotWasCommitted() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 17, hour: 9)
        let timeEnvironment = TinyBuddyTimeEnvironment(
            calendar: calendar,
            dateProvider: { today }
        )
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { _, _ in false },
            synchronizeWrites: { true }
        )
        var consumptions: [TinyBuddyHUDSnapshotConsumption] = []

        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(
                defaults: defaults,
                calendar: calendar,
                today: today
            ),
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            notificationCenter: NotificationCenter(),
            timeEnvironment: timeEnvironment,
            widgetReloader: {},
            hudSnapshotConsumptionRecorder: { consumptions.append($0) }
        )

        XCTAssertTrue(consumptions.isEmpty)
        XCTAssertNil(combinedSnapshotStore.readValidated(
            expectedDayIdentifier: viewModel.stats.dayIdentifier
        ).snapshot)
    }

    private func evidence(
        for snapshot: TinyBuddyCombinedSnapshot
    ) -> TinyBuddyHUDSnapshotConsumption {
        TinyBuddyHUDSnapshotConsumption(
            schemaVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            revision: snapshot.revision,
            dayIdentifier: snapshot.dayIdentifier
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyHUDSnapshotTelemetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeActivityStore(
        defaults: UserDefaults,
        calendar: Calendar,
        today: Date
    ) -> GitTodayActivityStore {
        GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            )
        )
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = makeCalendar()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }
}
