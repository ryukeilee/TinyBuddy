import XCTest
@testable import TinyBuddyCore

final class WidgetSharedDataLinkTests: XCTestCase {
    func testCombinedSnapshotSchemaDeclaresVerifiableMigrationPath() throws {
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.migrationPath(
                from: TinyBuddyCombinedSnapshotStore.legacySchemaVersion
            ),
            [1, 2]
        )
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.migrationPath(
                from: TinyBuddyCombinedSnapshotStore.currentSchemaVersion
            ),
            [2]
        )
        XCTAssertNil(
            TinyBuddyCombinedSnapshotStore.migrationPath(
                from: TinyBuddyCombinedSnapshotStore.currentSchemaVersion + 1
            )
        )
        let marker = try XCTUnwrap(TinyBuddyCombinedSnapshotStore.encodeSchemaVersion())
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decodeSchemaVersion(marker),
            TinyBuddyCombinedSnapshotStore.currentSchemaVersion
        )
        XCTAssertNil(
            TinyBuddyCombinedSnapshotStore.decodeSchemaVersion(
                corruptLastCharacter(of: marker)
            )
        )
    }

    func testLegacyNineFieldSnapshotMigratesToRedundantV2Envelope() throws {
        let defaults = makeDefaults()
        let legacySnapshot = TinyBuddyCombinedSnapshot(
            revision: 7,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 2,
                    completionCount: 1
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 3,
                commitCount: 5,
                recentProjectName: "TinyBuddy"
            )
        )
        let fields = TinyBuddyCombinedSnapshotStore.encode(legacySnapshot)
            .split(separator: "\t", omittingEmptySubsequences: false)
        let nineFieldValue = fields.dropLast().joined(separator: "\t")
        defaults.set(nineFieldValue, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )

        XCTAssertEqual(store.load(), legacySnapshot)
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot),
            TinyBuddyCombinedSnapshotStore.encode(legacySnapshot)
        )
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA, defaults: defaults),
            legacySnapshot
        )
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB, defaults: defaults),
            legacySnapshot
        )
        XCTAssertEqual(
            defaults.object(forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision) as? Int64,
            7
        )
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1),
            nineFieldValue
        )
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.schemaVersion)
                .flatMap(TinyBuddyCombinedSnapshotStore.decodeSchemaVersion),
            TinyBuddyCombinedSnapshotStore.currentSchemaVersion
        )
    }

    func testInterruptedLegacyMigrationKeepsRecoverableBackupAndCanResume() throws {
        let defaults = makeDefaults()
        let legacySnapshot = makeCombinedSnapshot(
            revision: 6,
            focusBlockCount: 2,
            commitCount: 4,
            projectName: "BeforeUpgrade"
        )
        let legacyValue = TinyBuddyCombinedSnapshotStore.encode(legacySnapshot)
        defaults.set(legacyValue, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)

        let interruptedStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                guard key != TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA,
                      key != TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB else {
                    return false
                }
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                _ = defaults.synchronize()
                return true
            }
        )

        XCTAssertEqual(interruptedStore.load(), legacySnapshot)
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1),
            legacyValue
        )
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot),
            legacyValue
        )
        defaults.set(
            "corrupt-after-interruption",
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )

        let resumedStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        XCTAssertEqual(resumedStore.load(), legacySnapshot)
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA, defaults: defaults),
            legacySnapshot
        )
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1),
            legacyValue
        )
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot),
            legacyValue
        )
    }

    func testV2ChecksumRejectsPayloadCorruptionButKeepsClaimedRevisionRecoverable() {
        let snapshot = makeCombinedSnapshot(revision: 11, focusBlockCount: 4, commitCount: 7)
        let encoded = TinyBuddyCombinedSnapshotStore.encodeV2(snapshot)
        let corrupted = corruptLastCharacter(of: encoded)

        XCTAssertNil(TinyBuddyCombinedSnapshotStore.decodeV2(corrupted))
        XCTAssertNotEqual(corrupted, encoded)
    }

    func testLegacyTenFieldSnapshotMigratesWithTrustedActivityRevision() throws {
        let defaults = makeDefaults()
        let legacySnapshot = makeCombinedSnapshot(
            revision: 8,
            focusBlockCount: 5,
            commitCount: 9,
            projectName: "TenField"
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encode(legacySnapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )

        XCTAssertEqual(store.load(), legacySnapshot)
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA, defaults: defaults),
            legacySnapshot
        )
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decodeRevisionMarker(
                try XCTUnwrap(defaults.string(
                    forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
                ))
            ),
            8
        )
    }

    func testLegacySnapshotSurvivesACrashAfterV2RevisionReservation() throws {
        let defaults = makeDefaults()
        let legacySnapshot = makeCombinedSnapshot(
            revision: 9,
            focusBlockCount: 4,
            commitCount: 7,
            projectName: "ReservedLegacy"
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encode(legacySnapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(9),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )

        let widgetStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertEqual(widgetStore.load(), legacySnapshot)

        let appStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        XCTAssertEqual(appStore.load(), legacySnapshot)
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA, defaults: defaults),
            legacySnapshot
        )
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decodeRevisionMarker(
                try XCTUnwrap(defaults.string(
                    forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
                ))
            ),
            9
        )
    }

    func testCorruptLegacyMirrorCannotOverrideChecksummedV2() throws {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let committed = try XCTUnwrap(store.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        ).snapshot)
        var legacyFields = TinyBuddyCombinedSnapshotStore.encode(committed)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        legacyFields[0] = String(Int64.max)
        defaults.set(
            legacyFields.joined(separator: "\t"),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )

        XCTAssertEqual(store.load(), committed)
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot),
            TinyBuddyCombinedSnapshotStore.encode(committed)
        )
    }

    func testInterruptedWriteRecoversPreviousPayloadWithoutRevisionRollback() throws {
        let defaults = makeDefaults()
        let committed = makeCombinedSnapshot(
            revision: 12,
            focusBlockCount: 4,
            commitCount: 7,
            projectName: "Committed"
        )
        let interrupted = makeCombinedSnapshot(
            revision: 13,
            focusBlockCount: 8,
            commitCount: 9,
            projectName: "Interrupted"
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeV2(committed),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA
        )
        defaults.set(
            corruptLastCharacter(of: TinyBuddyCombinedSnapshotStore.encodeV2(interrupted)),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(12),
            forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(13),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )
        defaults.set(13, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)

        let appStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let recovered = try XCTUnwrap(appStore.load())

        XCTAssertEqual(recovered.revision, 12)
        XCTAssertEqual(recovered.snapshot, committed.snapshot)
        XCTAssertEqual(recovered.activitySnapshot, committed.activitySnapshot)
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB, defaults: defaults),
            recovered
        )

        let widgetStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertEqual(widgetStore.load(), recovered)
    }

    func testBothCorruptV2CopiesRebuildAboveEveryClaimedRevision() throws {
        let defaults = makeDefaults()
        let corruptA = corruptLastCharacter(of: TinyBuddyCombinedSnapshotStore.encodeV2(
            makeCombinedSnapshot(revision: 20, focusBlockCount: 1, commitCount: 2)
        ))
        let corruptB = corruptLastCharacter(of: TinyBuddyCombinedSnapshotStore.encodeV2(
            makeCombinedSnapshot(revision: 21, focusBlockCount: 3, commitCount: 5)
        ))
        defaults.set(corruptA, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        defaults.set(corruptB, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB)
        defaults.set("corrupt legacy payload", forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        XCTAssertNil(store.load())

        let rebuilt = store.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 0,
                commitCount: 0
            )
        )

        XCTAssertEqual(rebuilt.outcome, .saved)
        XCTAssertEqual(rebuilt.snapshot?.revision, 22)
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA, defaults: defaults),
            rebuilt.snapshot
        )
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB, defaults: defaults),
            rebuilt.snapshot
        )
    }

    func testCorruptLegacyRevisionCounterCannotExhaustValidPayload() throws {
        let defaults = makeDefaults()
        let oldSnapshot = makeCombinedSnapshot(revision: 4, focusBlockCount: 2, commitCount: 3)
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encode(oldSnapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )
        defaults.set(Int64.max, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)

        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let recovered = try XCTUnwrap(store.load())

        XCTAssertEqual(recovered.revision, 4)
        XCTAssertEqual(recovered.snapshot, oldSnapshot.snapshot)
        XCTAssertEqual(recovered.activitySnapshot, oldSnapshot.activitySnapshot)
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA, defaults: defaults),
            recovered
        )
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB, defaults: defaults),
            recovered
        )
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decodeRevisionMarker(
                try XCTUnwrap(defaults.string(
                    forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
                ))
            ),
            4
        )

        let updated = store.updatePetSlice(
            oldSnapshot.snapshot,
            fallbackActivitySnapshot: oldSnapshot.activitySnapshot,
            fallbackActivityRevision: oldSnapshot.activityRevision
        )
        XCTAssertEqual(updated.outcome, .saved)
        XCTAssertEqual(updated.snapshot?.revision, 5)
    }

    func testTransactionalWritesKeepPreviousCommittedSlotAsBackup() throws {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let firstPetSnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(
                dayIdentifier: "2026-07-01",
                focusCount: 0,
                completionCount: 0
            )
        )
        let secondPetSnapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(
                dayIdentifier: "2026-07-01",
                focusCount: 1,
                completionCount: 0
            )
        )

        let first = store.updatePetSlice(firstPetSnapshot, fallbackActivitySnapshot: nil)
        let second = store.updatePetSlice(secondPetSnapshot, fallbackActivitySnapshot: nil)
        let slotRevisions = try [
            decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA, defaults: defaults).revision,
            decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB, defaults: defaults).revision
        ].sorted()

        XCTAssertEqual(first.snapshot?.revision, 1)
        XCTAssertEqual(second.snapshot?.revision, 2)
        XCTAssertEqual(slotRevisions, [1, 2])
        XCTAssertEqual(store.load(), second.snapshot)
    }

    func testFailedTransactionalPublicationKeepsReadersOnLastCommitAndRecoversMonotonically() throws {
        let defaults = makeDefaults()
        let initialStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let initialPetSnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(
                dayIdentifier: "2026-07-01",
                focusCount: 0,
                completionCount: 0
            )
        )
        let changedPetSnapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(
                dayIdentifier: "2026-07-01",
                focusCount: 1,
                completionCount: 0
            )
        )
        let initial = try XCTUnwrap(
            initialStore.updatePetSlice(
                initialPetSnapshot,
                fallbackActivitySnapshot: nil
            ).snapshot
        )
        let failingStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                guard key != TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB else {
                    return false
                }
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                _ = defaults.synchronize()
                return true
            }
        )

        let failed = failingStore.updatePetSlice(
            changedPetSnapshot,
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(failed.outcome, .persistenceFailed)
        XCTAssertFalse(failed.didPersist)
        XCTAssertEqual(failed.snapshot, initial)
        let widgetStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertEqual(widgetStore.load(), initial)

        let recoveringStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let recovered = try XCTUnwrap(recoveringStore.load())
        XCTAssertEqual(recovered, initial)
        let retried = recoveringStore.updatePetSlice(
            changedPetSnapshot,
            fallbackActivitySnapshot: nil
        )
        XCTAssertEqual(retried.outcome, .saved)
        XCTAssertEqual(retried.snapshot?.revision, 3)
        XCTAssertEqual(retried.snapshot?.snapshot, changedPetSnapshot)
    }

    func testFailedSlotSynchronizationDoesNotPublishStagedSnapshot() throws {
        let defaults = makeDefaults()
        let initialStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let initial = try XCTUnwrap(initialStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        ).snapshot)
        var synchronizationCount = 0
        let failingStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                synchronizationCount += 1
                if synchronizationCount == 3 {
                    return false
                }
                _ = defaults.synchronize()
                return true
            }
        )

        let failed = failingStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .focusing,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 1,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(failed.outcome, .persistenceFailed)
        XCTAssertEqual(failed.snapshot, initial)
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil },
                repairOnLoad: false
            ).load(),
            initial
        )
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decodeRevisionMarker(
                try XCTUnwrap(defaults.string(
                    forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
                ))
            ),
            initial.revision
        )
    }

    func testFailedRevisionReservationLeavesTheLastCommitAndAllowsRevisionReuse() throws {
        let defaults = makeDefaults()
        let initialStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let initial = try XCTUnwrap(initialStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        ).snapshot)
        let changed = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(
                dayIdentifier: "2026-07-01",
                focusCount: 1,
                completionCount: 0
            )
        )
        let failingStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                guard key != TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2 else {
                    return false
                }
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                _ = defaults.synchronize()
                return true
            }
        )

        let failed = failingStore.updatePetSlice(changed, fallbackActivitySnapshot: nil)

        XCTAssertEqual(failed.outcome, .persistenceFailed)
        XCTAssertEqual(failed.snapshot, initial)
        XCTAssertEqual(initialStore.loadReadOnly(), initial)

        let retried = initialStore.updatePetSlice(changed, fallbackActivitySnapshot: nil)
        XCTAssertEqual(retried.outcome, .saved)
        XCTAssertEqual(retried.snapshot?.revision, 2)
    }

    func testFailedCommitMarkerSynchronizationRollsBackStagedSlot() throws {
        let defaults = makeDefaults()
        let initialStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let initial = try XCTUnwrap(initialStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        ).snapshot)
        var synchronizationCount = 0
        let failingStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                synchronizationCount += 1
                if synchronizationCount == 4 {
                    return false
                }
                _ = defaults.synchronize()
                return true
            }
        )

        let failed = failingStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .focusing,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 1,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(failed.outcome, .persistenceFailed)
        XCTAssertEqual(failed.snapshot, initial)
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil },
                repairOnLoad: false
            ).load(),
            initial
        )
    }

    func testSavedRequiresOneCommittedV2SlotAndRepairsAncillaryCopiesLater() throws {
        let defaults = makeDefaults()
        let primaryOnlyStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { value, key in
                if key == TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB
                    || key == TinyBuddyCombinedSnapshotStore.Key.snapshot {
                    return false
                }
                defaults.set(value, forKey: key)
                return true
            },
            synchronizeWrites: {
                _ = defaults.synchronize()
                return true
            }
        )
        let result = primaryOnlyStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(result.outcome, .saved)
        XCTAssertTrue(result.didPersist)
        XCTAssertEqual(primaryOnlyStore.loadReadOnly(), result.snapshot)
        XCTAssertNil(defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB))
        XCTAssertNil(defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot))

        let repairingStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        XCTAssertEqual(repairingStore.load(), result.snapshot)
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB, defaults: defaults),
            result.snapshot
        )
        XCTAssertEqual(
            defaults.string(forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
                .flatMap(TinyBuddyCombinedSnapshotStore.decode),
            result.snapshot
        )
    }

    func testRepairKeepsTheLastWholeSnapshotBelowTheReservedRevisionFloor() throws {
        let defaults = makeDefaults()
        let initialStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let initial = try XCTUnwrap(initialStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        ).snapshot)
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(2),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )
        let failingRepairStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            writeValue: { _, _ in false },
            synchronizeWrites: {
                _ = defaults.synchronize()
                return true
            }
        )

        XCTAssertEqual(failingRepairStore.load(), initial)

        let recovered = try XCTUnwrap(TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        ).load())
        XCTAssertEqual(recovered, initial)
    }

    func testReadOnlyReaderIgnoresStagedSlotUntilCommitMarkerPublishes() throws {
        let suiteName = "TinyBuddyWidgetTransactionTests.\(UUID().uuidString)"
        let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        writerDefaults.removePersistentDomain(forName: suiteName)
        defer { writerDefaults.removePersistentDomain(forName: suiteName) }
        let writerStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: writerDefaults,
            sharedPreferencesProvider: { nil }
        )
        let initial = try XCTUnwrap(writerStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        ).snapshot)
        let staged = TinyBuddyCombinedSnapshot(
            revision: 2,
            dayIdentifier: initial.dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .focusing,
                stats: DailyStats(
                    dayIdentifier: initial.dayIdentifier,
                    focusCount: 1,
                    completionCount: 0
                )
            ),
            activitySnapshot: initial.activitySnapshot,
            activityRevision: initial.activityRevision
        )
        writerDefaults.set(
            TinyBuddyCombinedSnapshotStore.encodeV2(staged),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB
        )
        writerDefaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(2),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )
        writerDefaults.set(2, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)
        writerDefaults.synchronize()

        let readerDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let readerStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: readerDefaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertEqual(readerStore.load(), initial)

        writerDefaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(2),
            forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
        )
        writerDefaults.synchronize()
        readerDefaults.synchronize()
        XCTAssertEqual(readerStore.load(), staged)
    }

    func testAppRepairsAValidStagedSlotWhileWidgetKeepsTheLastCommit() throws {
        let defaults = makeDefaults()
        let appStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let initial = try XCTUnwrap(appStore.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        ).snapshot)
        let staged = makeCombinedSnapshot(
            revision: 2,
            focusBlockCount: 5,
            commitCount: 8,
            projectName: "Staged"
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeV2(staged),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(2),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )

        let widgetStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertEqual(widgetStore.load(), initial)

        XCTAssertEqual(appStore.load(), staged)
        XCTAssertEqual(widgetStore.load(), staged)
        XCTAssertEqual(
            TinyBuddyCombinedSnapshotStore.decodeRevisionMarker(
                try XCTUnwrap(defaults.string(
                    forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
                ))
            ),
            2
        )
    }

    func testCommittedMarkerAheadOfCorruptSlotRecoversOneWholeBackupPayload() throws {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let initial = try XCTUnwrap(store.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 1,
                commitCount: 2,
                recentProjectName: "Committed"
            )
        ).snapshot)
        let corruptNewer = corruptLastCharacter(of: TinyBuddyCombinedSnapshotStore.encodeV2(
            makeCombinedSnapshot(
                revision: 2,
                focusBlockCount: 99,
                commitCount: 100,
                projectName: "Corrupt"
            )
        ))
        defaults.set(corruptNewer, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(2),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(2),
            forKey: TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2
        )

        let widgetStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        let widgetRecovery = try XCTUnwrap(widgetStore.load())
        XCTAssertEqual(widgetRecovery, initial)

        let appRecovery = try XCTUnwrap(store.load())
        XCTAssertEqual(appRecovery, widgetRecovery)
        XCTAssertEqual(
            try decodeV2Slot(TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA, defaults: defaults),
            appRecovery
        )
    }

    func testLegacyMirrorRecoversAfterReservationAndBothV2SlotsAreCorrupt() throws {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let initial = try XCTUnwrap(store.updatePetSlice(
            TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 0,
                    completionCount: 0
                )
            ),
            fallbackActivitySnapshot: nil
        ).snapshot)
        let staged = makeCombinedSnapshot(
            revision: 2,
            focusBlockCount: 9,
            commitCount: 11,
            projectName: "Interrupted"
        )
        let corruptStaged = corruptLastCharacter(of: TinyBuddyCombinedSnapshotStore.encodeV2(staged))
        defaults.set(corruptStaged, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA)
        defaults.set(corruptStaged, forKey: TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB)
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(2),
            forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2
        )
        defaults.set(2, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)

        let widgetStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            repairOnLoad: false
        )
        XCTAssertEqual(widgetStore.load(), initial)

        let recovered = try XCTUnwrap(store.load())
        XCTAssertEqual(recovered, initial)

        let changedSnapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(
                dayIdentifier: "2026-07-01",
                focusCount: 1,
                completionCount: 0
            )
        )
        let next = store.updatePetSlice(changedSnapshot, fallbackActivitySnapshot: nil)
        XCTAssertEqual(next.outcome, .saved)
        XCTAssertEqual(next.snapshot?.revision, 3)
        XCTAssertEqual(next.snapshot?.snapshot, changedSnapshot)
    }

    func testNegativeActivityRevisionIsRejectedWithoutChangingTrustedSnapshot() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })
        let petSnapshot = TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0))
        let trusted = store.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13, recentProjectName: "Trusted"),
            activityRevision: 200,
            fallbackSnapshot: petSnapshot
        )
        let legacy = GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "Invalid")

        let activityResult = store.updateActivitySlice(legacy, activityRevision: -1, fallbackSnapshot: petSnapshot)
        let petResult = store.updatePetSlice(
            petSnapshot,
            fallbackActivitySnapshot: legacy,
            fallbackActivityRevision: -1
        )

        XCTAssertEqual(activityResult.outcome, .rejectedInvalidActivityRevision)
        XCTAssertEqual(petResult.outcome, .rejectedInvalidActivityRevision)
        XCTAssertFalse(activityResult.didPersist)
        XCTAssertFalse(petResult.didPersist)
        XCTAssertEqual(store.load(), trusted.snapshot)
    }

    func testConcurrentCallsKeepTheirOwnUpdateResults() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })
        let petSnapshot = TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0))
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [TinyBuddyCombinedSnapshotStore.UpdateResult] = []

        group.enter()
        DispatchQueue.global().async {
            let result = store.updateActivitySlice(
                GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13),
                activityRevision: 200,
                fallbackSnapshot: petSnapshot
            )
            lock.lock()
            results.append(result)
            lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let result = store.updateActivitySlice(
                GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2),
                activityRevision: -1,
                fallbackSnapshot: petSnapshot
            )
            lock.lock()
            results.append(result)
            lock.unlock()
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.map(\.outcome).sorted { "\($0)" < "\($1)" }, [.rejectedInvalidActivityRevision, .saved])
        XCTAssertEqual(results.filter(\.didPersist).count, 1)
    }

    func testCrossDayRevisionExhaustionKeepsAppAndWidgetReadersOnPersistedSnapshot() {
        let defaults = makeDefaults()
        let trusted = TinyBuddyCombinedSnapshot(
            revision: Int64.max,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13),
            activityRevision: 200
        )
        defaults.set(TinyBuddyCombinedSnapshotStore.encode(trusted), forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        let appStore = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })
        let widgetStore = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })

        let result = appStore.updatePetSlice(
            TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0)),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(result.outcome, .revisionExhausted)
        XCTAssertFalse(result.didPersist)
        XCTAssertEqual(result.snapshot, trusted)
        XCTAssertEqual(appStore.load(), trusted)
        XCTAssertEqual(widgetStore.load(), trusted)
    }

    func testActivitySliceRejectsLegacyActivityWhenCombinedHasNewerTrustedRevision() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
        )
        let trustedB = GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13, recentProjectName: "B")
        let legacyA = GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "A")

        _ = store.updateActivitySlice(trustedB, activityRevision: 200, fallbackSnapshot: petSnapshot)
        let result = store.updateActivitySlice(legacyA, activityRevision: nil, fallbackSnapshot: petSnapshot)

        XCTAssertEqual(result.snapshot?.activitySnapshot, trustedB)
        XCTAssertEqual(result.snapshot?.activityRevision, 200)
        XCTAssertEqual(result.outcome, .rejectedStaleActivity)
        XCTAssertFalse(result.didPersist)
    }

    func testActivitySliceRecognizesAnIdenticalTrustedRevisionAsAlreadyCurrent() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil }
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(
                dayIdentifier: "2026-07-01",
                focusCount: 0,
                completionCount: 0
            )
        )
        let activity = GitTodayActivitySnapshot(
            focusBlockCount: 8,
            commitCount: 13,
            recentProjectName: "TinyBuddy"
        )
        let saved = store.updateActivitySlice(
            activity,
            activityRevision: 200,
            fallbackSnapshot: petSnapshot
        )

        let alreadyCurrent = store.updateActivitySlice(
            activity,
            activityRevision: 200,
            fallbackSnapshot: petSnapshot
        )

        XCTAssertEqual(alreadyCurrent.outcome, .alreadyCurrent)
        XCTAssertFalse(alreadyCurrent.didPersist)
        XCTAssertEqual(alreadyCurrent.snapshot, saved.snapshot)
        XCTAssertEqual(store.load(), saved.snapshot)
    }

    func testRevisionExhaustionDoesNotOverwriteTrustedSnapshot() {
        let defaults = makeDefaults()
        let trusted = TinyBuddyCombinedSnapshot(
            revision: Int64.max,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 8, commitCount: 13),
            activityRevision: 200
        )
        defaults.set(TinyBuddyCombinedSnapshotStore.encode(trusted), forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        let store = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })

        let result = store.updatePetSlice(
            TinyBuddySnapshot(status: .focusing, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 1, completionCount: 0)),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(result.snapshot, trusted)
        XCTAssertEqual(store.load(), trusted)
        XCTAssertEqual(result.outcome, .revisionExhausted)
        XCTAssertFalse(result.didPersist)
    }

    func testInvalidOrZeroRevisionCounterStartsAtOne() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(userDefaults: defaults, sharedPreferencesProvider: { nil })
        defaults.set(-1, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)

        let first = store.updatePetSlice(
            TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            fallbackActivitySnapshot: nil
        )

        XCTAssertEqual(first.snapshot?.revision, 1)
        XCTAssertEqual(first.outcome, .saved)
        XCTAssertTrue(first.didPersist)
        defaults.set(0, forKey: TinyBuddyCombinedSnapshotStore.Key.highestRevision)
        let second = store.updatePetSlice(
            TinyBuddySnapshot(status: .focusing, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 1, completionCount: 0)),
            fallbackActivitySnapshot: nil
        )
        XCTAssertEqual(second.snapshot?.revision, 2)
    }

    func testPetSlicePrefersNewerTrustedActivityWhenCoordinatorCannotPublish() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )
        let activityA = GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 2, recentProjectName: "A")
        let activityB = GitTodayActivitySnapshot(focusBlockCount: 3, commitCount: 5, recentProjectName: "B")

        _ = store.updateActivitySlice(
            activityA,
            activityRevision: 100,
            fallbackSnapshot: petSnapshot
        )
        _ = store.updatePetSlice(
            petSnapshot,
            fallbackActivitySnapshot: activityB,
            fallbackActivityRevision: 200
        )

        XCTAssertEqual(store.load()?.activitySnapshot, activityB)
        XCTAssertEqual(store.load()?.activityRevision, 200)
    }

    func testCrossDayUpdateKeepsCombinedRevisionMonotonic() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let oldDaySnapshot = TinyBuddyCombinedSnapshot(
            revision: 40,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(
                status: .focusing,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 1, completionCount: 0)
            ),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 2, commitCount: 3),
            activityRevision: 100
        )
        defaults.set(
            TinyBuddyCombinedSnapshotStore.encode(oldDaySnapshot),
            forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot
        )
        let newDaySnapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0)
        )

        let updated = store.updatePetSlice(
            newDaySnapshot,
            fallbackActivitySnapshot: nil,
            fallbackActivityRevision: nil
        )

        XCTAssertEqual(updated.snapshot?.revision, 41)
        XCTAssertEqual(store.load(), updated.snapshot)
        XCTAssertEqual(updated.snapshot?.dayIdentifier, "2026-07-02")
    }

    func testSameRevisionCandidatesPreferDirectCombinedSnapshot() {
        let defaults = makeDefaults()
        let direct = TinyBuddyCombinedSnapshot(
            revision: 7,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 1, commitCount: 1),
            activityRevision: 10
        )
        let cached = TinyBuddyCombinedSnapshot(
            revision: 7,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(status: .idle, stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)),
            activitySnapshot: GitTodayActivitySnapshot(focusBlockCount: 9, commitCount: 9),
            activityRevision: 20
        )
        defaults.set(TinyBuddyCombinedSnapshotStore.encode(direct), forKey: TinyBuddyCombinedSnapshotStore.Key.snapshot)
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: {
                [TinyBuddyCombinedSnapshotStore.Key.snapshot: TinyBuddyCombinedSnapshotStore.encode(cached)]
            },
            fallbackDefaults: nil
        )

        XCTAssertEqual(store.load(), direct)
    }

    func testDelayedPetSlicePreservesNewerActivitySlice() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let staleActivity = GitTodayActivitySnapshot(
            focusBlockCount: 1,
            commitCount: 2,
            recentProjectName: "Old Project"
        )
        let newerActivity = GitTodayActivitySnapshot(
            focusBlockCount: 7,
            commitCount: 11,
            recentProjectName: "New Project"
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        _ = store.updateActivitySlice(newerActivity, activityRevision: 100, fallbackSnapshot: petSnapshot)
        _ = store.updatePetSlice(
            petSnapshot,
            fallbackActivitySnapshot: staleActivity,
            fallbackActivityRevision: 50
        )

        XCTAssertEqual(store.load()?.activitySnapshot, newerActivity)
        XCTAssertEqual(store.load()?.snapshot, petSnapshot)
        XCTAssertEqual(store.load()?.revision, 2)
    }

    func testConcurrentSliceWritersUseDeterministicRevisionsWithoutLosingEitherSlice() {
        let defaults = makeDefaults()
        let firstStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let secondStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let petSnapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 3, completionCount: 1)
        )
        let activitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: 5,
            commitCount: 8,
            recentProjectName: "TinyBuddy"
        )
        let group = DispatchGroup()
        let resultLock = NSLock()
        var revisions: [Int64] = []

        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                let result = firstStore.updatePetSlice(petSnapshot, fallbackActivitySnapshot: nil)
                resultLock.lock()
                if let revision = result.snapshot?.revision, result.didPersist {
                    revisions.append(revision)
                }
                resultLock.unlock()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                let result = secondStore.updateActivitySlice(activitySnapshot, fallbackSnapshot: petSnapshot)
                resultLock.lock()
                if let revision = result.snapshot?.revision, result.didPersist {
                    revisions.append(revision)
                }
                resultLock.unlock()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revisions.sorted(), Array(1...40).map(Int64.init))
        XCTAssertEqual(firstStore.load()?.snapshot, petSnapshot)
        XCTAssertEqual(firstStore.load()?.activitySnapshot, activitySnapshot)
        XCTAssertEqual(firstStore.load()?.revision, 40)
    }

    func testAppAndWidgetReadTheSameNewestCombinedSnapshot() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let newerSnapshot = TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
            )
        let newerActivity = GitTodayActivitySnapshot(
                focusBlockCount: 7,
                commitCount: 11,
                recentProjectName: "TinyBuddy"
            )

        _ = store.updateActivitySlice(newerActivity, fallbackSnapshot: newerSnapshot)
        _ = store.updatePetSlice(newerSnapshot, fallbackActivitySnapshot: nil)

        let appSnapshot = try? XCTUnwrap(store.load())
        let widgetSnapshot = try? XCTUnwrap(store.load())
        XCTAssertEqual(appSnapshot?.snapshot, newerSnapshot)
        XCTAssertEqual(appSnapshot?.activitySnapshot, newerActivity)
        XCTAssertEqual(widgetSnapshot, appSnapshot)
    }

    func testCombinedSnapshotPreservesUnavailableActivity() {
        let defaults = makeDefaults()
        let store = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: { nil },
            fallbackDefaults: nil
        )
        let snapshot = TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
            )
        let activitySnapshot = GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            )

        _ = store.updatePetSlice(snapshot, fallbackActivitySnapshot: activitySnapshot)
        XCTAssertEqual(store.load()?.snapshot, snapshot)
        XCTAssertEqual(store.load()?.activitySnapshot, activitySnapshot)
    }

    func testWidgetReadsAndPresentsStateWrittenByMainAppSession() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 1)

        let appStore = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let appSession = PetSession(store: appStore)

        appSession.select(.focusing)
        appSession.select(.focusing)
        appSession.select(.completedOnce)
        GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(3)
        GitTodayCommitCountStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayCount(4)
        GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        ).saveTodayProjectName("TinyBuddy")

        let widgetStore = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let activityStore = GitTodayActivityStore(
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
        let widgetSnapshot = widgetStore.loadSnapshot()
        let activitySnapshot = activityStore.loadTodaySnapshot()
        let smallPresentation = TinyBuddyWidgetPresentation(
            snapshot: widgetSnapshot,
            activitySnapshot: activitySnapshot
        )
        let mediumPresentation = TinyBuddyWidgetPresentation(
            snapshot: widgetSnapshot,
            activitySnapshot: activitySnapshot
        )

        XCTAssertEqual(widgetSnapshot.status, .completedOnce)
        XCTAssertEqual(widgetSnapshot.stats.focusCount, 2)
        XCTAssertEqual(widgetSnapshot.stats.completionCount, 1)
        XCTAssertEqual(smallPresentation.expression, "★ᴗ★")
        XCTAssertEqual(smallPresentation.statusTitle, "今日完成")
        XCTAssertEqual(smallPresentation.focusCount, 3)
        XCTAssertEqual(smallPresentation.completionCount, 4)
        XCTAssertEqual(smallPresentation.statusDisplayTitle, "今日完成 · TinyBuddy")
        XCTAssertEqual(mediumPresentation.focusCount, 3)
        XCTAssertEqual(mediumPresentation.completionCount, 4)
        XCTAssertEqual(mediumPresentation.statusTitle, "今日完成")
        XCTAssertEqual(mediumPresentation.statusDisplayTitle, "今日完成 · TinyBuddy")
    }

    func testWidgetSnapshotDoesNotCarryYesterdayStatusIntoToday() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        var currentDate = makeDate(year: 2026, month: 7, day: 1)
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { currentDate }
        )
        let session = PetSession(store: store)

        session.select(.focusing)
        currentDate = makeDate(year: 2026, month: 7, day: 2)

        let widgetSnapshot = store.loadSnapshot()
        let presentation = TinyBuddyWidgetPresentation(
            snapshot: widgetSnapshot,
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: nil,
                commitCount: nil,
                recentProjectName: nil
            )
        )

        XCTAssertEqual(widgetSnapshot.status, .idle)
        XCTAssertEqual(widgetSnapshot.stats, DailyStats(dayIdentifier: "2026-07-02", focusCount: 0, completionCount: 0))
        XCTAssertEqual(presentation.statusTitle, "待机")
        XCTAssertEqual(presentation.displayState, .idle)
    }

    func testUnifiedWidgetPresentationDoesNotFallBackToSnapshotStatsForSmallFamily() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )
        let activitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: 8,
            commitCount: 13,
            recentProjectName: "TinyBuddy"
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )

        XCTAssertEqual(presentation.focusCount, 8)
        XCTAssertEqual(presentation.completionCount, 13)
        XCTAssertEqual(presentation.statusTitle, "今日完成")
        XCTAssertEqual(presentation.statusDisplayTitle, "今日完成 · TinyBuddy")
    }

    func testUnifiedWidgetPresentationFallsBackToSnapshotStateWhenGitActivityIsUnavailable() {
        let snapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )
        let activitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: nil,
            commitCount: nil,
            recentProjectName: nil
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            activitySnapshot: activitySnapshot
        )

        XCTAssertEqual(presentation.focusCount, 0)
        XCTAssertEqual(presentation.completionCount, 0)
        XCTAssertEqual(presentation.statusTitle, "专注中")
        XCTAssertEqual(presentation.statusDisplayTitle, "专注中")
        XCTAssertEqual(presentation.displayState, .focusing)
        XCTAssertEqual(presentation.expression, "–_–")
    }

    func testWidgetPresentationCanOverrideFocusAndCompletionCountWithGitCounts() {
        let snapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 6,
            completionCountOverride: 9,
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.focusCount, 6)
        XCTAssertEqual(presentation.completionCount, 9)
        XCTAssertEqual(presentation.statusTitle, "今日完成")
    }

    func testWidgetPresentationUsesZeroWhenGitCountsAreUnavailable() {
        let snapshot = TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )
        let gitTodayFocusBlockCount: Int? = nil
        let gitTodayCommitCount: Int? = nil

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: gitTodayFocusBlockCount ?? 0,
            completionCountOverride: gitTodayCommitCount ?? 0,
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.focusCount, 0)
        XCTAssertEqual(presentation.completionCount, 0)
        XCTAssertEqual(presentation.statusTitle, "今日无活动")
    }

    func testWidgetPresentationDefaultsToSnapshotStatusTitle() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 6,
            completionCountOverride: 9
        )

        XCTAssertEqual(presentation.statusTitle, "今日完成")
    }

    func testWidgetPresentationMapsGitTodayActivityStatusTitle() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        XCTAssertEqual(
            makeGitActivityPresentation(snapshot: snapshot, focusCount: 0, completionCount: 0).statusTitle,
            "今日无活动"
        )
        XCTAssertEqual(
            makeGitActivityPresentation(snapshot: snapshot, focusCount: 3, completionCount: 0).statusTitle,
            "专注中"
        )
        XCTAssertEqual(
            makeGitActivityPresentation(snapshot: snapshot, focusCount: 0, completionCount: 4).statusTitle,
            "今日完成"
        )
        XCTAssertEqual(
            makeGitActivityPresentation(snapshot: snapshot, focusCount: 5, completionCount: 6).statusTitle,
            "今日完成"
        )
    }

    func testWidgetPresentationAppendsRecentProjectNameToStatusDisplayTitle() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 5,
            completionCountOverride: 6,
            recentProjectName: "TinyBuddy",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.statusTitle, "今日完成")
        XCTAssertEqual(presentation.statusDisplayTitle, "今日完成 · TinyBuddy")
    }

    func testWidgetPresentationAppendsRecentProjectNameForFocusingStatus() {
        let snapshot = TinyBuddySnapshot(
            status: .focusing,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 1, completionCount: 0)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 3,
            completionCountOverride: 0,
            recentProjectName: "TinyBuddy",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.statusTitle, "专注中")
        XCTAssertEqual(presentation.statusDisplayTitle, "专注中 · TinyBuddy")
    }

    func testWidgetPresentationAppendsRecentProjectNameForCompletedStatus() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 0,
            completionCountOverride: 2,
            recentProjectName: "TinyBuddy",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.statusTitle, "今日完成")
        XCTAssertEqual(presentation.statusDisplayTitle, "今日完成 · TinyBuddy")
    }

    func testWidgetPresentationKeepsOriginalStatusDisplayWhenProjectNameIsUnavailable() {
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        let presentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 3,
            completionCountOverride: 0,
            recentProjectName: "  ",
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(presentation.statusTitle, "专注中")
        XCTAssertEqual(presentation.statusDisplayTitle, "专注中")
    }

    func testWidgetPresentationUpdatesRecentProjectNameWhenTodayActiveProjectChanges() {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 1)
        let recentProjectStore = GitTodayRecentProjectStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today },
            sharedFallbacksEnabled: false
        )
        let snapshot = TinyBuddySnapshot(
            status: .completedOnce,
            stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 2, completionCount: 1)
        )

        recentProjectStore.saveTodayProjectName("Project A")
        let firstPresentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 3,
            completionCountOverride: 1,
            recentProjectName: recentProjectStore.loadTodayProjectName(),
            statusTitleSource: .gitTodayActivity
        )

        recentProjectStore.saveTodayProjectName("Project B")
        let updatedPresentation = TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: 3,
            completionCountOverride: 1,
            recentProjectName: recentProjectStore.loadTodayProjectName(),
            statusTitleSource: .gitTodayActivity
        )

        XCTAssertEqual(firstPresentation.statusDisplayTitle, "今日完成 · Project A")
        XCTAssertEqual(updatedPresentation.statusDisplayTitle, "今日完成 · Project B")
    }

    private func makeGitActivityPresentation(
        snapshot: TinyBuddySnapshot,
        focusCount: Int,
        completionCount: Int
    ) -> TinyBuddyWidgetPresentation {
        TinyBuddyWidgetPresentation(
            snapshot: snapshot,
            focusCountOverride: focusCount,
            completionCountOverride: completionCount,
            statusTitleSource: .gitTodayActivity
        )
    }

    private func makeCombinedSnapshot(
        revision: Int64,
        focusBlockCount: Int,
        commitCount: Int,
        projectName: String? = nil
    ) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: "2026-07-01",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: 2,
                    completionCount: 1
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: focusBlockCount,
                commitCount: commitCount,
                recentProjectName: projectName
            ),
            activityRevision: revision * 10
        )
    }

    private func decodeV2Slot(
        _ key: String,
        defaults: UserDefaults
    ) throws -> TinyBuddyCombinedSnapshot {
        let value = try XCTUnwrap(defaults.string(forKey: key))
        return try XCTUnwrap(TinyBuddyCombinedSnapshotStore.decodeV2(value))
    }

    private func corruptLastCharacter(of value: String) -> String {
        guard let lastCharacter = value.last else {
            return "corrupt"
        }
        return String(value.dropLast()) + (lastCharacter == "A" ? "B" : "A")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyWidgetLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.calendar = makeCalendar()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return components.date!
    }
}
