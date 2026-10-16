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

    func testAdvisorySharedFileReadFailureDoesNotHideValidUserDefaultsSnapshot() {
        let snapshot = makeSnapshot(dayIdentifier: "2026-07-16")
        let defaults = UserDefaults(
            suiteName: "SharedSnapshotObservationTests.\(UUID().uuidString)"
        )!
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encode(snapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false,
            writeValue: { _, _ in true },
            synchronizeWrites: { true },
            readFailureProvider: { .sandboxReadDenied },
            readFailureIsAdvisory: true
        )

        let result = store.readValidated(expectedDayIdentifier: "2026-07-16")

        XCTAssertEqual(result.snapshot, snapshot)
        XCTAssertNil(result.observation)
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

    // MARK: - Snapshot read payload-decode cost

    /// Redundant-copies upper bound: both transactional slots hold the exact
    /// same current-revision V3 raw value.
    ///
    /// This is an upper bound, not the production steady state.
    /// `transactionalTargetKey(for:)` always overwrites the older-or-empty
    /// slot, so once a second revision is committed the two slots carry
    /// different revisions, and
    /// `repairAncillaryCopiesLocked` only mirrors into a slot that is nil or
    /// same-revision-but-different-content. Byte-identical slot contents only
    /// happen when a duplicate copy exists, so this variant measures the most
    /// any same-content sharing could ever save: the payload appears twice
    /// verbatim in one read.
    ///
    /// Measures the read-only entry point over a V3 payload whose `fh`
    /// focus-history publication is large enough that envelope and payload
    /// decoding dominate a read. Every measured iteration reloads the same raw
    /// values from scratch, so the numbers track per-read decode work rather
    /// than any cross-read cache.
    func testLoadReadOnlyDecodeCostWithRedundantSlotCopies() throws {
        let dayIdentifier = "2026-07-16"
        let snapshot = makeDecodeHeavySnapshot(
            dayIdentifier: dayIdentifier,
            revision: 7,
            historyDayCount: 300,
            projectCount: 60
        )
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let counter = ReadCounter()
        let store = makeCountingStore(
            values: redundantCopyValues(encodedV3: encoded, snapshot: snapshot),
            counter: counter
        )

        // Self-verification: the measured path must really decode the payload
        // instead of settling for an empty or stale candidate set, and one
        // read must still load the source exactly once.
        let readOnly = store.loadReadOnly()
        XCTAssertEqual(readOnly, snapshot)
        XCTAssertEqual(readOnly?.revision, snapshot.revision)
        XCTAssertEqual(readOnly?.dayIdentifier, dayIdentifier)
        XCTAssertEqual(readOnly?.focusHistoryPublication, snapshot.focusHistoryPublication)
        XCTAssertEqual(counter.value, 1)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            XCTAssertEqual(store.loadReadOnly(), snapshot)
        }
    }

    /// Measures the validated read path over the same redundant-copies
    /// large-focus-history V3 payload used by
    /// `testLoadReadOnlyDecodeCostWithRedundantSlotCopies`.
    func testReadValidatedDecodeCostWithRedundantSlotCopies() throws {
        let dayIdentifier = "2026-07-16"
        let snapshot = makeDecodeHeavySnapshot(
            dayIdentifier: dayIdentifier,
            revision: 7,
            historyDayCount: 300,
            projectCount: 60
        )
        let encoded = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeV3(snapshot))
        let counter = ReadCounter()
        let store = makeCountingStore(
            values: redundantCopyValues(encodedV3: encoded, snapshot: snapshot),
            counter: counter
        )

        let validated = store.readValidated(expectedDayIdentifier: dayIdentifier)
        XCTAssertEqual(validated.snapshot, snapshot)
        XCTAssertEqual(validated.snapshot?.revision, snapshot.revision)
        XCTAssertEqual(validated.snapshot?.dayIdentifier, dayIdentifier)
        XCTAssertEqual(
            validated.snapshot?.focusHistoryPublication,
            snapshot.focusHistoryPublication
        )
        XCTAssertNil(validated.observation)
        XCTAssertEqual(counter.value, 1)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            XCTAssertEqual(
                store.readValidated(expectedDayIdentifier: dayIdentifier).snapshot,
                snapshot
            )
        }
    }

    /// Production steady state after a commit: slot A keeps the previous
    /// revision's V3 payload and slot B the current one, which is what
    /// `transactionalTargetKey(for:)` leaves behind. The two slots therefore
    /// hold different content and both must be decoded before the newer
    /// revision can be selected.
    func testLoadReadOnlyDecodeCostWithPreviousRevisionSlotCopies() throws {
        let dayIdentifier = "2026-07-16"
        let current = makeDecodeHeavySnapshot(
            dayIdentifier: dayIdentifier,
            revision: 8,
            historyDayCount: 300,
            projectCount: 60
        )
        let previous = makeDecodeHeavySnapshot(
            dayIdentifier: dayIdentifier,
            revision: 7,
            historyDayCount: 299,
            projectCount: 60
        )
        let encodedPrevious = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.encodeV3(previous)
        )
        let encodedCurrent = try XCTUnwrap(
            TinyBuddyCombinedSnapshotStore.encodeV3(current)
        )
        let counter = ReadCounter()
        let store = makeCountingStore(
            values: steadyStateValues(
                current: current,
                encodedPrevious: encodedPrevious,
                encodedCurrent: encodedCurrent
            ),
            counter: counter
        )

        // Self-verification: the measured path must decode both slot payloads
        // and select the newer revision rather than the first slot visited,
        // and one read must still load the source exactly once.
        let readOnly = store.loadReadOnly()
        XCTAssertEqual(readOnly, current)
        XCTAssertEqual(readOnly?.revision, current.revision)
        XCTAssertEqual(readOnly?.revision, 8)
        XCTAssertEqual(readOnly?.dayIdentifier, dayIdentifier)
        XCTAssertEqual(readOnly?.focusHistoryPublication, current.focusHistoryPublication)
        XCTAssertNotEqual(readOnly, previous)
        XCTAssertEqual(counter.value, 1)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            XCTAssertEqual(store.loadReadOnly(), current)
        }
    }

    /// Redundant-copies upper bound: the current-revision V3 envelope appears
    /// verbatim in both transactional slots, while the V1 key still carries the
    /// legacy mirror and the ancillary markers are present.
    private func redundantCopyValues(
        encodedV3: String,
        snapshot: TinyBuddyCombinedSnapshot
    ) -> [String: Any] {
        [
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA: encodedV3,
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB: encodedV3,
            TinyBuddyCombinedSnapshotStore.Key.snapshot:
                TinyBuddyCombinedSnapshotStore.encode(snapshot),
            TinyBuddyCombinedSnapshotStore.Key.highestRevision: snapshot.revision,
            TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2:
                TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(snapshot.revision) as Any,
            TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2:
                TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(snapshot.revision) as Any,
            TinyBuddyCombinedSnapshotStore.Key.schemaVersion:
                TinyBuddyCombinedSnapshotStore.encodeSchemaVersion() as Any
        ]
    }

    /// Production steady state: slot A keeps the previous revision's V3 payload
    /// and slot B the current revision's, with the V1 key mirroring the
    /// committed current snapshot and the committed markers at its revision.
    private func steadyStateValues(
        current: TinyBuddyCombinedSnapshot,
        encodedPrevious: String,
        encodedCurrent: String
    ) -> [String: Any] {
        [
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA: encodedPrevious,
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB: encodedCurrent,
            TinyBuddyCombinedSnapshotStore.Key.snapshot:
                TinyBuddyCombinedSnapshotStore.encode(current),
            TinyBuddyCombinedSnapshotStore.Key.highestRevision: current.revision,
            TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2:
                TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(current.revision) as Any,
            TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2:
                TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(current.revision) as Any,
            TinyBuddyCombinedSnapshotStore.Key.schemaVersion:
                TinyBuddyCombinedSnapshotStore.encodeSchemaVersion() as Any
        ]
    }

    private func makeDecodeHeavySnapshot(
        dayIdentifier: String,
        revision: Int64,
        historyDayCount: Int,
        projectCount: Int
    ) -> TinyBuddyCombinedSnapshot {
        let days = makeHistoryDays(endingAt: dayIdentifier, count: historyDayCount)
        let projects = (0 ..< projectCount).map { index in
            FocusHistoryProject(
                displayName: "Project \(index)",
                isHistoricalArchive: index.isMultiple(of: 2),
                focusDuration: Double(index * 60),
                completedSessionCount: index,
                focusShare: 1 / Double(projectCount)
            )
        }
        let publication = FocusHistoryPublication(
            revision: revision,
            snapshot: FocusHistorySnapshot(
                state: .available,
                sourceHealth: .available,
                recentDays: days,
                currentWeek: FocusHistoryWeek(
                    startDayIdentifier: days.first?.dayIdentifier ?? dayIdentifier,
                    endDayIdentifier: dayIdentifier,
                    state: .available,
                    focusDuration: 12_345,
                    completedSessionCount: historyDayCount,
                    goalCompletionRate: 0.75,
                    goalMetDayCount: 3,
                    configuredGoalDayCount: 4,
                    projectDistribution: projects
                ),
                currentGoalStreakDays: 2
            )
        )
        return TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: dayIdentifier, focusCount: 2, completionCount: 1)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 5,
                recentProjectName: "Decode benchmark repository"
            ),
            activityRevision: 8,
            focusHistoryPublication: publication
        )
    }

    private func makeHistoryDays(
        endingAt dayIdentifier: String,
        count: Int
    ) -> [FocusHistoryDay] {
        historyDayIdentifiers(endingAt: dayIdentifier, count: count)
            .enumerated()
            .map { index, identifier in
                FocusHistoryDay(
                    dayIdentifier: identifier,
                    state: .sessions,
                    focusDuration: Double(index * 30),
                    completedSessionCount: 1,
                    goalMinutes: 60,
                    goalCompletionRate: 0.5,
                    isGoalMet: false,
                    contributingSessionIDs: [
                        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
                    ]
                )
            }
    }

    private func historyDayIdentifiers(
        endingAt dayIdentifier: String,
        count: Int
    ) -> [String] {
        let parts = dayIdentifier.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        guard parts.count == 3, let timeZone = TimeZone(secondsFromGMT: 0) else {
            return []
        }
        calendar.timeZone = timeZone
        guard let end = calendar.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2],
            hour: 12
        )) else {
            return []
        }
        return (0 ..< count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
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
