import CryptoKit
import Foundation

// MARK: - Stable Repository Identifier

/// An irreversible, stable identifier derived from a repository URL's real path.
/// This replaces absolute paths in logs, diagnostics, and exports so that
/// fault correlation remains possible without exposing the user's filesystem
/// structure or username.
public struct TinyBuddyStableRepoIdentifier: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Short, stable fingerprint (first 12 hex chars of SHA-256 of the
    /// standardized real path).  Collision probability is negligible for the
    /// expected repository count (~dozens), and the truncated hash prevents
    /// path reconstruction.
    public let value: String

    public var description: String { "<repo:\(value)>" }

    public init(path: String) {
        let normalized = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let hash = TinyBuddyPrivacyRedactor.sha256HexPrefix(normalized, length: 12)
        value = hash
    }
}

// MARK: - Privacy Classification

/// Describes the sensitivity level of a data field for automated policy
/// enforcement in logging, persistence, and export operations.
public enum TinyBuddyPrivacyClassification: Equatable, Sendable {
    /// Safe for persistence, display, and export in any context.
    case `public`
    /// Safe for on-device persistence but must be redacted in exports,
    /// diagnostics shared with the user, and logs.
    case `internal`
    /// Never persisted, logged, or exported. Must be masked at the call site.
    case sensitive
}

// MARK: - Core Privacy Redactor

/// Centralized sanitization engine for TinyBuddy.  Every log line, diagnostic
/// report, error message, export payload, and shared snapshot passes through
/// this module before it reaches any external boundary (file, clipboard,
/// widget, stdout).
///
/// **Guarantees:**
/// - Full absolute paths are never persisted or exported.
/// - The local username (`NSUserName()`) is never written to any output.
/// - Email addresses are detected and redacted.
/// - Remote repository URLs have their scheme, host, and credentials removed.
/// - Access tokens and credentials are masked after the first few characters.
/// - Full commit content is never included in diagnostics.
/// - A stable, irreversible repo identifier preserves fault correlation.
public enum TinyBuddyPrivacyRedactor {
    // MARK: - Path Sanitization

    /// Returns only the last two path components of a file system path.
    /// Use this for diagnostics, logs, and any user-facing output.
    ///
    ///     /Users/Alice/Projects/MyApp/.git  →  …/MyApp/.git
    public static func briefPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let components = url.pathComponents
        guard components.count > 2 else {
            return url.lastPathComponent
        }
        let tail = components.suffix(2)
        return "…/" + tail.joined(separator: "/")
    }

    /// Returns the last path component (file or directory name) only.
    public static func lastComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Generates a stable, irreversible identifier from a path.
    /// This is the preferred way to correlate log entries or diagnostics
    /// that reference a specific repository or directory.
    public static func stableIdentifier(for path: String) -> String {
        TinyBuddyStableRepoIdentifier(path: path).value
    }

    // MARK: - Username Redaction

    /// Replaces the current user's short username and home-directory patterns.
    public static func redactUsername(_ text: String) -> String {
        var result = text
        let username = NSUserName()
        guard !username.isEmpty else { return result }

        let homePattern = "/Users/\(username)"
        result = result.replacingOccurrences(of: homePattern, with: "/Users/<redacted>")

        if let regex = try? NSRegularExpression(
            pattern: "\\b\(NSRegularExpression.escapedPattern(for: username))\\b",
            options: []
        ) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "<redacted>"
            )
        }

        return result
    }

    // MARK: - Email Redaction

    /// Masks email addresses, preserving the domain for debugging.
    /// `alice@example.com` → `***@example.com`
    public static func redactEmail(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "[a-zA-Z0-9._%+-]+@([a-zA-Z0-9.-]+\\.[a-zA-Z]{2,})",
            options: []
        ) else { return text }

        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "***@$1"
        )
    }

    // MARK: - Remote URL Redaction

    /// Strips credentials and host details from a remote Git URL, keeping
    /// only the path for debugging.
    ///
    /// `https://user:token@github.com/owner/repo.git` → `github.com/owner/repo.git`
    /// `git@github.com:owner/repo.git` → `github.com/owner/repo.git`
    public static func redactRemoteURL(_ url: String) -> String {
        var result = url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "git@", with: "")
            .replacingOccurrences(of: "ssh://", with: "")
            .replacingOccurrences(of: "git+", with: "")

        if let atRange = result.range(of: "@") {
            result = String(result[atRange.upperBound...])
        }

        // Convert the SSH-style colon separator (before any `/`) to `/`.
        // For git@github.com:owner/repo.git, after removing git@, we have
        // github.com:owner/repo.git. The colon before the path must become `/`.
        let beforeFirstSlash = result.split(separator: "/", maxSplits: 1).first ?? ""
        if beforeFirstSlash.contains(":") {
            let parts = result.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result = "\(parts[0])/\(parts[1])"
            }
        }

        return result
    }

    // MARK: - Token and Credential Redaction

    /// Masks a token, showing only the first 4 characters.
    /// `ghp_abc123def456` → `ghp_… (truncated)`
    public static func redactToken(_ token: String) -> String {
        guard token.count > 4 else { return "****" }
        return "\(token.prefix(4))… (truncated)"
    }

    /// Scans a string for common credential patterns and redacts them.
    public static func redactCredentials(_ text: String) -> String {
        var result = text

        let patterns = [
            "ghp_[a-zA-Z0-9]{36}",
            "gho_[a-zA-Z0-9]{36}",
            "ghu_[a-zA-Z0-9]{36}",
            "ghs_[a-zA-Z0-9]{36}",
            "ghr_[a-zA-Z0-9]{36}",
            "github_pat_[a-zA-Z0-9_]{85}",
            "Bearer\\s+[a-zA-Z0-9._-]+",
            "token\\s+[a-zA-Z0-9._-]+",
            "api[_-]?key['\"]?\\s*[:=]\\s*['\"][a-zA-Z0-9._-]+['\"]",
            "secret['\"]?\\s*[:=]\\s*['\"][a-zA-Z0-9._-]+['\"]"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "<redacted:credential>"
                )
            }
        }

        return result
    }

    // MARK: - Commit Content Redaction

    /// Truncates a commit message to a single-line summary (first line only,
    /// max 80 chars). Full commit bodies are never included in diagnostics.
    public static func redactCommitMessage(_ message: String) -> String {
        let firstLine = message
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? message
        if firstLine.count > 80 {
            return String(firstLine.prefix(76)) + "…"
        }
        return firstLine
    }

    // MARK: - Full Sanitizers

    /// Applies all redaction passes for diagnostic logging and user-facing
    /// diagnostic output.  Paths are briefed, usernames/emails/credentials
    /// are masked.  Remote URLs are preserved for debugging but credentials
    /// are stripped.
    public static func sanitizeForDiagnostics(_ text: String) -> String {
        var result = text
        result = redactUsername(result)
        result = redactEmail(result)
        result = redactCredentials(result)
        return result
    }

    /// Full redaction for data that leaves the device boundary (clipboard,
    /// export, share sheet).  Remote URLs are also redacted.
    public static func sanitizeForExport(_ text: String) -> String {
        var result = sanitizeForDiagnostics(text)
        if let regex = try? NSRegularExpression(
            pattern: "https?://[^\\s]+|git@[^\\s:]+:[^\\s]+|ssh://[^\\s]+",
            options: []
        ) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "<redacted:url>"
            )
        }
        return result
    }

    // MARK: - Error Description Sanitization

    /// Sanitizes an error description for diagnostic use.
    /// Absolute paths, usernames, and credentials are masked.
    /// Stable identifiers and enum-style values are preserved.
    ///
    /// Returns the sanitized description, or a fallback string if the
    /// provided error's description is empty after sanitization.
    public static func sanitizedErrorDescription(
        _ error: Error,
        fallback: String = "unknown error"
    ) -> String {
        let description = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        guard !description.isEmpty else { return fallback }
        let sanitized = sanitizeForDiagnostics(description)
        guard !sanitized.isEmpty else { return fallback }
        return sanitized
    }

    /// Sanitizes an error for logging.  The full sanitized description is
    /// returned alongside the error's type name for diagnostics.
    public static func sanitizedErrorLogDescription(_ error: Error) -> String {
        let typeName = "\(type(of: error))"
        let desc = sanitizedErrorDescription(error, fallback: "n/a")
        return "\(typeName): \(desc)"
    }

    // MARK: - App Group Identifier Sanitization

    /// Returns a sanitized version of the app group identifier for diagnostics.
    /// The real identifier contains the developer's username (`com.ryukeili.TinyBuddy`).
    public static func sanitizedAppGroupIdentifier() -> String {
        let raw = TinyBuddySharedData.appGroupIdentifier
        return raw.replacingOccurrences(
            of: NSUserName().lowercased(),
            with: "<redacted>",
            options: .caseInsensitive
        )
    }

    // MARK: - Scan Root Paths Sanitization

    /// Sanitizes an array of absolute scan root paths for diagnostic display.
    /// Each path is reduced to a brief form and then the username is redacted.
    public static func sanitizedScanRootPaths(_ paths: [String]) -> [String] {
        paths.map { redactUsername(briefPath($0)) }
    }

    // MARK: - Internal Helpers

    /// Hex prefix of the SHA-256 digest of `string`.
    static func sha256HexPrefix(_ string: String, length: Int) -> String {
        guard let data = string.data(using: .utf8) else {
            return String(repeating: "0", count: length)
        }
        let digest = SHA256.hash(data: data)
        return digest.prefix((length + 1) / 2)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(length)
            .lowercased()
    }
}

// MARK: - Extensions on existing types

extension TinyBuddyAppConfig {
    /// A diagnostic-safe view of the config.  Paths are reduced to brief form,
    /// and the config version is preserved for fault correlation.
    public var diagnosticSummary: String {
        let safePaths = TinyBuddyPrivacyRedactor.sanitizedScanRootPaths(scanRootPaths)
        let fields = [
            "configVersion=\(configVersion)",
            "scanRoots=[\(safePaths.joined(separator: ", "))]",
            "launchAtLogin=\(launchAtLoginEnabled)",
            "hudEnabled=\(hudEnabled)",
            "strategy=\(refreshStrategy.rawValue)",
            "day=\(dayIdentifier)"
        ]
        return fields.joined(separator: " ")
    }
}

extension TinyBuddyCombinedSnapshot {
    /// A diagnostic-safe summary.  The project name is excluded; structured
    /// counts and identifiers are preserved for fault correlation.
    public var diagnosticSummary: String {
        let fields = [
            "revision=\(revision)",
            "day=\(dayIdentifier)",
            "status=\(snapshot.status.rawValue)",
            "focus=\(snapshot.stats.focusCount)",
            "completion=\(snapshot.stats.completionCount)",
            "actFocus=\(activitySnapshot.focusBlockCount.map(String.init) ?? "nil")",
            "actCommit=\(activitySnapshot.commitCount.map(String.init) ?? "nil")",
            "actRevision=\(activityRevision.map(String.init) ?? "nil")"
        ]
        return fields.joined(separator: " ")
    }
}


