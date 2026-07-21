import XCTest
@testable import TinyBuddyCore

final class FocusModeCodableTests: XCTestCase {

    func test_focus_mode_roundtrips_through_json() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // .automatic roundtrip
        let autoData = try encoder.encode(FocusMode.automatic)
        XCTAssertEqual(try decoder.decode(FocusMode.self, from: autoData), .automatic)

        // .manual roundtrip
        let manualData = try encoder.encode(FocusMode.manual)
        XCTAssertEqual(try decoder.decode(FocusMode.self, from: manualData), .manual)

        // Fallback: FocusSession without mode key decodes mode as .automatic
        let json = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "project": {"key": "test", "displayName": "Test"},
            "dayIdentifier": "2026-07-21",
            "startedAt": 1234567890,
            "status": "active",
            "lastUserActivityAt": 1234567890,
            "lastStateChangeAt": 1234567890,
            "pausedTotal": 0,
            "isManuallyConfirmed": false
        }
        """
        let session = try decoder.decode(FocusSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.mode, .automatic)
    }

    func test_manual_control_state_equality() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let t1 = Date(timeIntervalSinceReferenceDate: 1010)
        let projectA = FocusProjectContext(key: "proj.a", displayName: "Project A")
        let projectB = FocusProjectContext(key: "proj.b", displayName: "Project B")

        // .idle == .idle
        XCTAssertEqual(ManualFocusControlState.idle, ManualFocusControlState.idle)

        // Same focusing state
        XCTAssertEqual(
            ManualFocusControlState.focusing(project: projectA, startedAt: t0, activeDuration: 10),
            ManualFocusControlState.focusing(project: projectA, startedAt: t0, activeDuration: 10)
        )

        // Different project → not equal
        XCTAssertNotEqual(
            ManualFocusControlState.focusing(project: projectA, startedAt: t0, activeDuration: 10),
            ManualFocusControlState.focusing(project: projectB, startedAt: t0, activeDuration: 10)
        )

        // Same paused state
        XCTAssertEqual(
            ManualFocusControlState.paused(project: projectA, startedAt: t0, pausedAt: t1, activeDuration: 5),
            ManualFocusControlState.paused(project: projectA, startedAt: t0, pausedAt: t1, activeDuration: 5)
        )

        // Different cases (idle vs focusing) not equal
        XCTAssertNotEqual(
            ManualFocusControlState.idle,
            ManualFocusControlState.focusing(project: projectA, startedAt: t0, activeDuration: 0)
        )
    }
}
