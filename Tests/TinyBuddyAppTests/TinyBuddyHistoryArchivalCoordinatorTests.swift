import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

@MainActor
final class TinyBuddyHistoryArchivalCoordinatorTests: XCTestCase {
    private let todayIdentifier = "2026-07-21"
    private let yesterdayIdentifier = "2026-07-20"

    private func makeSnapshot(dayIdentifier: String, revision: Int64 = 1) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: dayIdentifier,
                    focusCount: 1,
                    completionCount: 2
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 4,
                recentProjectName: "TestProject"
            ),
            activityRevision: 100
        )
    }

    private func makeHistoryStore(currentDay: String? = nil) -> TinyBuddyHistoryStore {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-archival-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }
        let currentDayIdentifier = currentDay ?? todayIdentifier

        let quarantine = TinyBuddyCorruptedRecordQuarantine(
            storageURL: tmpURL
                .appendingPathComponent("Quarantine", isDirectory: true)
                .appendingPathComponent("corrupted_records.json")
        )

        return TinyBuddyHistoryStore(
            fileManager: .default,
            snapshotEncoder: TinyBuddyCombinedSnapshotStore.encodeV3,
            snapshotDecoder: TinyBuddyCombinedSnapshotStore.decodeV3,
            retentionPolicy: TinyBuddyHistoryRetentionPolicy(
                maxDayCount: 30,
                maxTotalBytes: 2_097_152
            ),
            customContainerURL: tmpURL,
            currentDayIdentifierProvider: { currentDayIdentifier },
            quarantine: quarantine
        )
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let name = "TinyBuddyHistoryArchivalCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeCleanupService(
        onCleanup: @escaping @Sendable () -> Void
    ) -> TinyBuddyStorageCleanupService {
        TinyBuddyStorageCleanupService(
            loadPreferences: {
                onCleanup()
                return [:]
            },
            writeValue: { _, _ in true },
            removeValue: { _ in true },
            synchronize: { true },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil },
            retentionPolicy: RetentionPolicy(
                staleKeyMaxAgeDays: 1,
                minFreeDiskSpaceBytes: 0
            )
        )
    }

    private func makeCoordinator(
        snapshotProvider: @escaping () -> TinyBuddyCombinedSnapshot?,
        historyStore: TinyBuddyHistoryStore,
        cleanupService: TinyBuddyStorageCleanupService,
        currentDay: String = "2026-07-21"
    ) -> TinyBuddyHistoryArchivalCoordinator {
        TinyBuddyHistoryArchivalCoordinator(
            snapshotReader: { expectedDay in
                guard let snapshot = snapshotProvider(),
                      expectedDay == nil || snapshot.dayIdentifier == expectedDay else {
                    return TinyBuddyValidatedCombinedSnapshotRead(snapshot: nil, observation: nil)
                }
                return TinyBuddyValidatedCombinedSnapshotRead(snapshot: snapshot, observation: nil)
            },
            historyStore: historyStore,
            cleanupService: cleanupService,
            timeContextProvider: {
                TinyBuddyTimeContext(
                    now: Self.fixedDateForDay(currentDay),
                    timeZone: TimeZone(secondsFromGMT: 0)!,
                    locale: Locale(identifier: "en_US_POSIX"),
                    sourceCalendar: Calendar(identifier: .gregorian)
                )
            },
            throttleInterval: 3600
        )
    }

    // MARK: - Launch

    func testDelayedLaunchCalibrationCanMissPreviousDaySnapshot() async throws {
        let previousDay = "2026-09-16"
        let currentDay = "2026-09-17"
        let defaults = makeIsolatedDefaults()
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let timeEnvironment = TinyBuddyTimeEnvironment.fixed(
            now: Self.fixedDateForDay(currentDay),
            timeZone: timeZone
        )
        let combinedStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let yesterdayActivity = GitTodayActivitySnapshot(
            focusBlockCount: 3,
            commitCount: 2,
            recentProjectName: "Fixture"
        )
        let yesterdayPetSnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: previousDay, focusCount: 3, completionCount: 2)
        )
        let seeded = combinedStore.updatePetSlice(
            yesterdayPetSnapshot,
            fallbackActivitySnapshot: yesterdayActivity,
            fallbackActivityRevision: 1
        )
        XCTAssertTrue(seeded.didPersist)

        let historyStore = makeHistoryStore(currentDay: currentDay)
        let archivalCoordinator = TinyBuddyHistoryArchivalCoordinator(
            snapshotReader: { expectedDay in
                combinedStore.readValidated(expectedDayIdentifier: expectedDay)
            },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {}),
            timeContextProvider: { timeEnvironment.capture() }
        )
        let calibrationHandled = expectation(description: "deferred launch calibration handled")
        let continuity = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: previousDay,
            lastObservedTimeZoneIdentifier: timeZone.identifier,
            lastCalibrationDate: Self.fixedDateForDay(previousDay)
        )
        XCTAssertTrue(continuity.save(userDefaults: defaults))
        let calibrator = TinyBuddyTimeCalibrator(
            timeEnvironment: timeEnvironment,
            userDefaults: defaults,
            monotonicProvider: { 1_000 },
            onChange: { outcome in
                Task { @MainActor in
                    if case .dayChanged(_, let to, _) = outcome {
                        archivalCoordinator.handleDayTransition(to: to)
                    }
                    calibrationHandled.fulfill()
                }
            }
        )

        let calibrationOutcome = calibrator.calibrate()
        guard case .dayChanged(let from, let to, _) = calibrationOutcome else {
            XCTFail("fixture must emit the same deferred day-change callback as launch")
            return
        }
        XCTAssertEqual(from, previousDay)
        XCTAssertEqual(to, currentDay)
        XCTAssertEqual(
            archivalCoordinator.archivePriorDaySnapshotBeforeLaunchWrites(),
            .archived
        )

        // After the same synchronous preflight used by AppDelegate, startup
        // can roll the combined store before the MainActor callback runs.
        let todayPetSnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: currentDay, focusCount: 0, completionCount: 0)
        )
        let todayActivity = GitTodayActivitySnapshot(focusBlockCount: 0, commitCount: 0)
        let rolled = combinedStore.updatePetSlice(
            todayPetSnapshot,
            fallbackActivitySnapshot: todayActivity,
            fallbackActivityRevision: 1
        )
        XCTAssertTrue(rolled.didPersist)
        archivalCoordinator.runAtLaunch()
        await fulfillment(of: [calibrationHandled], timeout: 5)

        guard case .available(let archivedYesterday) = historyStore.readSnapshot(for: previousDay) else {
            XCTFail("the previous day's committed snapshot must be recovered before startup writes")
            return
        }
        XCTAssertEqual(archivedYesterday.snapshot.stats.focusCount, 3)
        XCTAssertEqual(archivedYesterday.snapshot.stats.completionCount, 2)
        XCTAssertEqual(archivedYesterday.activitySnapshot.focusBlockCount, 3)
        XCTAssertEqual(archivedYesterday.activitySnapshot.commitCount, 2)
        XCTAssertEqual(historyStore.readSnapshot(for: "2026-09-15"), .notFound)
        guard case .available(let archivedToday) = historyStore.readSnapshot(for: currentDay) else {
            XCTFail("existing launch behavior still archives today's snapshot")
            return
        }
        XCTAssertEqual(archivedToday.snapshot.stats.focusCount, 0)
    }

    func testRunAtLaunchArchivesCurrentDayAndRunsCleanup() throws {
        let historyStore = makeHistoryStore()
        let cleanupExpectation = expectation(description: "cleanup ran at launch")
        let cleanupService = makeCleanupService(onCleanup: {
            cleanupExpectation.fulfill()
        })
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: self.todayIdentifier, revision: 7) },
            historyStore: historyStore,
            cleanupService: cleanupService
        )

        coordinator.runAtLaunch()

        guard case .available(let archived) = historyStore.readSnapshot(for: todayIdentifier) else {
            XCTFail("current day must be archived at launch")
            return
        }
        XCTAssertEqual(archived.revision, 7)
        wait(for: [cleanupExpectation], timeout: 5)
    }

    func testRunAtLaunchWithNoSnapshotSkipsArchive() {
        let historyStore = makeHistoryStore()
        let cleanupExpectation = expectation(description: "cleanup ran")
        let cleanupService = makeCleanupService(onCleanup: {
            cleanupExpectation.fulfill()
        })
        let coordinator = makeCoordinator(
            snapshotProvider: { nil },
            historyStore: historyStore,
            cleanupService: cleanupService
        )

        coordinator.runAtLaunch()
        XCTAssertTrue(historyStore.archivedDayIdentifiers().isEmpty)
        wait(for: [cleanupExpectation], timeout: 5)
    }

    func testPrelaunchRecoveryArchivesOnlyTheExactOlderDay() {
        let currentDay = "2026-09-17"
        let priorDay = "2026-09-15"
        let historyStore = makeHistoryStore(currentDay: currentDay)
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: priorDay, revision: 7) },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {}),
            currentDay: currentDay
        )

        XCTAssertEqual(coordinator.archivePriorDaySnapshotBeforeLaunchWrites(), .archived)
        guard case .available(let archived) = historyStore.readSnapshot(for: priorDay) else {
            XCTFail("the exact older snapshot day must be archived")
            return
        }
        XCTAssertEqual(archived.revision, 7)
        XCTAssertEqual(historyStore.readSnapshot(for: "2026-09-16"), .notFound)
        XCTAssertEqual(historyStore.readSnapshot(for: currentDay), .notFound)
    }

    func testPrelaunchRecoverySkipsSameFutureAndInvalidSnapshotDays() {
        let currentDay = "2026-09-17"
        for snapshotDay in [currentDay, "2026-09-18", "not-a-day"] {
            let historyStore = makeHistoryStore(currentDay: currentDay)
            let coordinator = makeCoordinator(
                snapshotProvider: { self.makeSnapshot(dayIdentifier: snapshotDay, revision: 3) },
                historyStore: historyStore,
                cleanupService: makeCleanupService(onCleanup: {}),
                currentDay: currentDay
            )

            XCTAssertEqual(
                coordinator.archivePriorDaySnapshotBeforeLaunchWrites(),
                .noCandidate,
                "snapshot day \(snapshotDay) must not be archived as a prior day"
            )
            XCTAssertTrue(historyStore.archivedDayIdentifiers().isEmpty)
        }
    }

    func testPrelaunchRecoveryAndDelayedTransitionPreserveNewerExistingHistory() {
        let currentDay = "2026-09-17"
        let priorDay = "2026-09-16"
        let historyStore = makeHistoryStore(currentDay: currentDay)
        _ = historyStore.archiveSnapshot(makeSnapshot(dayIdentifier: priorDay, revision: 8))
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: priorDay, revision: 5) },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {}),
            currentDay: currentDay
        )

        XCTAssertEqual(
            coordinator.archivePriorDaySnapshotBeforeLaunchWrites(),
            .existingArchivePreserved
        )
        coordinator.handleDayTransition(to: currentDay)

        guard case .available(let archived) = historyStore.readSnapshot(for: priorDay) else {
            XCTFail("existing valid history must remain readable")
            return
        }
        XCTAssertEqual(archived.revision, 8)
    }

    func testPrelaunchArchiveFailureLeavesCombinedSourceAvailable() throws {
        let currentDay = "2026-09-17"
        let blockerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-history-blocker-\(UUID().uuidString)")
        try Data("file blocks directory creation".utf8).write(to: blockerURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: blockerURL) }
        let historyStore = TinyBuddyHistoryStore(
            fileManager: .default,
            snapshotEncoder: TinyBuddyCombinedSnapshotStore.encodeV3,
            snapshotDecoder: TinyBuddyCombinedSnapshotStore.decodeV3,
            customContainerURL: blockerURL,
            currentDayIdentifierProvider: { currentDay }
        )
        let candidate = makeSnapshot(dayIdentifier: "2026-09-16", revision: 3)
        let coordinator = makeCoordinator(
            snapshotProvider: { candidate },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {}),
            currentDay: currentDay
        )

        XCTAssertEqual(coordinator.archivePriorDaySnapshotBeforeLaunchWrites(), .failed)
        XCTAssertEqual(coordinator.archivePriorDaySnapshotBeforeLaunchWrites(), .failed)
        XCTAssertEqual(historyStore.readSnapshot(for: "2026-09-16"), .notFound)
    }

    // MARK: - Day transition

    func testDayTransitionArchivesClosingDayBeforeRollover() {
        let historyStore = makeHistoryStore()
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: self.yesterdayIdentifier, revision: 5) },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {})
        )

        coordinator.handleDayTransition(to: todayIdentifier)

        guard case .available(let archived) = historyStore.readSnapshot(for: yesterdayIdentifier) else {
            XCTFail("closing day must be archived at day transition")
            return
        }
        XCTAssertEqual(archived.revision, 5)
        // The new day must not be archived or touched by the transition.
        XCTAssertEqual(historyStore.readSnapshot(for: todayIdentifier), .notFound)
    }

    func testDayTransitionSkipsWhenStoreAlreadyRolled() {
        let historyStore = makeHistoryStore()
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: self.todayIdentifier, revision: 9) },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {})
        )

        coordinator.handleDayTransition(to: todayIdentifier)

        XCTAssertTrue(historyStore.archivedDayIdentifiers().isEmpty)
    }

    func testDayTransitionDoesNotDisplaceExistingCurrentDayArchive() {
        let historyStore = makeHistoryStore()
        _ = historyStore.archiveSnapshot(
            makeSnapshot(dayIdentifier: todayIdentifier, revision: 3)
        )
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: self.yesterdayIdentifier, revision: 5) },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {})
        )

        coordinator.handleDayTransition(to: todayIdentifier)

        guard case .available(let current) = historyStore.readSnapshot(for: todayIdentifier) else {
            XCTFail("current day archive must survive the transition")
            return
        }
        XCTAssertEqual(current.revision, 3, "transition must not overwrite the current day")
        guard case .available(let closing) = historyStore.readSnapshot(for: yesterdayIdentifier) else {
            XCTFail("closing day must be archived")
            return
        }
        XCTAssertEqual(closing.revision, 5)
    }

    func testDayTransitionIgnoresInvalidDayIdentifier() {
        let historyStore = makeHistoryStore()
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: self.yesterdayIdentifier, revision: 5) },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {})
        )

        coordinator.handleDayTransition(to: "not-a-day")
        XCTAssertTrue(historyStore.archivedDayIdentifiers().isEmpty)
    }

    // MARK: - Committed snapshot archival

    func testCommittedSnapshotArchivesOnlyCurrentDayAndThrottles() {
        let historyStore = makeHistoryStore()
        var snapshot = makeSnapshot(dayIdentifier: todayIdentifier, revision: 1)
        let coordinator = makeCoordinator(
            snapshotProvider: { snapshot },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {})
        )

        coordinator.handleCommittedSnapshot(dayIdentifier: todayIdentifier)
        guard case .available(let first) = historyStore.readSnapshot(for: todayIdentifier) else {
            XCTFail("committed snapshot must be archived")
            return
        }
        XCTAssertEqual(first.revision, 1)

        // A second commit within the throttle interval is skipped.
        snapshot = makeSnapshot(dayIdentifier: todayIdentifier, revision: 2)
        coordinator.handleCommittedSnapshot(dayIdentifier: todayIdentifier)
        guard case .available(let second) = historyStore.readSnapshot(for: todayIdentifier) else {
            XCTFail("archive must remain readable")
            return
        }
        XCTAssertEqual(second.revision, 1, "throttled re-archive must not overwrite")

        // Termination bypasses the throttle and captures the final state.
        coordinator.handleTermination()
        guard case .available(let final) = historyStore.readSnapshot(for: todayIdentifier) else {
            XCTFail("final archive must be readable")
            return
        }
        XCTAssertEqual(final.revision, 2)
    }

    func testCommittedSnapshotIgnoresNonCurrentDays() {
        let historyStore = makeHistoryStore()
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: self.todayIdentifier, revision: 1) },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {})
        )

        coordinator.handleCommittedSnapshot(dayIdentifier: "2000-01-01")
        coordinator.handleCommittedSnapshot(dayIdentifier: yesterdayIdentifier)
        XCTAssertTrue(historyStore.archivedDayIdentifiers().isEmpty)
    }

    // MARK: - Termination

    func testTerminationArchivesFinalSnapshot() {
        let historyStore = makeHistoryStore()
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: self.todayIdentifier, revision: 11) },
            historyStore: historyStore,
            cleanupService: makeCleanupService(onCleanup: {})
        )

        coordinator.handleTermination()

        guard case .available(let archived) = historyStore.readSnapshot(for: todayIdentifier) else {
            XCTFail("termination must archive the final snapshot")
            return
        }
        XCTAssertEqual(archived.revision, 11)
    }

    // MARK: - Failure isolation

    func testCleanupFailureDoesNotAffectArchiveOrReads() {
        let historyStore = makeHistoryStore()
        let cleanupExpectation = expectation(description: "failing cleanup ran")
        // A cleanup whose preferences are unloadable returns an observation and
        // performs no file mutations — it must not disturb the archive.
        let failingCleanup = TinyBuddyStorageCleanupService(
            loadPreferences: {
                cleanupExpectation.fulfill()
                return nil
            },
            writeValue: { _, _ in false },
            removeValue: { _ in false },
            synchronize: { false },
            timeContextProvider: { nil },
            schemaVersionProvider: { nil },
            committedRevisionProvider: { nil },
            retentionPolicy: RetentionPolicy(staleKeyMaxAgeDays: 1, minFreeDiskSpaceBytes: 0)
        )
        let coordinator = makeCoordinator(
            snapshotProvider: { self.makeSnapshot(dayIdentifier: self.todayIdentifier, revision: 4) },
            historyStore: historyStore,
            cleanupService: failingCleanup
        )

        coordinator.runAtLaunch()

        guard case .available(let archived) = historyStore.readSnapshot(for: todayIdentifier) else {
            XCTFail("archive must remain readable after cleanup failure")
            return
        }
        XCTAssertEqual(archived.revision, 4)
        wait(for: [cleanupExpectation], timeout: 5)
    }

    func testDiskSpacePressureRunsCleanupImmediately() {
        let cleanupExpectation = expectation(description: "cleanup ran under disk pressure")
        let cleanupService = makeCleanupService(onCleanup: {
            cleanupExpectation.fulfill()
        })
        let coordinator = makeCoordinator(
            snapshotProvider: { nil },
            historyStore: makeHistoryStore(),
            cleanupService: cleanupService
        )

        coordinator.handleDiskSpacePressure()
        wait(for: [cleanupExpectation], timeout: 5)
    }

    // MARK: - Helpers

    private static func fixedDateForDay(_ dayId: String) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: Int(dayId.prefix(4)),
            month: Int(dayId.dropFirst(5).prefix(2)),
            day: Int(dayId.suffix(2)),
            hour: 12
        ))!
    }
}
