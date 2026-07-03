import Foundation
import XCTest

final class GitActivityRefreshScriptTests: XCTestCase {
    func testScriptParsesTodayActivityFromRawHeadReflog() throws {
        let harness = try ScriptHarness()
        let repoURL = try harness.makeRepository(named: "ProjectAlpha")
        try harness.writeHeadReflog(
            for: repoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 10, message: "commit: first"),
                harness.reflogLine(daysOffset: 0, hour: 9, minute: 40, message: "merge branch 'main': result"),
                harness.reflogLine(daysOffset: -1, hour: 11, minute: 5, message: "commit: yesterday")
            ]
        )

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 2)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "ProjectAlpha")
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.dayIdentifier"] as? String, harness.todayIdentifier)
    }

    func testScriptPreservesPreviousSharedDataWhenAnyReadableReflogFailsToParse() throws {
        let harness = try ScriptHarness()
        let goodRepoURL = try harness.makeRepository(named: "ProjectGood")
        let badRepoURL = try harness.makeRepository(named: "ProjectBad")

        try harness.writeHeadReflog(
            for: goodRepoURL,
            lines: [
                harness.reflogLine(daysOffset: 0, hour: 10, minute: 15, message: "commit: good")
            ]
        )
        try harness.makeUnreadableAsFileHeadReflog(for: badRepoURL)
        try harness.seedPreferencesPlist([
            "tinybuddy.gitTodayCommitCount.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayCommitCount.count": 99,
            "tinybuddy.gitTodayFocusBlockCount.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayFocusBlockCount.count": 77,
            "tinybuddy.gitTodayRecentProject.dayIdentifier": harness.todayIdentifier,
            "tinybuddy.gitTodayRecentProject.projectName": "PreviousProject"
        ])

        let result = try harness.run(scanRoots: [harness.scanRootURL])
        let plist = try harness.readPreferencesPlist()

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(
            result.standardError.contains("preserving previous shared data"),
            "stderr did not mention preserving previous shared data: \(result.standardError)"
        )
        XCTAssertEqual(plist["tinybuddy.gitTodayCommitCount.count"] as? Int, 99)
        XCTAssertEqual(plist["tinybuddy.gitTodayFocusBlockCount.count"] as? Int, 77)
        XCTAssertEqual(plist["tinybuddy.gitTodayRecentProject.projectName"] as? String, "PreviousProject")
    }
}

private struct ScriptHarness {
    let fileManager = FileManager.default
    let rootURL: URL
    let homeURL: URL
    let scanRootURL: URL
    let plistURL: URL
    let scriptURL: URL
    let calendar: Calendar
    let todayIdentifier: String

    init() throws {
        rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        scanRootURL = rootURL.appendingPathComponent("scan-root", isDirectory: true)
        plistURL = rootURL.appendingPathComponent("group.plist")
        scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/update_git_completion_count.sh", isDirectory: false)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        self.calendar = calendar
        todayIdentifier = Self.dayFormatter.string(from: Date())

        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scanRootURL, withIntermediateDirectories: true)
    }

    func makeRepository(named name: String) throws -> URL {
        let repoURL = scanRootURL.appendingPathComponent(name, isDirectory: true)
        let gitLogsURL = repoURL.appendingPathComponent(".git/logs", isDirectory: true)
        try fileManager.createDirectory(at: gitLogsURL, withIntermediateDirectories: true)
        return repoURL
    }

    func writeHeadReflog(for repoURL: URL, lines: [String]) throws {
        let reflogURL = repoURL.appendingPathComponent(".git/logs/HEAD")
        try lines.joined(separator: "\n").appending("\n").write(to: reflogURL, atomically: true, encoding: .utf8)
    }

    func makeUnreadableAsFileHeadReflog(for repoURL: URL) throws {
        let reflogURL = repoURL.appendingPathComponent(".git/logs/HEAD", isDirectory: true)
        try fileManager.createDirectory(at: reflogURL, withIntermediateDirectories: true)
    }

    func seedPreferencesPlist(_ values: [String: Any]) throws {
        let dictionary = values as NSDictionary
        guard dictionary.write(to: plistURL, atomically: true) else {
            throw NSError(domain: "GitActivityRefreshScriptTests", code: 2)
        }
    }

    func readPreferencesPlist() throws -> [String: Any] {
        guard let dictionary = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw NSError(domain: "GitActivityRefreshScriptTests", code: 1)
        }
        return dictionary
    }

    func run(scanRoots: [URL]) throws -> ScriptRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeURL.path
        environment["TINYBUDDY_USER_HOME"] = homeURL.path
        environment["TINYBUDDY_APP_GROUP_CONTAINER"] = rootURL.appendingPathComponent("group-container", isDirectory: true).path
        environment["TINYBUDDY_APP_GROUP_PREFERENCES_DIR"] = plistURL.deletingLastPathComponent().path
        environment["TINYBUDDY_APP_GROUP_PREFERENCES_PLIST"] = plistURL.path
        environment["TINYBUDDY_GIT_SCAN_ROOTS"] = scanRoots.map(\.path).joined(separator: "\n")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let standardOutput = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let standardError = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ScriptRunResult(
            exitCode: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    func reflogLine(daysOffset: Int, hour: Int, minute: Int, message: String) -> String {
        let baseDate = calendar.startOfDay(for: Date())
        let date = calendar.date(
            byAdding: DateComponents(day: daysOffset, hour: hour, minute: minute),
            to: baseDate
        )!
        let epoch = Int(date.timeIntervalSince1970)
        let offsetSeconds = calendar.timeZone.secondsFromGMT(for: date)
        let offsetHours = offsetSeconds / 3600
        let offsetMinutes = abs(offsetSeconds / 60) % 60
        let offsetSign = offsetSeconds >= 0 ? "+" : "-"
        let timezoneOffset = String(format: "%@%02d%02d", offsetSign, abs(offsetHours), offsetMinutes)

        return "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 Tiny Buddy <tinybuddy@example.com> \(epoch) \(timezoneOffset)\t\(message)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct ScriptRunResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}
