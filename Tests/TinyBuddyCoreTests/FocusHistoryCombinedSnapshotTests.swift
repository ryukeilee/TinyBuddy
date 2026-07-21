import Foundation
import XCTest
@testable import TinyBuddyCore

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
                Dictionary(uniqueKeysWithValues: keys.compactMap { key in
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

    private final class MemoryPreferences {
        var values: [String: Any] = [:]
    }
}
