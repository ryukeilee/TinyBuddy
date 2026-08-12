import Foundation
import XCTest
@testable import TinyBuddyCore

final class DevelopmentInterruptionSnapshotTests: XCTestCase {
    func testDecodesPathFreeSnapshotAndBuildsPresentation() throws {
        let rawValue = payload(
            repositoryName: "TinyBuddy",
            branchName: "feature/resume",
            staged: 1,
            modified: 2,
            untracked: 3,
            conflicted: 1,
            commitHash: "abc1234",
            commitSubject: "Add resume state",
            commitEpoch: 1_700_000_000,
            activityEpoch: 1_700_000_300,
            capturedEpoch: 1_700_000_600
        )

        let snapshot = try XCTUnwrap(DevelopmentInterruptionSnapshotStore.decode(rawValue))
        XCTAssertEqual(snapshot.repositoryName, "TinyBuddy")
        XCTAssertEqual(snapshot.branchName, "feature/resume")
        XCTAssertEqual(snapshot.workingTree.totalCount, 7)
        XCTAssertEqual(snapshot.recentCommit?.subject, "Add resume state")

        let presentation = DevelopmentInterruptionPresentation(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_004_020)
        )
        XCTAssertEqual(presentation.workingTreeText, "冲突 1 · 已暂存 1 · 已修改 2 · 未跟踪 3")
        XCTAssertEqual(presentation.recentCommitText, "abc1234 · Add resume state")
        XCTAssertEqual(presentation.awayDurationText, "离开 1 小时 2 分钟")
    }

    func testRejectsMalformedOrFutureSnapshots() throws {
        XCTAssertNil(DevelopmentInterruptionSnapshotStore.decode("v1\tbroken"))

        let suiteName = "DevelopmentInterruptionSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(payload(activityEpoch: 2_000, capturedEpoch: 2_000), forKey: DevelopmentInterruptionSnapshotStore.Key.snapshot)
        let store = DevelopmentInterruptionSnapshotStore(userDefaults: defaults)

        XCTAssertNil(store.load(at: Date(timeIntervalSince1970: 1_000)))
    }

    func testExpiresAndClearsSnapshotAfterSevenDays() throws {
        let suiteName = "DevelopmentInterruptionSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(payload(activityEpoch: 1_000, capturedEpoch: 1_000), forKey: DevelopmentInterruptionSnapshotStore.Key.snapshot)
        let store = DevelopmentInterruptionSnapshotStore(userDefaults: defaults)
        let expiredAt = Date(timeIntervalSince1970: 1_000 + DevelopmentInterruptionSnapshotStore.maximumAge + 1)

        XCTAssertNil(store.load(at: expiredAt))
        XCTAssertTrue(store.clearIfExpired(at: expiredAt))
        XCTAssertNil(defaults.object(forKey: DevelopmentInterruptionSnapshotStore.Key.snapshot))
    }

    private func payload(
        repositoryName: String = "Repo",
        branchName: String = "main",
        staged: Int = 0,
        modified: Int = 0,
        untracked: Int = 0,
        conflicted: Int = 0,
        commitHash: String = "abc1234",
        commitSubject: String = "Commit",
        commitEpoch: Int = 900,
        activityEpoch: Int,
        capturedEpoch: Int
    ) -> String {
        [
            "v1",
            encode("fingerprint"),
            encode(repositoryName),
            encode(branchName),
            String(staged),
            String(modified),
            String(untracked),
            String(conflicted),
            encode(commitHash),
            encode(commitSubject),
            String(commitEpoch),
            String(activityEpoch),
            String(capturedEpoch)
        ].joined(separator: "\t")
    }

    private func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}
