import Foundation
import TinyBuddyCore

@main
struct TinyBuddyReleaseVerifierCommand {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5,
              arguments[0] == "shared-snapshot",
              arguments[1] == "--plist",
              arguments[3] == "--expected-day" else {
            fail(reason: "invalid_arguments")
        }

        let plistURL = URL(fileURLWithPath: arguments[2])
        guard let data = try? Data(contentsOf: plistURL) else {
            fail(reason: "plist_unreadable")
        }
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let plist = propertyList as? [String: Any] else {
            fail(reason: "plist_invalid")
        }

        switch TinyBuddyReleaseSnapshotVerifier.verify(
            plist: plist,
            expectedDayIdentifier: arguments[4]
        ) {
        case let .valid(result):
            print(successLine(for: result))
        case let .invalid(reason):
            fail(reason: reason.rawValue)
        }
    }

    private static func successLine(
        for result: TinyBuddyReleaseSnapshotVerificationResult
    ) -> String {
        [
            "TINYBUDDY_RELEASE_SNAPSHOT",
            "schema=\(result.schemaVersion)",
            "revision=\(result.revision)",
            "day=\(result.dayIdentifier)",
            "status=\(result.status)",
            "focus_count=\(result.focusCount)",
            "completion_count=\(result.completionCount)",
            "activity_focus_blocks=\(integerValue(result.activityFocusBlockCount))",
            "activity_commits=\(integerValue(result.activityCommitCount))",
            "activity_revision=\(integerValue(result.activityRevision))"
        ].joined(separator: " ")
    }

    private static func integerValue<T: BinaryInteger>(_ value: T?) -> String {
        value.map(String.init) ?? "none"
    }

    private static func fail(reason: String) -> Never {
        FileHandle.standardError.write(
            Data("TINYBUDDY_RELEASE_SNAPSHOT_ERROR reason=\(reason)\n".utf8)
        )
        Foundation.exit(1)
    }
}
