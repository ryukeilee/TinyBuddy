import Foundation

/// Pure, case-insensitive matching of project-exclusion path rules against the
/// canonical paths (repository common-dir aliases) that identify a git project.
///
/// macOS volumes are case-insensitive by default, so path comparisons are folded
/// to lowercase. Matches are evaluated over the repository's canonical aliases,
/// which the scanner already resolves through symlinks (`pwd -P`), so worktrees
/// of one repository — sharing the same common dir — are covered by the same
/// canonical path.
public enum FocusProjectExclusionMatcher {

    /// True when `canonicalPath` (an absolute, symlink-resolved directory path)
    /// is covered by `pattern`.
    ///
    /// - A multi-segment pattern (`a/b`) excludes that subtree: it matches when
    ///   the pattern occupies whole trailing segments of the canonical path, so
    ///   nested repositories under an excluded parent are excluded too.
    /// - A single-segment pattern (`build`) matches any canonical path
    ///   component equal to it, at any depth.
    public static func patternMatches(_ pattern: String, canonicalPath: String) -> Bool {
        let path = normalizedCanonicalPath(canonicalPath)
        guard pattern.isEmpty == false,
              let foldedPattern = TinyBuddyExclusionRule.normalizedPattern(pattern)?
                .lowercased(),
              !path.isEmpty else {
            return false
        }
        let foldedPath = path.lowercased()
        if foldedPattern.contains("/") {
            return foldedPath.hasSuffix("/" + foldedPattern)
                || foldedPath.contains("/" + foldedPattern + "/")
        }
        return foldedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains(where: { $0 == foldedPattern })
    }

    /// True when any of the candidate canonical paths is covered by any rule.
    public static func isExcluded(canonicalPaths: [String], patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        return canonicalPaths.contains { path in
            patterns.contains { patternMatches($0, canonicalPath: path) }
        }
    }

    /// Trims whitespace and a single trailing slash from a canonical path so a
    /// repo root and its parent compare identically.
    static func normalizedCanonicalPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}