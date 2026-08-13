import Foundation
import XCTest
@testable import TinyBuddyCore

final class DevelopmentInterruptionResumeDecisionTests: XCTestCase {
    private let fingerprint = "repo-fingerprint-abc"

    private func project(
        id: String,
        name: String = "TinyBuddy",
        fingerprint: String? = "repo-fingerprint-abc",
        kind: TinyBuddyProjectKind = .gitRepository,
        state: TinyBuddyProjectState = .active
    ) -> TinyBuddyProject {
        TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: id),
            kind: kind,
            displayName: name,
            repositoryFingerprint: fingerprint,
            state: state
        )
    }

    private func openSession(
        key: String,
        status: FocusSessionStatus = .active
    ) -> (project: FocusProjectContext, status: FocusSessionStatus) {
        (
            project: FocusProjectContext(key: key, displayName: "TinyBuddy"),
            status: status
        )
    }

    // MARK: - Exact fingerprint gating

    func testExactFingerprintMatchWithActiveGitProjectIsAvailable() {
        let project = project(id: "proj-1")
        // Snapshot fingerprint differs in case; the registry convention folds case.
        let state = DevelopmentInterruptionResumeDecision.make(
            fingerprint: "REPO-FINGERPRINT-ABC",
            projects: [project],
            openSession: nil
        )
        XCTAssertEqual(state, .available(project: project))
        XCTAssertEqual(state.matchedProject, project)
    }

    func testSameDisplayNameDifferentFingerprintIsBlocked() {
        let project = project(id: "proj-1", fingerprint: "other-fingerprint")
        let state = DevelopmentInterruptionResumeDecision.make(
            fingerprint: fingerprint,
            projects: [project],
            openSession: nil
        )
        XCTAssertEqual(state, .blocked)
    }

    func testProjectWithNilFingerprintNeverMatches() {
        let project = project(id: "proj-1", fingerprint: nil)
        let state = DevelopmentInterruptionResumeDecision.make(
            fingerprint: fingerprint,
            projects: [project],
            openSession: nil
        )
        XCTAssertEqual(state, .blocked)
    }

    func testEmptyOrWhitespaceSnapshotFingerprintIsBlocked() {
        let project = project(id: "proj-1")
        XCTAssertEqual(
            DevelopmentInterruptionResumeDecision.make(
                fingerprint: "",
                projects: [project],
                openSession: nil
            ),
            .blocked
        )
        XCTAssertEqual(
            DevelopmentInterruptionResumeDecision.make(
                fingerprint: "   ",
                projects: [project],
                openSession: nil
            ),
            .blocked
        )
    }

    // MARK: - Usable project gating

    func testNonActiveProjectsAreBlocked() {
        for state in [
            TinyBuddyProjectState.archived,
            TinyBuddyProjectState.temporarilyUnavailable,
            TinyBuddyProjectState.removed
        ] {
            let project = project(id: "proj-1", state: state)
            XCTAssertEqual(
                DevelopmentInterruptionResumeDecision.make(
                    fingerprint: fingerprint,
                    projects: [project],
                    openSession: nil
                ),
                .blocked,
                "state \(state) must not offer resume"
            )
        }
    }

    func testNonGitKindIsBlocked() {
        let project = project(id: "proj-1", kind: .application)
        XCTAssertEqual(
            DevelopmentInterruptionResumeDecision.make(
                fingerprint: fingerprint,
                projects: [project],
                openSession: nil
            ),
            .blocked
        )
    }

    func testMultipleMatchesPreferActiveThenSmallestStableID() {
        let archived = project(id: "proj-b", state: .archived)
        let active = project(id: "proj-a")
        let state = DevelopmentInterruptionResumeDecision.make(
            fingerprint: fingerprint,
            projects: [archived, active],
            openSession: nil
        )
        XCTAssertEqual(state, .available(project: active))

        let first = project(id: "proj-1")
        let second = project(id: "proj-2")
        XCTAssertEqual(
            DevelopmentInterruptionResumeDecision.make(
                fingerprint: fingerprint,
                projects: [second, first],
                openSession: nil
            ),
            .available(project: first)
        )
    }

    // MARK: - Open-session conflict gating

    func testOpenSessionOnMatchedProjectIsInProgress() {
        let project = project(id: "proj-1")
        let state = DevelopmentInterruptionResumeDecision.make(
            fingerprint: fingerprint,
            projects: [project],
            openSession: openSession(key: "proj-1", status: .active)
        )
        XCTAssertEqual(state, .inProgress(project: project, status: .active))

        let paused = DevelopmentInterruptionResumeDecision.make(
            fingerprint: fingerprint,
            projects: [project],
            openSession: openSession(key: "proj-1", status: .paused)
        )
        XCTAssertEqual(paused, .inProgress(project: project, status: .paused))
    }

    func testOpenSessionOnAnotherProjectIsBlocked() {
        let project = project(id: "proj-1")
        let state = DevelopmentInterruptionResumeDecision.make(
            fingerprint: fingerprint,
            projects: [project],
            openSession: openSession(key: "proj-other")
        )
        XCTAssertEqual(state, .blocked)
    }
}
