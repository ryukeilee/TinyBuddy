import Foundation

/// Whether the HUD's “继续上次开发” card may start a manual focus session for
/// the repository captured by the development interruption snapshot.
///
/// The decision is pure: fingerprint matching follows the project registry's
/// case-folding convention and never guesses by display name or alias, and the
/// session-conflict check is based on the engine's currently open session
/// (manual or automatic), never on the manual-control projection alone.
public enum DevelopmentInterruptionResumeState: Equatable, Sendable {
    /// No usable exact fingerprint match, or another project's session is open:
    /// the card stays read-only and the resume action is a no-op.
    case blocked
    /// The matched project already has an open session (manual or automatic,
    /// active or paused). The card shows the current state and offers no
    /// start action.
    case inProgress(project: TinyBuddyProject, status: FocusSessionStatus)
    /// The matched project is usable and no session is open: starting a manual
    /// focus session for the project's stable registered identity is safe.
    case available(project: TinyBuddyProject)

    /// The exactly matched registered project, when one exists.
    public var matchedProject: TinyBuddyProject? {
        switch self {
        case .blocked:
            return nil
        case .inProgress(let project, _), .available(let project):
            return project
        }
    }
}

public enum DevelopmentInterruptionResumeDecision {
    /// Resolves the card's one-click resume gate.
    ///
    /// - Parameters:
    ///   - fingerprint: The development interruption snapshot's
    ///     `repositoryFingerprint`.
    ///   - projects: The project registry's current projects.
    ///   - openSession: The engine's currently open session (manual or
    ///     automatic) with its live status, if any.
    public static func make(
        fingerprint: String,
        projects: [TinyBuddyProject],
        openSession: (project: FocusProjectContext, status: FocusSessionStatus)?
    ) -> DevelopmentInterruptionResumeState {
        guard let matched = usableProject(matching: fingerprint, in: projects) else {
            return .blocked
        }
        if let openSession {
            if openSession.project.key == matched.id.rawValue {
                return .inProgress(project: matched, status: openSession.status)
            }
            // Any other open session (manual or automatic) keeps the card
            // read-only: starting would switch the focused project.
            return .blocked
        }
        return .available(project: matched)
    }

    /// Exact fingerprint match against a usable registered project: kind
    /// `gitRepository`, state `active`, and a non-empty stored fingerprint
    /// equal to the snapshot's under the registry's case-folding convention.
    /// Multiple matches resolve deterministically — active first, then the
    /// smallest stable project id. Name/alias-only matches are never
    /// considered, so a renamed repository or a same-named different
    /// repository cannot be guessed.
    static func usableProject(
        matching fingerprint: String,
        in projects: [TinyBuddyProject]
    ) -> TinyBuddyProject? {
        let folded = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !folded.isEmpty else { return nil }
        let candidates = projects.filter { project in
            guard project.kind == .gitRepository,
                  project.state == .active,
                  let stored = project.repositoryFingerprint else {
                return false
            }
            return stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == folded
        }
        return candidates.min { lhs, rhs in
            if lhs.state != rhs.state {
                return lhs.state == .active
            }
            return lhs.id < rhs.id
        }
    }
}
