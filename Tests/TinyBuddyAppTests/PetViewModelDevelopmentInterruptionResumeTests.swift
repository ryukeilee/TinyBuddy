import Foundation
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

private final class ResumeFakeClock: FocusClock, @unchecked Sendable {
    private var _now: Date
    var now: Date { _now }
    var monotonic: TimeInterval { _now.timeIntervalSinceReferenceDate }

    init(_ date: Date) {
        _now = date
    }

    func advance(by seconds: TimeInterval) {
        _now.addTimeInterval(seconds)
    }
}

/// Lightweight non‑persisting session store for deterministic tests.
private final class ResumeMemoryStore: FocusSessionPersisting, @unchecked Sendable {
    private var data: [FocusSession] = []

    init() {
        data = []
    }

    func load() -> [FocusSession]? { data }
    func save(_ sessions: [FocusSession]) -> Bool {
        data = sessions
        return true
    }
}

private func resumeDayIdentifier(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

/// Interaction tests for the one-click “继续专注” card action: exact
/// fingerprint gating, current-state presentation, safe no-op behavior, and
/// no repository-path persistence.
@MainActor
final class PetViewModelDevelopmentInterruptionResumeTests: XCTestCase {
    private let snapshotFingerprint = "FINGER-1"
    private let matchedProject = TinyBuddyProject(
        id: TinyBuddyProjectID(rawValue: "proj-1"),
        kind: .gitRepository,
        displayName: "TinyBuddy",
        repositoryFingerprint: "finger-1",
        aliases: ["/Users/secret/PrivateRepo"],
        state: .active
    )

    // MARK: - Available path

    func testResumeStartsManualSessionKeyedByMatchedProjectID() {
        let harness = makeHarness(projects: [matchedProject])

        XCTAssertEqual(
            harness.viewModel.developmentInterruptionResumeState,
            .available(project: matchedProject)
        )

        harness.viewModel.setFocusSessionEngine(harness.engine)
        XCTAssertEqual(
            harness.viewModel.developmentInterruptionResumeState,
            .available(project: matchedProject)
        )
        XCTAssertEqual(harness.viewModel.manualControlState, .idle)

        harness.viewModel.resumeDevelopmentInterruption()

        let sessions = harness.engine.allSessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].mode, .manual)
        XCTAssertEqual(sessions[0].project.key, matchedProject.id.rawValue)
        XCTAssertEqual(sessions[0].project.displayName, matchedProject.displayName)
        XCTAssertTrue(sessions[0].isOpen)
        XCTAssertTrue(harness.viewModel.manualControlState.isManualSessionActive)
        // The manual-state refresh recomputed the gate: the card now shows the
        // current state instead of offering another start.
        XCTAssertEqual(
            harness.viewModel.developmentInterruptionResumeState,
            .inProgress(project: matchedProject, status: .active)
        )
    }

    // MARK: - Current-state presentation

    func testMatchedProjectManualSessionShowsStateAndResumeIsNoOp() {
        let harness = makeHarness(projects: [matchedProject])
        harness.viewModel.setFocusSessionEngine(harness.engine)

        harness.viewModel.startManualFocus(project: FocusProjectContext(
            key: matchedProject.id.rawValue,
            displayName: matchedProject.displayName
        ))
        XCTAssertEqual(
            harness.viewModel.developmentInterruptionResumeState,
            .inProgress(project: matchedProject, status: .active)
        )

        harness.viewModel.resumeDevelopmentInterruption()
        XCTAssertEqual(harness.engine.allSessions.count, 1)
        XCTAssertTrue(harness.viewModel.manualControlState.isManualSessionActive)

        harness.viewModel.pauseManualFocus()
        XCTAssertEqual(
            harness.viewModel.developmentInterruptionResumeState,
            .inProgress(project: matchedProject, status: .paused)
        )
        XCTAssertTrue(harness.viewModel.manualControlState.isManualSessionPaused)

        harness.viewModel.resumeDevelopmentInterruption()
        XCTAssertEqual(harness.engine.allSessions.count, 1)
        XCTAssertEqual(
            harness.viewModel.developmentInterruptionResumeState,
            .inProgress(project: matchedProject, status: .paused)
        )
        XCTAssertTrue(harness.viewModel.manualControlState.isManualSessionPaused)
    }

    func testAutomaticSessionOnMatchedProjectShowsStateDespiteIdleManualControl() {
        let harness = makeHarness(projects: [matchedProject])
        // An automatic session is invisible to manualControlState, so gating
        // must come from the engine's open session, not the manual projection.
        _ = harness.engine.userActivity(
            in: FocusProjectContext(key: matchedProject.id.rawValue, displayName: "TinyBuddy"),
            at: harness.today
        )

        harness.viewModel.setFocusSessionEngine(harness.engine)
        XCTAssertEqual(harness.viewModel.manualControlState, .idle)
        XCTAssertEqual(
            harness.viewModel.developmentInterruptionResumeState,
            .inProgress(project: matchedProject, status: .active)
        )

        harness.viewModel.resumeDevelopmentInterruption()
        XCTAssertEqual(harness.engine.allSessions.count, 1)
        XCTAssertEqual(harness.engine.allSessions[0].mode, .automatic)
    }

    // MARK: - Read-only blocking

    func testOtherProjectFocusBlocksResumeAndIsNoOp() {
        let harness = makeHarness(projects: [matchedProject])
        harness.viewModel.setFocusSessionEngine(harness.engine)
        harness.viewModel.startManualFocus(project: FocusProjectContext(
            key: "proj-other",
            displayName: "Other"
        ))

        XCTAssertEqual(harness.viewModel.developmentInterruptionResumeState, .blocked)

        harness.viewModel.resumeDevelopmentInterruption()
        XCTAssertEqual(harness.engine.allSessions.count, 1)
        XCTAssertEqual(harness.engine.currentProject?.key, "proj-other")
        XCTAssertTrue(harness.viewModel.manualControlState.isManualSessionActive)
    }

    func testUnavailableOrUnmatchedProjectBlocksResumeAndIsNoOp() {
        let archived = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "proj-archived"),
            kind: .gitRepository,
            displayName: "TinyBuddy",
            repositoryFingerprint: "finger-1",
            state: .archived
        )
        let harness = makeHarness(projects: [archived])
        harness.viewModel.setFocusSessionEngine(harness.engine)
        XCTAssertEqual(harness.viewModel.developmentInterruptionResumeState, .blocked)

        harness.viewModel.resumeDevelopmentInterruption()
        XCTAssertTrue(harness.engine.allSessions.isEmpty)

        let noMatch = makeHarness(projects: [])
        noMatch.viewModel.setFocusSessionEngine(noMatch.engine)
        XCTAssertEqual(noMatch.viewModel.developmentInterruptionResumeState, .blocked)
        noMatch.viewModel.resumeDevelopmentInterruption()
        XCTAssertTrue(noMatch.engine.allSessions.isEmpty)
    }

    func testNoSnapshotBlocksResumeAndIsNoOp() {
        let harness = makeHarness(projects: [matchedProject], seedSnapshot: false)
        harness.viewModel.setFocusSessionEngine(harness.engine)
        XCTAssertNil(harness.viewModel.developmentInterruptionSnapshot)
        XCTAssertEqual(harness.viewModel.developmentInterruptionResumeState, .blocked)
        harness.viewModel.resumeDevelopmentInterruption()
        XCTAssertTrue(harness.engine.allSessions.isEmpty)
    }

    func testRegistryChangeNotificationRecomputesGate() {
        var projects = [matchedProject]
        let harness = makeHarness(projectsProvider: { projects })
        XCTAssertEqual(
            harness.viewModel.developmentInterruptionResumeState,
            .available(project: matchedProject)
        )

        projects = [TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "proj-1"),
            kind: .gitRepository,
            displayName: "TinyBuddy",
            repositoryFingerprint: "finger-1",
            state: .archived
        )]
        harness.notificationCenter.post(
            name: Notification.Name("TinyBuddy.projectRegistryDidChange"),
            object: nil
        )
        XCTAssertEqual(harness.viewModel.developmentInterruptionResumeState, .blocked)
    }

    // MARK: - No path persistence, no new defaults keys

    func testResumePersistsNoRepositoryPathAndAddsNoDefaultsKeys() {
        let harness = makeHarness(projects: [matchedProject])
        harness.viewModel.setFocusSessionEngine(harness.engine)

        let defaultsKeysBefore = Set(harness.defaults.dictionaryRepresentation().keys)
        harness.viewModel.resumeDevelopmentInterruption()
        let defaultsKeysAfter = Set(harness.defaults.dictionaryRepresentation().keys)

        XCTAssertEqual(defaultsKeysAfter, defaultsKeysBefore)
        let sessions = harness.engine.allSessions
        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertFalse(session.project.key.contains("/Users/secret/PrivateRepo"))
        XCTAssertFalse(session.project.displayName.contains("/Users/secret/PrivateRepo"))
        XCTAssertEqual(session.project.key, matchedProject.id.rawValue)
    }

    // MARK: - Harness

    private struct Harness {
        let viewModel: PetViewModel
        let engine: FocusSessionEngine
        let defaults: UserDefaults
        let notificationCenter: NotificationCenter
        let today: Date
    }

    private func makeHarness(
        projects: [TinyBuddyProject],
        seedSnapshot: Bool = true
    ) -> Harness {
        makeHarness(projectsProvider: { projects }, seedSnapshot: seedSnapshot)
    }

    private func makeHarness(
        projectsProvider: @escaping () -> [TinyBuddyProject],
        seedSnapshot: Bool = true
    ) -> Harness {
        let defaults = makeDefaults()
        let calendar = makeCalendar()
        let today = makeDate(year: 2026, month: 7, day: 4, hour: 8, minute: 0, second: 0)
        if seedSnapshot {
            seedInterruptionSnapshot(in: defaults, fingerprint: snapshotFingerprint, now: today)
        }
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { today }
        )
        let engine = FocusSessionEngine(
            clock: ResumeFakeClock(today),
            persisting: ResumeMemoryStore(),
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { resumeDayIdentifier(for: $0) },
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            }
        )
        let notificationCenter = NotificationCenter()
        let viewModel = PetViewModel(
            store: store,
            activityStore: makeActivityStore(defaults: defaults, calendar: calendar, today: today),
            combinedSnapshotStore: store.makeCombinedSnapshotStore(),
            refreshStatusStore: GitActivityRefreshStatusStore(userDefaults: defaults),
            developmentInterruptionStore: DevelopmentInterruptionSnapshotStore(
                userDefaults: defaults
            ),
            notificationCenter: notificationCenter,
            timeEnvironment: makeTimeEnvironment(calendar: calendar, now: today),
            registeredProjectsProvider: projectsProvider,
            widgetReloader: {}
        )
        return Harness(
            viewModel: viewModel,
            engine: engine,
            defaults: defaults,
            notificationCenter: notificationCenter,
            today: today
        )
    }

    private func seedInterruptionSnapshot(
        in defaults: UserDefaults,
        fingerprint: String,
        now: Date
    ) {
        let encode: (String) -> String = { Data($0.utf8).base64EncodedString() }
        defaults.set([
            "v1",
            encode(fingerprint),
            encode("TinyBuddy"),
            encode("main"),
            "0", "2", "0", "0",
            encode("abc1234"),
            encode("Add resume"),
            String(Int(now.timeIntervalSince1970) - 120),
            String(Int(now.timeIntervalSince1970) - 60),
            String(Int(now.timeIntervalSince1970))
        ].joined(separator: "\t"), forKey: DevelopmentInterruptionSnapshotStore.Key.snapshot)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyPetViewModelResumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeActivityStore(
        defaults: UserDefaults,
        calendar: Calendar,
        today: Date
    ) -> GitTodayActivityStore {
        GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { today },
                sharedFallbacksEnabled: false
            )
        )
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeTimeEnvironment(calendar: Calendar, now: Date) -> TinyBuddyTimeEnvironment {
        TinyBuddyTimeEnvironment(calendar: calendar, dateProvider: { now })
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}
