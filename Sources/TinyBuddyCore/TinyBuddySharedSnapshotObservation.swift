import Foundation

/// A stable lifecycle boundary for shared snapshot diagnostics. Values are safe
/// to persist or aggregate: they never contain a path, project name, or raw error.
public enum TinyBuddySharedSnapshotPhase: String, Equatable, Sendable {
    case gitScan
    case snapshotWrite
    case snapshotRead
    case timelineReload

    public var identifier: String { rawValue }
}

public enum TinyBuddySharedSnapshotReason: String, Equatable, Sendable {
    case staleData
    case snapshotCorrupt
    case appGroupUnavailable
    case sandboxReadDenied
    case versionIncompatible
    case invalidActivityRevision
    case persistenceFailed
    case timelineReloadFailed
    case gitScanFailed
    case gitScanPartial
    case gitScanSkipped

    public var identifier: String { rawValue }
}

public enum TinyBuddySharedSnapshotRecovery: String, Equatable, Sendable {
    case none
    case rereadSucceeded
    case rebuilt
    case stopped

    public var identifier: String { rawValue }
}

public struct TinyBuddySharedSnapshotObservation: Equatable, Sendable {
    public let phase: TinyBuddySharedSnapshotPhase
    public let reason: TinyBuddySharedSnapshotReason
    public let recovery: TinyBuddySharedSnapshotRecovery
    public let identifier: String
    public let attemptCount: Int

    public init(
        phase: TinyBuddySharedSnapshotPhase,
        reason: TinyBuddySharedSnapshotReason,
        recovery: TinyBuddySharedSnapshotRecovery,
        attemptCount: Int
    ) {
        self.phase = phase
        self.reason = reason
        self.recovery = recovery
        self.identifier = "tinybuddy.sharedSnapshot.\(phase.identifier).\(reason.identifier)"
        self.attemptCount = max(1, attemptCount)
    }
}

public struct TinyBuddyValidatedCombinedSnapshotRead: Equatable, Sendable {
    public let snapshot: TinyBuddyCombinedSnapshot?
    public let observation: TinyBuddySharedSnapshotObservation?

    public init(
        snapshot: TinyBuddyCombinedSnapshot?,
        observation: TinyBuddySharedSnapshotObservation?
    ) {
        self.snapshot = snapshot
        self.observation = observation
    }
}
