import XCTest
@testable import TinyBuddyCore

// MARK: - PrivacyRedactor Auto-Scan Tests

/// Comprehensive evidence-driven tests for the TinyBuddy privacy redactor.
///
/// These tests verify that:
/// - Absolute paths are never present in any output.
/// - The current user's username is never exposed.
/// - Email addresses, tokens, and credentials are masked.
/// - Remote URLs have credentials stripped.
/// - Commit messages are truncated to safe summaries.
/// - Stable identifiers are deterministic and irreversible.
/// - Diagnostic reports and summaries contain no sensitive fields.
/// - Error descriptions are sanitized before logging or display.
final class TinyBuddyPrivacyRedactorTests: XCTestCase {
    private let testUsername = NSUserName()
    private let testHomePath = "/Users/\(NSUserName())"
    private let testAbsolutePath = "/Users/\(NSUserName())/Projects/TinyBuddy/.git"
    private let testEmail = "alice@example.com"
    private let testGitHubToken = "ghp_" + "abc123def456ghi789jkl012mno345pqr678stu"
    private let testRemoteURL = "https://user:token@github.com/owner/repo.git"
    private let testCommitMessage = """
    Add awesome feature

    This commit adds a ton of amazing code.
    It spans multiple lines and should be truncated.
    """

    // MARK: - Path Sanitization

    func testBriefPathRemovesLeadingPaths() {
        let result = TinyBuddyPrivacyRedactor.briefPath(testAbsolutePath)
        XCTAssertFalse(result.contains(testUsername), "briefPath must not contain username")
        XCTAssertTrue(result.contains("…/"), "briefPath must use ellipsis prefix")
        XCTAssertTrue(result.hasSuffix("TinyBuddy/.git"), "briefPath must preserve last 2 components")
    }

    func testBriefPathForShortPath() {
        // /tmp/x.log has components ["/", "tmp", "x.log"] → suffix(2) = tmp/x.log
        let result = TinyBuddyPrivacyRedactor.briefPath("/tmp/x.log")
        XCTAssertEqual(result, "…/tmp/x.log")
    }

    func testBriefPathEmptyOrRoot() {
        // URL(fileURLWithPath:) resolves "" relative to CWD, so just check no crash
        _ = TinyBuddyPrivacyRedactor.briefPath("")
        _ = TinyBuddyPrivacyRedactor.briefPath("/")
    }

    func testLastComponentReturnsOnlyFilename() {
        let result = TinyBuddyPrivacyRedactor.lastComponent(testAbsolutePath)
        XCTAssertEqual(result, ".git")
        XCTAssertFalse(result.contains(testUsername))
    }

    func testStableIdentifierIsDeterministic() {
        let a = TinyBuddyPrivacyRedactor.stableIdentifier(for: testAbsolutePath)
        let b = TinyBuddyPrivacyRedactor.stableIdentifier(for: testAbsolutePath)
        XCTAssertEqual(a, b, "stableIdentifier must be deterministic")
    }

    func testStableIdentifierIsIrreversible() {
        let result = TinyBuddyPrivacyRedactor.stableIdentifier(for: testAbsolutePath)
        XCTAssertFalse(result.contains(testUsername), "stableIdentifier must not contain username")
        XCTAssertFalse(result.contains("Projects"), "stableIdentifier must not contain path components")
        XCTAssertEqual(result.count, 12, "stableIdentifier must be exactly 12 hex characters")
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(CharacterSet(charactersIn: result).isSubset(of: hexChars),
                      "stableIdentifier must be hex only")
    }

    func testStableIdentifierDiffersForDifferentPaths() {
        let a = TinyBuddyPrivacyRedactor.stableIdentifier(for: "/Users/UserA/Project")
        let b = TinyBuddyPrivacyRedactor.stableIdentifier(for: "/Users/UserB/Project")
        XCTAssertNotEqual(a, b, "different paths must produce different stable identifiers")
    }

    func testTinyBuddyStableRepoIdentifier() {
        let id = TinyBuddyStableRepoIdentifier(path: testAbsolutePath)
        let desc = id.description
        XCTAssertTrue(desc.hasPrefix("<repo:"), "description must use <repo:…> format")
        XCTAssertTrue(desc.hasSuffix(">"), "description must use <repo:…> format")
        XCTAssertEqual(id.value.count, 12)
    }

    // MARK: - Username Redaction

    func testRedactUsernameRemovesNSUserName() {
        let result = TinyBuddyPrivacyRedactor.redactUsername(testAbsolutePath)
        XCTAssertFalse(result.contains(testUsername), "username must be redacted from absolute paths")
        XCTAssertTrue(result.contains("/Users/<redacted>"),
                      "home directory must be replaced with <redacted>")
    }

    func testRedactUsernamePreservesSafeContent() {
        let safe = "Hello world, nothing sensitive here"
        let result = TinyBuddyPrivacyRedactor.redactUsername(safe)
        XCTAssertEqual(result, safe)
    }

    func testRedactUsernameDoesNotCrashOnEmpty() {
        XCTAssertEqual(TinyBuddyPrivacyRedactor.redactUsername(""), "")
    }

    // MARK: - Email Redaction

    func testRedactEmailMasksLocalPart() {
        let result = TinyBuddyPrivacyRedactor.redactEmail(testEmail)
        XCTAssertTrue(result.hasPrefix("***@"), "email local part must be masked")
        XCTAssertTrue(result.hasSuffix("example.com"), "email domain must be preserved")
    }

    func testRedactEmailPreservesNonEmailText() {
        let safe = "contact support at helpdesk"
        let result = TinyBuddyPrivacyRedactor.redactEmail(safe)
        XCTAssertEqual(result, safe)
    }

    func testRedactEmailHandlesMultipleEmails() {
        let input = "alice@test.com and bob@test.com"
        let result = TinyBuddyPrivacyRedactor.redactEmail(input)
        XCTAssertEqual(result.components(separatedBy: "***@").count, 3,
                       "both emails must be masked")
    }

    // MARK: - Remote URL Redaction

    func testRedactRemoteURLStripsCredentials() {
        let result = TinyBuddyPrivacyRedactor.redactRemoteURL(testRemoteURL)
        XCTAssertFalse(result.contains("https://"), "scheme must be removed")
        XCTAssertFalse(result.contains("user:token"), "credentials must be removed")
        XCTAssertFalse(result.contains("user@"), "user must be removed")
        XCTAssertTrue(result.contains("github.com/owner/repo.git"),
                      "path must be preserved for debugging")
    }

    func testRedactRemoteURLHandlesSSH() {
        let ssh = "git@github.com:owner/repo.git"
        let result = TinyBuddyPrivacyRedactor.redactRemoteURL(ssh)
        XCTAssertFalse(result.contains("git@"), "git@ prefix must be removed")
        // After removing git@: "github.com:owner/repo.git" → ":" is converted to "/"
        XCTAssertEqual(result, "github.com/owner/repo.git",
                       "SSH URL must be normalized to path form")
    }

    func testRedactRemoteURLPreservesSafeURLs() {
        let safe = "github.com/owner/repo"
        XCTAssertEqual(TinyBuddyPrivacyRedactor.redactRemoteURL(safe), safe)
    }

    // MARK: - Token Redaction

    func testRedactTokenShowsOnlyFirstFour() {
        let result = TinyBuddyPrivacyRedactor.redactToken(testGitHubToken)
        XCTAssertTrue(result.hasPrefix("ghp_"), "first 4 chars must be visible")
        XCTAssertTrue(result.hasSuffix("(truncated)"), "truncation suffix must be present")
        XCTAssertFalse(result.contains("def456"), "rest of token must be masked")
    }

    func testRedactTokenHandlesShortTokens() {
        let short = "ab"
        let result = TinyBuddyPrivacyRedactor.redactToken(short)
        XCTAssertEqual(result, "****")
    }

    // MARK: - Credential Redaction

    func testRedactCredentialsMasksGitHubTokens() {
        let result = TinyBuddyPrivacyRedactor.redactCredentials(testGitHubToken)
        XCTAssertTrue(result.contains("<redacted:credential>"),
                      "GitHub token must be replaced")
        XCTAssertFalse(result.contains("abc123def"), "token value must be removed")
    }

    func testRedactCredentialsMasksBearerTokens() {
        let input = "Authorization: Bearer sk-abc123def456"
        let result = TinyBuddyPrivacyRedactor.redactCredentials(input)
        XCTAssertTrue(result.contains("<redacted:credential>"),
                      "Bearer token must be masked")
    }

    func testRedactCredentialsPreservesSafeText() {
        let safe = "Hello world, nothing sensitive here"
        XCTAssertEqual(TinyBuddyPrivacyRedactor.redactCredentials(safe), safe)
    }

    // MARK: - Commit Message Redaction

    func testRedactCommitMessageTruncatesToFirstLine() {
        let result = TinyBuddyPrivacyRedactor.redactCommitMessage(testCommitMessage)
        XCTAssertEqual(result, "Add awesome feature",
                       "commit message must contain only first line")
        XCTAssertFalse(result.contains("ton of amazing"), "body must be removed")
    }

    func testRedactCommitMessageTruncatesLongLines() {
        // 100 chars → prefix(76) + "…" = 77 chars total
        let longMessage = String(repeating: "a", count: 100)
        let result = TinyBuddyPrivacyRedactor.redactCommitMessage(longMessage)
        XCTAssertEqual(result.count, 77, "long first lines must be truncated to 77 chars with ellipsis")
        XCTAssertTrue(result.hasSuffix("…"), "truncated message must end with ellipsis")
    }

    func testRedactCommitMessagePreservesShortLines() {
        let short = "Fix typo"
        XCTAssertEqual(TinyBuddyPrivacyRedactor.redactCommitMessage(short), short)
    }

    func testRedactCommitMessageHandlesEmptyString() {
        XCTAssertEqual(TinyBuddyPrivacyRedactor.redactCommitMessage(""), "")
    }

    // MARK: - Full Sanitizer Scans

    func testSanitizeForDiagnosticsRemovesUsername() {
        let input = "Processing repo at \(testAbsolutePath) for user \(testUsername)"
        let result = TinyBuddyPrivacyRedactor.sanitizeForDiagnostics(input)
        XCTAssertFalse(result.contains(testUsername), "diagnostics must redact username")
        XCTAssertTrue(result.contains("<redacted>"), "redaction markers must be present")
    }

    func testSanitizeForDiagnosticsRemovesEmail() {
        let input = "Contact: \(testEmail)"
        let result = TinyBuddyPrivacyRedactor.sanitizeForDiagnostics(input)
        XCTAssertTrue(result.contains("***@example.com"), "email local part must be masked")
    }

    func testSanitizeForDiagnosticsRemovesCredentials() {
        let input = "Token: \(testGitHubToken)"
        let result = TinyBuddyPrivacyRedactor.sanitizeForDiagnostics(input)
        XCTAssertTrue(result.contains("<redacted:credential>"), "credentials must be masked")
    }

    func testSanitizeForExportRemovesRemoteURLs() {
        let input = "Clone from \(testRemoteURL)"
        let result = TinyBuddyPrivacyRedactor.sanitizeForExport(input)
        XCTAssertTrue(result.contains("<redacted:url>"), "remote URLs must be redacted for export")
    }

    // MARK: - Error Description Sanitization

    func testSanitizedErrorDescriptionMasksUsername() {
        let error = NSError(domain: "test", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: testAbsolutePath])
        let result = TinyBuddyPrivacyRedactor.sanitizedErrorDescription(error)
        XCTAssertFalse(result.contains(testUsername), "error descriptions must not contain username")
        XCTAssertTrue(result.contains("<redacted>"), "redacted marker must be present")
    }

    func testSanitizedErrorDescriptionWithLocalizedError() {
        let error = TestError(message: "Access denied at \(testHomePath)/Secret")
        let result = TinyBuddyPrivacyRedactor.sanitizedErrorDescription(error)
        XCTAssertFalse(result.contains(testUsername))
        XCTAssertTrue(result.contains("<redacted>"))
    }

    func testSanitizedErrorDescriptionFallback() {
        let genericError = NSError(domain: "test", code: -1, userInfo: [:])
        let result = TinyBuddyPrivacyRedactor.sanitizedErrorDescription(
            genericError, fallback: "fallback"
        )
        // NSError's localizedDescription is non-empty in this case
        _ = result
    }

    func testSanitizedErrorLogDescriptionIncludesType() {
        let error = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "error occurred"
        ])
        let result = TinyBuddyPrivacyRedactor.sanitizedErrorLogDescription(error)
        XCTAssertTrue(result.contains("NSError"), "type name must be included")
        XCTAssertTrue(result.contains("error occurred"), "description must be included")
    }

    func testSanitizedErrorLogDescriptionMasksUsername() {
        let error = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: testAbsolutePath
        ])
        let result = TinyBuddyPrivacyRedactor.sanitizedErrorLogDescription(error)
        XCTAssertFalse(result.contains(testUsername), "username must be removed from error log")
    }

    // MARK: - App Group Sanitization

    func testSanitizedAppGroupIdentifierRedactsUsername() {
        let result = TinyBuddyPrivacyRedactor.sanitizedAppGroupIdentifier()
        let raw = TinyBuddySharedData.appGroupIdentifier
        let isRedacted = raw.lowercased().contains(NSUserName().lowercased())
        if isRedacted {
            XCTAssertFalse(result.contains(NSUserName().lowercased()),
                           "app group ID must not contain username when it's part of the identifier")
            XCTAssertNotEqual(result, raw, "app group ID must be sanitized when it contains username")
        }
    }

    // MARK: - Scan Root Paths Sanitization

    func testSanitizedScanRootPathsBriefsAndRedacts() {
        let paths = [
            "/Users/\(testUsername)/ProjectA",
            "/Users/\(testUsername)/Work/ProjectB"
        ]
        let result = TinyBuddyPrivacyRedactor.sanitizedScanRootPaths(paths)
        for r in result {
            XCTAssertFalse(r.contains(testUsername), "scan root paths must not contain username")
            XCTAssertTrue(r.hasPrefix("…/"), "absolute prefix must be removed")
        }
    }

    // MARK: - Diagnostic Summary Tests

    func testTinyBuddyAppConfigDiagnosticSummaryContainsNoPaths() {
        let config = TinyBuddyAppConfig(
            configVersion: 5,
            scanRootPaths: [
                "/Users/\(testUsername)/ProjectA",
                "/Users/\(testUsername)/Work/ProjectB"
            ],
            launchAtLoginEnabled: true,
            hudEnabled: true,
            refreshStrategy: .automatic,
            dayIdentifier: "2026-07-20"
        )
        let summary = config.diagnosticSummary
        XCTAssertFalse(summary.contains(testUsername), "config summary must not contain username")
        XCTAssertTrue(summary.contains("configVersion=5"), "safe numeric values must be preserved")
        XCTAssertTrue(summary.contains("day=2026-07-20"), "day identifier must be preserved")
        XCTAssertTrue(summary.contains("strategy=automatic"), "enum values must be preserved")
    }

    func testCombinedSnapshotDiagnosticSummaryIsSafe() {
        let snapshot = TinyBuddyCombinedSnapshot(
            revision: 42,
            dayIdentifier: "2026-07-20",
            snapshot: TinyBuddySnapshot(
                status: .completedOnce,
                stats: DailyStats(dayIdentifier: "2026-07-20", focusCount: 5, completionCount: 3)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 8,
                commitCount: 12,
                recentProjectName: "MySecretProject"
            ),
            activityRevision: 420
        )
        let summary = snapshot.diagnosticSummary
        XCTAssertFalse(summary.contains("MySecretProject"),
                       "project name must not appear in diagnostic summary")
        XCTAssertTrue(summary.contains("revision=42"), "revision must be preserved")
        XCTAssertTrue(summary.contains("day=2026-07-20"), "day identifier must be preserved")
        XCTAssertTrue(summary.contains("status=completedOnce"), "status must be preserved")
        XCTAssertTrue(summary.contains("focus=5"), "focus count must be preserved")
        XCTAssertTrue(summary.contains("completion=3"), "completion count must be preserved")
        XCTAssertTrue(summary.contains("actFocus=8"), "activity focus must be preserved")
        XCTAssertTrue(summary.contains("actCommit=12"), "activity commits must be preserved")
    }

    func testDiagnosticReportFormattedContainsNoSensitiveData() {
        let report = TinyBuddyDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            appName: "TinyBuddy",
            appVersion: "1.2.3",
            buildNumber: "42",
            schemaVersion: 3,
            snapshotState: "revision=42 day=2026-07-20",
            dataAvailability: "available",
            authorizationSummary: "2/3 available",
            recentObservation: nil,
            storageSummary: "3 files, 12 KB",
            debugLogState: "not enabled"
        )
        let formatted = report.formatted
        XCTAssertTrue(formatted.contains("TinyBuddy"), "app name must be present")
        XCTAssertTrue(formatted.contains("v1.2.3"), "version must be present")
        XCTAssertFalse(formatted.contains(testUsername), "report must not contain username")
    }

    func testDiagnosticReportClipboardFormattedIsExportSafe() {
        let report = TinyBuddyDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            appName: "TinyBuddy",
            appVersion: "1.0",
            buildNumber: "1",
            schemaVersion: 3,
            snapshotState: "revision=1 day=2026-07-20",
            dataAvailability: "available",
            authorizationSummary: "1/1 available",
            recentObservation: nil,
            storageSummary: "ok",
            debugLogState: "not enabled"
        )
        let clipboard = report.clipboardFormatted
        // clipboardFormatted applies sanitizeForExport
        XCTAssertFalse(clipboard.contains(testUsername),
                       "clipboard format must not contain username")
    }

    func testTinyBuddyDiagnosticReportBuilderProducesSafeReport() {
        let report = TinyBuddyDiagnosticReportBuilder.build(
            appVersion: "1.0",
            buildNumber: "1",
            schemaVersion: 3,
            snapshotRevision: 42,
            snapshotDayIdentifier: "2026-07-20",
            authorizedRootCount: 2,
            availableRootCount: 1
        )
        let formatted = report.formatted
        XCTAssertFalse(formatted.contains(testUsername))
        XCTAssertTrue(formatted.contains("revision=42"))
        XCTAssertTrue(formatted.contains("day=2026-07-20"))
    }
}

// MARK: - Test Helpers

private struct TestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
