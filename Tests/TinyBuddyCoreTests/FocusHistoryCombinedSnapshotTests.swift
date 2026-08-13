import Foundation
import XCTest
@testable import TinyBuddyCore

private struct LegacyFocusHistoryPublication: Codable {
    let revision: Int64
    let snapshot: FocusHistorySnapshot
}

final class FocusHistoryCombinedSnapshotTests: XCTestCase {
    func testV3RoundTripKeepsHistoryPublication() throws {
        let publication = makePublication(revision: 8, completedSessionCount: 3)
        let snapshot = makeCombinedSnapshot(publication: publication)

        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))

        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decodeV3(encoded)?.focusHistoryPublication,
            publication
        )
    }

    func testV3RejectsMalformedHistoryPayload() throws {
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(
            makeCombinedSnapshot(publication: makePublication(revision: 8, completedSessionCount: 3))
        ))
        var fields = encoded.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        var format = PropertyListSerialization.PropertyListFormat.binary
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: try XCTUnwrap(Data(base64Encoded: fields[4])),
            options: [],
            format: &format
        ) as? [String: Any])
        plist["fh"] = Data("not a history plist".utf8)
        let payload = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        fields[3] = checksum(payload)
        fields[4] = payload.base64EncodedString()

        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(fields.joined(separator: "\t")))
    }

    func testV3WithoutHistoryDecodesForBackwardCompatibility() throws {
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(
            makeCombinedSnapshot(publication: nil)
        ))

        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV3(encoded)?.focusHistoryPublication)
    }

    func testLegacyHistoryPublicationDefaultsToInactiveState() throws {
        let current = makePublication(revision: 8, completedSessionCount: 3)
        let legacyData = try PropertyListEncoder().encode(
            LegacyFocusHistoryPublication(
                revision: current.revision,
                snapshot: current.snapshot
            )
        )

        let decoded = try PropertyListDecoder().decode(
            FocusHistoryPublication.self,
            from: legacyData
        )

        XCTAssertEqual(decoded.revision, current.revision)
        XCTAssertEqual(decoded.snapshot, current.snapshot)
        XCTAssertFalse(decoded.isFocusSessionActive)
        XCTAssertFalse(decoded.isFocusSessionPaused)
    }

    func testHistoryUpdateRejectsOlderArchiveRevisionButAcceptsEqualRevisionConfigurationRefresh() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let fallback = makeCombinedSnapshot(publication: nil).snapshot
        let original = makePublication(revision: 8, completedSessionCount: 3, goalMinutes: 60)
        let refreshed = makePublication(revision: 8, completedSessionCount: 3, goalMinutes: 90)
        let delayed = makePublication(revision: 7, completedSessionCount: 1)

        XCTAssertEqual(store.updateFocusHistorySlice(original, fallbackSnapshot: fallback).outcome, .saved)
        let refresh = store.updateFocusHistorySlice(refreshed, fallbackSnapshot: fallback)
        XCTAssertEqual(refresh.outcome, .saved)
        XCTAssertEqual(refresh.snapshot?.focusHistoryPublication, refreshed)

        let stale = store.updateFocusHistorySlice(delayed, fallbackSnapshot: fallback)
        XCTAssertEqual(stale.outcome, .alreadyCurrent)
        XCTAssertFalse(stale.didPersist)
        XCTAssertEqual(stale.snapshot?.focusHistoryPublication, refreshed)
    }

    func testHistoryUpdatePersistsLiveDurationBeforeAnySessionCompletes() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let fallback = makeCombinedSnapshot(publication: nil).snapshot
        let liveSessionID = UUID()
        let current = FocusHistoryDay(
            dayIdentifier: "2026-07-20",
            state: .sessions,
            focusDuration: 90,
            completedSessionCount: 0,
            goalMinutes: nil,
            goalCompletionRate: nil,
            isGoalMet: nil,
            contributingSessionIDs: [liveSessionID]
        )
        let publication = FocusHistoryPublication(
            revision: 8,
            snapshot: FocusHistorySnapshot(
                state: .available,
                sourceHealth: .available,
                recentDays: [
                    FocusHistoryDay(
                        dayIdentifier: "2026-07-19",
                        state: .noSessions,
                        focusDuration: 0,
                        completedSessionCount: 0,
                        goalMinutes: nil,
                        goalCompletionRate: nil,
                        isGoalMet: nil
                    ),
                    current
                ],
                currentWeek: FocusHistoryWeek(
                    startDayIdentifier: "2026-07-14",
                    endDayIdentifier: "2026-07-20",
                    state: .available,
                    focusDuration: 90,
                    completedSessionCount: 0,
                    goalCompletionRate: nil,
                    goalMetDayCount: nil,
                    configuredGoalDayCount: nil,
                    projectDistribution: [
                        FocusHistoryProject(
                            displayName: "Alpha",
                            isHistoricalArchive: false,
                            focusDuration: 90,
                            completedSessionCount: 0,
                            focusShare: 1,
                            contributingSessionIDs: [liveSessionID]
                        )
                    ]
                ),
                currentGoalStreakDays: nil
            )
        )

        let update = store.updateFocusHistorySlice(publication, fallbackSnapshot: fallback)

        XCTAssertEqual(update.outcome, .saved)
        XCTAssertEqual(update.snapshot?.focusHistoryPublication?.snapshot.recentDays.last, current)
    }

    func testActivityWriteRetainsHistoryPublication() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let fallback = makeCombinedSnapshot(publication: nil).snapshot
        let publication = makePublication(revision: 8, completedSessionCount: 3)

        XCTAssertEqual(store.updateFocusHistorySlice(publication, fallbackSnapshot: fallback).outcome, .saved)
        let update = store.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 4, commitCount: 2, recentProjectName: "Project A"),
            activityRevision: 1,
            fallbackSnapshot: fallback
        )

        XCTAssertEqual(update.outcome, .saved)
        XCTAssertEqual(update.snapshot?.focusHistoryPublication, publication)
    }

    func testUnknownHistoryDayDoesNotOverwriteDailyStatsWithZero() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 7, completionCount: 0)
        )
        let publication = makePublication(revision: 8, completedSessionCount: nil)

        let update = store.updateFocusHistorySlice(publication, fallbackSnapshot: fallback)

        XCTAssertEqual(update.outcome, .saved)
        XCTAssertEqual(update.snapshot?.snapshot.stats.focusCount, 7)
        XCTAssertNil(update.snapshot?.focusHistoryPublication?.snapshot.recentDays.last?.completedSessionCount)
    }

    func testSnapshotOverrideWritesStatusAndHistoryAtomically() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 0, completionCount: 0)
        )
        let publication = makePublication(revision: 8, completedSessionCount: 3, goalMinutes: 60)
        let overrideSnapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 3, completionCount: 0)
        )

        // Write both status and history in a single call
        let update = store.updateFocusHistorySlice(
            publication,
            fallbackSnapshot: fallback,
            snapshotOverride: overrideSnapshot
        )

        XCTAssertEqual(update.outcome, .saved)
        XCTAssertEqual(update.didPersist, true)
        XCTAssertEqual(update.snapshot?.snapshot.status, .focusing)
        XCTAssertEqual(update.snapshot?.snapshot.stats.focusCount, 3)
        XCTAssertEqual(update.snapshot?.focusHistoryPublication, publication)

        // Verify the combined snapshot reflects both
        XCTAssertEqual(update.snapshot?.dayIdentifier, "2026-07-20")
    }

    func testHistoryUpdateRejectsSemanticallyInvalidUnknownDay() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let fallback = makeCombinedSnapshot(publication: nil).snapshot
        let invalidDay = FocusHistoryDay(
            dayIdentifier: "2026-07-20",
            state: .unknown,
            focusDuration: 0,
            completedSessionCount: 0,
            goalMinutes: nil,
            goalCompletionRate: nil,
            isGoalMet: nil
        )
        let publication = FocusHistoryPublication(
            revision: 8,
            snapshot: FocusHistorySnapshot(
                state: .unknown,
                sourceHealth: .unavailable,
                recentDays: [invalidDay],
                currentWeek: FocusHistoryWeek(
                    startDayIdentifier: "2026-07-20",
                    endDayIdentifier: "2026-07-20",
                    state: .unknown,
                    focusDuration: nil,
                    completedSessionCount: nil,
                    goalCompletionRate: nil,
                    goalMetDayCount: nil,
                    configuredGoalDayCount: nil,
                    projectDistribution: nil
                ),
                currentGoalStreakDays: nil
            )
        )

        XCTAssertEqual(
            store.updateFocusHistorySlice(publication, fallbackSnapshot: fallback).outcome,
            .persistenceFailed
        )
        XCTAssertNil(store.load())
    }

    private func makeCombinedSnapshot(
        publication: FocusHistoryPublication?
    ) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: 42,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 1, completionCount: 0)
            ),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: nil, commitCount: nil),
            focusHistoryPublication: publication
        )
    }

    private func makePublication(
        revision: Int64,
        completedSessionCount: Int?,
        goalMinutes: Int = 60
    ) -> FocusHistoryPublication {
        let isUnknown = completedSessionCount == nil
        let previous = FocusHistoryDay(
            dayIdentifier: "2026-07-19",
            state: isUnknown ? .unknown : .noSessions,
            focusDuration: isUnknown ? nil : 0,
            completedSessionCount: isUnknown ? nil : 0,
            goalMinutes: isUnknown ? nil : goalMinutes,
            goalCompletionRate: isUnknown ? nil : 0,
            isGoalMet: isUnknown ? nil : false
        )
        let current = FocusHistoryDay(
            dayIdentifier: "2026-07-20",
            state: completedSessionCount == nil ? .unknown : .sessions,
            focusDuration: completedSessionCount.map { _ in 3_600 },
            completedSessionCount: completedSessionCount,
            goalMinutes: isUnknown ? nil : goalMinutes,
            goalCompletionRate: completedSessionCount.map { _ in 1 },
            isGoalMet: completedSessionCount.map { _ in true }
        )
        return FocusHistoryPublication(
            revision: revision,
            snapshot: FocusHistorySnapshot(
                state: completedSessionCount == nil ? .unknown : .available,
                sourceHealth: completedSessionCount == nil ? .unavailable : .available,
                recentDays: [previous, current],
                currentWeek: FocusHistoryWeek(
                    startDayIdentifier: "2026-07-14",
                    endDayIdentifier: "2026-07-20",
                    state: completedSessionCount == nil ? .unknown : .available,
                    focusDuration: completedSessionCount.map { _ in 3_600 },
                    completedSessionCount: completedSessionCount,
                    goalCompletionRate: completedSessionCount.map { _ in 1 },
                    goalMetDayCount: completedSessionCount.map { _ in 1 },
                    configuredGoalDayCount: completedSessionCount.map { _ in 2 },
                    projectDistribution: completedSessionCount.map { _ in [] }
                ),
                currentGoalStreakDays: completedSessionCount.map { _ in 1 }
            )
        )
    }

    private func makeStore(_ preferences: MemoryPreferences) -> TinyBuddyCombinedSnapshotStore {
        let adapter = TinyBuddyAppGroupPreferencesStore(
            applicationIdentifier: "group.example.TinyBuddy.history",
            loadValues: { _, keys in
                Dictionary(uniqueKeysWithValues: (keys ?? Array(preferences.values.keys)).compactMap { key in
                    preferences.values[key].map { (key, $0) }
                })
            },
            setValue: { _, key, value in preferences.values[key] = value },
            synchronize: { _ in true }
        )
        return TinyBuddyCombinedSnapshotStore(
            preferencesStore: adapter,
            sharedPreferencesProvider: { nil }
        )
    }

    private func checksum(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let value = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - value.count) + value
    }

    // MARK: - Engine → Combined Snapshot Integration

    func testEngineEditWritesUpdatedFocusHistoryToCombinedSnapshot() throws {
        let clock = FakeCombinedSnapshotClock(reference: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let store = MemoryCombinedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { date in
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.timeZone = TimeZone(secondsFromGMT: 0)
                fmt.dateFormat = "yyyy-MM-dd"
                return fmt.string(from: date)
            },
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            },
            historyGoalMinutes: { 240 },
            historyActiveProjectKeys: { _ in nil },
            projectContextResolver: { $0 },
            ruleVersionProvider: { FocusSessionRuleVersion.current }
        )

        // Create an initial ended session
        let projectA = FocusProjectContext(key: "repo/alpha", displayName: "Project Alpha")
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)
        clock.advance(by: 30)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)
        let sessionID = try XCTUnwrap(engine.allSessions.first?.id)
        let originalEnd = engine.allSessions.first!.endedAt!
        let sessionDay = engine.allSessions.first!.dayIdentifier

        // Set up combined snapshot store and wire the publication handler
        let preferences = MemoryPreferences()
        let combinedStore = makeStore(preferences)
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: sessionDay, focusCount: 0, completionCount: 0)
        )

        // Publish the initial state
        let revisionBox = SendableBox<Int64?>(nil)
        engine.committedSnapshotHandler = { _ in
            // Not used in this test
        }
        let storeHandle = StoreHandle(store: combinedStore)
        engine.committedHistorySnapshotHandler = { [handle = storeHandle, box = revisionBox] publication in
            box.value = publication.revision
            handle.update(publication, fallbackSnapshot: fallback)
        }

        // Trigger a publication to capture the initial session
        engine.republishFocusHistory()
        let initialRevision = try XCTUnwrap(revisionBox.value)

        // Verify initial publication shows 1 completed session
        var storedPublication = combinedStore.load()?.focusHistoryPublication
        let initialRecentDay = try XCTUnwrap(storedPublication?.snapshot.recentDays.last)
        XCTAssertEqual(initialRecentDay.completedSessionCount, 1)
        XCTAssertEqual(initialRecentDay.focusDuration ?? -1, 30, accuracy: 0.001)

        // Edit the session: change project and extend duration
        // Advance clock close to the new end time so it's within tolerance
        let projectB = FocusProjectContext(key: "repo/beta", displayName: "Project Beta")
        clock.set(to: originalEnd.addingTimeInterval(29.5)) // 0.5s before new end
        let extendedEnd = clock.now.addingTimeInterval(0.5) // Just 0.5s in the future
        guard case .saved = engine.editSession(id: sessionID, project: projectB, endedAt: extendedEnd) else {
            return XCTFail("Expected successful edit")
        }

        // Verify the stored publication was updated via the handler
        // (editSession calls committedHistorySnapshotHandler internally)
        let updatedRevision = try XCTUnwrap(revisionBox.value)
        XCTAssertGreaterThan(updatedRevision, initialRevision, "Edit must advance archive revision")

        storedPublication = combinedStore.load()?.focusHistoryPublication
        let updatedRecentDay = try XCTUnwrap(storedPublication?.snapshot.recentDays.last)
        XCTAssertEqual(updatedRecentDay.completedSessionCount, 1, "Still one session after edit")
        // Duration: original session started at t0 (1,000,000), ended at t0+30.
        // Edit extends end to t0+60, so active duration = 60 seconds.
        XCTAssertEqual(updatedRecentDay.focusDuration ?? -1, 60, accuracy: 0.001)

        // Verify project distribution reflects the new project
        let projectDistribution = try XCTUnwrap(storedPublication?.snapshot.currentWeek.projectDistribution)
        XCTAssertTrue(projectDistribution.contains { $0.displayName == "Project Beta" },
                      "Edited project must appear in distribution")
        XCTAssertFalse(projectDistribution.contains { $0.displayName == "Project Alpha" },
                       "Original project must not appear after reassignment")
    }

    func testEngineDeleteRemovesSessionFocusDurationFromCombinedSnapshot() throws {
        let clock = FakeCombinedSnapshotClock(reference: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let store = MemoryCombinedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { date in
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.timeZone = TimeZone(secondsFromGMT: 0)
                fmt.dateFormat = "yyyy-MM-dd"
                return fmt.string(from: date)
            },
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            },
            historyGoalMinutes: { 240 },
            historyActiveProjectKeys: { _ in nil }
        )

        // Create two ended sessions on different days
        let projectA = FocusProjectContext(key: "repo/alpha", displayName: "Project Alpha")
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)
        clock.advance(by: 30)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)
        let session1ID = try XCTUnwrap(engine.allSessions.first?.id)

        // Advance to a new day for the second session
        let nextDay = calendar.date(byAdding: .day, value: 1, to: clock.now)!
        clock.set(to: nextDay)
        // Notify the engine of the day change so currentDay matches the new day
        let newDayStr = dayID(for: nextDay)
        _ = engine.timeChanged(at: clock.now, dayIdentifier: newDayStr)
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)
        clock.advance(by: 60)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)
        let sessionIDs = engine.allSessions.map(\.id)
        let session2ID = sessionIDs.first(where: { $0 != session1ID })
        XCTAssertNotNil(session2ID)

        // Wire the combined snapshot store using the engine's current day
        let preferences = MemoryPreferences()
        let combinedStore = makeStore(preferences)
        let engineDay = engine.currentDayIdentifier
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: engineDay, focusCount: 0, completionCount: 0)
        )

        let handle = StoreHandle(store: combinedStore)
        engine.committedHistorySnapshotHandler = { [handle] publication in
            handle.update(publication, fallbackSnapshot: fallback)
        }

        // Publish initial state with both sessions
        engine.republishFocusHistory()
        let beforeDelete = try XCTUnwrap(combinedStore.load()?.focusHistoryPublication)
        let beforeDay = try XCTUnwrap(beforeDelete.snapshot.recentDays.last)
        // The most recent day has the second session (60s)
        XCTAssertEqual(beforeDay.completedSessionCount, 1)
        XCTAssertEqual(beforeDay.focusDuration ?? -1, 60, accuracy: 0.001)

        // Delete the second session
        clock.advance(by: 10)
        guard case .saved = engine.deleteSession(id: try XCTUnwrap(session2ID)) else {
            return XCTFail("Expected successful delete")
        }

        // Verify the combined snapshot was updated
        let afterDelete = try XCTUnwrap(combinedStore.load()?.focusHistoryPublication)
        let afterDay = try XCTUnwrap(afterDelete.snapshot.recentDays.last)
        XCTAssertEqual(afterDay.completedSessionCount, 0,
                       "After delete, most recent day must have zero completed sessions")
        XCTAssertEqual(afterDay.focusDuration ?? -1, 0, accuracy: 0.001,
                       "After delete, focus duration must be zero")
    }

    // MARK: - Helpers for Engine Integration Tests

    /// A clock that advances by a fixed step per call, used instead of
    /// FakeClock from FocusSessionEngineTests to avoid cross-file dependency.
    private final class FakeCombinedSnapshotClock: @unchecked Sendable, FocusClock {
        private var _now: Date
        var now: Date { _now }
        let monotonic: TimeInterval

        init(reference: Date) {
            _now = reference
            monotonic = reference.timeIntervalSinceReferenceDate
        }

        func advance(by seconds: TimeInterval) {
            _now = _now.addingTimeInterval(seconds)
        }

        func set(to date: Date) {
            _now = date
        }
    }

    /// An in-memory store that also conforms to FocusSessionPersisting for
    /// use with FocusSessionEngine.
    private final class MemoryCombinedStore: @unchecked Sendable, FocusSessionPersisting {
        var stored: [FocusSession]?

        func load() -> [FocusSession]? { stored }
        @discardableResult
        func save(_ sessions: [FocusSession]) -> Bool {
            stored = sessions
            return true
        }
    }

    /// A thread-safe wrapper for capturing values in @Sendable closures.
    private final class SendableBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Returns the UTC day identifier for a given date.
    private func dayID(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    // MARK: - Activity + History coexistence

    func testFocusHistoryWritePreservesPreviouslyCommittedActivityData() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let today = "2026-07-20"
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: today, focusCount: 0, completionCount: 0)
        )

        // Step 1: Write activity data first (simulates Git refresh at startup)
        let activity = GitTodayActivitySnapshot(
            focusBlockCount: 5, commitCount: 3, recentProjectName: "Project A"
        )
        XCTAssertEqual(
            store.updateActivitySlice(activity, activityRevision: 1, fallbackSnapshot: fallback).outcome,
            .saved
        )

        // Verify activity data is present
        var combined = store.load()
        XCTAssertEqual(combined?.activitySnapshot.focusBlockCount, 5)
        XCTAssertEqual(combined?.activitySnapshot.commitCount, 3)
        XCTAssertEqual(combined?.activitySnapshot.recentProjectName, "Project A")
        XCTAssertNil(combined?.focusHistoryPublication, "No history yet")

        // Step 2: Write focus history (simulates focus session update)
        let publication = makePublication(revision: 8, completedSessionCount: 2)
        let historyUpdate = store.updateFocusHistorySlice(publication, fallbackSnapshot: fallback)
        XCTAssertEqual(historyUpdate.outcome, .saved)

        // Verify BOTH activity data AND focus history persist
        combined = store.load()
        XCTAssertEqual(combined?.activitySnapshot.focusBlockCount, 5,
                       "Activity focusBlockCount must be preserved after history write")
        XCTAssertEqual(combined?.activitySnapshot.commitCount, 3,
                       "Activity commitCount must be preserved after history write")
        XCTAssertEqual(combined?.activitySnapshot.recentProjectName, "Project A",
                       "Recent project must be preserved after history write")
        XCTAssertEqual(combined?.focusHistoryPublication, publication,
                       "Focus history publication must be written")

        // Step 3: Write activity data again (simulates subsequent Git refresh)
        let activity2 = GitTodayActivitySnapshot(
            focusBlockCount: 7, commitCount: 4, recentProjectName: "Project B"
        )
        XCTAssertEqual(
            store.updateActivitySlice(activity2, activityRevision: 2, fallbackSnapshot: fallback).outcome,
            .saved
        )

        // Verify focus history survives the second activity write
        combined = store.load()
        XCTAssertEqual(combined?.activitySnapshot.focusBlockCount, 7)
        XCTAssertEqual(combined?.activitySnapshot.commitCount, 4)
        XCTAssertEqual(combined?.focusHistoryPublication, publication,
                       "Focus history publication must survive subsequent activity write")
    }

    func testFocusHistoryWritePreservesLiveDurationWithIncompleteSession() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let today = "2026-07-20"
        let fallback = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: today, focusCount: 0, completionCount: 0)
        )

        // Simulate an in-progress session (has duration but no completed sessions)
        let liveSessionID = UUID()
        let current = FocusHistoryDay(
            dayIdentifier: today,
            state: .sessions,
            focusDuration: 270, // 4 min 30 sec in progress
            completedSessionCount: 0,
            goalMinutes: nil,
            goalCompletionRate: nil,
            isGoalMet: nil,
            contributingSessionIDs: [liveSessionID]
        )
        let previous = FocusHistoryDay(
            dayIdentifier: "2026-07-19",
            state: .noSessions,
            focusDuration: 0,
            completedSessionCount: 0,
            goalMinutes: nil,
            goalCompletionRate: nil,
            isGoalMet: nil
        )
        let publication = FocusHistoryPublication(
            revision: 5,
            snapshot: FocusHistorySnapshot(
                state: .available,
                sourceHealth: .available,
                recentDays: [previous, current],
                currentWeek: FocusHistoryWeek(
                    startDayIdentifier: "2026-07-14",
                    endDayIdentifier: today,
                    state: .available,
                    focusDuration: 270,
                    completedSessionCount: 0,
                    goalCompletionRate: nil,
                    goalMetDayCount: nil,
                    configuredGoalDayCount: nil,
                    projectDistribution: [
                        FocusHistoryProject(
                            displayName: "Live Project",
                            isHistoricalArchive: false,
                            focusDuration: 270,
                            completedSessionCount: 0,
                            focusShare: 1,
                            contributingSessionIDs: [liveSessionID]
                        )
                    ]
                ),
                currentGoalStreakDays: nil
            )
        )

        // Write focus history with in-progress session
        let update = store.updateFocusHistorySlice(publication, fallbackSnapshot: fallback)
        XCTAssertEqual(update.outcome, .saved)
        XCTAssertEqual(update.didPersist, true)

        // Verify the stored publication has the live duration
        let stored = store.load()
        let storedDay = stored?.focusHistoryPublication?.snapshot.recentDays.last
        XCTAssertEqual(storedDay?.state, .sessions)
        XCTAssertEqual(storedDay?.focusDuration ?? -1, 270, accuracy: 0.001)
        XCTAssertEqual(storedDay?.completedSessionCount, 0,
                       "In-progress session must not increment completedSessionCount")
        XCTAssertEqual(storedDay?.contributingSessionIDs, [liveSessionID])

        // Verify the combined snapshot maintains the correct day and status
        XCTAssertEqual(stored?.dayIdentifier, today)
        XCTAssertEqual(stored?.snapshot.status, .focusing)
    }

    func testCrossDayActivityWriteDoesNotCorruptExistingFocusHistory() {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let today = "2026-07-20"
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: today, focusCount: 0, completionCount: 0)
        )

        // Write activity data for today first (simulates Git refresh)
        let initialActivity = GitTodayActivitySnapshot(
            focusBlockCount: 5, commitCount: 3, recentProjectName: "Project A"
        )
        XCTAssertEqual(
            store.updateActivitySlice(initialActivity, activityRevision: 1, fallbackSnapshot: fallback).outcome,
            .saved
        )

        // Write focus history for today
        let publication = makePublication(revision: 8, completedSessionCount: 2)
        XCTAssertEqual(
            store.updateFocusHistorySlice(publication, fallbackSnapshot: fallback).outcome,
            .saved
        )

        // Now write activity for a DIFFERENT day (simulates Git refresh on a
        // new day before any focus history was committed for that day)
        let tomorrow = "2026-07-21"
        let tomorrowFallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: tomorrow, focusCount: 0, completionCount: 0)
        )
        let nextActivity = GitTodayActivitySnapshot(
            focusBlockCount: 3, commitCount: 1, recentProjectName: "Project C"
        )
        let activityUpdate = store.updateActivitySlice(
            nextActivity, activityRevision: 2, fallbackSnapshot: tomorrowFallback
        )
        XCTAssertEqual(activityUpdate.outcome, .saved)

        // Verify the NEW day's snapshot has activity but NO history (correct)
        let tomorrowSnapshot = store.readValidated(expectedDayIdentifier: tomorrow).snapshot
        XCTAssertEqual(tomorrowSnapshot?.dayIdentifier, tomorrow)
        XCTAssertEqual(tomorrowSnapshot?.activitySnapshot.focusBlockCount, 3)
        XCTAssertNil(tomorrowSnapshot?.focusHistoryPublication,
                     "New day must not inherit previous day's focus history")

        // Verify the ORIGINAL day's data is completely unchanged
        let todaySnapshot = store.readValidated(expectedDayIdentifier: today).snapshot
        XCTAssertEqual(todaySnapshot?.dayIdentifier, today)
        XCTAssertEqual(todaySnapshot?.focusHistoryPublication, publication,
                       "Today's focus history must survive cross-day activity write")
        XCTAssertEqual(todaySnapshot?.activitySnapshot.focusBlockCount, 5,
                       "Today's activity data must survive cross-day activity write")
        XCTAssertEqual(todaySnapshot?.activitySnapshot.commitCount, 3,
                       "Today's commit count must survive cross-day activity write")
    }

    /// A @unchecked Sendable handle to the non-Sendable combined snapshot store.
    /// The engine calls the handler while holding its lock, so access is
    /// serialised and safe despite the lack of formal Sendable conformance.
    private final class StoreHandle: @unchecked Sendable {
        private let store: TinyBuddyCombinedSnapshotStore
        init(store: TinyBuddyCombinedSnapshotStore) { self.store = store }
        func update(_ publication: FocusHistoryPublication, fallbackSnapshot: TinyBuddySnapshot) {
            _ = store.updateFocusHistorySlice(publication, fallbackSnapshot: fallbackSnapshot)
        }
    }

    private final class MemoryPreferences {
        var values: [String: Any] = [:]
    }

    // MARK: - End-to-End Integration: Engine → Combined Snapshot → Widget

    /// Simulates the complete cold-start path:
    /// 1. No pre-existing combined snapshot (fresh install / reinstall)
    /// 2. Focus engine starts a live session (active, no ended sessions yet)
    /// 3. Publication is written to the combined snapshot
    /// 4. Widget reads the combined snapshot and gets valid focus duration
    func testColdStartWithLiveSessionProducesValidFocusHistoryPublication() throws {
        let clock = FakeCombinedSnapshotClock(reference: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let store = MemoryCombinedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayProvider: (Date) -> String = { date in
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: date)
        }
        let currentDay = dayProvider(clock.now)

        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: dayProvider,
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            },
            historyGoalMinutes: { 240 },
            historyActiveProjectKeys: { _ in nil }
        )

        // Wire the combined snapshot store
        let preferences = MemoryPreferences()
        let combinedStore = makeStore(preferences)
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: currentDay, focusCount: 0, completionCount: 0)
        )

        // Capture publications
        let writtenPub = SendableBox<FocusHistoryPublication?>(nil)
        let handle = StoreHandle(store: combinedStore)
        engine.committedHistorySnapshotHandler = { [handle, box = writtenPub] publication in
            box.value = publication
            handle.update(publication, fallbackSnapshot: fallback)
        }

        // Step 1: Start a live session (simulating auto-focus engine on cold start)
        let projectA = FocusProjectContext(key: "com.example.App", displayName: "Example App")
        clock.advance(by: 5) // 5 seconds after reference
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)

        // Verify the session was started
        XCTAssertEqual(engine.allSessions.count, 1)
        let session = try XCTUnwrap(engine.allSessions.first)
        XCTAssertTrue(session.isOpen)
        XCTAssertEqual(session.status, .active)

        // Step 2: Advance clock and republish to simulate live duration update
        clock.advance(by: 60) // 1 minute of focus
        engine.republishFocusHistory()

        // Step 3: Verify the publication was written to the combined snapshot
        let publication = try XCTUnwrap(writtenPub.value)
        XCTAssertGreaterThan(publication.revision, 0)

        // Step 4: Read the combined snapshot as the Widget would
        let combined = try XCTUnwrap(combinedStore.load())
        let widgetPub = try XCTUnwrap(combined.focusHistoryPublication)
        XCTAssertEqual(widgetPub.revision, publication.revision)

        // Step 5: Verify the focus duration is valid (non-nil, > 0)
        let recentDay = try XCTUnwrap(widgetPub.snapshot.recentDays.last)
        XCTAssertEqual(recentDay.dayIdentifier, currentDay)
        XCTAssertNotNil(recentDay.focusDuration, "focusDuration must not be nil for a live session")
        XCTAssertGreaterThan(recentDay.focusDuration ?? -1, 0, "Live session must have positive focus duration")
        XCTAssertEqual(recentDay.state, .sessions, "Live session day should be .sessions")
        // No completed sessions yet (session is still active)
        XCTAssertEqual(recentDay.completedSessionCount, 0)
    }

    /// Simulates the scenario where only a live (in-progress) session exists
    /// with no completed sessions. The Widget should show the elapsed duration
    /// correctly, never "未知".
    func testInProgressSessionWithoutCompletedSessions() throws {
        let clock = FakeCombinedSnapshotClock(reference: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let store = MemoryCombinedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayProvider: (Date) -> String = { date in
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: date)
        }
        let currentDay = dayProvider(clock.now)

        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: dayProvider,
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            },
            historyGoalMinutes: { 240 },
            historyActiveProjectKeys: { _ in nil }
        )

        let preferences = MemoryPreferences()
        let combinedStore = makeStore(preferences)
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: currentDay, focusCount: 0, completionCount: 0)
        )

        let writtenPub = SendableBox<FocusHistoryPublication?>(nil)
        let handle = StoreHandle(store: combinedStore)
        engine.committedHistorySnapshotHandler = { [handle, box = writtenPub] publication in
            box.value = publication
            handle.update(publication, fallbackSnapshot: fallback)
        }

        // Start a live session and let it run for 15 minutes
        let projectA = FocusProjectContext(key: "com.example.App", displayName: "Example App")
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)
        clock.advance(by: 900) // 15 minutes

        // Republish to simulate live duration update from publishLiveFocusHistoryIfNeeded
        engine.republishFocusHistory()

        // The live duration is 900 seconds, but no completed sessions
        let combined = try XCTUnwrap(combinedStore.load())
        let pub = try XCTUnwrap(combined.focusHistoryPublication)
        let day = try XCTUnwrap(pub.snapshot.recentDays.last)

        // State should be .sessions (live session is accumulating)
        XCTAssertEqual(day.state, .sessions)
        // Duration must be provided (completedSessionCount can be 0)
        XCTAssertNotNil(day.focusDuration)
        XCTAssertEqual(day.focusDuration ?? -1, 900, accuracy: 0.001)
        // No completed sessions
        XCTAssertEqual(day.completedSessionCount, 0)
        // Confirm the formatter would NOT return "未知"
        XCTAssertNotEqual(FocusHistoryDurationFormatter.text(for: day.focusDuration), "未知")
        XCTAssertEqual(FocusHistoryDurationFormatter.text(for: day.focusDuration), "0 小时 15 分")
    }

    /// When the day has NO sessions at all (trustworthy zero focus), the
    /// Widget must show "0 小时 0 分" rather than "未知".
    func testTrustworthyZeroFocusShowsZeroNotUnknown() throws {
        let clock = FakeCombinedSnapshotClock(reference: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let store = MemoryCombinedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayProvider: (Date) -> String = { date in
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: date)
        }
        let currentDay = dayProvider(clock.now)

        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: dayProvider,
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            },
            historyGoalMinutes: { 240 },
            historyActiveProjectKeys: { _ in nil }
        )

        let preferences = MemoryPreferences()
        let combinedStore = makeStore(preferences)
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: currentDay, focusCount: 0, completionCount: 0)
        )

        let writtenPub = SendableBox<FocusHistoryPublication?>(nil)
        let handle = StoreHandle(store: combinedStore)
        engine.committedHistorySnapshotHandler = { [handle, box = writtenPub] publication in
            box.value = publication
            handle.update(publication, fallbackSnapshot: fallback)
        }

        // No sessions at all - publish initial (empty) state
        engine.republishFocusHistory()

        let publication = try XCTUnwrap(writtenPub.value)
        let day = try XCTUnwrap(publication.snapshot.recentDays.last)
        XCTAssertEqual(day.state, .noSessions)
        XCTAssertEqual(day.focusDuration, 0)
        XCTAssertEqual(day.completedSessionCount, 0)
        // Formatter must return "0 小时 0 分" not "未知"
        XCTAssertEqual(FocusHistoryDurationFormatter.text(for: day.focusDuration), "0 小时 0 分")
    }

    /// After editing a session (changing project), the combined snapshot must
    /// reflect the updated focus history. Verifies the publication revision
    /// advances and focus duration remains accurate.
    func testEditAfterSessionUpdatesFocusHistoryPublication() throws {
        let clock = FakeCombinedSnapshotClock(reference: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let store = MemoryCombinedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayProvider: (Date) -> String = { date in
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: date)
        }
        let currentDay = dayProvider(clock.now)

        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: dayProvider,
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            },
            historyGoalMinutes: { 240 },
            historyActiveProjectKeys: { _ in nil }
        )

        let preferences = MemoryPreferences()
        let combinedStore = makeStore(preferences)
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: currentDay, focusCount: 0, completionCount: 0)
        )

        let writtenPub = SendableBox<FocusHistoryPublication?>(nil)
        let handle = StoreHandle(store: combinedStore)
        engine.committedHistorySnapshotHandler = { [handle, box = writtenPub] publication in
            box.value = publication
            handle.update(publication, fallbackSnapshot: fallback)
        }

        // Create a session
        let projectA = FocusProjectContext(key: "repo/alpha", displayName: "Project Alpha")
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)
        clock.advance(by: 30)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)
        let sessionID = try XCTUnwrap(engine.allSessions.first?.id)
        let beforeEditRevision = try XCTUnwrap(writtenPub.value?.revision)

        // Edit the session: change project
        let projectB = FocusProjectContext(key: "repo/beta", displayName: "Project Beta")
        let originalEnd = engine.allSessions.first!.endedAt!
        clock.set(to: originalEnd.addingTimeInterval(-0.1))
        guard case .saved = engine.editSession(id: sessionID, project: projectB) else {
            return XCTFail("Expected successful edit")
        }

        // Verify revision advanced
        let afterEditPub = try XCTUnwrap(writtenPub.value)
        XCTAssertGreaterThan(afterEditPub.revision, beforeEditRevision,
                             "Edit must advance publication revision")

        // Verify the combined snapshot reflects the edit
        let combined = try XCTUnwrap(combinedStore.load())
        let pub = try XCTUnwrap(combined.focusHistoryPublication)
        let day = try XCTUnwrap(pub.snapshot.recentDays.last)
        XCTAssertNotNil(day.focusDuration, "Focus duration must survive edit")
        XCTAssertEqual(day.completedSessionCount, 1, "One completed session")
    }

    /// After deleting a session, the combined snapshot must reflect the
    /// reduced (zero) focus duration and completed session count.
    func testDeleteAfterSessionUpdatesFocusHistoryPublication() throws {
        let clock = FakeCombinedSnapshotClock(reference: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let store = MemoryCombinedStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayProvider: (Date) -> String = { date in
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: date)
        }
        let currentDay = dayProvider(clock.now)

        let engine = FocusSessionEngine(
            clock: clock,
            persisting: store,
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: dayProvider,
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            },
            historyGoalMinutes: { 240 },
            historyActiveProjectKeys: { _ in nil }
        )

        let preferences = MemoryPreferences()
        let combinedStore = makeStore(preferences)
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: currentDay, focusCount: 0, completionCount: 0)
        )

        let writtenPub = SendableBox<FocusHistoryPublication?>(nil)
        let handle = StoreHandle(store: combinedStore)
        engine.committedHistorySnapshotHandler = { [handle, box = writtenPub] publication in
            box.value = publication
            handle.update(publication, fallbackSnapshot: fallback)
        }

        // Create a session and end it
        let projectA = FocusProjectContext(key: "repo/alpha", displayName: "Project Alpha")
        XCTAssertEqual(engine.userActivity(in: projectA, at: clock.now), .saved)
        clock.advance(by: 30)
        XCTAssertEqual(engine.lockScreen(at: clock.now), .saved)
        let sessionID = try XCTUnwrap(engine.allSessions.first?.id)

        // Verify publication reflects the session
        var combined = try XCTUnwrap(combinedStore.load())
        var pub = try XCTUnwrap(combined.focusHistoryPublication)
        var day = try XCTUnwrap(pub.snapshot.recentDays.last)
        XCTAssertEqual(day.completedSessionCount, 1)
        XCTAssertEqual(day.focusDuration ?? -1, 30, accuracy: 0.001)

        // Delete the session
        clock.advance(by: 10)
        guard case .saved = engine.deleteSession(id: sessionID) else {
            return XCTFail("Expected successful delete")
        }

        // Verify publication is updated
        combined = try XCTUnwrap(combinedStore.load())
        pub = try XCTUnwrap(combined.focusHistoryPublication)
        day = try XCTUnwrap(pub.snapshot.recentDays.last)
        XCTAssertEqual(day.completedSessionCount, 0, "After delete, zero sessions")
        XCTAssertEqual(day.focusDuration ?? -1, 0, accuracy: 0.001, "After delete, zero duration")
        XCTAssertEqual(day.state, .noSessions)
    }

    /// Activity write must never overwrite existing focus history publication.
    /// This simulates Git refresh committing activity while a focus session
    /// publication is already in the combined snapshot.
    func testActivityWriteDoesNotOverwriteFocusHistoryPublication() throws {
        let preferences = MemoryPreferences()
        let store = makeStore(preferences)
        let today = "2026-07-20"
        let fallback = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: today, focusCount: 0, completionCount: 0)
        )

        // Write focus history first
        let publication = makePublication(revision: 8, completedSessionCount: 2)
        XCTAssertEqual(store.updateFocusHistorySlice(publication, fallbackSnapshot: fallback).outcome, .saved)

        // Then write activity data (same day)
        let activity = GitTodayActivitySnapshot(
            focusBlockCount: 5, commitCount: 3, recentProjectName: "Project A"
        )
        let activityUpdate = store.updateActivitySlice(activity, activityRevision: 1, fallbackSnapshot: fallback)
        XCTAssertEqual(activityUpdate.outcome, .saved)

        // Verify focus history survived
        let combined = try XCTUnwrap(store.load())
        XCTAssertNotNil(combined.focusHistoryPublication, "Focus history must survive activity write")
        XCTAssertEqual(combined.focusHistoryPublication, publication)
        XCTAssertEqual(combined.activitySnapshot.focusBlockCount, 5)
        XCTAssertEqual(combined.activitySnapshot.commitCount, 3)
    }


}
