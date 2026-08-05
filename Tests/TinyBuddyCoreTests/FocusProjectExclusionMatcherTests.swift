import XCTest
@testable import TinyBuddyCore

// MARK: - Local helpers (reuse the shared FakeClock / MemoryStore from
// FocusSessionEngineTests.swift; only declare what is file-local here.)

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000) // arbitrary reference

/// Minimal in-memory registry backing so the move/rename and worktree cases can
/// exercise the same `resolve → aliases → exists → matcher` gate the app builds.
private final class InMemoryProjectRegistryStore: TinyBuddyProjectRegistryPersisting, @unchecked Sendable {
    var snapshot: TinyBuddyProjectRegistrySnapshot?

    func load() -> TinyBuddyProjectRegistrySnapshot? { snapshot }
    @discardableResult
    func save(_ snapshot: TinyBuddyProjectRegistrySnapshot) -> Bool {
        self.snapshot = snapshot
        return true
    }
}

private func makeRegistry(
    aliases: Set<String>,
    fingerprint: String = "git-roots:abc123"
) -> TinyBuddyProjectRegistry {
    let project = TinyBuddyProject(
        kind: .gitRepository,
        displayName: "Repo",
        repositoryFingerprint: fingerprint,
        aliases: aliases,
        state: .active
    )
    let store = InMemoryProjectRegistryStore()
    store.snapshot = TinyBuddyProjectRegistrySnapshot(projects: [project])
    return TinyBuddyProjectRegistry(store: store)
}

private func exclusionsDayIdentifier(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func makeExclusionEngine(
    clock: FakeClock,
    store: MemoryStore
) -> FocusSessionEngine {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return FocusSessionEngine(
        clock: clock,
        persisting: store,
        config: FocusSessionConfiguration(
            idleThreshold: 120,
            briefInterruptionThreshold: 60,
            longAbsenceThreshold: 600,
            maxSessionSpan: nil,
            dayBoundaryTolerance: 1
        ),
        dayIdentifier: { exclusionsDayIdentifier(for: $0) },
        nextDayBoundary: { date in
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        }
    )
}

// MARK: - Matcher (pure)

final class FocusProjectExclusionMatcherTests: XCTestCase {
    func testSingleSegmentRuleMatchesAnyPathComponentAtAnyDepth() {
        XCTAssertTrue(FocusProjectExclusionMatcher.patternMatches(
            "build", canonicalPath: "/Users/x/proj/build"))
        XCTAssertTrue(FocusProjectExclusionMatcher.patternMatches(
            "build", canonicalPath: "/Users/x/proj/build/sub"))
        XCTAssertFalse(FocusProjectExclusionMatcher.patternMatches(
            "build", canonicalPath: "/Users/x/proj/builder"))
        XCTAssertFalse(FocusProjectExclusionMatcher.patternMatches(
            "build", canonicalPath: "/Users/x/proj"))
    }

    func testMultiSegmentRuleExcludesNestedRepositories() {
        let pattern = "work/archive"
        XCTAssertTrue(FocusProjectExclusionMatcher.patternMatches(
            pattern, canonicalPath: "/Users/me/work/archive"))
        // A nested repository inside the excluded subtree is also excluded.
        XCTAssertTrue(FocusProjectExclusionMatcher.patternMatches(
            pattern, canonicalPath: "/Users/me/work/archive/nested"))
        XCTAssertFalse(FocusProjectExclusionMatcher.patternMatches(
            pattern, canonicalPath: "/Users/me/work"))
        XCTAssertFalse(FocusProjectExclusionMatcher.patternMatches(
            pattern, canonicalPath: "/Users/me/work/archived"))
    }

    func testCaseInsensitiveMatchingOnDefaultMacOSVolume() {
        // macOS volumes are case-insensitive by default; a rule typed in either
        // case must cover a path whose case differs.
        XCTAssertTrue(FocusProjectExclusionMatcher.patternMatches(
            "MyRepos/legacy", canonicalPath: "/Users/me/myREPOS/LEGACY"))
        XCTAssertTrue(FocusProjectExclusionMatcher.patternMatches(
            "legacy", canonicalPath: "/Users/me/MyRepos/LEGACY"))
    }

    func testTrailingSlashNormalization() {
        XCTAssertTrue(FocusProjectExclusionMatcher.patternMatches(
            "a/b", canonicalPath: "/root/a/b/"))
        XCTAssertTrue(FocusProjectExclusionMatcher.patternMatches(
            "build", canonicalPath: "/root/build/"))
    }

    func testIsExcludedAnyOfSeveralRules() {
        XCTAssertTrue(FocusProjectExclusionMatcher.isExcluded(
            canonicalPaths: ["/Users/me/a"],
            patterns: ["b", "me/a"]
        ))
        XCTAssertFalse(FocusProjectExclusionMatcher.isExcluded(
            canonicalPaths: ["/Users/me/a"],
            patterns: ["b", "me/c"]
        ))
        XCTAssertFalse(FocusProjectExclusionMatcher.isExcluded(
            canonicalPaths: ["/Users/me/a"],
            patterns: []
        ))
    }

    func testInvalidPatternNeverMatches() {
        XCTAssertFalse(FocusProjectExclusionMatcher.patternMatches(
            "", canonicalPath: "/root/a"))
        XCTAssertFalse(FocusProjectExclusionMatcher.patternMatches(
            "../etc", canonicalPath: "/root/etc"))
    }
}

// MARK: - Coordinator + exclusion gate (real-time attribution)

extension FocusProjectExclusionMatcherTests {
    @MainActor
    func testExclusionGateRealTimeOnGitAttribution() {
        let clock = FakeClock(t0)
        let store = MemoryStore()
        let engine = makeExclusionEngine(clock: clock, store: store)

        // Exclusion rule for the repo's canonical path.
        var exclusions: [String] = []
        let coordinator = FocusSessionCoordinator(
            engine: engine,
            policy: FocusAttributionPolicy(gitAttributionWindow: nil),
            clock: clock,
            exclusionGate: { context in
                // context.key is the repo alias path in this test.
                return FocusProjectExclusionMatcher.isExcluded(
                    canonicalPaths: [context.key],
                    patterns: exclusions
                )
            }
        )

        coordinator.reportForegroundApp(
            bundleID: "com.apple.dt.Xcode", displayName: "Xcode", isCodeEditor: true)

        // With the rule absent, non-automated git in the repo starts an
        // automatic session.
        exclusions = []
        coordinator.reportGitActivity(repoKey: "/Users/me/work/repoA", displayName: "A", automated: false)
        XCTAssertNotNil(coordinator.currentFocusProject())
        XCTAssertEqual(engine.allSessions.count, 1)

        // A brand-new coordinator state with the SAME event sequence but the
        // rule already present must NOT start a session — the rule takes effect
        // on the first attribution event, not the next scan.
        let clock2 = FakeClock(t0)
        let store2 = MemoryStore()
        let engine2 = makeExclusionEngine(clock: clock2, store: store2)
        exclusions = ["work/repoA"]
        let coordinator2 = FocusSessionCoordinator(
            engine: engine2,
            policy: FocusAttributionPolicy(gitAttributionWindow: nil),
            clock: clock2,
            exclusionGate: { context in
                FocusProjectExclusionMatcher.isExcluded(
                    canonicalPaths: [context.key], patterns: exclusions)
            }
        )
        coordinator2.reportForegroundApp(
            bundleID: "com.apple.dt.Xcode", displayName: "Xcode", isCodeEditor: true)
        coordinator2.reportGitActivity(repoKey: "/Users/me/work/repoA", displayName: "A", automated: false)
        XCTAssertNil(coordinator2.currentFocusProject(),
                     "an excluded repo must not start an automatic session")
        XCTAssertEqual(engine2.allSessions.count, 0)

        // Removing the rule restores attribution immediately — the very next
        // event for the same repo starts a session.
        exclusions = []
        coordinator2.reportGitActivity(repoKey: "/Users/me/work/repoA", displayName: "A", automated: false)
        XCTAssertNotNil(coordinator2.currentFocusProject(),
                        "removing the rule must restore automatic focus immediately")
        XCTAssertEqual(engine2.allSessions.count, 1)
    }

    @MainActor
    func testExclusionGateDoesNotAffectForegroundAppContexts() {
        let clock = FakeClock(t0)
        let store = MemoryStore()
        let engine = makeExclusionEngine(clock: clock, store: store)
        let coordinator = FocusSessionCoordinator(
            engine: engine,
            policy: FocusAttributionPolicy(gitAttributionWindow: nil),
            clock: clock,
            // A rule targeting a path component must never filter a bundle-ID
            // context, which has no canonical path.
            exclusionGate: { context in
                FocusProjectExclusionMatcher.isExcluded(
                    canonicalPaths: [context.key],
                    patterns: ["blocked"]
                )
            }
        )

        coordinator.reportForegroundApp(
            bundleID: "com.apple.Notes", displayName: "Notes", isCodeEditor: false)
        coordinator.reportUserInput()
        // "com.apple.Notes" has no "blocked" path component, so it passes.
        XCTAssertEqual(coordinator.currentFocusProject()?.key, "com.apple.Notes")
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions.first?.project.key, "com.apple.Notes")
    }
}

// MARK: - Session invariants on rule change

extension FocusProjectExclusionMatcherTests {
    @MainActor
    func testMoveRestoresAndWorktreeSharesCanonicalAlias() {
        // The app builds this gate in FocusSessionAppBridge.createStandard:
        // resolve the context key to a project, keep only canonical aliases
        // that still exist on disk, then match the live rules.
        func makeGate(
            registry: TinyBuddyProjectRegistry,
            exists: @escaping (String) -> Bool,
            patterns: @escaping () -> [String]
        ) -> @MainActor (FocusProjectContext) -> Bool {
            { context in
                guard let project = registry.resolve(projectKey: context.key) else { return false }
                return FocusProjectExclusionMatcher.isExcluded(
                    canonicalPaths: Array(project.aliases).filter(exists),
                    patterns: patterns()
                )
            }
        }

        // -- Move/rename: the old excluded path no longer exists, so the repo
        // is NOT excluded at its current location and automatic focus restores.
        let moved = makeRegistry(aliases: ["/old/path/work/repoA", "/Users/me/prj/repoA"])
        let movedGate = makeGate(registry: moved, exists: { $0 == "/Users/me/prj/repoA" },
                                 patterns: { ["work/repoA"] })
        XCTAssertFalse(movedGate(FocusProjectContext(key: "/Users/me/prj/repoA", displayName: "Repo")))

        // While it lived under the excluded subtree, it WAS excluded.
        let atOld = makeGate(registry: moved, exists: { $0 == "/old/path/work/repoA" },
                             patterns: { ["work/repoA"] })
        XCTAssertTrue(atOld(FocusProjectContext(key: "/old/path/work/repoA", displayName: "Repo")))

        // -- Worktree: a linked worktree shares the repository's canonical
        // common-dir alias, so excluding the repo excludes the worktree too.
        let worktree = makeRegistry(aliases: ["/Users/me/work/repoRoot", "/Users/me/work/repoRoot-worktree"])
        let worktreeGate = makeGate(registry: worktree, exists: { _ in true },
                                    patterns: { ["work/repoRoot"] })
        // If the scanner records the worktree's own path as an alias, that
        // path also lives under the excluded root, so it is covered either way.
        XCTAssertTrue(worktreeGate(FocusProjectContext(key: "/Users/me/work/repoRoot", displayName: "Repo")))

        // A project with no surviving alias (e.g. an excluded-only old path
        // after a move) is treated as not excluded — stale identity must not
        // keep it out of automatic focus.
        let staleOnly = makeRegistry(aliases: ["/old/path/work/repoA"])
        let staleGate = makeGate(registry: staleOnly, exists: { _ in false },
                                 patterns: { ["work/repoA"] })
        XCTAssertFalse(staleGate(FocusProjectContext(key: "/old/path/work/repoA", displayName: "Repo")))
    }
}

// MARK: - Session invariants on rule change

extension FocusProjectExclusionMatcherTests {
    @MainActor
    func testRuleChangeDoesNotTruncateDuplicateOrMisattributeExistingSession() {
        let clock = FakeClock(t0)
        let store = MemoryStore()
        let engine = makeExclusionEngine(clock: clock, store: store)
        let project = FocusProjectContext(key: "/Users/me/work/repoA", displayName: "A")

        // Establish an automatic session in repoA.
        engine.userActivity(in: project, at: clock.now)
        clock.advance(by: 90)
        engine.userActivity(in: project, at: clock.now)
        XCTAssertEqual(engine.allSessions.count, 1)

        // Simulate a live rule switch (exclude on) without touching the engine.
        var exclusions = ["work/repoA"]
        let coordinator = FocusSessionCoordinator(
            engine: engine,
            policy: FocusAttributionPolicy(gitAttributionWindow: nil),
            clock: clock,
            exclusionGate: { context in
                FocusProjectExclusionMatcher.isExcluded(
                    canonicalPaths: [context.key], patterns: exclusions)
            }
        )
        coordinator.reportForegroundApp(
            bundleID: "com.apple.dt.Xcode", displayName: "Xcode", isCodeEditor: true)

        // User keeps typing in repoA; it is now excluded → un-attributable input.
        clock.advance(by: 30)
        exclusions = [] // freeze: still excluded for this event
        coordinator.reportGitActivity(repoKey: project.key, displayName: "A", automated: false)
        // The existing automatic session is untouched — still one session, still repoA.
        XCTAssertEqual(engine.allSessions.count, 1)
        XCTAssertEqual(engine.allSessions.first?.project.key, project.key)
        XCTAssertTrue(engine.allSessions.first?.activeDuration(now: clock.now) ?? 0 > 0,
                      "exclusion must not truncate the existing session's elapsed time")

        // Re-include and confirm a new project can start a fresh session.
        exclusions = []
        coordinator.reportForegroundApp(
            bundleID: "com.apple.TextEdit", displayName: "TextEdit", isCodeEditor: false)
        let other = FocusProjectContext(key: "com.apple.TextEdit", displayName: "TextEdit")
        engine.userActivity(in: other, at: clock.now)
        XCTAssertEqual(engine.allSessions.count, 2, "a re-included/relevant project starts its own session")
    }
}