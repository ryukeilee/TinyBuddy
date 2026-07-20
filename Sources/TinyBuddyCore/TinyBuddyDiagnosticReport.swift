import Foundation

// MARK: - Diagnostic Report

/// A safe, minimal diagnostic report that users can copy or export for
/// troubleshooting.  The report contains only the information needed to
/// diagnose common issues while applying the project's privacy rules.
///
/// **Rules:**
/// - Absolute paths are never included.  Paths are reduced to brief form
///   (last 2 components) or replaced with stable identifiers.
/// - The local username is never exported.
/// - Email addresses and credentials are masked.
/// - Remote repository URLs are stripped of credentials and host details.
/// - Full commit messages are never included (only truncated first lines).
/// - Access tokens are masked after the first 4 characters.
/// - The report includes the app version, schema version, snapshot revision,
///   diagnostic observation identifiers, and authorization status — all
///   of which are safe for cross-device fault correlation.
public struct TinyBuddyDiagnosticReport: Equatable, Sendable {
    public let generatedAt: Date
    public let appName: String
    public let appVersion: String?
    public let buildNumber: String?
    public let schemaVersion: Int
    public let snapshotState: String
    public let dataAvailability: String
    public let authorizationSummary: String
    public let recentObservation: String?
    public let storageSummary: String
    public let debugLogState: String

    public var formatted: String {
        let dateStr = ISO8601DateFormatter().string(from: generatedAt)
        let lines = [
            "── TinyBuddy 诊断报告 ──",
            "生成时间: \(dateStr)",
            "应用: \(appName) v\(appVersion ?? "?") (\(buildNumber ?? "?"))",
            "",
            "快照状态: \(snapshotState)",
            "数据可用性: \(dataAvailability)",
            "快照 Schema: v\(schemaVersion)",
            "授权: \(authorizationSummary)",
            "存储: \(storageSummary)",
            "",
            recentObservation.map { "诊断事件: \($0)" },
            "调试日志: \(debugLogState)",
            "",
            "── 报告结束 ──"
        ]
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    /// Returns the report formatted for clipboard copy (sanitized for export).
    public var clipboardFormatted: String {
        TinyBuddyPrivacyRedactor.sanitizeForExport(formatted)
    }
}

// MARK: - Report Builder

public enum TinyBuddyDiagnosticReportBuilder {
    /// Builds a diagnostic report from the current app state.
    /// All parameters are optional — the builder uses defaults for anything
    /// not provided so it can be called from any context.
    public static func build(
        appVersion: String? = nil,
        buildNumber: String? = nil,
        snapshotState: String? = nil,
        dataAvailability: TinyBuddyDisplayDataAvailability? = nil,
        schemaVersion: Int? = nil,
        snapshotRevision: Int64? = nil,
        snapshotDayIdentifier: String? = nil,
        authorizedRootCount: Int = 0,
        availableRootCount: Int = 0,
        observation: TinyBuddySharedSnapshotObservation? = nil,
        storageInfo: String? = nil
    ) -> TinyBuddyDiagnosticReport {
        let snapshotDesc: String
        if let state = snapshotState {
            snapshotDesc = state
        } else if let rev = snapshotRevision, let day = snapshotDayIdentifier {
            snapshotDesc = "revision=\(rev) day=\(day)"
        } else {
            snapshotDesc = "无"
        }

        let availabilityDesc: String
        if let da = dataAvailability {
            switch da {
            case .available:
                availabilityDesc = "可用"
            case .loading:
                availabilityDesc = "加载中"
            case .stale:
                availabilityDesc = "过期"
            case .failed(let reason):
                availabilityDesc = "失败(\(reason?.identifier ?? "unknown"))"
            }
        } else {
            availabilityDesc = "未指定"
        }

        let authSummary = "\(availableRootCount)/\(authorizedRootCount) 可用"

        let obsDesc = observation.map { obs in
            "phase=\(obs.phase.identifier) reason=\(obs.reason.identifier) recovery=\(obs.recovery.identifier) count=\(obs.attemptCount)"
        }

        let now = Date()
        let debugState = TinyBuddyDebugLogManager.shared.isActive
            ? "已启用"
            : "未启用"

        return TinyBuddyDiagnosticReport(
            generatedAt: now,
            appName: "TinyBuddy",
            appVersion: appVersion,
            buildNumber: buildNumber,
            schemaVersion: schemaVersion ?? TinyBuddyCombinedSnapshotStore.currentSchemaVersion,
            snapshotState: snapshotDesc,
            dataAvailability: availabilityDesc,
            authorizationSummary: authSummary,
            recentObservation: obsDesc,
            storageSummary: storageInfo ?? "未检查",
            debugLogState: debugState
        )
    }
}
