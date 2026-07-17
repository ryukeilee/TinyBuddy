import Foundation
import XCTest

final class ReleaseWorkflowHardeningTests: XCTestCase {
    func testValidateReleaseInstallPathsRejectsRegularFileAndDanglingSymlink() throws {
        let script = try buildAndRunScript()
        let function = try XCTUnwrap(shellFunction(named: "validate_release_install_paths", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleasePathTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let installedApp = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        try Data("not-an-app".utf8).write(to: installedApp)

        let regularFileResult = try runBash("""
        APP_NAME=TinyBuddy
        INSTALL_DIR=\(shellQuote(temporaryDirectory.path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        \(function)
        validate_release_install_paths
        """)

        XCTAssertEqual(regularFileResult.exitCode, 2)
        XCTAssertTrue(regularFileResult.standardError.contains("non-directory or symlink"))

        try FileManager.default.removeItem(at: installedApp)
        try FileManager.default.createSymbolicLink(
            at: installedApp,
            withDestinationURL: temporaryDirectory.appendingPathComponent("missing-target")
        )

        let danglingSymlinkResult = try runBash("""
        APP_NAME=TinyBuddy
        INSTALL_DIR=\(shellQuote(temporaryDirectory.path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        \(function)
        validate_release_install_paths
        """)

        XCTAssertEqual(danglingSymlinkResult.exitCode, 2)
        XCTAssertTrue(danglingSymlinkResult.standardError.contains("non-directory or symlink"))
    }

    func testReleasePathsStayOnTheFrozenCanonicalTargetAfterAliasRetarget() throws {
        let function = try XCTUnwrap(
            shellFunction(named: "validate_release_install_paths", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyCanonicalInstallTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let targetA = temporaryDirectory.appendingPathComponent("target-a")
        let targetB = temporaryDirectory.appendingPathComponent("target-b")
        let alias = temporaryDirectory.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: targetA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetB, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: targetA)

        let result = try runBash("""
        APP_NAME=TinyBuddy
        INSTALL_DIR=\(shellQuote(alias.path))
        INSTALLED_APP="$INSTALL_DIR/TinyBuddy.app"
        RELEASE_CANONICAL_INSTALL_DIR=""
        \(function)
        validate_release_install_paths || exit $?
        first_install_dir="$INSTALL_DIR"
        /bin/rm \(shellQuote(alias.path))
        /bin/ln -s \(shellQuote(targetB.path)) \(shellQuote(alias.path))
        validate_release_install_paths || exit $?
        printf 'first=%s\nsecond=%s\ninstalled=%s\n' \
          "$first_install_dir" "$INSTALL_DIR" "$INSTALLED_APP"
        """)
        let output = Dictionary(uniqueKeysWithValues: result.standardOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            })
        let first = try XCTUnwrap(output["first"])
        let second = try XCTUnwrap(output["second"])
        let installed = try XCTUnwrap(output["installed"])

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(first, second)
        XCTAssertEqual(installed, "\(first)/TinyBuddy.app")
        XCTAssertTrue(first.hasSuffix("/target-a"))
        XCTAssertFalse(second.hasSuffix("/target-b"))
    }

    func testDefaultReleaseDerivedDataIsNamespacedByCanonicalRootAndInstallTarget() throws {
        let script = try buildAndRunScript()
        let defaultFunction = try XCTUnwrap(
            shellFunction(named: "default_derived_data_dir", in: script)
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyDerivedDataNamespaceTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let rootA = temporaryDirectory.appendingPathComponent("root-a")
        let rootB = temporaryDirectory.appendingPathComponent("root-b")
        let installA = temporaryDirectory.appendingPathComponent("install-a")
        let installB = temporaryDirectory.appendingPathComponent("install-b")
        for directory in [rootA, rootB, installA, installB] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func derivedData(root: URL, install: URL) throws -> String {
            let result = try runBash("""
            ROOT_DIR=\(shellQuote(root.path))
            SIGNING_MODE=signed
            TMPDIR=\(shellQuote(temporaryDirectory.path))
            RELEASE_CANONICAL_INSTALL_DIR=\(shellQuote(install.path))
            \(defaultFunction)
            default_derived_data_dir
            """)
            XCTAssertEqual(result.exitCode, 0, result.standardError)
            return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let first = try derivedData(root: rootA, install: installA)
        XCTAssertEqual(first, try derivedData(root: rootA, install: installA))
        XCTAssertNotEqual(first, try derivedData(root: rootA, install: installB))
        XCTAssertNotEqual(first, try derivedData(root: rootB, install: installA))
    }

    func testReleaseFlockRejectsConcurrentOwnerAndRecoversAfterOwnerDeath() throws {
        let script = try buildAndRunScript()
        let validateFunction = try XCTUnwrap(
            shellFunction(named: "validate_release_install_paths", in: script)
        )
        let acquireFunction = try XCTUnwrap(shellFunction(named: "acquire_release_lock", in: script))
        let releaseFunction = try XCTUnwrap(shellFunction(named: "release_release_lock", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseLockTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let probe = temporaryDirectory.appendingPathComponent("lock-probe.sh")
        let ready = temporaryDirectory.appendingPathComponent("holder-ready")
        try Data("""
        #!/bin/bash
        set -u
        APP_NAME=TinyBuddy
        MODE=release-acceptance
        INSTALL_DIR=\(shellQuote(temporaryDirectory.path))
        INSTALLED_APP="$INSTALL_DIR/TinyBuddy.app"
        RELEASE_CANONICAL_INSTALL_DIR=""
        RELEASE_LOCK_DIR=""
        RELEASE_LOCK_FILE=""
        RELEASE_LOCK_HELD=0
        RELEASE_LOCK_PERL_BIN=/usr/bin/perl
        \(validateFunction)
        \(acquireFunction)
        \(releaseFunction)
        case "$1" in
          hold)
            acquire_release_lock || exit $?
            : >\(shellQuote(ready.path))
            /bin/kill -STOP "$$"
            ;;
          once)
            acquire_release_lock || exit $?
            release_release_lock
            ;;
          *) exit 64 ;;
        esac
        """.utf8).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)

        let result = try runBash("""
        \(shellQuote(probe.path)) hold &
        holder_pid=$!
        attempts=0
        while [ ! -f \(shellQuote(ready.path)) ] && [ "$attempts" -lt 100 ]; do
          /bin/sleep 0.05
          attempts=$((attempts + 1))
        done
        [ -f \(shellQuote(ready.path)) ] || exit 91
        \(shellQuote(probe.path)) once
        busy_status=$?
        /bin/kill -KILL "$holder_pid"
        wait "$holder_pid" >/dev/null 2>&1 || true
        \(shellQuote(probe.path)) once
        recovered_status=$?
        printf 'busy_status=%s recovered_status=%s\n' "$busy_status" "$recovered_status"
        exit 0
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("busy_status=75 recovered_status=0"))
        XCTAssertTrue(result.standardError.contains("release workflow is active"))
        let lockDirectory = temporaryDirectory.appendingPathComponent(".TinyBuddy.release.lock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockDirectory.path))
        XCTAssertTrue(
            try String(contentsOf: lockDirectory.appendingPathComponent("owner"), encoding: .utf8)
                .contains("flock-v1")
        )
    }

    func testReleaseStagePipelineStopsOnFailureAndCommitsEvidenceOnlyAfterCompleteSuccess() throws {
        let script = try buildAndRunScript()
        let evidenceFunctions = try XCTUnwrap(scriptSection(
            startingAt: "initialize_release_evidence() {",
            endingBefore: "\nrollback_release_install() {",
            in: script
        ))
        let pipelineFunctions = try XCTUnwrap(scriptSection(
            startingAt: "run_release_acceptance_stages() {",
            endingBefore: "\ncase \"$MODE\" in",
            in: script
        ))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleasePipelineTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let failureRoot = temporaryDirectory.appendingPathComponent("failure-evidence")
        let failureCalls = temporaryDirectory.appendingPathComponent("failure-calls")
        let failureResult = try runBash(releasePipelineProbe(
            evidenceFunctions: evidenceFunctions,
            pipelineFunctions: pipelineFunctions,
            evidenceRoot: failureRoot,
            callsFile: failureCalls,
            failingStageFunction: "build_current_app"
        ))

        XCTAssertEqual(failureResult.exitCode, 0, failureResult.standardError)
        XCTAssertTrue(failureResult.standardOutput.contains("workflow_status=23"))
        XCTAssertEqual(try lines(in: failureCalls), ["swift-test", "release-build"])
        let failureEvidence = try onlyChildDirectory(of: failureRoot)
        XCTAssertEqual(
            try statusValue("state", in: failureEvidence.appendingPathComponent("01-swift-test.status")),
            "passed"
        )
        XCTAssertEqual(
            try statusValue("state", in: failureEvidence.appendingPathComponent("02-release-build.status")),
            "failed"
        )
        XCTAssertEqual(
            try statusValue("exit_status", in: failureEvidence.appendingPathComponent("02-release-build.status")),
            "23"
        )
        XCTAssertEqual(
            try statusValue("state", in: failureEvidence.appendingPathComponent("overall.status")),
            "failed"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: failureEvidence.appendingPathComponent("03-candidate-contract.status").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: failureEvidence.appendingPathComponent("release-complete").path
        ))

        let successRoot = temporaryDirectory.appendingPathComponent("success-evidence")
        let successCalls = temporaryDirectory.appendingPathComponent("success-calls")
        let successResult = try runBash(releasePipelineProbe(
            evidenceFunctions: evidenceFunctions,
            pipelineFunctions: pipelineFunctions,
            evidenceRoot: successRoot,
            callsFile: successCalls,
            failingStageFunction: nil
        ))

        XCTAssertEqual(successResult.exitCode, 0, successResult.standardError)
        XCTAssertTrue(successResult.standardOutput.contains("workflow_status=0"))
        XCTAssertEqual(try lines(in: successCalls), [
            "swift-test",
            "release-build",
            "candidate-contract",
            "environment-preflight",
            "primary-install",
            "same-version-reinstall",
            "final-fresh-verification"
        ])
        let successEvidence = try onlyChildDirectory(of: successRoot)
        XCTAssertEqual(
            try statusValue("state", in: successEvidence.appendingPathComponent("overall.status")),
            "passed"
        )
        XCTAssertEqual(
            try statusValue("stage_count", in: successEvidence.appendingPathComponent("overall.status")),
            "7"
        )
        XCTAssertEqual(
            try statusValue("state", in: successEvidence.appendingPathComponent("release-complete")),
            "passed"
        )
    }

    func testReleaseWorkflowFailsWhenPassingEvidenceCannotBeCommitted() throws {
        let workflowFunction = try XCTUnwrap(
            shellFunction(named: "run_locked_release_workflow", in: try buildAndRunScript())
        )
        let result = try runBash("""
        RELEASE_EVIDENCE_DIR=/tmp/TinyBuddyEvidenceFinalizationProbe
        RELEASE_LOCK_HELD=0
        RELEASE_LOCK_DIR=""
        RELEASE_ACTIVE_STAGE_PID=""
        RELEASE_SIGNAL_NAME=""
        RELEASE_SIGNAL_STATUS=0
        RELEASE_SIGNAL_FORWARDED=0
        acquire_release_lock() { RELEASE_LOCK_HELD=1; return 0; }
        release_release_lock() { RELEASE_LOCK_HELD=0; return 0; }
        initialize_release_evidence() { return 0; }
        initialize_build_artifact_paths() { return 0; }
        record_release_signal() { return 0; }
        finish_release_evidence() {
          printf 'finish=%s:%s\n' "$1" "$2"
          [ "$1" != passed ] || return 73
        }
        successful_stages() { return 0; }
        \(workflowFunction)
        run_locked_release_workflow successful_stages
        workflow_status=$?
        printf 'workflow_status=%s\n' "$workflow_status"
        exit 0
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("finish=passed:0"))
        XCTAssertTrue(result.standardOutput.contains("finish=failed:73"))
        XCTAssertTrue(result.standardOutput.contains("workflow_status=73"))
        XCTAssertFalse(result.standardOutput.contains("workflow_status=0"))
        XCTAssertTrue(result.standardError.contains("final evidence could not be committed"))
    }

    func testParentTermWaitsForStageRollbackBeforeEvidenceAndLockRelease() throws {
        let script = try buildAndRunScript()
        let stageFunctions = try [
            "write_release_status_file",
            "write_release_stage_status",
            "forward_pending_release_signal_to_stage",
            "record_release_signal",
            "run_release_stage"
        ].map { try XCTUnwrap(shellFunction(named: $0, in: script)) }
            .joined(separator: "\n")
        let workflowFunction = try XCTUnwrap(
            shellFunction(named: "run_locked_release_workflow", in: script)
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyParentSignalTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let probe = temporaryDirectory.appendingPathComponent("signal-probe.sh")
        let evidence = temporaryDirectory.appendingPathComponent("evidence")
        let events = temporaryDirectory.appendingPathComponent("events")
        let ready = temporaryDirectory.appendingPathComponent("ready")
        let childPID = temporaryDirectory.appendingPathComponent("stage-child-pid")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)

        try Data("""
        #!/bin/bash
        set -u
        MODE=release-acceptance
        RELEASE_EVIDENCE_DIR=\(shellQuote(evidence.path))
        RELEASE_COMPLETION_MARKER="$RELEASE_EVIDENCE_DIR/release-complete"
        RELEASE_STAGE_INDEX=0
        RELEASE_LOCK_HELD=0
        RELEASE_LOCK_DIR=""
        RELEASE_ACTIVE_STAGE_PID=""
        RELEASE_SIGNAL_NAME=""
        RELEASE_SIGNAL_STATUS=0
        RELEASE_SIGNAL_FORWARDED=0
        EVENTS=\(shellQuote(events.path))
        READY=\(shellQuote(ready.path))
        CHILD_PID_FILE=\(shellQuote(childPID.path))
        acquire_release_lock() { RELEASE_LOCK_HELD=1; echo lock-acquired >>"$EVENTS"; }
        release_release_lock() { RELEASE_LOCK_HELD=0; echo lock-released >>"$EVENTS"; }
        initialize_release_evidence() { return 0; }
        initialize_build_artifact_paths() { return 0; }
        finish_release_evidence() {
          printf 'evidence-%s-%s\n' "$1" "$2" >>"$EVENTS"
          return 0
        }
        rollback_stage() {
          trap - EXIT
          trap '' HUP INT TERM
          echo rollback-start >>"$EVENTS"
          /bin/sleep 0.2
          echo rollback-done >>"$EVENTS"
        }
        interruptible_stage() {
          trap rollback_stage EXIT
          trap 'exit 143' TERM
          /bin/sleep 30 &
          stage_child=$!
          printf '%s\n' "$stage_child" >"$CHILD_PID_FILE"
          echo stage-ready >>"$EVENTS"
          : >"$READY"
          wait "$stage_child"
        }
        \(stageFunctions)
        signal_workflow() { run_release_stage signal-stage interruptible_stage; }
        \(workflowFunction)
        run_locked_release_workflow signal_workflow
        exit $?
        """.utf8).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)

        let result = try runBash("""
        \(shellQuote(probe.path)) &
        workflow_pid=$!
        attempts=0
        while [ ! -f \(shellQuote(ready.path)) ] && [ "$attempts" -lt 100 ]; do
          /bin/sleep 0.05
          attempts=$((attempts + 1))
        done
        [ -f \(shellQuote(ready.path)) ] || exit 91
        /bin/kill -TERM "$workflow_pid"
        wait "$workflow_pid"
        workflow_status=$?
        stage_child=$(/bin/cat \(shellQuote(childPID.path)))
        if /bin/kill -0 "$stage_child" 2>/dev/null; then
          child_alive=1
          /bin/kill -KILL "$stage_child" 2>/dev/null || true
        else
          child_alive=0
        fi
        printf 'workflow_status=%s child_alive=%s\n' "$workflow_status" "$child_alive"
        exit 0
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("workflow_status=143 child_alive=0"))
        XCTAssertEqual(try lines(in: events), [
            "lock-acquired",
            "stage-ready",
            "rollback-start",
            "rollback-done",
            "evidence-failed-143",
            "lock-released"
        ])
    }

    func testRollbackPreservesTheOnlyPreviousBundleWhenCandidateRemovalFails() throws {
        let script = try buildAndRunScript()
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyRollbackPreservationTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let installDirectory = temporaryDirectory.appendingPathComponent("install")
        let installedApp = installDirectory.appendingPathComponent("TinyBuddy.app")
        let transaction = installDirectory.appendingPathComponent(".TinyBuddy.install.4242")
        let backup = transaction.appendingPathComponent("TinyBuddy.backup.app")
        let fakeRM = temporaryDirectory.appendingPathComponent("fake-rm.sh")
        try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("candidate".utf8).write(to: installedApp.appendingPathComponent("marker"))
        try Data("previous".utf8).write(to: backup.appendingPathComponent("marker"))
        try Data("""
        #!/bin/bash
        last=""
        for argument in "$@"; do
          last="$argument"
        done
        if [ "$last" = "$FAIL_REMOVE_PATH" ]; then
          exit 74
        fi
        exec /bin/rm "$@"
        """.utf8).write(to: fakeRM)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRM.path)
        let rollback = try XCTUnwrap(
            shellFunction(named: "rollback_release_install", in: script)
        ).replacingOccurrences(of: "/bin/rm", with: shellQuote(fakeRM.path))

        let result = try runBash("""
        set -u
        APP_NAME=TinyBuddy
        INSTALL_DIR=\(shellQuote(installDirectory.path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        RELEASE_TRANSACTION_DIR=\(shellQuote(transaction.path))
        RELEASE_STAGED_APP="$RELEASE_TRANSACTION_DIR/TinyBuddy.app"
        RELEASE_BACKUP_APP=\(shellQuote(backup.path))
        RELEASE_HAD_PREVIOUS=1
        RELEASE_SWITCHED=1
        RELEASE_COMMITTED=0
        FAIL_REMOVE_PATH="$INSTALLED_APP"
        export FAIL_REMOVE_PATH
        stop_release_runtime() { return 0; }
        restore_release_runtime() { echo unexpected-restore; return 0; }
        unregister_widget_extensions() { echo unexpected-unregister; return 0; }
        \(rollback)
        rollback_release_install
        rollback_status=$?
        printf 'rollback_status=%s\n' "$rollback_status"
        exit 0
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("rollback_status=1"))
        XCTAssertFalse(result.standardOutput.contains("unexpected-restore"))
        XCTAssertEqual(
            try String(contentsOf: installedApp.appendingPathComponent("marker"), encoding: .utf8),
            "candidate"
        )
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("marker"), encoding: .utf8),
            "previous"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
        XCTAssertTrue(result.standardError.contains("recovery required"))
    }

    func testAuthorizationPreservationUsesStableV2IdentifiersInsteadOfBookmarkOrPathBytes() throws {
        let script = try buildAndRunScript()
        let identityFunctions = try XCTUnwrap(scriptSection(
            startingAt: "saved_git_scan_root_record_count() {",
            endingBefore: "\ngit_refresh_status_value() {",
            in: script
        ))
        let preservationFunction = try XCTUnwrap(
            shellFunction(named: "verify_authorization_record_preservation", in: script)
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyAuthorizationIdentityTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let before = temporaryDirectory.appendingPathComponent("before.plist")
        let sameIdentifiers = temporaryDirectory.appendingPathComponent("same-identifiers.plist")
        let changedIdentifiers = temporaryDirectory.appendingPathComponent("changed-identifiers.plist")
        try writeAuthorizationRecords(
            ids: ["root-b", "root-a"],
            bookmarkPrefix: "before-bookmark",
            pathPrefix: "/before/path",
            to: before
        )
        try writeAuthorizationRecords(
            ids: ["root-a", "root-b"],
            bookmarkPrefix: "replacement-bookmark",
            pathPrefix: "/moved/path",
            to: sameIdentifiers
        )
        try writeAuthorizationRecords(
            ids: ["root-a", "root-c"],
            bookmarkPrefix: "replacement-bookmark",
            pathPrefix: "/moved/path",
            to: changedIdentifiers
        )

        let beforeResult = try runBash(authorizationProbePreamble(
            identityFunctions: identityFunctions,
            preferences: before
        ) + """
        saved_git_scan_root_record_count
        saved_git_scan_root_record_identity
        """)
        let beforeLines = beforeResult.standardOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(beforeResult.exitCode, 0, beforeResult.standardError)
        XCTAssertEqual(beforeLines.count, 2)
        let beforeCount = try XCTUnwrap(beforeLines.first)
        let beforeIdentity = try XCTUnwrap(beforeLines.dropFirst().first)
        XCTAssertEqual(beforeCount, "2")
        XCTAssertTrue(beforeIdentity.hasPrefix("v2:"))

        let sameIdentifierResult = try runBash(authorizationProbePreamble(
            identityFunctions: identityFunctions,
            preferences: sameIdentifiers
        ) + """
        \(preservationFunction)
        verify_authorization_record_preservation 2 \(shellQuote(beforeIdentity))
        """)
        XCTAssertEqual(sameIdentifierResult.exitCode, 0, sameIdentifierResult.standardError)
        XCTAssertTrue(sameIdentifierResult.standardOutput.contains("identities=stable"))

        let changedIdentifierResult = try runBash(authorizationProbePreamble(
            identityFunctions: identityFunctions,
            preferences: changedIdentifiers
        ) + """
        \(preservationFunction)
        verify_authorization_record_preservation 2 \(shellQuote(beforeIdentity))
        """)
        XCTAssertEqual(changedIdentifierResult.exitCode, 1)
        XCTAssertTrue(changedIdentifierResult.standardError.contains("identities changed"))
    }

    func testPreflightLaunchItemDiscoveryIgnoresCustomFilenameAndLabel() throws {
        let script = try buildAndRunScript()
        let launchItemFunctions = try XCTUnwrap(scriptSection(
            startingAt: "launch_item_references_tinybuddy() {",
            endingBefore: "\nverify_release_environment_preflight() {",
            in: script
        ))
        let preflightFunction = try XCTUnwrap(
            shellFunction(named: "verify_release_environment_preflight", in: script)
        )
        XCTAssertTrue(preflightFunction.contains("find_tinybuddy_launch_item"))

        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyLaunchItemTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let userAgents = temporaryDirectory.appendingPathComponent("user-agents")
        let systemAgents = temporaryDirectory.appendingPathComponent("system-agents")
        let systemDaemons = temporaryDirectory.appendingPathComponent("system-daemons")
        try FileManager.default.createDirectory(at: userAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemDaemons, withIntermediateDirectories: true)

        let programPlist = userAgents.appendingPathComponent("custom-helper-name.plist")
        try writePropertyList([
            "Label": "org.example.unrelated.program-label",
            "Program": "/tmp/renamed/TinyBuddy.app/Contents/MacOS/TinyBuddy"
        ], to: programPlist)
        XCTAssertEqual(
            try discoveredLaunchItem(
                launchItemFunctions: launchItemFunctions,
                userAgents: userAgents,
                systemAgents: systemAgents,
                systemDaemons: systemDaemons
            ),
            programPlist.path
        )

        try FileManager.default.removeItem(at: programPlist)
        let argumentsPlist = systemDaemons.appendingPathComponent("nightly-maintenance.plist")
        try writePropertyList([
            "Label": "org.example.unrelated.arguments-label",
            "ProgramArguments": [
                "/usr/bin/open",
                "/tmp/renamed/TinyBuddy.app/Contents/MacOS/TinyBuddy"
            ]
        ], to: argumentsPlist)
        XCTAssertEqual(
            try discoveredLaunchItem(
                launchItemFunctions: launchItemFunctions,
                userAgents: userAgents,
                systemAgents: systemAgents,
                systemDaemons: systemDaemons
            ),
            argumentsPlist.path
        )
    }

    private func releasePipelineProbe(
        evidenceFunctions: String,
        pipelineFunctions: String,
        evidenceRoot: URL,
        callsFile: URL,
        failingStageFunction: String?
    ) -> String {
        let functions = [
            ("run_release_regression_tests", "swift-test"),
            ("build_current_app", "release-build"),
            ("verify_release_bundle", "candidate-contract"),
            ("verify_release_environment_preflight", "environment-preflight"),
            ("install_release_app", "primary-install"),
            ("install_same_version_release_app", "same-version-reinstall"),
            ("verify_release_app_fresh", "final-fresh-verification")
        ].map { function, stage in
            let result = function == failingStageFunction ? "return 23" : "return 0"
            return "\(function)() { echo \(stage) >>\"$CALLS_FILE\"; \(result); }"
        }.joined(separator: "\n")

        return """
        MODE=release-acceptance
        INSTALLED_APP=/tmp/TinyBuddyNeverInstalledByThisTest.app
        RELEASE_EVIDENCE_DIR=""
        RELEASE_STAGE_INDEX=0
        RELEASE_COMPLETION_MARKER=""
        RELEASE_LOCK_HELD=0
        RELEASE_LOCK_DIR=""
        RELEASE_ACTIVE_STAGE_PID=""
        RELEASE_SIGNAL_NAME=""
        RELEASE_SIGNAL_STATUS=0
        RELEASE_SIGNAL_FORWARDED=0
        TINYBUDDY_RELEASE_EVIDENCE_DIR=\(shellQuote(evidenceRoot.path))
        CALLS_FILE=\(shellQuote(callsFile.path))
        acquire_release_lock() { RELEASE_LOCK_HELD=1; return 0; }
        release_release_lock() { RELEASE_LOCK_HELD=0; return 0; }
        initialize_build_artifact_paths() { return 0; }
        \(functions)
        \(evidenceFunctions)
        \(pipelineFunctions)
        run_locked_release_workflow run_release_acceptance_stages
        workflow_status=$?
        echo "workflow_status=$workflow_status"
        exit 0
        """
    }

    private func authorizationProbePreamble(
        identityFunctions: String,
        preferences: URL
    ) -> String {
        let cacheRoot = preferences.deletingLastPathComponent().appendingPathComponent("module-cache")
        return """
        export CLANG_MODULE_CACHE_PATH=\(shellQuote(cacheRoot.appendingPathComponent("clang").path))
        export SWIFT_MODULECACHE_PATH=\(shellQuote(cacheRoot.appendingPathComponent("swift").path))
        APP_PREFERENCES_PLIST=\(shellQuote(preferences.path))
        GIT_SCAN_ROOT_RECORDS_KEY=tinybuddy.gitScanRoots.records.v2
        GIT_SCAN_ROOT_BOOKMARK_KEY=tinybuddy.gitScanRoots.bookmarkData
        \(identityFunctions)
        """
    }

    private func discoveredLaunchItem(
        launchItemFunctions: String,
        userAgents: URL,
        systemAgents: URL,
        systemDaemons: URL
    ) throws -> String {
        let result = try runBash("""
        BUNDLE_ID=com.ryukeili.TinyBuddy
        WIDGET_BUNDLE_ID=com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension
        APP_NAME=TinyBuddy
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        USER_LAUNCH_AGENTS_DIR=\(shellQuote(userAgents.path))
        SYSTEM_LAUNCH_AGENTS_DIR=\(shellQuote(systemAgents.path))
        SYSTEM_LAUNCH_DAEMONS_DIR=\(shellQuote(systemDaemons.path))
        \(launchItemFunctions)
        find_tinybuddy_launch_item
        """)
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeAuthorizationRecords(
        ids: [String],
        bookmarkPrefix: String,
        pathPrefix: String,
        to url: URL
    ) throws {
        let records: [[String: Any]] = ids.enumerated().map { index, id in
            [
                "id": id,
                "bookmarkData": Data("\(bookmarkPrefix)-\(index)".utf8),
                "displayName": "Root \(index)",
                "lastKnownPath": "\(pathPrefix)/\(index)"
            ]
        }
        try writePropertyList(["tinybuddy.gitScanRoots.records.v2": records], to: url)
    }

    private func statusValue(_ key: String, in url: URL) throws -> String? {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("\(key)=") })?
            .dropFirst(key.count + 1)
            .description
    }

    private func lines(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func onlyChildDirectory(of root: URL) throws -> URL {
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        return try XCTUnwrap(children.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }))
    }

    private func buildAndRunScript() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/build_and_run.sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func shellFunction(named name: String, in script: String) -> String? {
        let startMarker = "\(name)() {"
        guard let start = script.range(of: startMarker),
              let end = script.range(of: "\n}\n", range: start.lowerBound..<script.endIndex) else {
            return nil
        }
        return String(script[start.lowerBound..<end.upperBound])
    }

    private func scriptSection(
        startingAt startMarker: String,
        endingBefore endMarker: String,
        in script: String
    ) -> String? {
        guard let start = script.range(of: startMarker),
              let end = script.range(of: endMarker, range: start.lowerBound..<script.endIndex) else {
            return nil
        }
        return String(script[start.lowerBound..<end.lowerBound])
    }

    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix).\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePropertyList(_ propertyList: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try data.write(to: url)
    }

    private func runBash(_ script: String) throws -> (
        exitCode: Int32,
        standardOutput: String,
        standardError: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let standardError = Pipe()
        let standardOutput = Pipe()
        process.standardError = standardError
        process.standardOutput = standardOutput
        try process.run()
        process.waitUntilExit()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: outputData, encoding: .utf8) ?? "",
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
