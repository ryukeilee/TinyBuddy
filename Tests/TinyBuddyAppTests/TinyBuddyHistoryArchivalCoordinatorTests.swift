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

    private func makeHistoryStore() -> TinyBuddyHistoryStore {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinybuddy-archival-\\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

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
            currentDayIdentifierProvider: { [todayIdentifier] in todayIdentifier },
            quarantine: quarantine
        )
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
