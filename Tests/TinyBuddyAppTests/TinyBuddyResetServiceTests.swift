import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

final class TinyBuddyResetServiceTests: XCTestCase {
    private var standardDefaults: UserDefaults!
    private var sharedDefaults: UserDefaults!
    private var containerURL: URL!
    private var temporaryURL: URL!
    private var userRepositoryURL: URL!
    private var standardDefaultsSuiteName = ""
    private var sharedDefaultsSuiteName = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let identifier = UUID().uuidString
        standardDefaultsSuiteName = "reset.standard.\(identifier)"
        sharedDefaultsSuiteName = "reset.shared.\(identifier)"
        standardDefaults = try makeDefaults(standardDefaultsSuiteName)
        sharedDefaults = try makeDefaults(sharedDefaultsSuiteName)
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyResetTests-\(identifier)", isDirectory: true)
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyResetTemporaryTests-\(identifier)", isDirectory: true)
        userRepositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyResetUserRepository-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: userRepositoryURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ref: refs/heads/main\n".utf8).write(
            to: userRepositoryURL.appendingPathComponent(".git/HEAD")
        )
    }

    override func tearDownWithError() throws {
        if let standardDefaults {
            standardDefaults.removePersistentDomain(forName: standardDefaultsSuiteName)
        }
        if let sharedDefaults {
            sharedDefaults.removePersistentDomain(forName: sharedDefaultsSuiteName)
        }
        if let containerURL {
            try? FileManager.default.removeItem(at: containerURL)
        }
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        if let userRepositoryURL {
            try? FileManager.default.removeItem(at: userRepositoryURL)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testRuntimeResetClearsOnlyOwnedRuntimeStateAndFiles() throws {
        populateRuntimeState()
        standardDefaults.set("bookmark", forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey)
        sharedDefaults.set("config", forKey: TinyBuddyConfigStore.Key.configPayload)
        try makeOwnedCacheFiles()

        let result = makeService().perform(level: .runtimeState)

        XCTAssertEqual(result, .success(TinyBuddyResetResult(
            level: .runtimeState,
            removedPreferenceKeyCount: 5,
            removedFileCount: 5
        )))
        XCTAssertNil(sharedDefaults.object(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot))
        XCTAssertNil(sharedDefaults.object(forKey: "tinybuddy.dailyStats.dayIdentifier"))
        XCTAssertNil(standardDefaults.object(forKey: GitTodayCommitCountStore.Key.count))
        XCTAssertEqual(standardDefaults.string(forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey), "bookmark")
        XCTAssertEqual(sharedDefaults.string(forKey: TinyBuddyConfigStore.Key.configPayload), "config")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repositoryCacheDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: buildLogsDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: releaseEvidenceDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: regressionEvidenceDirectory.path))
    }

    @MainActor
    func testSettingsResetClearsBookmarksConfigurationAndLoginItemButPreservesRuntime() {
        populateRuntimeState()
        standardDefaults.set("bookmark", forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey)
        standardDefaults.set("completed", forKey: TinyBuddyOnboardingStore.Key.state)
        sharedDefaults.set("config", forKey: TinyBuddyConfigStore.Key.configPayload)
        sharedDefaults.set("completed", forKey: TinyBuddyDisplaySharedState.onboardingStateKey)
        var unregisterCount = 0

        let result = makeService(unregisterLoginItem: { unregisterCount += 1 }).perform(level: .settings)

        XCTAssertEqual(unregisterCount, 1)
        XCTAssertEqual(result.map(\.level), .success(.settings))
        XCTAssertNil(standardDefaults.object(forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey))
        XCTAssertEqual(
            standardDefaults.string(forKey: TinyBuddyOnboardingStore.Key.state),
            TinyBuddyOnboardingStore.State.pending.rawValue
        )
        XCTAssertNil(sharedDefaults.object(forKey: TinyBuddyConfigStore.Key.configPayload))
        XCTAssertFalse(TinyBuddyDisplaySharedState.onboardingCompleted(userDefaults: sharedDefaults) ?? true)
        XCTAssertEqual(sharedDefaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot), "snapshot")
        XCTAssertEqual(standardDefaults.integer(forKey: GitTodayCommitCountStore.Key.count), 4)
        let widgetPresentation = TinyBuddyDisplayPresentation(
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 3, completionCount: 2)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 4,
                commitCount: 5,
                recentProjectName: "Retained Snapshot"
            ),
            onboardingCompleted: TinyBuddyDisplaySharedState.onboardingCompleted(
                userDefaults: sharedDefaults
            ) ?? true
        )
        XCTAssertEqual(widgetPresentation.state, .authorizationRequired)
        XCTAssertEqual(
            TinyBuddyOnboardingStore(
                userDefaults: standardDefaults,
                sharedDefaults: sharedDefaults
            ).state,
            .pending,
            "retained runtime data must not turn an explicit settings reset into a completed onboarding"
        )
    }

    @MainActor
    func testInterruptedResetRemainsRecoverableAndDoesNotReportSuccess() {
        populateRuntimeState()
        standardDefaults.set("bookmark", forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey)
        let failing = makeService(unregisterLoginItem: { throw TestError.denied })

        XCTAssertEqual(failing.perform(level: .allAppData), .failure(.launchItemUnregisterFailed))
        XCTAssertNotNil(sharedDefaults.object(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot))
        XCTAssertNotNil(standardDefaults.object(forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey))

        let recovery = makeService().recoverInterruptedResetIfNeeded()

        XCTAssertEqual(recovery.map { $0?.level }, .success(.allAppData))
        XCTAssertNil(sharedDefaults.object(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot))
        XCTAssertNil(standardDefaults.object(forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey))
        XCTAssertEqual(makeService().recoverInterruptedResetIfNeeded(), .success(nil))
    }

    @MainActor
    func testFileRemovalFailureLeavesJournalForOneExplicitRecoveryAttempt() throws {
        populateRuntimeState()
        try makeOwnedCacheFiles()
        let failureURL = repositoryCacheDirectory
        let failing = makeService(removeOwnedItem: { url in
            if url == failureURL {
                throw TestError.denied
            }
            try FileManager.default.removeItem(at: url)
        })

        XCTAssertEqual(failing.perform(level: .runtimeState), .failure(.removalFailed))
        XCTAssertNil(sharedDefaults.object(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryCacheDirectory.path))

        XCTAssertEqual(makeService().recoverInterruptedResetIfNeeded().map { $0?.level }, .success(.runtimeState))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repositoryCacheDirectory.path))
        XCTAssertEqual(makeService().recoverInterruptedResetIfNeeded(), .success(nil))
    }

    @MainActor
    func testClearAllNeverTouchesUserRepositoryOrGitMetadata() {
        populateRuntimeState()
        standardDefaults.set("bookmark", forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey)
        sharedDefaults.set("config", forKey: TinyBuddyConfigStore.Key.configPayload)

        XCTAssertEqual(makeService().perform(level: .allAppData).map(\.level), .success(.allAppData))
        let widgetRead = TinyBuddyCombinedSnapshotStore(
            userDefaults: sharedDefaults,
            sharedPreferencesProvider: { nil }
        ).readValidated()
        XCTAssertNil(widgetRead.snapshot, "an independently running Widget must not recover a cleared snapshot")
        XCTAssertEqual(TinyBuddyDisplaySharedState.onboardingCompleted(userDefaults: sharedDefaults), false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userRepositoryURL.path))
        XCTAssertEqual(
            try? String(contentsOf: userRepositoryURL.appendingPathComponent(".git/HEAD")),
            "ref: refs/heads/main\n"
        )
    }

    @MainActor
    func testClearAllThenSimulatedReinstallStartsFreshWithoutOldWidgetState() {
        populateRuntimeState()
        standardDefaults.set("bookmark", forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey)
        sharedDefaults.set("config", forKey: TinyBuddyConfigStore.Key.configPayload)

        XCTAssertEqual(makeService().perform(level: .allAppData).map(\.level), .success(.allAppData))

        let reinstalledOnboarding = TinyBuddyOnboardingStore(
            userDefaults: standardDefaults,
            sharedDefaults: sharedDefaults,
            legacyAuthorizationIsValid: { false }
        )
        let widgetRead = TinyBuddyCombinedSnapshotStore(
            userDefaults: sharedDefaults,
            sharedPreferencesProvider: { nil }
        ).readValidated()

        XCTAssertEqual(reinstalledOnboarding.state, .pending)
        XCTAssertNil(widgetRead.snapshot)
        XCTAssertNil(sharedDefaults.object(forKey: TinyBuddyConfigStore.Key.configPayload))
        XCTAssertNil(standardDefaults.object(forKey: GitScanRootAuthorizationStore.Constants.bookmarkDataKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userRepositoryURL.appendingPathComponent(".git/HEAD").path))
    }

    @MainActor
    func testCorruptResetJournalFailsClosedWithoutClearingAnyData() {
        populateRuntimeState()
        standardDefaults.set("unknown-reset-level", forKey: "tinybuddy.reset.journal.v1")

        let service = makeService()

        XCTAssertEqual(service.recoverInterruptedResetIfNeeded(), .failure(.journalCorrupt))
        XCTAssertEqual(service.perform(level: .allAppData), .failure(.journalCorrupt))
        XCTAssertEqual(sharedDefaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot), "snapshot")
        XCTAssertEqual(standardDefaults.string(forKey: "tinybuddy.reset.journal.v1"), "unknown-reset-level")
    }

    private enum TestError: Error {
        case denied
    }

    private func makeDefaults(_ suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Unable to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    private func makeService(
        removeOwnedItem: @escaping (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        unregisterLoginItem: @escaping () throws -> Void = {}
    ) -> TinyBuddyResetService {
        TinyBuddyResetService(
            standardDefaults: standardDefaults,
            sharedDefaults: sharedDefaults,
            appGroupContainerProvider: { self.containerURL },
            temporaryDirectoryProvider: { self.temporaryURL },
            removeOwnedItem: removeOwnedItem,
            unregisterLoginItem: unregisterLoginItem
        )
    }

    private func populateRuntimeState() {
        sharedDefaults.set("snapshot", forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        sharedDefaults.set("2026-07-20", forKey: "tinybuddy.dailyStats.dayIdentifier")
        sharedDefaults.set(3, forKey: "tinybuddy.dailyStats.focusCount")
        standardDefaults.set("2026-07-20", forKey: GitTodayCommitCountStore.Key.dayIdentifier)
        standardDefaults.set(4, forKey: GitTodayCommitCountStore.Key.count)
    }

    private var cacheDirectory: URL {
        containerURL
            .appendingPathComponent("Library/Caches/com.ryukeili.TinyBuddy", isDirectory: true)
    }

    private var repositoryCacheDirectory: URL {
        containerURL
            .appendingPathComponent("Library/Preferences/.tinybuddy-git-repository-cache", isDirectory: true)
    }

    private var buildLogsDirectory: URL {
        temporaryURL.appendingPathComponent("TinyBuddyBuildLogs", isDirectory: true)
    }

    private var releaseEvidenceDirectory: URL {
        temporaryURL.appendingPathComponent("TinyBuddyReleaseEvidence", isDirectory: true)
    }

    private var regressionEvidenceDirectory: URL {
        temporaryURL.appendingPathComponent("TinyBuddyRegressionEvidence", isDirectory: true)
    }

    private func makeOwnedCacheFiles() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repositoryCacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: buildLogsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: releaseEvidenceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: regressionEvidenceDirectory, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: cacheDirectory.appendingPathComponent("history"))
        try Data("cache".utf8).write(to: repositoryCacheDirectory.appendingPathComponent("repositories.txt"))
        try Data("build".utf8).write(to: buildLogsDirectory.appendingPathComponent("build.log"))
        try Data("release".utf8).write(to: releaseEvidenceDirectory.appendingPathComponent("stage.status"))
        try Data("regression".utf8).write(to: regressionEvidenceDirectory.appendingPathComponent("baseline.status"))
    }
}
