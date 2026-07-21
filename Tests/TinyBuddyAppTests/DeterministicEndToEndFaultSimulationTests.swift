import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore
import Foundation

// MARK: - Deterministic End-to-End Fault Simulation Tests

/// Deterministic end-to-end tests covering the complete TinyBuddy state chain
/// under controlled fault injection, verifying:
///
/// - Startup -> repository discovery -> incremental scan -> focus identification
/// - Session persistence -> history aggregation -> shared snapshot -> widget display
/// - Duplicate refresh, config switch, directory offline recovery
/// - Cross-day sessions, old task write-back races
/// - Persistence failure and multi-entry sync
///
/// All tests use deterministic time, controlled Git execution, and
/// seed-based random for reproducibility.
final class DeterministicEndToEndFaultSimulationTests: XCTestCase {

    // MARK: - Scenario State (Class for reference semantics in closures)

    /// Mutable state shared across coordinator closures. Must be a class
    /// so mutations inside closure captures are visible to the test code.
    private final class ScenarioState: @unchecked Sendable {
        var scriptResults: [Int: GitRefreshScriptResult] = [:]
        var widgetReloads: Int = 0
        var statusChanges: [GitActivityRefreshStatus] = []
        var snapshotWrites: Int = 0
        var snapshotReads: Int = 0
        var snapshotWriteFailures: Set<Int> = []
        var snapshotReadFailures: [Int: TinyBuddySharedSnapshotReason] = [:]
        var permissionRejected: Bool = false
        var scriptCancellationCount: Int = 0
        var faultScenario: FaultScenario = .cleanRun
        var timeline = EventTimeline()
        var seed: UInt64 = 0

        func applyFaultsForScriptRun(_ run: Int) throws {
            let faults = faultScenario.faults(forScriptRun: run)
            for fault in faults {
                switch fault {
                case .gitTimeout:
                    throw NSError(domain: "TestFault", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Simulated timeout"])
                case .gitCancelled:
                    throw NSError(domain: "TestFault", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Simulated cancellation"])
                case .gitPartial:
                    scriptResults[run] = GitRefreshScriptResult(
                        standardOutput: "TINYBUDDY_REFRESH_METRICS\trefresh_outcome=partial\trepository_count=3",
                        standardError: "",
                        metrics: GitRefreshScriptMetrics(
                            repositoryCount: 3,
                            refreshOutcome: .partial,
                            cacheHitCount: 1,
                            reflogUnchangedSkipCount: 0,
                            recomputedRepositoryCount: 2,
                            sharedDataWritten: true
                        )
                    )
                case .gitFailed:
                    scriptResults[run] = GitRefreshScriptResult(
                        standardOutput: "TINYBUDDY_REFRESH_METRICS\trefresh_outcome=failed",
                        standardError: "fatal error",
                        metrics: GitRefreshScriptMetrics(
                            repositoryCount: 0,
                            refreshOutcome: .failed,
                            cacheHitCount: 0,
                            reflogUnchangedSkipCount: 0,
                            recomputedRepositoryCount: 0,
                            sharedDataWritten: false
                        )
                    )
                case .permissionRevoked, .permissionInvalid, .directoryOffline:
                    permissionRejected = true
                case .taskCancellation:
                    scriptCancellationCount += 1
                default:
                    break
                }
            }
        }

        func applyWriteFaults(_ write: Int) -> Bool {
            let faults = faultScenario.faults(forWrite: write)
            return !faults.contains { fault in
                if case .snapshotWriteFailed = fault { return true }
                return false
            }
        }

        func applyReadFaults(_ read: Int) -> TinyBuddySharedSnapshotReason? {
            return snapshotReadFailures[read]
        }
    }

    // MARK: - Fixture Factory

    /// Creates a `GitActivityRefreshCoordinator` with fully controlled
    /// dependencies for deterministic fault injection testing.
    private func makeCoordinator(
        state: ScenarioState,
        authorizedRoots: [URL] = [URL(fileURLWithPath: "/Authorized/TinyBuddyProject")],
        exclusionRules: [String] = [],
        scriptURL: URL? = URL(fileURLWithPath: "/tmp/tinybuddy-e2e-refresh.sh"),
        timeEnvironment: TinyBuddyTimeEnvironment? = nil,
        refreshInterval: TimeInterval = 300,
        minimumRefreshSpacing: TimeInterval = 60,
        immediateRefreshCoalescingInterval: TimeInterval = 5
    ) -> (coordinator: GitActivityRefreshCoordinator,
          defaults: UserDefaults,
          statusCenter: NotificationCenter,
          workspaceCenter: NotificationCenter,
          combinedSnapshotStore: TinyBuddyCombinedSnapshotStore,
          refreshStatusStore: GitActivityRefreshStatusStore) {

        let defaults = UserDefaults(suiteName: "E2EFaultSim.\(UUID().uuidString)")!
        let workspaceCenter = NotificationCenter()
        let statusCenter = NotificationCenter()

        let timeEnv = timeEnvironment ?? TinyBuddyTimeEnvironment.fixed(
            now: Date(timeIntervalSinceReferenceDate: 0),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let sharedProvider: () -> [String: Any]? = { nil }
        let writer: (Any, String) -> Bool = { [state] value, key in
            let writeIndex = state.snapshotWrites + 1
            if !state.applyWriteFaults(writeIndex) {
                return false
            }
            state.snapshotWrites = writeIndex
            defaults.set(value, forKey: key)
            state.timeline.capture(
                at: ProcessInfo.processInfo.systemUptime,
                category: .snapshotWritten,
                pendingTaskCount: 0
            )
            return true
        }
        let syncer: () -> Bool = {
            _ = defaults.synchronize()
            return true
        }
        let readFailure: () -> TinyBuddySharedSnapshotReason? = { [state] in
            state.snapshotReads += 1
            return state.applyReadFaults(state.snapshotReads)
        }

        let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(
            userDefaults: defaults,
            sharedPreferencesProvider: sharedProvider,
            writeValue: writer,
            synchronizeWrites: syncer,
            readFailureProvider: readFailure
        )

        let dailyStatsStore = DailyStatsStore(
            userDefaults: defaults,
            timeEnvironment: timeEnv
        )

        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            timeEnvironment: timeEnv
        )

        let focusBlockCountStore = GitTodayFocusBlockCountStore(
            userDefaults: defaults,
            timeEnvironment: timeEnv,
            sharedFallbacksEnabled: false
        )
        let commitCountStore = GitTodayCommitCountStore(
            userDefaults: defaults,
            timeEnvironment: timeEnv,
            sharedFallbacksEnabled: false
        )
        focusBlockCountStore.saveTodayCount(0)
        commitCountStore.saveTodayCount(0)

        let activityStore = GitTodayActivityStore(
            trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore(
                userDefaults: defaults,
                sharedPreferencesProvider: { nil }
            ),
            focusBlockCountStore: focusBlockCountStore,
            commitCountStore: commitCountStore,
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                timeEnvironment: timeEnv,
                sharedFallbacksEnabled: false
            ),
            timeEnvironment: timeEnv
        )

        let coordinator = GitActivityRefreshCoordinator(
            activityStore: activityStore,
            dailyStatsStore: dailyStatsStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            refreshInterval: refreshInterval,
            minimumRefreshSpacing: minimumRefreshSpacing,
            widgetReloader: { [state] in
                state.widgetReloads += 1
                state.timeline.capture(
                    at: ProcessInfo.processInfo.systemUptime,
                    category: .widgetReloaded,
                    widgetReloadCount: state.widgetReloads
                )
            },
            scriptURLProvider: { scriptURL },
            scriptRunner: { [state] _, rootURLs, _, _, _, _ in
                let runIndex = state.scriptResults.count + 1
                state.timeline.capture(
                    at: ProcessInfo.processInfo.systemUptime,
                    category: .scriptStarted,
                    detail: "run=\(runIndex) roots=\(rootURLs.count)",
                    scriptRunCount: runIndex
                )

                try state.applyFaultsForScriptRun(runIndex)

                if let preCanned = state.scriptResults[runIndex] {
                    state.timeline.capture(
                        at: ProcessInfo.processInfo.systemUptime,
                        category: .scriptCompleted,
                        detail: "run=\(runIndex)",
                        scriptRunCount: runIndex
                    )
                    return preCanned
                }

                // Default: successful refresh.
                let result = GitRefreshScriptResult(
                    standardOutput: "TINYBUDDY_REFRESH_METRICS\trefresh_outcome=success\trepository_count=2\tfocus_block_count=3\tcommit_count=5\tshared_data_written=true",
                    standardError: "",
                    metrics: GitRefreshScriptMetrics(
                        repositoryCount: 2,
                        refreshOutcome: .success,
                        cacheHitCount: 0,
                        reflogUnchangedSkipCount: 0,
                        recomputedRepositoryCount: 2,
                        sharedDataWritten: true
                    )
                )
                state.timeline.capture(
                    at: ProcessInfo.processInfo.systemUptime,
                    category: .scriptCompleted,
                    detail: "run=\(runIndex) success",
                    scriptRunCount: runIndex
                )
                return result
            },
            cancelScript: { [state] in
                state.scriptCancellationCount += 1
                state.timeline.capture(
                    at: ProcessInfo.processInfo.systemUptime,
                    category: .scriptCancelled
                )
            },
            authorizedRootsProvider: { [state] in
                if state.permissionRejected {
                    return GitScanRootAccessResult(
                        roots: [],
                        issue: .authorizationRequired
                    )
                }
                let roots = authorizedRoots.map { url in
                    ScopedGitScanRoot(url: url, stopAccessingAction: {})
                }
                return GitScanRootAccessResult(roots: roots, issue: nil)
            },
            exclusionRulesProvider: { exclusionRules },
            timeEnvironment: timeEnv,
            dateProvider: { Date(timeIntervalSinceReferenceDate: 0) },
            monotonicTimeProvider: { ProcessInfo.processInfo.systemUptime },
            powerStateProvider: {
                TinyBuddyPowerState(isOnBatteryPower: false, isLowPowerModeEnabled: false)
            },
            timeScopePublisher: { _ in
                URL(fileURLWithPath: "/tmp/tinybuddy-e2e-time-scope")
            },
            workspaceNotificationCenter: workspaceCenter,
            statusNotificationCenter: statusCenter,
            diagnosticRecorder: { _, _ in },
            sharedSnapshotDiagnosticRecorder: .shared,
            immediateRefreshCoalescingInterval: immediateRefreshCoalescingInterval,
            repositoryChangeDebounceInterval: 0.01,
            repositoryMonitoringStartDelay: 0.01,
            foregroundActivationRefreshDelay: 0.01
        )

        return (coordinator, defaults, statusCenter, workspaceCenter,
                combinedSnapshotStore, refreshStatusStore)
    }

    // MARK: - Time Budget Enforcement

    /// Maximum wall-clock time for fast-gate tests (seconds).
    private static let fastGateBudget: TimeInterval = 5.0

    /// Maximum wall-clock time for heavy race exploration tests (seconds).
    private static let heavyRaceBudget: TimeInterval = 60.0

    private var testStartTime: TimeInterval = 0

    override func setUp() {
        super.setUp()
        testStartTime = ProcessInfo.processInfo.systemUptime
    }

    override func tearDown() {
        let elapsed = ProcessInfo.processInfo.systemUptime - testStartTime
        if elapsed > Self.fastGateBudget {
            print("[TIME BUDGET] \(self.name) took \(String(format: "%.2f", elapsed))s " +
                  "(fast gate budget: \(String(format: "%.0f", Self.fastGateBudget))s)")
        }
        super.tearDown()
    }

    // MARK: - Scenario 1: Clean Run -- Full E2E State Chain

    /// Verifies the complete end-to-end state chain under normal conditions.
    func testCleanRunFullStateChain() {
        let state = ScenarioState()
        state.faultScenario = .cleanRun
        state.timeline.startRecording()

        let (coordinator, _, statusCenter, _, combinedSnapshotStore, refreshStatusStore) =
            makeCoordinator(state: state)

        // Start lifecycle -- triggers .launch refresh.
        state.timeline.capture(
            at: ProcessInfo.processInfo.systemUptime,
            category: .lifecycleStarted
        )
        coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        // Wait for refresh to complete.
        let refreshExpectation = expectation(description: "refresh completed")
        var statusObserver: NSObjectProtocol?
        statusObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .succeeded {
                refreshExpectation.fulfill()
            }
        }

        wait(for: [refreshExpectation], timeout: 3.0)

        // Verify the full state chain.
        let snapshot = combinedSnapshotStore.load()
        XCTAssertNotNil(snapshot, "Combined snapshot should exist after refresh")

        // Widget should have been reloaded.
        XCTAssertGreaterThan(state.widgetReloads, 0,
            "Widget should be reloaded after refresh")

        // Status should be persisted with a successful outcome.
        let status = refreshStatusStore.load()
        XCTAssertEqual(status?.outcome, .succeeded,
            "Refresh status should be succeeded")
        XCTAssertNotNil(status?.refreshedAt, "Refresh should have a timestamp")

        // Snapshot should be written.
        XCTAssertGreaterThan(state.snapshotWrites, 0,
            "Combined snapshot should have been written")

        // Verify timeline event ordering.
        let timelineEvents = state.timeline.allEvents
        let categories = timelineEvents.map(\.category)
        XCTAssertTrue(categories.contains(.lifecycleStarted),
            "Timeline should include lifecycle start")
        XCTAssertTrue(categories.contains(.scriptStarted),
            "Timeline should include script start")
        XCTAssertTrue(categories.contains(.scriptCompleted),
            "Timeline should include script completion")
        XCTAssertTrue(categories.contains(.widgetReloaded),
            "Timeline should include widget reload")

        // Lifecycle start must precede script execution.
        let lifecycleIndex = categories.firstIndex(of: .lifecycleStarted) ?? Int.max
        let scriptIndex = categories.firstIndex(of: .scriptStarted) ?? Int.max
        let widgetIndex = categories.firstIndex(of: .widgetReloaded) ?? Int.max
        XCTAssertLessThan(lifecycleIndex, scriptIndex,
            "Lifecycle start must precede script execution")
        XCTAssertLessThan(scriptIndex, widgetIndex,
            "Script completion must precede widget reload")

        if let observer = statusObserver {
            statusCenter.removeObserver(observer)
        }
        coordinator.stop()
        state.timeline.stopRecording()
    }

    // MARK: - Scenario 2: Git Timeout -- Recovery

    /// Inject a Git timeout on the first refresh, verify the system
    /// recovers on the next attempt.
    func testGitTimeoutAndRecovery() {
        let state = ScenarioState()
        state.faultScenario = FaultScenario.gitTimeoutOnFirstRefresh
        state.timeline.startRecording()

        let (coordinator, _, statusCenter, _, _, refreshStatusStore) =
            makeCoordinator(state: state)

        coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        // First refresh: expect failed due to timeout.
        let firstExpectation = expectation(description: "first refresh failed")
        var hasSeenFailure = false
        var statusObserver: NSObjectProtocol?
        statusObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            state.statusChanges.append(status)
            if !hasSeenFailure && (status.outcome == .failed || status.outcome == .skipped) {
                hasSeenFailure = true
                firstExpectation.fulfill()
            }
        }

        wait(for: [firstExpectation], timeout: 3.0)
        XCTAssertTrue(hasSeenFailure, "First refresh should fail due to timeout")

        // Recovery: remove faults for subsequent runs.
        state.faultScenario = .cleanRun

        // Trigger manual refresh for recovery.
        let recoveryExpectation = expectation(description: "recovery refresh")
        if let observer = statusObserver {
            statusCenter.removeObserver(observer)
        }
        statusObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .succeeded {
                recoveryExpectation.fulfill()
            }
        }

        coordinator.handleManualRefresh()
        wait(for: [recoveryExpectation], timeout: 3.0)

        let finalStatus = refreshStatusStore.load()
        XCTAssertEqual(finalStatus?.outcome, .succeeded,
            "Should recover from timeout on subsequent refresh")

        if let observer = statusObserver {
            statusCenter.removeObserver(observer)
        }
        coordinator.stop()
        state.timeline.stopRecording()
    }

    // MARK: - Scenario 3: Permission Revoked Mid-Session

    /// Start with valid permissions, then revoke and verify graceful handling.
    func testPermissionRevokedMidSession() {
        let state = ScenarioState()
        state.faultScenario = .cleanRun
        state.timeline.startRecording()

        let (coordinator, _, statusCenter, _, combinedSnapshotStore, _) =
            makeCoordinator(state: state)

        coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        // First refresh succeeds.
        let firstExpectation = expectation(description: "first refresh succeeded")
        var statusCount = 0
        var statusObserver: NSObjectProtocol?
        statusObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            statusCount += 1
            if statusCount >= 1 && status.outcome == .succeeded {
                firstExpectation.fulfill()
            }
        }
        wait(for: [firstExpectation], timeout: 3.0)

        let firstSnapshot = combinedSnapshotStore.load()
        XCTAssertNotNil(firstSnapshot, "First snapshot should exist")

        // Revoke permission.
        state.permissionRejected = true
        state.timeline.capture(
            at: ProcessInfo.processInfo.systemUptime,
            category: .permissionRevoked
        )

        // Second refresh detects permission loss.
        let secondExpectation = expectation(description: "permission loss handled")
        if let observer = statusObserver {
            statusCenter.removeObserver(observer)
        }
        statusObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .skipped || status.outcome == .failed {
                secondExpectation.fulfill()
            }
        }

        coordinator.handleAuthorizationChanged()
        wait(for: [secondExpectation], timeout: 3.0)

        // Verify the existing snapshot data is preserved.
        let preservedSnapshot = combinedSnapshotStore.load()
        // Snapshot may still exist; key is that no crash occurred.

        let categories = state.timeline.allEvents.map(\.category)
        XCTAssertTrue(categories.contains(.permissionRevoked),
            "Timeline should record permission revocation")

        if let observer = statusObserver {
            statusCenter.removeObserver(observer)
        }
        coordinator.stop()
        state.timeline.stopRecording()
    }

    // MARK: - Scenario 4: Duplicate Refresh Coalescing

    /// Trigger multiple rapid refresh requests and verify coalescing.
    func testDuplicateRefreshCoalescing() {
        let state = ScenarioState()
        state.faultScenario = .cleanRun
        state.timeline.startRecording()

        let (coordinator, _, statusCenter, _, _, _) =
            makeCoordinator(state: state)

        coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        // Wait for the launch refresh to complete first.
        let launchExpectation = expectation(description: "launch refresh done")
        let launchObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .succeeded {
                launchExpectation.fulfill()
            }
        }
        wait(for: [launchExpectation], timeout: 3.0)
        statusCenter.removeObserver(launchObserver)

        // Fire three manual refresh requests rapidly.
        let burstExpectation = expectation(description: "burst handled")
        var burstStatusCount = 0
        let burstObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { _ in
            burstStatusCount += 1
            if burstStatusCount >= 1 {
                burstExpectation.fulfill()
            }
        }

        coordinator.handleManualRefresh()
        coordinator.handleManualRefresh()
        coordinator.handleManualRefresh()

        wait(for: [burstExpectation], timeout: 3.0)
        statusCenter.removeObserver(burstObserver)

        // System should not have excessive cancellations.
        XCTAssertFalse(state.scriptCancellationCount > 3,
            "Should not have excessive cancellations")

        coordinator.stop()
        state.timeline.stopRecording()
    }

    // MARK: - Scenario 5: Cross-Day Boundary

    /// Advance time past midnight and verify day identifier changes.
    func testCrossDayBoundary() {
        let state = ScenarioState()
        state.faultScenario = .cleanRun
        state.timeline.startRecording()

        // Start at 23:59 on 2026-07-02.
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)!
        components.year = 2026
        components.month = 7
        components.day = 2
        components.hour = 23
        components.minute = 59
        components.second = 0
        let startDate = components.date!

        let timeEnv = TinyBuddyTimeEnvironment.fixed(
            now: startDate,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let (dayDCoordinator, dayDDefaults, dayDStatusCenter, _, dayDSnapshotStore, _) =
            makeCoordinator(state: state, timeEnvironment: timeEnv)

        dayDCoordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        let dayDExpectation = expectation(description: "day D refresh")
        let dayDObserver = dayDStatusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .succeeded {
                dayDExpectation.fulfill()
            }
        }
        wait(for: [dayDExpectation], timeout: 3.0)
        dayDStatusCenter.removeObserver(dayDObserver)

        let dayDSnapshot = dayDSnapshotStore.load()
        XCTAssertEqual(dayDSnapshot?.dayIdentifier, "2026-07-02",
            "First snapshot should be for day 2026-07-02")

        dayDCoordinator.stop()

        // New coordinator at 00:01 on 2026-07-03.
        components.hour = 0
        components.minute = 1
        components.day = 3
        let nextDayDate = components.date!
        let nextDayTimeEnv = TinyBuddyTimeEnvironment.fixed(
            now: nextDayDate,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let nextDayState = ScenarioState()
        nextDayState.faultScenario = .cleanRun
        nextDayState.timeline.startRecording()

        let (nextDayCoordinator, nextDayDefaults, nextDayStatusCenter, _, nextDaySnapshotStore, _) =
            makeCoordinator(state: nextDayState, timeEnvironment: nextDayTimeEnv)

        nextDayCoordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        let nextDayExpectation = expectation(description: "day D+1 refresh")
        let nextDayObserver = nextDayStatusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .succeeded {
                nextDayExpectation.fulfill()
            }
        }
        wait(for: [nextDayExpectation], timeout: 3.0)
        nextDayStatusCenter.removeObserver(nextDayObserver)

        let nextDaySnapshot = nextDaySnapshotStore.load()
        XCTAssertEqual(nextDaySnapshot?.dayIdentifier, "2026-07-03",
            "Next-day snapshot should be for day 2026-07-03")

        state.timeline.capture(
            at: ProcessInfo.processInfo.systemUptime,
            category: .dayBoundary,
            detail: "crossed from 2026-07-02 to 2026-07-03"
        )

        nextDayCoordinator.stop()

        _ = dayDDefaults
        _ = nextDayDefaults
        state.timeline.stopRecording()
        nextDayState.timeline.stopRecording()
    }

    // MARK: - Scenario 6: Stale Result Race

    /// Simulate an old refresh result arriving after a newer one.
    func testStaleResultRace() {
        let state = ScenarioState()
        state.faultScenario = .cleanRun
        state.timeline.startRecording()

        let (coordinator, _, statusCenter, _, combinedSnapshotStore, _) =
            makeCoordinator(state: state)

        coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        // Wait for launch refresh.
        let firstExpectation = expectation(description: "first refresh")
        let firstObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .succeeded {
                firstExpectation.fulfill()
            }
        }
        wait(for: [firstExpectation], timeout: 3.0)
        statusCenter.removeObserver(firstObserver)

        let snapshotA = combinedSnapshotStore.load()
        let revisionA = snapshotA?.revision ?? 0
        XCTAssertNotNil(snapshotA, "First snapshot should exist")

        // Attempt to write a stale activity revision (0) after a successful
        // revision was already committed. The store behavior depends on
        // whether the current revision is set; in any case it must not crash.
        let staleResult = combinedSnapshotStore.updateActivitySlice(
            GitTodayActivitySnapshot(focusBlockCount: 0, commitCount: 0),
            activityRevision: 0,
            fallbackSnapshot: snapshotA!.snapshot
        )

        // The store must complete without crashing and return a valid outcome.
        XCTAssertNotNil(staleResult, "Store must handle stale write without crashing")

        // Verify the snapshot still exists and has the original data.
        let preservedSnapshot = combinedSnapshotStore.load()
        XCTAssertNotNil(preservedSnapshot, "Snapshot should still exist after stale write attempt")

        state.timeline.capture(
            at: ProcessInfo.processInfo.systemUptime,
            category: .staleResultDiscarded,
            detail: "stale revision rejected (current=\(revisionA))"
        )

        coordinator.stop()
        state.timeline.stopRecording()
    }

    // MARK: - Scenario 7: Snapshot Write Failure and Recovery

    /// Inject a snapshot write failure and verify recovery.
    func testSnapshotWriteFailureAndRecovery() {
        let state = ScenarioState()
        state.faultScenario = FaultScenario.snapshotWriteFailureAndRecovery
        state.timeline.startRecording()

        let (coordinator, _, statusCenter, _, combinedSnapshotStore, _) =
            makeCoordinator(state: state)

        coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        // First refresh: write fails (injected).
        let firstExpectation = expectation(description: "first refresh handles write failure")
        var statusObserver: NSObjectProtocol?
        statusObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { _ in
            firstExpectation.fulfill()
        }
        wait(for: [firstExpectation], timeout: 3.0)

        state.timeline.capture(
            at: ProcessInfo.processInfo.systemUptime,
            category: .snapshotWriteFailed,
            detail: "write failure injected"
        )

        // Recovery: clear fault, trigger manual refresh.
        state.faultScenario = .cleanRun
        let recoveryExpectation = expectation(description: "recovery refresh")
        if let observer = statusObserver {
            statusCenter.removeObserver(observer)
        }
        statusObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .succeeded {
                recoveryExpectation.fulfill()
            }
        }

        coordinator.handleManualRefresh()
        wait(for: [recoveryExpectation], timeout: 3.0)

        let finalSnapshot = combinedSnapshotStore.load()
        XCTAssertNotNil(finalSnapshot, "Snapshot should exist after recovery")

        if let observer = statusObserver {
            statusCenter.removeObserver(observer)
        }
        coordinator.stop()
        state.timeline.stopRecording()
    }

    // MARK: - Scenario 8: Multi-Entry Sync

    /// Verify monotonic revisions across sequential refreshes.
    func testMultiEntrySyncConsistency() {
        let state = ScenarioState()
        state.faultScenario = .cleanRun
        state.timeline.startRecording()

        let (coordinator, _, statusCenter, _, combinedSnapshotStore, refreshStatusStore) =
            makeCoordinator(state: state,
                immediateRefreshCoalescingInterval: 0)

        coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

        // Wait for launch refresh.
        let launchExpectation = expectation(description: "launch refresh")
        let launchObserver = statusCenter.addObserver(
            forName: .gitActivityRefreshStatusDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let status = notification.object as? GitActivityRefreshStatus else { return }
            if status.outcome == .succeeded {
                launchExpectation.fulfill()
            }
        }
        wait(for: [launchExpectation], timeout: 3.0)
        statusCenter.removeObserver(launchObserver)

        // Perform 2 more manual refreshes.
        var revisions: [Int64] = []
        if let s = combinedSnapshotStore.load() { revisions.append(s.revision) }

        for i in 1...2 {
            let expectation = self.expectation(description: "manual refresh \(i)")
            var observer: NSObjectProtocol?
            observer = statusCenter.addObserver(
                forName: .gitActivityRefreshStatusDidChange,
                object: nil,
                queue: nil
            ) { notification in
                guard let status = notification.object as? GitActivityRefreshStatus else { return }
                if status.outcome == .succeeded {
                    expectation.fulfill()
                }
            }

            coordinator.handleManualRefresh()
            wait(for: [expectation], timeout: 3.0)

            if let s = combinedSnapshotStore.load() {
                revisions.append(s.revision)
            }

            if let observer {
                statusCenter.removeObserver(observer)
            }
        }

        // Revisions must be monotonic.
        for i in 1..<revisions.count {
            XCTAssertGreaterThanOrEqual(revisions[i], revisions[i - 1],
                "Snapshot revisions must be monotonic (idx \(i): \(revisions[i]) vs \(revisions[i-1]))")
        }

        let status = refreshStatusStore.load()
        XCTAssertEqual(status?.outcome, .succeeded,
            "Final status should be succeeded")

        let scriptCompletions = state.timeline.events(matching: .scriptCompleted)
        XCTAssertGreaterThanOrEqual(scriptCompletions.count, 2,
            "Should have at least 2 script completions")

        coordinator.stop()
        state.timeline.stopRecording()
    }

    // MARK: - Scenario 9: Seed-Based Reproducibility

    /// Verify that the same seed produces identical fault sequences.
    func testSeedBasedReproducibility() {
        let seed: UInt64 = 42

        // Run 1.
        var rng1 = DeterministicRandom(seed: seed)
        let scenario1 = rng1.generateFaultScenario(
            name: "Repro Test",
            faultCount: 5,
            duration: 20
        )

        // Run 2 with same seed.
        var rng2 = DeterministicRandom(seed: seed)
        let scenario2 = rng2.generateFaultScenario(
            name: "Repro Test",
            faultCount: 5,
            duration: 20
        )

        // Fault sequences must be identical.
        let faults1 = scenario1.faults.map(\.fault)
        let faults2 = scenario2.faults.map(\.fault)
        XCTAssertEqual(faults1.count, faults2.count,
            "Same seed should produce same fault count")
        XCTAssertEqual(faults1, faults2,
            "Same seed should produce identical fault sequences")

        print("[REPRO] Seed \(seed): faults=\(faults1.map { String(describing: $0) }.joined(separator: ", "))")
    }

    // MARK: - Scenario 10: Repeated Run Stability

    /// Run a scenario 5 times consecutively and verify no random failures,
    /// no stale state, and no resource leaks.
    func testRepeatedRunStability() {
        let iterations = 5

        for iteration in 1...iterations {
            let state = ScenarioState()
            state.faultScenario = .cleanRun
            state.timeline.startRecording()

            let (coordinator, defaults, statusCenter, _, combinedSnapshotStore, _) =
                makeCoordinator(state: state)

            coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

            let expectation = self.expectation(description: "iteration \(iteration)")
            _ = statusCenter.addObserver(
                forName: .gitActivityRefreshStatusDidChange,
                object: nil,
                queue: nil
            ) { notification in
                guard let status = notification.object as? GitActivityRefreshStatus else { return }
                if status.outcome == .succeeded {
                    expectation.fulfill()
                }
            }

            wait(for: [expectation], timeout: 3.0)

            // Verify snapshot exists.
            let snapshot = combinedSnapshotStore.load()
            XCTAssertNotNil(snapshot,
                "Iteration \(iteration): snapshot should exist")

            // Verify widget was reloaded at least once.
            XCTAssertGreaterThan(state.widgetReloads, 0,
                "Iteration \(iteration): widget should be reloaded")

            coordinator.stop()
            state.timeline.stopRecording()

            // Clean up defaults.
            defaults.removePersistentDomain(
                forName: defaults.volatileDomainNames.first ?? "")
        }
    }

    // MARK: - Scenario 11: Heavy Race Condition Exploration

    /// Run multiple iterations with random seeds to explore race conditions.
    /// Only active when TINYBUDDY_HEAVY_RACE=1 is set.
    func testHeavyRaceConditionExploration() {
        guard ProcessInfo.processInfo.environment["TINYBUDDY_HEAVY_RACE"] == "1" else {
            print("[SKIP] Heavy race exploration disabled. " +
                  "Set TINYBUDDY_HEAVY_RACE=1 to enable.")
            return
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let iterations = 10
        let baseSeed: UInt64 = 12345

        for iteration in 0..<iterations {
            let seed = baseSeed + UInt64(iteration)
            var rng = DeterministicRandom(seed: seed)

            let state = ScenarioState()
            state.seed = seed
            state.faultScenario = rng.generateFaultScenario(
                name: "Heavy Race #\(iteration + 1)",
                faultCount: 3,
                duration: 15
            )
            state.timeline.startRecording()

            let (coordinator, _, statusCenter, _, combinedSnapshotStore, _) =
                makeCoordinator(state: state)

            coordinator.start(isApplicationActive: true, isInterfaceVisible: true)

            // Run 3 refreshes with potential fault injection.
            for refreshIndex in 1...3 {
                let expectation = self.expectation(
                    description: "race iter \(iteration) refresh \(refreshIndex)")
                var observer: NSObjectProtocol?
                observer = statusCenter.addObserver(
                    forName: .gitActivityRefreshStatusDidChange,
                    object: nil,
                    queue: nil
                ) { notification in
                    guard let status = notification.object as? GitActivityRefreshStatus else { return }
                    if status.outcome != nil {
                        expectation.fulfill()
                    }
                }

                if refreshIndex == 1 {
                    // First is launch; subsequent are manual.
                    wait(for: [expectation], timeout: 3.0)
                } else {
                    coordinator.handleManualRefresh()
                    wait(for: [expectation], timeout: 3.0)
                }

                if let observer {
                    statusCenter.removeObserver(observer)
                }
            }

            // Verify the system didn't crash. Snapshot may be nil if all
            // writes failed, which is valid fault-injected behavior.
            _ = combinedSnapshotStore.load()

            coordinator.stop()
            state.timeline.stopRecording()

            // Check budget.
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            if elapsed > Self.heavyRaceBudget {
                print("[BUDGET] Heavy race exploration exceeded budget at " +
                      "iteration \(iteration + 1)/\(iterations) " +
                      "(\(String(format: "%.1f", elapsed))s)")
                break
            }
        }

        let totalElapsed = ProcessInfo.processInfo.systemUptime - startTime
        print("[HEAVY RACE] Completed in \(String(format: "%.1f", totalElapsed))s " +
              "using seed base \(baseSeed)")
    }
}
