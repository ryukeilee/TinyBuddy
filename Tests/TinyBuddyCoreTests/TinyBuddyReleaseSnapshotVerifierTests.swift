import XCTest
@testable import TinyBuddyCore

final class TinyBuddyReleaseSnapshotVerifierTests: XCTestCase {
    func testAcceptsCurrentCommittedSnapshotAndLegacyMirror() throws {
        let snapshot = makeSnapshot(revision: 42, dayIdentifier: "2026-07-17")

        let outcome = TinyBuddyReleaseSnapshotVerifier.verify(
            plist: validPlist(for: snapshot),
            expectedDayIdentifier: "2026-07-17"
        )

        XCTAssertEqual(outcome, .valid(TinyBuddyReleaseSnapshotVerificationResult(
            schemaVersion: TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            revision: 42,
            dayIdentifier: "2026-07-17",
            status: PetStatus.completedOnce.rawValue,
            focusCount: 3,
            completionCount: 2,
            activityFocusBlockCount: 5,
            activityCommitCount: 7,
            activityRevision: 18
        )))
    }

    func testRejectsDamagedSchemaMarker() {
        let snapshot = makeSnapshot(revision: 42, dayIdentifier: "2026-07-17")
        var plist = validPlist(for: snapshot)
        plist[TinyBuddyCombinedSnapshotStore.Key.schemaVersion] = "2\\tbroken"

        XCTAssertEqual(
            TinyBuddyReleaseSnapshotVerifier.verify(
                plist: plist,
                expectedDayIdentifier: "2026-07-17"
            ),
            .invalid(.schemaInvalid)
        )
    }

    func testRejectsDamagedCommitMarker() {
        let snapshot = makeSnapshot(revision: 42, dayIdentifier: "2026-07-17")
        var plist = validPlist(for: snapshot)
        plist[TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2] = "2\\t42\\tbroken"

        XCTAssertEqual(
            TinyBuddyReleaseSnapshotVerifier.verify(
                plist: plist,
                expectedDayIdentifier: "2026-07-17"
            ),
            .invalid(.committedRevisionInvalid)
        )
    }

    func testAcceptsOneHealthyCommittedSlotWhenTheOtherIsDamaged() {
        let snapshot = makeSnapshot(revision: 42, dayIdentifier: "2026-07-17")
        var plist = validPlist(for: snapshot)
        plist[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA] = "corrupt"

        guard case let .valid(result) = TinyBuddyReleaseSnapshotVerifier.verify(
            plist: plist,
            expectedDayIdentifier: "2026-07-17"
        ) else {
            return XCTFail("expected one committed slot to be accepted")
        }
        XCTAssertEqual(result.revision, 42)
    }

    func testRejectsSlotsThatDoNotMatchCommittedRevision() {
        let snapshot = makeSnapshot(revision: 42, dayIdentifier: "2026-07-17")
        var plist = validPlist(for: snapshot)
        let other = makeSnapshot(revision: 43, dayIdentifier: "2026-07-17")
        plist[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA] =
            TinyBuddyCombinedSnapshotStore.encodeV2(other)
        plist[TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB] =
            TinyBuddyCombinedSnapshotStore.encodeV2(other)

        XCTAssertEqual(
            TinyBuddyReleaseSnapshotVerifier.verify(
                plist: plist,
                expectedDayIdentifier: "2026-07-17"
            ),
            .invalid(.committedSnapshotMissing)
        )
    }

    func testRejectsCrossDayCommittedSnapshot() {
        let snapshot = makeSnapshot(revision: 42, dayIdentifier: "2026-07-16")

        XCTAssertEqual(
            TinyBuddyReleaseSnapshotVerifier.verify(
                plist: validPlist(for: snapshot),
                expectedDayIdentifier: "2026-07-17"
            ),
            .invalid(.committedSnapshotMissing)
        )
    }

    func testRejectsLegacyMirrorWithDifferentRevisionOrDay() {
        let snapshot = makeSnapshot(revision: 42, dayIdentifier: "2026-07-17")
        var plist = validPlist(for: snapshot)
        plist[TinyBuddyCombinedSnapshotStore.Key.snapshot] = TinyBuddyCombinedSnapshotStore.encode(
            makeSnapshot(revision: 41, dayIdentifier: "2026-07-16")
        )

        XCTAssertEqual(
            TinyBuddyReleaseSnapshotVerifier.verify(
                plist: plist,
                expectedDayIdentifier: "2026-07-17"
            ),
            .invalid(.legacyMirrorMismatch)
        )
    }

    func testRejectsLegacyMirrorWithDifferentPayloadAtCommittedRevision() {
        let snapshot = makeSnapshot(revision: 42, dayIdentifier: "2026-07-17")
        var plist = validPlist(for: snapshot)
        let differentPayload = TinyBuddyCombinedSnapshot(
            revision: snapshot.revision,
            dayIdentifier: snapshot.dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(
                    dayIdentifier: snapshot.dayIdentifier,
                    focusCount: 99,
                    completionCount: 2
                )
            ),
            activitySnapshot: snapshot.activitySnapshot,
            activityRevision: snapshot.activityRevision
        )
        plist[TinyBuddyCombinedSnapshotStore.Key.snapshot] =
            TinyBuddyCombinedSnapshotStore.encode(differentPayload)

        XCTAssertEqual(
            TinyBuddyReleaseSnapshotVerifier.verify(
                plist: plist,
                expectedDayIdentifier: "2026-07-17"
            ),
            .invalid(.legacyMirrorMismatch)
        )
    }

    private func validPlist(for snapshot: TinyBuddyCombinedSnapshot) -> [String: Any] {
        [
            TinyBuddyCombinedSnapshotStore.Key.schemaVersion:
                TinyBuddyCombinedSnapshotStore.encodeSchemaVersion()!,
            TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2:
                TinyBuddyCombinedSnapshotStore.encodeRevisionMarker(snapshot.revision)!,
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA:
                TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB:
                TinyBuddyCombinedSnapshotStore.encodeV2(snapshot),
            TinyBuddyCombinedSnapshotStore.Key.snapshot:
                TinyBuddyCombinedSnapshotStore.encode(snapshot)
        ]
    }

    private func makeSnapshot(
        revision: Int64,
        dayIdentifier: String
    ) -> TinyBuddyCombinedSnapshot {
        TinyBuddyCombinedSnapshot(
            revision: revision,
            dayIdentifier: dayIdentifier,
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(
                    dayIdentifier: dayIdentifier,
                    focusCount: 3,
                    completionCount: 2
                )
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 5,
                commitCount: 7,
                recentProjectName: "Private project name"
            ),
            activityRevision: 18
        )
    }
}
