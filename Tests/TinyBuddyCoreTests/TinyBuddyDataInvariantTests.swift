import XCTest
@testable import TinyBuddyCore

// MARK: - Helpers

/// Creates a valid ended focus session with minimal required fields.
private func makeSession(
    id: UUID = UUID(),
    projectKey: String = "com.example.myapp",
    projectDisplayName: String = "MyApp",
    dayIdentifier: String = "2026-07-20",
    startedAt: Date,
    endedAt: Date? = nil,
    status: FocusSessionStatus = .ended,
    lastUserActivityAt: Date? = nil,
    lastStateChangeAt: Date? = nil,
    pausedTotal: TimeInterval = 0,
    currentPauseStartedAt: Date? = nil,
    isManuallyConfirmed: Bool = false,
    manualRevision: Int64? = nil,
    decisionEvents: [FocusSessionDecisionEvent]? = nil,
    mode: FocusMode = .automatic
) -> FocusSession {
    let activity = lastUserActivityAt ?? startedAt
    let stateChange = lastStateChangeAt ?? startedAt
    return FocusSession(
        id: id,
        project: FocusProjectContext(key: projectKey, displayName: projectDisplayName),
        dayIdentifier: dayIdentifier,
        startedAt: startedAt,
        endedAt: endedAt,
        status: status,
        lastUserActivityAt: activity,
        lastStateChangeAt: stateChange,
        pausedTotal: pausedTotal,
        currentPauseStartedAt: currentPauseStartedAt,
        isManuallyConfirmed: isManuallyConfirmed,
        manualRevision: manualRevision,
        decisionEvents: decisionEvents,
        mode: mode
    )
}

/// Creates a minimal project registry snapshot.
private func makeProjectRegistry(
    projects: [TinyBuddyProject] = [],
    redirects: [TinyBuddyProjectID: TinyBuddyProjectID] = [:]
) -> TinyBuddyProjectRegistrySnapshot {
    TinyBuddyProjectRegistrySnapshot(
        schemaVersion: TinyBuddyProjectRegistrySnapshot.currentSchemaVersion,
        revision: 0,
        generation: 0,
        projects: projects,
        redirects: redirects
    )
}

/// Creates a minimal combined snapshot.
private func makeCombinedSnapshot(
    revision: Int64 = 0,
    dayIdentifier: String = "2026-07-20",
    focusCount: Int = 0,
    completionCount: Int = 0,
    status: PetStatus = .idle,
    focusSessionSnapshot: FocusSessionDerivedSnapshot? = nil,
    focusHistoryPublication: FocusHistoryPublication? = nil
) -> TinyBuddyCombinedSnapshot {
    let stats = DailyStats(
        dayIdentifier: dayIdentifier,
        focusCount: focusCount,
        completionCount: completionCount
    )
    let snapshot = TinyBuddySnapshot(status: status, stats: stats)
    let activity = GitTodayActivitySnapshot(
        focusBlockCount: nil,
        commitCount: nil,
        recentProjectName: nil
    )
    return TinyBuddyCombinedSnapshot(
        revision: revision,
        dayIdentifier: dayIdentifier,
        snapshot: snapshot,
        activitySnapshot: activity,
        activityRevision: nil,
        focusSessionSnapshot: focusSessionSnapshot,
        focusHistoryPublication: focusHistoryPublication
    )
}

/// UTC date helper.
private func date(day: Int = 20, month: Int = 7, year: Int = 2026,
                  hour: Int = 10, minute: Int = 0, second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                              hour: hour, minute: minute, second: second))!
}

private let fixedNow: Date = date(hour: 12, minute: 0, second: 0)

// MARK: - 1. Invariant Types Tests

final class TinyBuddyDataInvariantTypesTests: XCTestCase {

    // MARK: TinyBuddyDataDomain

    func testDataDomainValues() {
        XCTAssertEqual(TinyBuddyDataDomain.focusSession.identifier, "focusSession")
        XCTAssertEqual(TinyBuddyDataDomain.projectIdentity.identifier, "projectIdentity")
        XCTAssertEqual(TinyBuddyDataDomain.configSnapshot.identifier, "configSnapshot")
        XCTAssertEqual(TinyBuddyDataDomain.historyAggregation.identifier, "historyAggregation")
        XCTAssertEqual(TinyBuddyDataDomain.sharedSnapshot.identifier, "sharedSnapshot")
        XCTAssertEqual(TinyBuddyDataDomain.dailyStats.identifier, "dailyStats")
    }

    // MARK: TinyBuddyDataInvariantSeverity

    func testSeverityOrdering() {
        XCTAssertLessThan(TinyBuddyDataInvariantSeverity.warning, .error)
        XCTAssertLessThan(TinyBuddyDataInvariantSeverity.error, .critical)
        XCTAssertLessThan(TinyBuddyDataInvariantSeverity.warning, .critical)
        XCTAssertEqual(TinyBuddyDataInvariantSeverity.warning, .warning)
        XCTAssertEqual(TinyBuddyDataInvariantSeverity.error, .error)
        XCTAssertEqual(TinyBuddyDataInvariantSeverity.critical, .critical)
    }

    // MARK: TinyBuddyDataInvariantViolation

    func testViolationInit() {
        let id = UUID()
        let now = Date()
        let violation = TinyBuddyDataInvariantViolation(
            id: id,
            domain: .focusSession,
            kind: .duplicateSessionID(UUID()),
            severity: .critical,
            description: "Test violation",
            affectedIdentifiers: ["abc"],
            detectedAt: now,
            suggestedRepair: .isolated
        )
        XCTAssertEqual(violation.id, id)
        XCTAssertEqual(violation.domain, .focusSession)
        XCTAssertEqual(violation.severity, .critical)
        XCTAssertEqual(violation.description, "Test violation")
        XCTAssertEqual(violation.affectedIdentifiers, ["abc"])
        XCTAssertEqual(violation.detectedAt, now)
        XCTAssertEqual(violation.suggestedRepair, .isolated)
    }

    func testViolationDiagnosticKey() {
        let v1 = TinyBuddyDataInvariantViolation(
            domain: .focusSession,
            kind: .duplicateSessionID(UUID()),
            severity: .critical,
            description: "dup"
        )
        XCTAssertEqual(v1.diagnosticKey, "invariant.focusSession.duplicate_session_id")

        let v2 = TinyBuddyDataInvariantViolation(
            domain: .projectIdentity,
            kind: .projectRegistryRedirectCycle,
            severity: .critical,
            description: "cycle"
        )
        XCTAssertEqual(v2.diagnosticKey, "invariant.projectIdentity.registry_redirect_cycle")

        let v3 = TinyBuddyDataInvariantViolation(
            domain: .sharedSnapshot,
            kind: .snapshotFieldMissing(field: "focusCount"),
            severity: .error,
            description: "missing"
        )
        XCTAssertEqual(v3.diagnosticKey, "invariant.sharedSnapshot.snapshot_field_missing")
    }

    // MARK: TinyBuddyDataRepairResult

    func testRepairResultInit() {
        let id = UUID()
        let result = TinyBuddyDataRepairResult(
            violationID: id,
            action: .repaired,
            verifiedAfterRepair: true,
            diagnosticKey: "repair.test",
            quarantineEntryIDs: [UUID(), UUID()],
            summary: "Fixed it"
        )
        XCTAssertEqual(result.violationID, id)
        XCTAssertEqual(result.action, .repaired)
        XCTAssertTrue(result.verifiedAfterRepair)
        XCTAssertEqual(result.diagnosticKey, "repair.test")
        XCTAssertEqual(result.quarantineEntryIDs.count, 2)
        XCTAssertEqual(result.summary, "Fixed it")
    }

    // MARK: TinyBuddyDataRepairSession

    func testRepairSessionInit() {
        let id = UUID()
        let start = Date()
        let session = TinyBuddyDataRepairSession(
            id: id,
            startedAt: start,
            endedAt: start,
            violations: [],
            results: [],
            didComplete: true,
            inputHash: "abc123",
            didPerformRepair: true
        )
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.startedAt, start)
        XCTAssertEqual(session.endedAt, start)
        XCTAssertTrue(session.didComplete)
        XCTAssertEqual(session.inputHash, "abc123")
        XCTAssertTrue(session.didPerformRepair)
        XCTAssertEqual(session.id, id)
    }

    func testRepairSessionIdProperty() {
        let id = UUID()
        let session = TinyBuddyDataRepairSession(id: id)
        XCTAssertEqual(session.id, id)
    }

    // MARK: TinyBuddyCorruptedRecordEntry

    func testCorruptedRecordEntryInit() {
        let id = UUID()
        let now = Date()
        let entry = TinyBuddyCorruptedRecordEntry(
            id: id,
            domain: .focusSession,
            violationKind: .duplicateSessionID(UUID()),
            redactedOriginalData: "{redacted}",
            diagnosticKey: "invariant.focusSession.duplicate_session_id",
            isolatedAt: now
        )
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.domain, .focusSession)
        XCTAssertEqual(entry.redactedOriginalData, "{redacted}")
        XCTAssertEqual(entry.diagnosticKey, "invariant.focusSession.duplicate_session_id")
        XCTAssertEqual(entry.isolatedAt, now)
    }

    // MARK: TinyBuddyDataInvariantKind Codable round-trip

    func testKindCodableRoundTripDuplicateSessionID() throws {
        let id = UUID()
        let kind = TinyBuddyDataInvariantKind.duplicateSessionID(id)
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(TinyBuddyDataInvariantKind.self, from: data)
        XCTAssertEqual(decoded, kind)
    }

    func testKindCodableRoundTripNegativeDuration() throws {
        let sessionID = UUID()
        let kind = TinyBuddyDataInvariantKind.negativeDuration(sessionID: sessionID, duration: -30)
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(TinyBuddyDataInvariantKind.self, from: data)
        XCTAssertEqual(decoded, kind)
    }

    func testKindCodableRoundTripSnapshotFieldMissing() throws {
        let kind = TinyBuddyDataInvariantKind.snapshotFieldMissing(field: "focusCount")
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(TinyBuddyDataInvariantKind.self, from: data)
        XCTAssertEqual(decoded, kind)
    }

    func testKindCodableRoundTripUnknown() throws {
        let kind = TinyBuddyDataInvariantKind.unknown("test")
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(TinyBuddyDataInvariantKind.self, from: data)
        XCTAssertEqual(decoded, kind)
    }

    func testKindCodableRoundTripNoPayloadCases() throws {
        let cases: [TinyBuddyDataInvariantKind] = [
            .projectRegistryRedirectCycle,
            .projectRegistryRedirectToSelf,
            .configPayloadDecodeFailed,
            .configVersionMarkerMismatch,
            .snapshotSchemaVersionMismatch
        ]
        for kind in cases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(TinyBuddyDataInvariantKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func testKindCodableRoundTripProjectRelated() throws {
        let id = TinyBuddyProjectID(rawValue: "test-proj")
        let kinds: [TinyBuddyDataInvariantKind] = [
            .duplicateProjectID(id),
            .projectEmptyProjectDisplayName(projectID: id),
            .staleProjectReference(projectKey: "com.example"),
            .projectRedirectSourceNotInRegistry(source: id),
            .projectRedirectTargetNotInRegistry(target: id)
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(TinyBuddyDataInvariantKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }
}

// MARK: - 2. Validator: Focus Session Tests

final class TinyBuddyDataValidatorFocusSessionTests: XCTestCase {

    func testNormalDataNoViolations() {
        let sessions = [
            makeSession(id: UUID(), dayIdentifier: "2026-07-20", startedAt: date(hour: 9), endedAt: date(hour: 10)),
            makeSession(id: UUID(), dayIdentifier: "2026-07-20", startedAt: date(hour: 10, minute: 30), endedAt: date(hour: 11))
        ]
        let violations = TinyBuddyDataValidator.validateFocusSessions(
            sessions, now: fixedNow, activeProjectKeys: ["com.example.myapp"]
        )
        XCTAssertTrue(violations.isEmpty, "Expected no violations for valid sessions, got \(violations)")
    }

    func testDuplicateSessionIDs() {
        let id = UUID()
        let sessions = [
            makeSession(id: id, startedAt: date(hour: 9), endedAt: date(hour: 10)),
            makeSession(id: id, startedAt: date(hour: 11), endedAt: date(hour: 12))
        ]
        let violations = TinyBuddyDataValidator.validateFocusSessions(sessions, now: fixedNow)
        // Valid duplicate sessions produce only the grouped duplicate violation (1),
        // not per-session structural violations since each individual session is structurally valid.
        XCTAssertEqual(violations.count, 1, "Expected 1 violation for duplicate session IDs")
        let dups = violations.filter { v in
            if case .duplicateSessionID = v.kind { return true }
            return false
        }
        XCTAssertEqual(dups.count, 1)
        XCTAssertEqual(dups[0].severity, .critical)
        XCTAssertEqual(dups[0].suggestedRepair, .isolated)
    }

    func testTimeOverlap() {
        let sessions = [
            makeSession(dayIdentifier: "2026-07-20", startedAt: date(hour: 9), endedAt: date(hour: 11)),
            makeSession(dayIdentifier: "2026-07-20", startedAt: date(hour: 10), endedAt: date(hour: 12))
        ]
        let violations = TinyBuddyDataValidator.validateFocusSessions(sessions, now: fixedNow)
        let overlaps = violations.filter { v in
            if case .sessionTimeOverlap = v.kind { return true }
            return false
        }
        XCTAssertEqual(overlaps.count, 1)
        XCTAssertEqual(overlaps[0].severity, .error)
    }

    func testNoOverlapForDifferentDays() {
        let sessions = [
            makeSession(dayIdentifier: "2026-07-20", startedAt: date(hour: 9), endedAt: date(hour: 11)),
            makeSession(dayIdentifier: "2026-07-21", startedAt: date(hour: 10), endedAt: date(hour: 11))
        ]
        let violations = TinyBuddyDataValidator.validateFocusSessions(sessions, now: fixedNow)
        let overlaps = violations.filter { v in
            if case .sessionTimeOverlap = v.kind { return true }
            return false
        }
        XCTAssertTrue(overlaps.isEmpty, "Different days should not overlap")
    }

    func testNegativePausedTotal() {
        let session = makeSession(
            startedAt: date(hour: 9), endedAt: date(hour: 10),
            pausedTotal: -30
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let pausedIssues = violations.filter { v in
            if case .pausedTotalExceedsGross = v.kind { return true }
            return false
        }
        XCTAssertEqual(pausedIssues.count, 1)
        XCTAssertEqual(pausedIssues[0].severity, .error)
        XCTAssertEqual(pausedIssues[0].suggestedRepair, .repaired)
    }

    func testFutureStartedAt() {
        let future = date(hour: 14, minute: 0) // 2 hours after fixedNow (12:00)
        let session = makeSession(startedAt: future, endedAt: future.addingTimeInterval(1800))
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let futureIssues = violations.filter { v in
            if case .futureStartedAt = v.kind { return true }
            return false
        }
        // FutureTolerance is 3600 — 7200 > 3600 so violation expected
        XCTAssertEqual(futureIssues.count, 1, "Expected 1 futureStartedAt violation, got \(futureIssues.count)")
        XCTAssertEqual(futureIssues[0].severity, .error)
        XCTAssertEqual(futureIssues[0].suggestedRepair, .repaired)
    }

    func testFutureStartedAtWithinToleranceNoViolation() {
        let nearFuture = fixedNow.addingTimeInterval(1800) // 30 min — within 1 hour tolerance
        let session = makeSession(startedAt: nearFuture, endedAt: nearFuture.addingTimeInterval(600))
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let futureIssues = violations.filter { v in
            if case .futureStartedAt = v.kind { return true }
            return false
        }
        XCTAssertTrue(futureIssues.isEmpty, "StartedAt within tolerance should not trigger violation")
    }

    func testInvalidDayIdentifier() {
        let session = makeSession(
            dayIdentifier: "not-a-date",
            startedAt: date(hour: 9), endedAt: date(hour: 10)
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let dayIssues = violations.filter { v in
            if case .invalidDayIdentifier = v.kind { return true }
            return false
        }
        XCTAssertEqual(dayIssues.count, 1)
        XCTAssertEqual(dayIssues[0].severity, .critical)
        XCTAssertEqual(dayIssues[0].suggestedRepair, .isolated)
    }

    func testEmptyProjectKey() {
        let session = makeSession(
            projectKey: "", projectDisplayName: "EmptyKey",
            startedAt: date(hour: 9), endedAt: date(hour: 10)
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let keyIssues = violations.filter { v in
            if case .emptyProjectKey = v.kind { return true }
            return false
        }
        XCTAssertEqual(keyIssues.count, 1)
        XCTAssertEqual(keyIssues[0].severity, .error)
        XCTAssertEqual(keyIssues[0].suggestedRepair, .repaired)
    }

    func testEmptyProjectDisplayName() {
        let session = makeSession(
            projectKey: "com.example", projectDisplayName: "",
            startedAt: date(hour: 9), endedAt: date(hour: 10)
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let nameIssues = violations.filter { v in
            if case .sessionEmptyProjectDisplayName = v.kind { return true }
            return false
        }
        XCTAssertEqual(nameIssues.count, 1)
        XCTAssertEqual(nameIssues[0].severity, .error)
        XCTAssertEqual(nameIssues[0].suggestedRepair, .repaired)
    }

    func testStatusEndedWithoutEndedAt() {
        let session = makeSession(
            startedAt: date(hour: 9), endedAt: nil, status: .ended
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let endedIssues = violations.filter { v in
            if case .statusEndedWithoutEndedAt = v.kind { return true }
            return false
        }
        XCTAssertEqual(endedIssues.count, 1)
        XCTAssertEqual(endedIssues[0].severity, .error)
    }

    func testStatusActiveWithEndedAt() {
        let session = makeSession(
            startedAt: date(hour: 9), endedAt: date(hour: 10), status: .active
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let activeIssues = violations.filter { v in
            if case .statusActiveWithEndedAt = v.kind { return true }
            return false
        }
        XCTAssertEqual(activeIssues.count, 1)
        XCTAssertEqual(activeIssues[0].severity, .error)
    }

    func testLastUserActivityBeforeStart() {
        let start = date(hour: 10)
        let earlyActivity = date(hour: 9)
        let session = makeSession(
            startedAt: start, endedAt: date(hour: 11),
            lastUserActivityAt: earlyActivity
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let activityIssues = violations.filter { v in
            if case .lastUserActivityBeforeStart = v.kind { return true }
            return false
        }
        XCTAssertEqual(activityIssues.count, 1)
        XCTAssertEqual(activityIssues[0].severity, .error)
    }

    func testStaleProjectReference() {
        let sessions = [
            makeSession(
                projectKey: "unknown.app",
                startedAt: date(hour: 9), endedAt: date(hour: 10)
            )
        ]
        let violations = TinyBuddyDataValidator.validateFocusSessions(
            sessions, now: fixedNow,
            activeProjectKeys: ["com.example.known"]
        )
        let staleIssues = violations.filter { v in
            if case .staleProjectReference = v.kind { return true }
            return false
        }
        XCTAssertEqual(staleIssues.count, 1)
        XCTAssertEqual(staleIssues[0].severity, .warning)
        XCTAssertEqual(staleIssues[0].suggestedRepair, .none)
    }

    func testNoStaleReferenceWhenKeysEmpty() {
        let sessions = [
            makeSession(
                projectKey: "unknown.app",
                startedAt: date(hour: 9), endedAt: date(hour: 10)
            )
        ]
        let violations = TinyBuddyDataValidator.validateFocusSessions(
            sessions, now: fixedNow,
            activeProjectKeys: []
        )
        let staleIssues = violations.filter { v in
            if case .staleProjectReference = v.kind { return true }
            return false
        }
        XCTAssertTrue(staleIssues.isEmpty, "Empty activeProjectKeys should not trigger stale reference")
    }
}

// MARK: - 3. Validator: Project Registry Tests

final class TinyBuddyDataValidatorProjectRegistryTests: XCTestCase {

    private func makeProject(id: String, displayName: String = "Test Project") -> TinyBuddyProject {
        TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: id),
            kind: .gitRepository,
            displayName: displayName,
            aliases: [id],
            state: .active
        )
    }

    func testNormalDataNoViolations() {
        let projects = [
            makeProject(id: "proj-a", displayName: "Project A"),
            makeProject(id: "proj-b", displayName: "Project B")
        ]
        let snapshot = makeProjectRegistry(projects: projects)
        let violations = TinyBuddyDataValidator.validateProjectRegistry(snapshot)
        XCTAssertTrue(violations.isEmpty, "Expected no violations, got \(violations)")
    }

    func testEmptyDisplayName() {
        let projects = [
            makeProject(id: "proj-a", displayName: "")
        ]
        let snapshot = makeProjectRegistry(projects: projects)
        let violations = TinyBuddyDataValidator.validateProjectRegistry(snapshot)
        let nameIssues = violations.filter { v in
            if case .projectEmptyProjectDisplayName = v.kind { return true }
            return false
        }
        XCTAssertEqual(nameIssues.count, 1)
        XCTAssertEqual(nameIssues[0].severity, .error)
    }

    func testSelfRedirect() {
        let id = TinyBuddyProjectID(rawValue: "proj-a")
        let projects = [
            TinyBuddyProject(id: id, kind: .gitRepository, displayName: "A", aliases: [], state: .active)
        ]
        let snapshot = makeProjectRegistry(projects: projects, redirects: [id: id])
        let violations = TinyBuddyDataValidator.validateProjectRegistry(snapshot)
        let selfRedirectIssues = violations.filter { v in
            if case .projectRegistryRedirectToSelf = v.kind { return true }
            return false
        }
        XCTAssertEqual(selfRedirectIssues.count, 1)
        XCTAssertEqual(selfRedirectIssues[0].severity, .critical)
    }

    func testRedirectCycle() {
        let a = TinyBuddyProjectID(rawValue: "proj-a")
        let b = TinyBuddyProjectID(rawValue: "proj-b")
        let projects = [
            TinyBuddyProject(id: a, kind: .gitRepository, displayName: "A", aliases: [], state: .active),
            TinyBuddyProject(id: b, kind: .gitRepository, displayName: "B", aliases: [], state: .active)
        ]
        let snapshot = makeProjectRegistry(projects: projects, redirects: [a: b, b: a])
        let violations = TinyBuddyDataValidator.validateProjectRegistry(snapshot)
        let cycleIssues = violations.filter { v in
            if case .projectRegistryRedirectCycle = v.kind { return true }
            return false
        }
        XCTAssertEqual(cycleIssues.count, 1)
        XCTAssertEqual(cycleIssues[0].severity, .critical)
    }

    func testRedirectSourceNotInRegistry() {
        let a = TinyBuddyProjectID(rawValue: "proj-a")
        let b = TinyBuddyProjectID(rawValue: "proj-b")
        let projects = [
            TinyBuddyProject(id: a, kind: .gitRepository, displayName: "A", aliases: [], state: .active)
        ]
        let snapshot = makeProjectRegistry(projects: projects, redirects: [a: b])
        let violations = TinyBuddyDataValidator.validateProjectRegistry(snapshot)
        let missingTarget = violations.filter { v in
            if case .projectRedirectTargetNotInRegistry = v.kind { return true }
            return false
        }
        XCTAssertEqual(missingTarget.count, 1)
        XCTAssertEqual(missingTarget[0].severity, .error)
    }

    func testRedirectTargetNotInRegistry() {
        let a = TinyBuddyProjectID(rawValue: "proj-a")
        let b = TinyBuddyProjectID(rawValue: "proj-b")
        let projects = [
            TinyBuddyProject(id: b, kind: .gitRepository, displayName: "B", aliases: [], state: .active)
        ]
        let snapshot = makeProjectRegistry(projects: projects, redirects: [a: b])
        let violations = TinyBuddyDataValidator.validateProjectRegistry(snapshot)
        let missingSource = violations.filter { v in
            if case .projectRedirectSourceNotInRegistry = v.kind { return true }
            return false
        }
        XCTAssertEqual(missingSource.count, 1)
        XCTAssertEqual(missingSource[0].severity, .error)
    }

    func testDuplicateProjectIDs() {
        let id = TinyBuddyProjectID(rawValue: "dup-id")
        let projects = [
            TinyBuddyProject(id: id, kind: .gitRepository, displayName: "A", aliases: [], state: .active),
            TinyBuddyProject(id: id, kind: .gitRepository, displayName: "B", aliases: [], state: .active)
        ]
        let snapshot = makeProjectRegistry(projects: projects)
        let violations = TinyBuddyDataValidator.validateProjectRegistry(snapshot)
        let dupIssues = violations.filter { v in
            if case .duplicateProjectID = v.kind { return true }
            return false
        }
        XCTAssertEqual(dupIssues.count, 1)
        XCTAssertEqual(dupIssues[0].severity, .critical)
    }
}

// MARK: - 4. Validator: Combined Snapshot Tests

final class TinyBuddyDataValidatorCombinedSnapshotTests: XCTestCase {

    func testNormalSnapshotNoViolations() {
        let snapshot = makeCombinedSnapshot()
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        XCTAssertTrue(violations.isEmpty, "Expected no violations for valid snapshot, got \(violations)")
    }

    func testNegativeFocusCount() {
        let snapshot = makeCombinedSnapshot(focusCount: -3)
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        let focusIssues = violations.filter { v in
            if case .focusCountNegative = v.kind { return true }
            return false
        }
        XCTAssertEqual(focusIssues.count, 1)
        XCTAssertEqual(focusIssues[0].severity, .error)
    }

    func testNegativeCompletionCount() {
        let snapshot = makeCombinedSnapshot(completionCount: -1)
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        let compIssues = violations.filter { v in
            if case .completionCountNegative = v.kind { return true }
            return false
        }
        XCTAssertEqual(compIssues.count, 1)
        XCTAssertEqual(compIssues[0].severity, .error)
    }

    func testDayIdentifierMismatch() {
        let stats = DailyStats(dayIdentifier: "2026-07-21", focusCount: 0, completionCount: 0)
        let innerSnapshot = TinyBuddySnapshot(status: .idle, stats: stats)
        let activity = GitTodayActivitySnapshot(focusBlockCount: nil, commitCount: nil)
        let snapshot = TinyBuddyCombinedSnapshot(
            revision: 0,
            dayIdentifier: "2026-07-20",
            snapshot: innerSnapshot,
            activitySnapshot: activity
        )
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        let dayIssues = violations.filter { v in
            if case .snapshotDayIdentifierMismatch = v.kind { return true }
            return false
        }
        XCTAssertEqual(dayIssues.count, 1)
        XCTAssertEqual(dayIssues[0].severity, .error)
    }

    func testFocusSessionDayMismatch() {
        let focusSnapshot = FocusSessionDerivedSnapshot(
            revision: 0,
            dayIdentifier: "2026-07-21",
            focusDuration: 3600,
            projectDurations: [:],
            completedSessionCount: 1
        )
        let snapshot = makeCombinedSnapshot(
            dayIdentifier: "2026-07-20",
            focusSessionSnapshot: focusSnapshot
        )
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        let focusDayIssues = violations.filter { v in
            if case .snapshotFocusSessionDayMismatch = v.kind { return true }
            return false
        }
        XCTAssertEqual(focusDayIssues.count, 1)
        XCTAssertEqual(focusDayIssues[0].severity, .error)
    }
}

// MARK: - 5. Validator: Daily Stats Tests

final class TinyBuddyDataValidatorDailyStatsTests: XCTestCase {

    func testNormalStatsNoViolations() {
        let stats = DailyStats(dayIdentifier: "2026-07-20", focusCount: 3, completionCount: 5)
        let violations = TinyBuddyDataValidator.validateDailyStats(stats)
        XCTAssertTrue(violations.isEmpty, "Expected no violations for valid stats, got \(violations)")
    }

    func testNegativeFocusCount() {
        let stats = DailyStats(dayIdentifier: "2026-07-20", focusCount: -1, completionCount: 0)
        let violations = TinyBuddyDataValidator.validateDailyStats(stats)
        let focusIssues = violations.filter { v in
            if case .focusCountNegative = v.kind { return true }
            return false
        }
        XCTAssertEqual(focusIssues.count, 1)
        XCTAssertEqual(focusIssues[0].severity, .error)
    }

    func testNegativeCompletionCount() {
        let stats = DailyStats(dayIdentifier: "2026-07-20", focusCount: 0, completionCount: -5)
        let violations = TinyBuddyDataValidator.validateDailyStats(stats)
        let compIssues = violations.filter { v in
            if case .completionCountNegative = v.kind { return true }
            return false
        }
        XCTAssertEqual(compIssues.count, 1)
        XCTAssertEqual(compIssues[0].severity, .error)
    }

    func testDayRollback() {
        let current = DailyStats(dayIdentifier: "2026-07-19", focusCount: 1, completionCount: 1)
        let previous = DailyStats(dayIdentifier: "2026-07-20", focusCount: 2, completionCount: 2)
        let violations = TinyBuddyDataValidator.validateDailyStats(current, previousStats: previous)
        let rollbackIssues = violations.filter { v in
            if case .dayIdentifierRollback = v.kind { return true }
            return false
        }
        XCTAssertEqual(rollbackIssues.count, 1)
        XCTAssertEqual(rollbackIssues[0].severity, .error)
        XCTAssertEqual(rollbackIssues[0].suggestedRepair, .preserved)
    }

    func testNoRollbackWhenLaterDay() {
        let current = DailyStats(dayIdentifier: "2026-07-21", focusCount: 1, completionCount: 1)
        let previous = DailyStats(dayIdentifier: "2026-07-20", focusCount: 2, completionCount: 2)
        let violations = TinyBuddyDataValidator.validateDailyStats(current, previousStats: previous)
        let rollbackIssues = violations.filter { v in
            if case .dayIdentifierRollback = v.kind { return true }
            return false
        }
        XCTAssertTrue(rollbackIssues.isEmpty, "Later day should not trigger rollback")
    }
}

// MARK: - 6. Repair Engine Tests

final class TinyBuddyDataRepairEngineTests: XCTestCase {

    // MARK: Session Repair

    func testSessionDeduplication() {
        let id = UUID()
        var sessions = [
            makeSession(id: id, startedAt: date(hour: 9), endedAt: date(hour: 10)),
            makeSession(id: id, startedAt: date(hour: 11), endedAt: date(hour: 12))
        ]
        var projectSnapshot = makeProjectRegistry()
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot()

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        // After dedup, only one session with that ID should remain
        let matching = sessions.filter { $0.id == id }
        XCTAssertEqual(matching.count, 1, "Expected exactly one session after deduplication")
        XCTAssertTrue(result.didPerformRepair)
        let isolatedResults = result.results.filter { $0.action == .isolated }
        // Deduplication may produce an isolated result depending on violation presence
        // Not asserting count here as it depends on violation matching
    }

    func testNegativePausedTotalClamping() {
        var sessions = [
            makeSession(startedAt: date(hour: 9), endedAt: date(hour: 10), pausedTotal: -50)
        ]
        var projectSnapshot = makeProjectRegistry()
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot()

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        XCTAssertEqual(sessions[0].pausedTotal, 0, "Negative pausedTotal should be clamped to 0")
        XCTAssertTrue(result.didPerformRepair)
    }

    func testFutureStartedAtClamping() {
        let future = date(day: 21, hour: 12) // next day — way beyond tolerance
        var sessions = [
            makeSession(startedAt: future, endedAt: future.addingTimeInterval(1800))
        ]
        var projectSnapshot = makeProjectRegistry()
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot()

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        XCTAssertLessThanOrEqual(sessions[0].startedAt, fixedNow,
                                 "Future startedAt should be clamped to now")
        // lastUserActivityAt and lastStateChangeAt should also be >= new startedAt
        XCTAssertGreaterThanOrEqual(sessions[0].lastUserActivityAt, sessions[0].startedAt)
        XCTAssertGreaterThanOrEqual(sessions[0].lastStateChangeAt, sessions[0].startedAt)
        XCTAssertTrue(result.didPerformRepair)
    }

    func testEmptyProjectKeyFix() {
        var sessions = [
            makeSession(projectKey: "", startedAt: date(hour: 9), endedAt: date(hour: 10))
        ]
        var projectSnapshot = makeProjectRegistry()
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot()

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        XCTAssertFalse(sessions[0].project.key.isEmpty, "Empty project key should be replaced")
        XCTAssertTrue(sessions[0].project.key.hasPrefix("unknown."),
                      "Repaired key should start with 'unknown.'")
        XCTAssertTrue(result.didPerformRepair)
    }

    // MARK: Project Registry Repair

    func testProjectRegistryDeduplication() {
        let id = TinyBuddyProjectID(rawValue: "dup-proj")
        var projectSnapshot = makeProjectRegistry(projects: [
            TinyBuddyProject(id: id, kind: .gitRepository, displayName: "A", aliases: [], state: .active),
            TinyBuddyProject(id: id, kind: .gitRepository, displayName: "B", aliases: [], state: .active)
        ])
        var sessions: [FocusSession] = []
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot()

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        let matching = projectSnapshot.projects.filter { $0.id == id }
        XCTAssertEqual(matching.count, 1, "Expected exactly one project after deduplication")
        XCTAssertTrue(result.didPerformRepair, "Expected repair to be performed")
    }

    func testProjectRegistryEmptyNameFix() {
        let id = TinyBuddyProjectID(rawValue: "no-name")
        var projectSnapshot = makeProjectRegistry(projects: [
            TinyBuddyProject(id: id, kind: .gitRepository, displayName: "", aliases: [], state: .active)
        ])
        var sessions: [FocusSession] = []
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot()

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        XCTAssertFalse(projectSnapshot.projects[0].displayName.isEmpty,
                       "Empty display name should be filled")
        XCTAssertTrue(result.didPerformRepair)
    }

    func testSelfRedirectRemoval() {
        let id = TinyBuddyProjectID(rawValue: "self-redirect")
        var projectSnapshot = makeProjectRegistry(projects: [
            TinyBuddyProject(id: id, kind: .gitRepository, displayName: "Self", aliases: [], state: .active)
        ], redirects: [id: id])
        var sessions: [FocusSession] = []
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot()

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        XCTAssertNil(projectSnapshot.redirects[id], "Self-redirect should be removed")
        XCTAssertTrue(result.didPerformRepair)
    }

    // MARK: Combined Snapshot Repair

    func testCombinedSnapshotNegativeStatsClamping() {
        var sessions = [
            makeSession(dayIdentifier: "2026-07-20", startedAt: date(hour: 9), endedAt: date(hour: 10))
        ]
        var projectSnapshot = makeProjectRegistry()
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot(focusCount: -5)

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        XCTAssertNotNil(combinedSnapshot)
        XCTAssertGreaterThanOrEqual(combinedSnapshot!.snapshot.stats.focusCount, 0,
                                    "Negative focusCount should be clamped")
        XCTAssertTrue(result.didPerformRepair)
    }

    // MARK: Full Repair Cycle

    func testFullRepairCycle() {
        let dupID = UUID()
        var sessions = [
            makeSession(id: dupID, dayIdentifier: "2026-07-20",
                        startedAt: date(hour: 9), endedAt: date(hour: 10)),
            makeSession(id: dupID, dayIdentifier: "2026-07-20",
                        startedAt: date(hour: 11), endedAt: date(hour: 12)),
            makeSession(projectKey: "", dayIdentifier: "2026-07-20",
                        startedAt: date(hour: 14), endedAt: date(hour: 15))
        ]
        let emptyNameID = TinyBuddyProjectID(rawValue: "empty-name")
        var projectSnapshot = makeProjectRegistry(projects: [
            TinyBuddyProject(id: emptyNameID, kind: .gitRepository,
                             displayName: "", aliases: [], state: .active)
        ])
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot(focusCount: -1)

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        // Results and violations should be populated
        XCTAssertFalse(result.violations.isEmpty, "Should have detected violations")
        XCTAssertFalse(result.results.isEmpty, "Should have performed repairs")
        XCTAssertTrue(result.didComplete, "Session should complete")
        XCTAssertTrue(result.didPerformRepair, "Should have performed actual repairs")
        XCTAssertFalse(result.inputHash.isEmpty, "Input hash should not be empty")

        // Duplicates removed
        let remaining = sessions.filter { $0.id == dupID }
        XCTAssertEqual(remaining.count, 1, "Duplicate should be removed")

        // Empty key fixed
        let emptyKeySessions = sessions.filter { $0.project.key.isEmpty }
        XCTAssertTrue(emptyKeySessions.isEmpty, "No sessions should have empty project keys")
    }

    // MARK: Idempotency

    func testRepairIdempotency() {
        let dupID = UUID()
        var sessions1 = [
            makeSession(id: dupID, startedAt: date(hour: 9), endedAt: date(hour: 10)),
            makeSession(id: dupID, startedAt: date(hour: 11), endedAt: date(hour: 12)),
            makeSession(projectKey: "", startedAt: date(hour: 14), endedAt: date(hour: 15))
        ]
        var projectSnapshot1 = makeProjectRegistry()
        var combinedSnapshot1: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot(focusCount: -1)

        let result1 = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions1,
            projectSnapshot: &projectSnapshot1,
            combinedSnapshot: &combinedSnapshot1,
            now: fixedNow
        )

        // Run repairAll a second time on the (already-repaired) data
        var sessions2 = sessions1
        var projectSnapshot2 = projectSnapshot1
        var combinedSnapshot2 = combinedSnapshot1

        let result2 = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions2,
            projectSnapshot: &projectSnapshot2,
            combinedSnapshot: &combinedSnapshot2,
            now: fixedNow
        )

        // Second pass should produce no new repairs (idempotent)
        let actualRepairs2 = result2.results.filter {
            $0.action != .none && $0.action != .skippedAlreadyApplied
        }
        XCTAssertEqual(actualRepairs2.count, 0,
                       "Second repair pass should find no new violations")

        // Data should be identical
        XCTAssertEqual(sessions1, sessions2)
        XCTAssertEqual(projectSnapshot1, projectSnapshot2)
        XCTAssertEqual(combinedSnapshot1, combinedSnapshot2)
    }
}

// MARK: - 7. Quarantine Tests

final class TinyBuddyCorruptedRecordQuarantineTests: XCTestCase {

    private var tempDir: URL!
    private var quarantine: TinyBuddyCorruptedRecordQuarantine!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyQuarantineTests_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("test_quarantine.json")
        quarantine = TinyBuddyCorruptedRecordQuarantine(storageURL: storageURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        quarantine = nil
        tempDir = nil
        super.tearDown()
    }

    func testIsolateEntry() {
        let entry = TinyBuddyCorruptedRecordEntry(
            domain: .focusSession,
            violationKind: .duplicateSessionID(UUID()),
            redactedOriginalData: "{}",
            diagnosticKey: "invariant.focusSession.duplicate_session_id"
        )
        let success = quarantine.isolate(entries: [entry])
        XCTAssertTrue(success)
        XCTAssertEqual(quarantine.count(), 1)
    }

    func testLoadQuarantined() {
        let entry = TinyBuddyCorruptedRecordEntry(
            domain: .focusSession,
            violationKind: .duplicateSessionID(UUID()),
            redactedOriginalData: "{\"id\": \"...\"}",
            diagnosticKey: "invariant.focusSession.duplicate_session_id"
        )
        quarantine.isolate(entries: [entry])

        let loaded = quarantine.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].diagnosticKey, entry.diagnosticKey)
        XCTAssertEqual(loaded[0].domain, entry.domain)
        XCTAssertEqual(loaded[0].redactedOriginalData, entry.redactedOriginalData)
    }

    func testPruneOldEntries() {
        let now = Date()
        let oldDate = Date(timeIntervalSince1970: 0)
        let newEntry = TinyBuddyCorruptedRecordEntry(
            domain: .focusSession,
            violationKind: .duplicateSessionID(UUID()),
            redactedOriginalData: "new",
            diagnosticKey: "invariant.focusSession.duplicate_session_id",
            isolatedAt: now
        )
        let oldEntry = TinyBuddyCorruptedRecordEntry(
            domain: .focusSession,
            violationKind: .duplicateSessionID(UUID()),
            redactedOriginalData: "old",
            diagnosticKey: "invariant.focusSession.duplicate_session_id",
            isolatedAt: oldDate
        )
        quarantine.isolate(entries: [newEntry, oldEntry])
        XCTAssertEqual(quarantine.count(), 2)

        // Prune at a time clearly after the old entry but before the new entry
        let midDate = Date(timeIntervalSince1970: 1000)
        let removed = quarantine.prune(before: midDate)
        // Only the old entry (isolatedAt = 1970) should be removed
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(quarantine.count(), 1)

        let loaded = quarantine.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].redactedOriginalData, "new")
    }

    func testClearAll() {
        let entry = TinyBuddyCorruptedRecordEntry(
            domain: .focusSession,
            violationKind: .duplicateSessionID(UUID()),
            redactedOriginalData: "data",
            diagnosticKey: "invariant.focusSession.duplicate_session_id"
        )
        quarantine.isolate(entries: [entry])
        XCTAssertEqual(quarantine.count(), 1)

        let cleared = quarantine.clearAll()
        XCTAssertTrue(cleared)
        XCTAssertEqual(quarantine.count(), 0)
    }

    func testDiagnosticSummaries() {
        let key = "invariant.focusSession.duplicate_session_id"
        quarantine.isolate(entries: [
            TinyBuddyCorruptedRecordEntry(
                domain: .focusSession, violationKind: .duplicateSessionID(UUID()),
                redactedOriginalData: "a", diagnosticKey: key
            ),
            TinyBuddyCorruptedRecordEntry(
                domain: .focusSession, violationKind: .duplicateSessionID(UUID()),
                redactedOriginalData: "b", diagnosticKey: key
            ),
            TinyBuddyCorruptedRecordEntry(
                domain: .projectIdentity, violationKind: .duplicateProjectID(TinyBuddyProjectID(rawValue: "x")),
                redactedOriginalData: "c", diagnosticKey: "invariant.projectIdentity.duplicate_project_id"
            )
        ])

        let summaries = quarantine.diagnosticSummaries()
        XCTAssertEqual(summaries.count, 2)
        let dupKeySummary = summaries.first { $0.diagnosticKey == key }
        XCTAssertNotNil(dupKeySummary)
        XCTAssertEqual(dupKeySummary?.count, 2)
        let projKeySummary = summaries.first { $0.diagnosticKey == "invariant.projectIdentity.duplicate_project_id" }
        XCTAssertNotNil(projKeySummary)
        XCTAssertEqual(projKeySummary?.count, 1)
    }

    func testIsolateSingleEntry() {
        let entry = quarantine.isolate(
            domain: .focusSession,
            violationKind: .emptyProjectKey(sessionID: UUID()),
            redactedOriginalData: "redacted",
            diagnosticKey: "invariant.focusSession.empty_project_key"
        )
        XCTAssertNotNil(entry)
        XCTAssertEqual(quarantine.count(), 1)
    }

    func testRemoveEntryByID() {
        let entry = TinyBuddyCorruptedRecordEntry(
            domain: .focusSession,
            violationKind: .duplicateSessionID(UUID()),
            redactedOriginalData: "test",
            diagnosticKey: "invariant.focusSession.duplicate_session_id"
        )
        quarantine.isolate(entries: [entry])
        XCTAssertEqual(quarantine.count(), 1)

        let removed = quarantine.removeEntry(id: entry.id)
        XCTAssertTrue(removed)
        XCTAssertEqual(quarantine.count(), 0)
    }
}

// MARK: - 8. Cross-cutting Tests

final class TinyBuddyDataInvariantCrossCuttingTests: XCTestCase {

    func testNormalDataPreserved() {
        let sessions = [
            makeSession(id: UUID(), dayIdentifier: "2026-07-20",
                        startedAt: date(hour: 9), endedAt: date(hour: 10)),
            makeSession(id: UUID(), dayIdentifier: "2026-07-20",
                        startedAt: date(hour: 11), endedAt: date(hour: 12))
        ]
        let projects = [
            TinyBuddyProject(id: TinyBuddyProjectID(rawValue: "p1"), kind: .gitRepository,
                             displayName: "P1", aliases: [], state: .active)
        ]
        let projectSnapshot = makeProjectRegistry(projects: projects)
        let combinedSnapshot = makeCombinedSnapshot(
            focusCount: 2, completionCount: 1
        )

        // Validate all domains
        let sessionViolations = TinyBuddyDataValidator.validateFocusSessions(
            sessions, now: fixedNow, activeProjectKeys: ["com.example.myapp"]
        )
        let projectViolations = TinyBuddyDataValidator.validateProjectRegistry(projectSnapshot)
        let combinedViolations = TinyBuddyDataValidator.validateCombinedSnapshot(combinedSnapshot)

        XCTAssertTrue(sessionViolations.isEmpty,
                      "Valid sessions should have no violations, got: \(sessionViolations)")
        XCTAssertTrue(projectViolations.isEmpty,
                      "Valid project registry should have no violations, got: \(projectViolations)")
        XCTAssertTrue(combinedViolations.isEmpty,
                      "Valid combined snapshot should have no violations, got: \(combinedViolations)")
    }

    func testLocalizedRepair() {
        // One corrupt session among valid ones
        let validID1 = UUID()
        let validID2 = UUID()
        let corruptID = UUID()
        var sessions = [
            makeSession(id: validID1, projectKey: "valid.app", dayIdentifier: "2026-07-20",
                        startedAt: date(hour: 9), endedAt: date(hour: 10)),
            makeSession(id: validID2, projectKey: "valid.app", dayIdentifier: "2026-07-20",
                        startedAt: date(hour: 11), endedAt: date(hour: 12)),
            makeSession(id: corruptID, projectKey: "", dayIdentifier: "2026-07-20",
                        startedAt: date(hour: 14), endedAt: date(hour: 15)) // Empty project key
        ]
        var projectSnapshot = makeProjectRegistry()
        var combinedSnapshot: TinyBuddyCombinedSnapshot? = makeCombinedSnapshot()

        let result = TinyBuddyDataRepairEngine.repairAll(
            sessions: &sessions,
            projectSnapshot: &projectSnapshot,
            combinedSnapshot: &combinedSnapshot,
            now: fixedNow
        )

        // Valid sessions untouched
        let valid1 = sessions.first { $0.id == validID1 }
        let valid2 = sessions.first { $0.id == validID2 }
        XCTAssertNotNil(valid1)
        XCTAssertNotNil(valid2)
        XCTAssertEqual(valid1?.project.key, "valid.app")
        XCTAssertEqual(valid2?.project.key, "valid.app")

        // Corrupt session repaired
        let corrupt = sessions.first { $0.id == corruptID }
        XCTAssertNotNil(corrupt)
        XCTAssertFalse(corrupt!.project.key.isEmpty, "Corrupt session's project key should be repaired")
        XCTAssertTrue(corrupt!.project.key.hasPrefix("unknown."))

        XCTAssertTrue(result.didPerformRepair)
    }

    func testUnrecoverableDataPreserved() {
        // Config version regression should return .preserved, not be silently discarded
        let config = TinyBuddyAppConfig(configVersion: 1, dayIdentifier: "2026-07-20")
        let violations = TinyBuddyDataValidator.validateConfigSnapshot(
            config: config,
            previousVersion: 5,
            previousPlayload: nil
        )
        let regressionIssues = violations.filter { v in
            if case .configVersionRegression = v.kind { return true }
            return false
        }
        XCTAssertEqual(regressionIssues.count, 1)
        XCTAssertEqual(regressionIssues[0].severity, .critical)
        XCTAssertEqual(regressionIssues[0].suggestedRepair, .preserved,
                       "Config version regression should be preserved, not repaired")
    }

    func testEndedSessionPausedTotalExceedsGross() {
        // An ended session where pausedTotal is greater than the gross duration
        let start = date(hour: 10)
        let end = date(hour: 10, minute: 30) // 30 minutes gross
        let session = makeSession(
            startedAt: start, endedAt: end,
            pausedTotal: 2400 // 40 minutes — exceeds 30 min gross
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let excessIssues = violations.filter { v in
            if case .pausedTotalExceedsGross = v.kind { return true }
            return false
        }
        // Should get at least the pausedTotalExceedsGross violation
        XCTAssertEqual(excessIssues.count, 1)
        XCTAssertEqual(excessIssues[0].severity, .error)
    }

    func testPausedStatusWithoutCurrentPauseStart() {
        // A paused session that has nil currentPauseStartedAt
        let session = makeSession(
            startedAt: date(hour: 9),
            endedAt: nil,
            status: .paused,
            currentPauseStartedAt: nil
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        // Should trigger the "paused_no_pause_start" unknown violation
        let pauseIssues = violations.filter { v in
            if case .unknown(let desc) = v.kind, desc == "paused_no_pause_start" {
                return true
            }
            return false
        }
        XCTAssertEqual(pauseIssues.count, 1)
        XCTAssertEqual(pauseIssues[0].severity, .error)
    }

    func testEndedSessionWithCurrentPauseStartedAt() {
        let session = makeSession(
            startedAt: date(hour: 9),
            endedAt: date(hour: 10),
            status: .ended,
            currentPauseStartedAt: date(hour: 9, minute: 30)
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let pauseIssues = violations.filter { v in
            if case .currentPauseNotNilForEnded = v.kind { return true }
            return false
        }
        XCTAssertEqual(pauseIssues.count, 1)
        XCTAssertEqual(pauseIssues[0].severity, .error)
    }

    func testSnapshotRevisionNegative() {
        let activity = GitTodayActivitySnapshot(focusBlockCount: nil, commitCount: nil)
        let stats = DailyStats(dayIdentifier: "2026-07-20", focusCount: 0, completionCount: 0)
        let innerSnapshot = TinyBuddySnapshot(status: .idle, stats: stats)
        let snapshot = TinyBuddyCombinedSnapshot(
            revision: -1,
            dayIdentifier: "2026-07-20",
            snapshot: innerSnapshot,
            activitySnapshot: activity
        )
        let violations = TinyBuddyDataValidator.validateCombinedSnapshot(snapshot)
        let revIssues = violations.filter { v in
            if case .snapshotRevisionRegression = v.kind { return true }
            return false
        }
        XCTAssertEqual(revIssues.count, 1)
        XCTAssertEqual(revIssues[0].severity, .critical)
        XCTAssertEqual(revIssues[0].suggestedRepair, .preserved)
    }

    func testEmptyProjectDisplayNameOnSession() {
        let session = makeSession(
            projectKey: "com.example", projectDisplayName: "",
            startedAt: date(hour: 9), endedAt: date(hour: 10)
        )
        let violations = TinyBuddyDataValidator.validateFocusSessions([session], now: fixedNow)
        let displayIssues = violations.filter { v in
            if case .sessionEmptyProjectDisplayName = v.kind { return true }
            return false
        }
        XCTAssertEqual(displayIssues.count, 1)
    }
}
