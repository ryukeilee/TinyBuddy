import Foundation
import TinyBuddyCore

extension Notification.Name {
    static let tinyBuddySharedSnapshotDiagnosticDidChange = Notification.Name(
        "TinyBuddy.sharedSnapshotDiagnosticDidChange"
    )
}

/// A deliberately small, display-independent diagnostic record.  It is safe to
/// retain locally because it contains only the core stable identifier and enum
/// values; paths, repository names, and process output never enter this type.
struct TinyBuddyHiddenSnapshotDiagnosticSummary: Equatable {
    let identifier: String
    let phase: TinyBuddySharedSnapshotPhase
    let reason: TinyBuddySharedSnapshotReason
    let recovery: TinyBuddySharedSnapshotRecovery
    let attemptCount: Int

    init(_ observation: TinyBuddySharedSnapshotObservation) {
        identifier = observation.identifier
        phase = observation.phase
        reason = observation.reason
        recovery = observation.recovery
        attemptCount = observation.attemptCount
    }

    /// A sanitized diagnostic string suitable for export.
    /// Contains only the stable identifier and enum-based state — no paths,
    /// no usernames, no sensitive content.
    var sanitizedDiagnosticLine: String {
        "id=\(identifier) phase=\(phase.rawValue) reason=\(reason.rawValue) recovery=\(recovery.rawValue) attempt=\(attemptCount)"
    }
}

final class TinyBuddySharedSnapshotDiagnosticRecorder: @unchecked Sendable {
    static let shared = TinyBuddySharedSnapshotDiagnosticRecorder()

    private let lock = NSLock()
    private var storedSummary: TinyBuddyHiddenSnapshotDiagnosticSummary?

    var latestSummary: TinyBuddyHiddenSnapshotDiagnosticSummary? {
        lock.lock()
        defer { lock.unlock() }
        return storedSummary
    }

    func record(_ observation: TinyBuddySharedSnapshotObservation) {
        lock.lock()
        storedSummary = TinyBuddyHiddenSnapshotDiagnosticSummary(observation)
        lock.unlock()
        NotificationCenter.default.post(
            name: .tinyBuddySharedSnapshotDiagnosticDidChange,
            object: self
        )
    }

    func record(
        phase: TinyBuddySharedSnapshotPhase,
        reason: TinyBuddySharedSnapshotReason,
        recovery: TinyBuddySharedSnapshotRecovery = .stopped,
        attemptCount: Int = 1
    ) {
        record(TinyBuddySharedSnapshotObservation(
            phase: phase,
            reason: reason,
            recovery: recovery,
            attemptCount: attemptCount
        ))
    }
}
