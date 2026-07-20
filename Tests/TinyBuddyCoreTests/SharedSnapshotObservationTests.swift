import XCTest
@testable import TinyBuddyCore

final class SharedSnapshotObservationTests: XCTestCase {
    func testValidatedReadUsesOneSourceReadWhenSnapshotIsHealthy() {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        let counter = ReadCounter()
        let store = makeCountingStore(values: validValues(for: snapshot), counter: counter)

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertEqual(result.snapshot, snapshot)
        XCTAssertNil(result.observation)
        XCTAssertEqual(counter.value, 1)
    }

    func testValidatedReadReturnsSameDaySnapshot() {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        let store = makeCountingStore(values: validValues(for: snapshot), counter: ReadCounter())

        XCTAssertEqual(
            store.readValidated(expectedDayIdentifier: "2026-07-16").snapshot,
            snapshot
        )
    }

    func testValidatedReadDoesNotReturnStaleSnapshot() {
        let store = makeCountingStore(
            values: validValues(for: makeSnapshot(dayIdentifier: "2026-07-15")),
            counter: ReadCounter()
        )

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.reason, .staleData)
        XCTAssertEqual(result.observation?.recovery, .stopped)
        XCTAssertEqual(result.observation?.attemptCount, 1)
    }

    func testChecksumCorruptionRereadsOnceAndUsesRedundantSnapshot() {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        var values = validValues(for: snapshot)
        values[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA] = corrupt(
            TinyBuddyCombinedSnapshotStore.encodeV2(snapshot)
        )
        let counter = ReadCounter()
        let store = makeCountingStore(values: values, counter: counter)

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertEqual(result.snapshot, snapshot)
        XCTAssertEqual(result.observation?.reason, .snapshotCorrupt)
        XCTAssertEqual(result.observation?.recovery, .rereadSucceeded)
        XCTAssertEqual(result.observation?.attemptCount, 2)
        XCTAssertEqual(counter.value, 2)
    }

    func testFullyCorruptSnapshotStopsAfterTwoReads() {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        let corrupted = corrupt(TinyBuddyCombinedSnapshotStore.encodeV2(snapshot))
        var values = validValues(for: snapshot)
        values[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA] = corrupted
        values[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB] = corrupted
        let counter = ReadCounter()
        let store = makeCountingStore(values: values, counter: counter)

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.reason, .snapshotCorrupt)
        XCTAssertEqual(result.observation?.recovery, .stopped)
        XCTAssertEqual(result.observation?.attemptCount, 2)
        XCTAssertEqual(counter.value, 2)
    }

    func testCorruptionFollowedByStaleSnapshotStopsAfterBoundedReread() {
        let staleSnapshot = makeSnapshot(dayIdentifier: "2026-07-15")
        let corrupted = corrupt(TinyBuddyCombinedSnapshotStore.encodeV2(staleSnapshot))
        let values: [[String: Any]] = [
            [TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA: corrupted],
            validValues(for: staleSnapshot)
        ]
        let counter = ReadCounter()
        let preferences = TinyBuddyAppGroupPreferencesStore(
            loadValues: { _, _ in
                let index = min(counter.value, values.count - 1)
                counter.value += 1
                return values[index]
            },
            setValue: { _, _, _ in },
            synchronize: { _ in true }
        )
        let store = TinyBuddyCombinedSnapshotStore(
            preferencesStore: preferences,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.reason, .staleData)
        XCTAssertEqual(result.observation?.recovery, .stopped)
        XCTAssertEqual(result.observation?.attemptCount, 2)
        XCTAssertEqual(counter.value, 2)
    }

    func testRecognizableButInvalidLegacySnapshotIsCorruption() {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        let counter = ReadCounter()
        let store = makeCountingStore(
            values: [
                TinyBuddyCombinedSnapshotStore.Key.snapshot:
                    corrupt(TinyBuddyCombinedSnapshotStore.encode(snapshot))
            ],
            counter: counter
        )

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.reason, .snapshotCorrupt)
        XCTAssertEqual(result.observation?.attemptCount, 2)
        XCTAssertEqual(counter.value, 2)
    }

    func testInjectedAccessFailuresAreClassifiedWithoutRetry() {
        for reason in [
            TinyBuddySharedSnapshotReason.appGroupUnavailable,
            .sandboxReadDenied
        ] {
            let defaults = UserDefaults(suiteName: "SharedSnapshotObservationTests.\(UUID().uuidString)")!
            let store = TinyBuddyCombinedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil },
                writeValue: { _, _ in true },
                synchronizeWrites: { true },
                readFailureProvider: { reason }
            )

            let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

            XCTAssertNil(result.snapshot)
            XCTAssertEqual(result.observation?.reason, reason)
            XCTAssertEqual(result.observation?.recovery, .stopped)
            XCTAssertEqual(result.observation?.attemptCount, 1)
        }
    }

    func testUnknownEnvelopeVersionStopsWithoutOverwritingInput() {
        let unknownEnvelope = "4\t17\tchecksum\tpayloadChecksum\tpayload"
        let values: [String: Any] = [
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA: unknownEnvelope
        ]
        let counter = ReadCounter()
        let store = makeCountingStore(values: values, counter: counter)

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.reason, .versionIncompatible)
        XCTAssertEqual(result.observation?.recovery, .stopped)
        XCTAssertEqual(result.observation?.attemptCount, 1)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(values[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA] as? String, unknownEnvelope)
    }

    func testTruncatedUnknownVersionsRemainVersionIncompatible() {
        let cases: [[String: Any]] = [
            [TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA: "4"],
            [TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2: "4\t17"]
        ]

        for values in cases {
            let counter = ReadCounter()
            let store = makeCountingStore(values: values, counter: counter)

            let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

            XCTAssertNil(result.snapshot)
            XCTAssertEqual(result.observation?.reason, .versionIncompatible)
            XCTAssertEqual(result.observation?.recovery, .stopped)
            XCTAssertEqual(counter.value, 1)
        }
    }

    func testFutureSchemaBlocksRepairAndUpdatesWithoutChangingPersistedValues() throws {
        let defaults = UserDefaults(
            suiteName: "SharedSnapshotObservationTests.\(UUID().uuidString)"
        )!
        let trusted = makeSnapshot(dayIdentifier: "2026-07-16")
        let futureSchema = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.encodeSchemaVersion(
                TinyBuddyCombinedSnapshotStore.currentSchemaVersion + 1
            )
        )
        let originalValues: [String: Any] = [
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA:
                TinyBuddyCombinedSnapshotStore.encodeV2(trusted),
            TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2:
                TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(trusted.revision)!,
            TinyBuddyCombinedSnapshotStore.Key.schemaVersion: futureSchema,
            "tinybuddy.future.only": "preserve-me"
        ]
        for (key, value) in originalValues {
            defaults.set(value, forKey: key)
        }
        var writeCount = 0
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                writeCount += 1
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                _ = defaults.synchronize()
                return true
            }
        )

        XCTAssertNil(store.load())
        let read = store.readValidated(expectedDayIdentifier: "2026-07-16")
        XCTAssertNil(read.snapshot)
        XCTAssertEqual(read.observation?.reason, .versionIncompatible)

        let update = store.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-16",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        )
        XCTAssertEqual(update.outcome, .versionIncompatible)
        XCTAssertFalse(update.didPersist)
        XCTAssertNil(update.snapshot)
        XCTAssertEqual(update.observation?.reason, .versionIncompatible)
        XCTAssertEqual(writeCount, 0)
        for (key, expectedValue) in originalValues {
            XCTAssertEqual(
                defaults.object(forKey: key) as? NSObject,
                expectedValue as? NSObject,
                "changed future-schema value for \(key)"
            )
        }
    }

    func testRecoveredRedundantSnapshotCanBeRepairedWithoutAnotherRevision() {
        let defaults = UserDefaults(suiteName: "SharedSnapshotObservationTests.\(UUID().uuidString)")!
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        var values = validValues(for: snapshot)
        values[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA] = corrupt(
            TinyBuddyCombinedSnapshotStore.encodeV2(snapshot)
        )
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )

        let recovered = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertEqual(recovered.snapshot, snapshot)
        XCTAssertEqual(recovered.observation?.reason, .snapshotCorrupt)
        XCTAssertTrue(store.repairValidatedSnapshot(snapshot))
        XCTAssertEqual(
            store.readValidated(expectedDayIdentifier: "2026-07-16"),
            TinyBuddyValidatedCombinedSnapshotRead(snapshot: snapshot, observation: nil)
        )
    }

    func testMalformedSnapshotPayloadIsObservedAsCorruption() {
        let counter = ReadCounter()
        let store = makeCountingStore(
            values: [TinyBuddyCombinedSnapshotStore.Key.snapshot: "not-a-snapshot"],
            counter: counter
        )

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.reason, .snapshotCorrupt)
        XCTAssertEqual(result.observation?.recovery, .stopped)
        XCTAssertEqual(result.observation?.attemptCount, 2)
        XCTAssertEqual(counter.value, 2)
    }

    func testMalformedCommittedMarkerIsObservedAsCorruption() {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        var values = validValues(for: snapshot)
        values[TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2] = "2\tbroken\tchecksum"
        let counter = ReadCounter()
        let store = makeCountingStore(values: values, counter: counter)

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.reason, .snapshotCorrupt)
        XCTAssertEqual(result.observation?.recovery, .stopped)
        XCTAssertEqual(result.observation?.attemptCount, 2)
        XCTAssertEqual(counter.value, 2)
    }

    func testTerminalAccessFailureDoesNotExposeFallbackCandidate() {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        let defaults = UserDefaults(suiteName: "SharedSnapshotObservationTests.\(UUID().uuidString)")!
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encode(snapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { _, _ in true },
            synchronizeWrites: { true },
            readFailureProvider: { .sandboxReadDenied }
        )

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.reason, .sandboxReadDenied)
        XCTAssertEqual(result.observation?.recovery, .stopped)
    }

    func testPersistenceFailureRemainsObservableOnUpdateResult() {
        let defaults = UserDefaults(suiteName: "SharedSnapshotObservationTests.\(UUID().uuidString)")!
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { _, _ in false },
            synchronizeWrites: { true }
        )

        let result = store.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-16", focusCount: 0, completionCount: 0)
            ),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(result.outcome, .persistenceFailed)
        XCTAssertFalse(result.didPersist)
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.observation?.phase, .snapshotWrite)
        XCTAssertEqual(result.observation?.reason, .persistenceFailed)
    }

    func testInvalidActivityRevisionDoesNotMasqueradeAsSnapshotCorruption() {
        let defaults = UserDefaults(suiteName: "SharedSnapshotObservationTests.\(UUID().uuidString)")!
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let snapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-16", focusCount: 0, completionCount: 0)
        )

        let result = store.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 1),
            activityRevision: -1,
            fallbackSnapshot: snapshot
        )

        XCTAssertEqual(result.outcome, .rejectedInvalidActivityRevision)
        XCTAssertFalse(result.didPersist)
        XCTAssertEqual(result.observation?.phase, .snapshotWrite)
        XCTAssertEqual(result.observation?.reason, .invalidActivityRevision)
        XCTAssertEqual(result.observation?.recovery, .stopped)
    }

    func testAppGroupPreferenceReaderClassifiesSandboxPermissionDenial() {
        let read = TinyBuddySharedData.readAppGroupPreferences(
            at: URL(fileURLWithPath: "/private/tmp/TinyBuddySharedSnapshotTests.plist"),
            dataLoader: { _ in
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadNoPermissionError
                )
            }
        )

        XCTAssertNil(read.values)
        XCTAssertEqual(read.failure, .sandboxReadDenied)
    }

    func testAppGroupPreferenceReaderTreatsMissingDomainAsFreshState() {
        let read = TinyBuddySharedData.readAppGroupPreferences(
            at: URL(fileURLWithPath: "/private/tmp/TinyBuddySharedSnapshotTests.plist"),
            dataLoader: { _ in
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileNoSuchFileError
                )
            }
        )

        XCTAssertNil(read.values)
        XCTAssertNil(read.failure)
    }

    func testAppGroupPreferenceReaderClassifiesInvalidPlistAsSnapshotCorruption() {
        let read = TinyBuddySharedData.readAppGroupPreferences(
            at: URL(fileURLWithPath: "/private/tmp/TinyBuddySharedSnapshotTests.plist"),
            dataLoader: { _ in Data("not a plist".utf8) }
        )

        XCTAssertNil(read.values)
        XCTAssertEqual(read.failure, .snapshotCorrupt)
    }

    private func makeCountingStore(
        values: [String: Any],
        counter: ReadCounter
    ) -> TinyBuddyCombinedSnapshotStore {
        let preferences = TinyBuddyAppGroupPreferencesStore(
            loadValues: { _, _ in
                counter.value += 1
                return values
            },
            setValue: { _, _, _ in },
            synchronize: { _ in true }
        )
        return TinyBuddyCombinedSnapshotStore(
            preferencesStore: preferences,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
    }

    private func validValues(for snapshot: TinyBuddyCombinedSnapshot) -> [String: Any] {
        [
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA:
                TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB:
                TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2:
                TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(snapshot.revision) as Any
        ]
    }

    private func makeSnapshot(dayIdentifier: String) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: 7,
            dayIdentifier: dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: dayIdentifier, focusCount: 2, completionCount: 1)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 5,
                recentProjectName: "Visible only in test data"
            ),
            activityRevision: 8
        )
    }

    private func corrupt(_ value: String) -> String {
        guard let finalCharacter = value.last else { return value + "x" }
        return String(value.dropLast()) + (finalCharacter == "A" ? "B" : "A")
    }
}

private final class ReadCounter {
    var value = 0
}
