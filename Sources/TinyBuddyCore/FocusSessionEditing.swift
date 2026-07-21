import Foundation

/// A fully recomputed, internally consistent view of recorded focus. The
/// revision advances only after the corresponding session archive was saved.
public struct FocusSessionDerivedSnapshot: Codable, Equatable, Sendable {
    public let revision: Int64
    public let dayIdentifier: String
    public let focusDuration: TimeInterval
    public let projectDurations: [String: TimeInterval]
    public let completedSessionCount: Int

    public init(
        revision: Int64,
        dayIdentifier: String,
        focusDuration: TimeInterval,
        projectDurations: [String: TimeInterval],
        completedSessionCount: Int
    ) {
        self.revision = revision
        self.dayIdentifier = dayIdentifier
        self.focusDuration = focusDuration
        self.projectDurations = projectDurations
        self.completedSessionCount = completedSessionCount
    }
}

public enum FocusSessionEditError: Equatable, Sendable {
    case sessionNotFound
    case sessionIsActive
    case invalidProject
    case invalidTimeRange
    case futureTime
    case overlappingSession
    case crossDayBoundaryUnavailable
    case insufficientSessionsToMerge
    case splitOutsideSession
    case persistenceFailed
    case nothingToUndo
    case alreadyConfirmed
}

public enum FocusSessionEditResult: Equatable, Sendable {
    case saved(replacedSessionIDs: [UUID], snapshot: FocusSessionDerivedSnapshot)
    case rejected(FocusSessionEditError)
}
