import Foundation
import OSLog

/// A bounded, background-friendly health check that verifies the complete
/// Widget lifecycle chain at startup or on demand.
///
/// Each check runs synchronously inside its verifying method so the caller
/// controls dispatch.  The intended usage is to call `runAll()` from a
/// background queue once at launch.
public final class TinyBuddyWidgetLifecycleHealthCheck: @unchecked Sendable {
    private let sharedDefaults: UserDefaults
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let configStore: TinyBuddyConfigStore
    private let fileManager: FileManager
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private static let logger = Logger(
        subsystem: "local.tinybuddy",
        category: "WidgetLifecycleHealthCheck"
    )

    public struct CheckResult: Equatable, Sendable {
        public let check: String
        public let passed: Bool
        public let detail: String

        public init(check: String, passed: Bool, detail: String) {
            self.check = check
            self.passed = passed
            self.detail = detail
        }
    }

    public init(
        sharedDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        combinedSnapshotStore: TinyBuddyCombinedSnapshotStore? = nil,
        configStore: TinyBuddyConfigStore? = nil,
        fileManager: FileManager = .default,
        timeEnvironment: TinyBuddyTimeEnvironment = TinyBuddyTimeEnvironment()
    ) {
        self.sharedDefaults = sharedDefaults
        self.combinedSnapshotStore = combinedSnapshotStore
            ?? TinyBuddyCombinedSnapshotStore(repairOnLoad: false)
        self.configStore = configStore ?? TinyBuddyConfigStore()
        self.fileManager = fileManager
        self.timeEnvironment = timeEnvironment
    }

    /// Runs all health checks and returns results.  Catches and reports
    /// unexpected errors from individual checks without aborting the
    /// remaining ones.
    public func runAll() -> [CheckResult] {
        var results: [CheckResult] = []
        let checks: [() -> CheckResult] = [
            checkSharedContainer,
            checkSnapshotSchema,
            checkAppGroupDefaults,
            checkConfigAccess,
            checkTimeContinuity,
        ]
        for check in checks {
            let result: CheckResult
            do {
                result = check()
            } catch {
                result = CheckResult(
                    check: "unexpectedError",
                    passed: false,
                    detail: "\(type(of: error)): \(error.localizedDescription)"
                )
            }
            if !result.passed {
                Self.logger.warning(
                    "health check failed: check=\(result.check, privacy: .public) detail=\(result.detail, privacy: .public)"
                )
            }
            results.append(result)
        }
        return results
    }

    // MARK: - Individual checks

    /// Verifies that the App Group container directory is accessible.
    public func checkSharedContainer() -> CheckResult {
        guard TinyBuddySharedData.isAppGroupContainerAvailable(fileManager: fileManager) else {
            return CheckResult(
                check: "sharedContainer",
                passed: false,
                detail: "App Group container (group.com.ryukeili.TinyBuddy) is not accessible"
            )
        }
        return CheckResult(
            check: "sharedContainer",
            passed: true,
            detail: "App Group container is accessible"
        )
    }

    /// Verifies that the combined snapshot schema version is compatible with
    /// the current build.
    public func checkSnapshotSchema() -> CheckResult {
        let schemaVersion = combinedSnapshotStore.loadSchemaVersion()
        guard let schemaVersion else {
            // No schema version stored yet (first launch).  Not a failure.
            return CheckResult(
                check: "snapshotSchema",
                passed: true,
                detail: "no stored schema version (first launch)"
            )
        }

        guard schemaVersion <= TinyBuddyCombinedSnapshotStore.currentSchemaVersion else {
            return CheckResult(
                check: "snapshotSchema",
                passed: false,
                detail: "stored schema version \(schemaVersion) > current \(TinyBuddyCombinedSnapshotStore.currentSchemaVersion)"
            )
        }

        guard TinyBuddyCombinedSnapshotStore.migrationPath(from: schemaVersion) != nil else {
            return CheckResult(
                check: "snapshotSchema",
                passed: false,
                detail: "no migration path from schema version \(schemaVersion)"
            )
        }

        let readable = combinedSnapshotStore.readValidated()
        if readable.observation?.reason == .snapshotCorrupt {
            return CheckResult(
                check: "snapshotSchema",
                passed: false,
                detail: "snapshot is corrupt; schema version \(schemaVersion)"
            )
        }

        return CheckResult(
            check: "snapshotSchema",
            passed: true,
            detail: "schema version \(schemaVersion) is compatible and readable"
        )
    }

    /// Verifies that the App Group UserDefaults domain is accessible.
    public func checkAppGroupDefaults() -> CheckResult {
        guard TinyBuddySharedData.isAppGroupDefaultsAvailable() else {
            return CheckResult(
                check: "appGroupDefaults",
                passed: false,
                detail: "UserDefaults(suiteName:) for App Group is nil"
            )
        }

        let testKey = "tinybuddy.healthCheck.probe"
        sharedDefaults.set(true, forKey: testKey)
        let canWrite = sharedDefaults.bool(forKey: testKey) == true
        sharedDefaults.removeObject(forKey: testKey)

        guard canWrite else {
            return CheckResult(
                check: "appGroupDefaults",
                passed: false,
                detail: "App Group UserDefaults read-write test failed"
            )
        }

        return CheckResult(
            check: "appGroupDefaults",
            passed: true,
            detail: "App Group UserDefaults is readable and writable"
        )
    }

    /// Verifies that the shared app config is accessible (if previously stored).
    public func checkConfigAccess() -> CheckResult {
        let config = configStore.load()
        _ = configStore.loadConfigVersion()
        // Config is optional; absence on first launch is not a failure.
        if config != nil {
            return CheckResult(
                check: "configAccess",
                passed: true,
                detail: "app config loaded successfully"
            )
        }
        return CheckResult(
            check: "configAccess",
            passed: true,
            detail: "no stored config (first launch or reset)"
        )
    }

    /// Verifies that the time continuity record is present and self-consistent.
    public func checkTimeContinuity() -> CheckResult {
        let continuity = TinyBuddyTimeContinuityRecord.load(userDefaults: sharedDefaults)
        guard continuity.lastObservedDayIdentifier.isEmpty == false else {
            return CheckResult(
                check: "timeContinuity",
                passed: true,
                detail: "no continuity record (first launch)"
            )
        }

        let calibrationGeneration = TinyBuddyTimeContinuityRecord.currentCalibrationGeneration(
            userDefaults: sharedDefaults
        )

        if calibrationGeneration != continuity.calibrationGeneration {
            return CheckResult(
                check: "timeContinuity",
                passed: false,
                detail: "calibration generation mismatch: record=\(continuity.calibrationGeneration) current=\(calibrationGeneration)"
            )
        }

        return CheckResult(
            check: "timeContinuity",
            passed: true,
            detail: "time continuity generation=\(continuity.calibrationGeneration) day=\(continuity.lastObservedDayIdentifier)"
        )
    }
}
