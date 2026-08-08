import Foundation
import XCTest
@testable import TinyBuddyCore

private final class UpgradeSessionStore: FocusSessionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [FocusSession] = []

    func load() -> [FocusSession]? {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    func save(_ sessions: [FocusSession]) -> Bool {
        lock.lock()
        self.sessions = sessions
        lock.unlock()
        return true
    }
}

private struct UpgradeTestClock: FocusClock {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let monotonic: TimeInterval = 1_000
}

private final class UpgradeCoordinatorReference: @unchecked Sendable {
    var value: FocusSessionUpgradeCoordinator?
}

private final class UpgradeCallbackSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPhases: [FocusSessionUpgradePhase] = []
    private var storedEngineStates: [Bool] = []
    private var storedApplyCount = 0
    private var storedApplyPhases: [FocusSessionUpgradePhase] = []

    var phases: [FocusSessionUpgradePhase] {
        lock.lock()
        defer { lock.unlock() }
        return storedPhases
    }

    var engineStates: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedEngineStates
    }

    var applyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedApplyCount
    }

    var applyPhases: [FocusSessionUpgradePhase] {
        lock.lock()
        defer { lock.unlock() }
        return storedApplyPhases
    }

    func record(phase: FocusSessionUpgradePhase) {
        lock.lock()
        storedPhases.append(phase)
        lock.unlock()
    }

    func record(enginePaused: Bool) {
        lock.lock()
        storedEngineStates.append(enginePaused)
        lock.unlock()
    }

    func recordApply() {
        lock.lock()
        storedApplyCount += 1
        lock.unlock()
    }

    func recordApply(phase: FocusSessionUpgradePhase) {
        lock.lock()
        storedApplyCount += 1
        storedApplyPhases.append(phase)
        lock.unlock()
    }
}

final class FocusSessionUpgradeCoordinatorTests: XCTestCase {
    func testBeginAndRollbackCallbacksCanReenterCoordinatorWithoutDeadlock() throws {
        let registry = makeRegistry()
        let oldRule = rule(major: 2, label: "current-before-preview")
        XCTAssertTrue(registry.registerNewRuleSet(oldRule))

        let coordinator = FocusSessionUpgradeCoordinator(
            registry: registry,
            store: UpgradeSessionStore(),
            clock: UpgradeTestClock()
        )
        coordinator.currentSessionProvider = { (sessions: [], revision: 7) }

        let reference = UpgradeCoordinatorReference()
        reference.value = coordinator
        let spy = UpgradeCallbackSpy()
        coordinator.onPhaseChange = { phase in
            spy.record(phase: phase)
            // This synchronous read used to deadlock because begin/rollback
            // invoked the callback while retaining the coordinator's NSLock.
            _ = reference.value?.currentPhase
        }
        coordinator.setEnginePaused = { spy.record(enginePaused: $0) }

        let preview = coordinator.beginUpgrade(
            newRuleSet: rule(major: 3, label: "preview"),
            scope: scope
        )
        XCTAssertNotNil(preview)
        XCTAssertEqual(spy.phases.count, 2)
        guard case .paused = spy.phases[0], case .previewReady = spy.phases[1] else {
            return XCTFail("expected paused -> previewReady")
        }
        XCTAssertEqual(spy.engineStates, [true])

        XCTAssertTrue(coordinator.rollbackUpgrade())
        guard case .rolledBack = coordinator.currentPhase else {
            return XCTFail("expected rolledBack phase")
        }
        XCTAssertEqual(spy.engineStates, [true, false])
        XCTAssertEqual(
            registry.currentRuleSet,
            oldRule,
            "preview rollback must not restore an unrelated previous rule set"
        )
    }

    func testMissingSessionProviderFailsAndResumesEngineWithoutDeadlock() {
        let coordinator = FocusSessionUpgradeCoordinator(
            registry: makeRegistry(),
            store: UpgradeSessionStore(),
            clock: UpgradeTestClock()
        )
        let reference = UpgradeCoordinatorReference()
        reference.value = coordinator
        let spy = UpgradeCallbackSpy()
        coordinator.onPhaseChange = { phase in
            spy.record(phase: phase)
            _ = reference.value?.currentPhase
        }
        coordinator.setEnginePaused = { spy.record(enginePaused: $0) }

        XCTAssertNil(coordinator.beginUpgrade(
            newRuleSet: rule(major: 2, label: "missing-provider"),
            scope: scope
        ))

        guard case .failed(let reason) = coordinator.currentPhase else {
            return XCTFail("expected failed phase")
        }
        XCTAssertEqual(reason, "currentSessionProvider not configured")
        XCTAssertEqual(spy.engineStates, [true, false])
    }

    func testCancellationFromPausedCallbackDoesNotRePauseEngineOrStageRecovery() {
        let registry = makeRegistry()
        let coordinator = FocusSessionUpgradeCoordinator(
            registry: registry,
            store: UpgradeSessionStore(),
            clock: UpgradeTestClock()
        )
        coordinator.currentSessionProvider = { (sessions: [], revision: 7) }

        let reference = UpgradeCoordinatorReference()
        reference.value = coordinator
        let spy = UpgradeCallbackSpy()
        coordinator.setEnginePaused = { spy.record(enginePaused: $0) }
        coordinator.onPhaseChange = { phase in
            guard case .paused = phase else { return }
            reference.value?.cancelUpgrade()
        }

        XCTAssertNil(coordinator.beginUpgrade(
            newRuleSet: rule(major: 3, label: "cancelled-preview"),
            scope: scope
        ))
        XCTAssertEqual(coordinator.currentPhase, .idle)
        XCTAssertEqual(spy.engineStates, [true, false])
        XCTAssertNil(registry.loadUpgradeState())
    }

    func testCancellationCannotInterruptAtomicApply() {
        let coordinator = FocusSessionUpgradeCoordinator(
            registry: makeRegistry(),
            store: UpgradeSessionStore(),
            clock: UpgradeTestClock()
        )
        coordinator.currentSessionProvider = { (sessions: [], revision: 7) }

        let reference = UpgradeCoordinatorReference()
        reference.value = coordinator
        let spy = UpgradeCallbackSpy()
        coordinator.setEnginePaused = { spy.record(enginePaused: $0) }
        coordinator.onPhaseChange = { phase in
            guard case .upgrading = phase else { return }
            reference.value?.cancelUpgrade()
        }
        coordinator.applySessionsAtomically = { _, _ in
            spy.recordApply(phase: reference.value?.currentPhase ?? .idle)
            return true
        }

        XCTAssertNotNil(coordinator.beginUpgrade(
            newRuleSet: rule(major: 3, label: "atomic-apply"),
            scope: scope
        ))
        XCTAssertNotNil(coordinator.confirmUpgrade())
        XCTAssertEqual(spy.applyCount, 1)
        XCTAssertEqual(spy.applyPhases, [.upgrading])
        XCTAssertEqual(spy.engineStates, [true, false])
        guard case .completed = coordinator.currentPhase else {
            return XCTFail("expected completed phase")
        }
    }

    func testExhaustedArchiveRevisionFailsClosedBeforeApply() throws {
        let coordinator = FocusSessionUpgradeCoordinator(
            registry: makeRegistry(),
            store: UpgradeSessionStore(),
            clock: UpgradeTestClock()
        )
        coordinator.currentSessionProvider = { (sessions: [], revision: Int64.max) }
        let spy = UpgradeCallbackSpy()
        coordinator.setEnginePaused = { spy.record(enginePaused: $0) }
        coordinator.applySessionsAtomically = { _, _ in
            spy.recordApply()
            return true
        }

        XCTAssertNotNil(coordinator.beginUpgrade(
            newRuleSet: rule(major: 2, label: "exhausted"),
            scope: scope
        ))
        XCTAssertNil(coordinator.confirmUpgrade())

        XCTAssertEqual(spy.applyCount, 0)
        XCTAssertEqual(spy.engineStates, [true, false])
        guard case .failed(let reason) = coordinator.currentPhase else {
            return XCTFail("expected failed phase")
        }
        XCTAssertEqual(reason, "Archive revision exhausted")
    }

    private var scope: FocusSessionRecalculationScope {
        FocusSessionRecalculationScope(
            dayStart: "2026-08-01",
            dayEnd: "2026-08-08"
        )
    }

    private func rule(major: Int, label: String) -> FocusSessionRuleSet {
        FocusSessionRuleSet(
            version: FocusSessionRuleVersion(major: major, minor: 0),
            configuration: FocusSessionConfiguration(),
            createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(major)),
            label: label
        )
    }

    private func makeRegistry() -> FocusSessionRuleRegistry {
        let suite = "FocusSessionUpgradeCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return FocusSessionRuleRegistry(userDefaults: defaults)
    }
}
