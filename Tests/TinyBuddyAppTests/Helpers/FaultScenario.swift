import Foundation
import TinyBuddyCore

// MARK: - Fault Scenario

/// Declarative fault injection configuration for deterministic end-to-end tests.
///
/// Define a sequence of faults that will be injected at specified points
/// during the refresh lifecycle. The scenario is applied through the
/// existing `RefreshHarness` hook infrastructure.
public struct FaultScenario: Sendable {

    // MARK: Fault Types

    /// Types of faults that can be injected.
    public enum Fault: Equatable, Sendable {
        /// Git script times out (no response within the timeout window).
        case gitTimeout(afterScriptRun: Int)

        /// Git script returns a partial result (some repos failed).
        case gitPartial(afterScriptRun: Int, message: String = "partial")

        /// Git script fails completely.
        case gitFailed(afterScriptRun: Int, message: String = "failed")

        /// Git script is cancelled mid-flight.
        case gitCancelled(afterScriptRun: Int)

        /// A stale (old) script result arrives after a newer one.
        case staleResultRace(afterScriptRun: Int, previousRun: Int)

        /// Permission to access scan roots is revoked.
        case permissionRevoked(afterScriptRun: Int)

        /// Permission becomes invalid (e.g., bookmark stale).
        case permissionInvalid(afterScriptRun: Int)

        /// Disk write fails during snapshot commit.
        case snapshotWriteFailed(afterWrite: Int)

        /// Snapshot read returns corrupted data.
        case snapshotReadCorrupted(afterRead: Int)

        /// File system change monitor stops unexpectedly.
        case monitorInterrupted(afterSeconds: TimeInterval)

        /// Power state changes to battery + low power.
        case powerStateLow(onBattery: Bool = true, lowPower: Bool = true)

        /// Power state changes to AC power.
        case powerStateNormal

        /// Sleep/wake cycle.
        case sleepWake(afterSeconds: TimeInterval)

        /// Cross-day boundary (advance past midnight).
        case crossDayBoundary(afterSeconds: TimeInterval)

        /// Task cancellation during refresh.
        case taskCancellation(afterScriptRun: Int)

        /// Widget reload fails.
        case widgetReloadFailed(afterReload: Int)

        /// Directory becomes unreachable (offline/NFS).
        case directoryOffline(afterScriptRun: Int)

        /// Config switch (e.g., exclusion rules change) during refresh.
        case configSwitch(afterScriptRun: Int, newRules: [String])
    }

    /// A scheduled fault with its injection point.
    public struct ScheduledFault: Equatable, Sendable {
        public let fault: Fault
        public let injectAfterSeconds: TimeInterval

        public init(fault: Fault, injectAfterSeconds: TimeInterval) {
            self.fault = fault
            self.injectAfterSeconds = injectAfterSeconds
        }
    }

    // MARK: Properties

    /// Ordered sequence of faults to inject.
    public let faults: [ScheduledFault]

    /// Human-readable scenario name for diagnostics.
    public let name: String

    /// Random seed used to generate this scenario (0 = manually specified).
    public let seed: UInt64

    // MARK: Initialization

    public init(name: String, faults: [ScheduledFault], seed: UInt64 = 0) {
        self.name = name
        self.faults = faults.sorted { $0.injectAfterSeconds < $1.injectAfterSeconds }
        self.seed = seed
    }

    /// Create a scenario from a descriptive DSL.
    public init(name: String, seed: UInt64 = 0, @ScenarioBuilder _ builder: () -> [ScheduledFault]) {
        self.init(name: name, faults: builder(), seed: seed)
    }

    // MARK: Scenario Application

    /// Applies all faults up to the given virtual time, returning the faults to inject.
    public func faultsToInject(at virtualTime: TimeInterval) -> [Fault] {
        faults
            .filter { $0.injectAfterSeconds <= virtualTime }
            .map(\.fault)
    }

    /// Returns faults that match the given script run count trigger.
    public func faults(forScriptRun scriptRunCount: Int) -> [Fault] {
        faults.compactMap { scheduled in
            switch scheduled.fault {
            case let .gitTimeout(afterScriptRun) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .gitPartial(afterScriptRun, _) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .gitFailed(afterScriptRun, _) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .gitCancelled(afterScriptRun) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .staleResultRace(afterScriptRun, _) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .permissionRevoked(afterScriptRun) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .permissionInvalid(afterScriptRun) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .taskCancellation(afterScriptRun) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .directoryOffline(afterScriptRun) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            case let .configSwitch(afterScriptRun, _) where afterScriptRun == scriptRunCount:
                return scheduled.fault
            default:
                return nil
            }
        }
    }

    /// Returns faults that match a specific write attempt.
    public func faults(forWrite writeCount: Int) -> [Fault] {
        faults.compactMap { scheduled in
            if case let .snapshotWriteFailed(afterWrite) = scheduled.fault,
               afterWrite == writeCount {
                return scheduled.fault
            }
            return nil
        }
    }

    /// Returns faults that match a specific read attempt.
    public func faults(forRead readCount: Int) -> [Fault] {
        faults.compactMap { scheduled in
            if case let .snapshotReadCorrupted(afterRead) = scheduled.fault,
               afterRead == readCount {
                return scheduled.fault
            }
            return nil
        }
    }
}

// MARK: - Scenario Builder

@resultBuilder
public enum ScenarioBuilder {
    public static func buildBlock(_ components: [FaultScenario.ScheduledFault]...) -> [FaultScenario.ScheduledFault] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: FaultScenario.ScheduledFault) -> [FaultScenario.ScheduledFault] {
        [expression]
    }

    public static func buildOptional(_ component: [FaultScenario.ScheduledFault]?) -> [FaultScenario.ScheduledFault] {
        component ?? []
    }

    public static func buildEither(first component: [FaultScenario.ScheduledFault]) -> [FaultScenario.ScheduledFault] {
        component
    }

    public static func buildEither(second component: [FaultScenario.ScheduledFault]) -> [FaultScenario.ScheduledFault] {
        component
    }
}

// MARK: - Convenience DSL

extension FaultScenario.ScheduledFault {
    /// Inject a fault after the given number of seconds have elapsed.
    public static func at(_ seconds: TimeInterval, inject fault: FaultScenario.Fault) -> FaultScenario.ScheduledFault {
        FaultScenario.ScheduledFault(fault: fault, injectAfterSeconds: seconds)
    }
}

// MARK: - Predefined Scenarios

extension FaultScenario {
    /// A clean run with no faults injected.
    public static let cleanRun = FaultScenario(
        name: "Clean Run (no faults)",
        faults: []
    )

    /// Git timeout on first refresh.
    public static let gitTimeoutOnFirstRefresh = FaultScenario(
        name: "Git Timeout on First Refresh",
        faults: [
            .at(0.1, inject: .gitTimeout(afterScriptRun: 1))
        ]
    )

    /// Permission revoked after successful first refresh, then second refresh fails.
    public static let permissionLostMidSession = FaultScenario(
        name: "Permission Lost Mid-Session",
        faults: [
            .at(1.0, inject: .permissionRevoked(afterScriptRun: 2))
        ]
    )

    /// Stale result race: old refresh result arrives after new one.
    public static let staleResultRace = FaultScenario(
        name: "Stale Result Race",
        faults: [
            .at(0.5, inject: .staleResultRace(afterScriptRun: 2, previousRun: 1))
        ]
    )

    /// Snapshot write fails, then recovery succeeds.
    public static let snapshotWriteFailureAndRecovery = FaultScenario(
        name: "Snapshot Write Failure + Recovery",
        faults: [
            .at(0.1, inject: .snapshotWriteFailed(afterWrite: 1))
        ]
    )

    /// Monitor interrupted and restarted.
    public static let monitorInterrupted = FaultScenario(
        name: "Monitor Interrupted",
        faults: [
            .at(2.0, inject: .monitorInterrupted(afterSeconds: 2))
        ]
    )

    /// Sleep/wake cycle.
    public static let sleepWakeCycle = FaultScenario(
        name: "Sleep/Wake Cycle",
        faults: [
            .at(5.0, inject: .sleepWake(afterSeconds: 5))
        ]
    )

    /// Cross-day boundary during refresh.
    public static let crossDayDuringSession = FaultScenario(
        name: "Cross-Day During Session",
        faults: [
            .at(10.0, inject: .crossDayBoundary(afterSeconds: 10))
        ]
    )

    /// Combined: timeout + stale race + permission drop.
    public static let combinedFaults = FaultScenario(
        name: "Combined Faults",
        faults: [
            .at(0.1, inject: .gitTimeout(afterScriptRun: 1)),
            .at(0.5, inject: .staleResultRace(afterScriptRun: 2, previousRun: 1)),
            .at(1.0, inject: .permissionRevoked(afterScriptRun: 3))
        ]
    )
}
