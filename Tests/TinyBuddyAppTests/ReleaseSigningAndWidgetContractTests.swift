import Foundation
import XCTest

final class ReleaseSigningAndWidgetContractTests: XCTestCase {
    func testSigningContractAcceptsExpectedEntitlementsAndRejectsContractDrift() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddySigningContractTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let widget = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        let fakeCodesign = temporaryDirectory.appendingPathComponent("fake-codesign.sh")
        try writeExecutable(
            """
            #!/bin/bash
            set -eu
            signed_path="${@: -1}"
            if [ "$signed_path" = "$FAKE_APP_PATH" ]; then
              team="$FAKE_APP_TEAM"
              entitlements="$FAKE_APP_ENTITLEMENTS"
            elif [ "$signed_path" = "$FAKE_WIDGET_PATH" ]; then
              team="$FAKE_WIDGET_TEAM"
              entitlements="$FAKE_WIDGET_ENTITLEMENTS"
            else
              echo "unexpected fake codesign path: $signed_path" >&2
              exit 64
            fi
            case " $* " in
              *" --entitlements "*) /bin/cat "$entitlements" ;;
              *) printf 'TeamIdentifier=%s\nAuthority=%s\n' "$team" "$FAKE_SIGNING_AUTHORITY" ;;
            esac
            """,
            to: fakeCodesign
        )

        let valid = try runSigningContract(
            in: temporaryDirectory,
            app: app,
            widget: widget,
            fakeCodesign: fakeCodesign,
            appEntitlements: appEntitlements(),
            widgetEntitlements: widgetEntitlements()
        )
        XCTAssertEqual(valid.exitCode, 0, valid.standardError)
        XCTAssertTrue(valid.standardOutput.contains("verified signing identity and entitlements"))

        let wrongTeam = try runSigningContract(
            in: temporaryDirectory,
            app: app,
            widget: widget,
            fakeCodesign: fakeCodesign,
            appEntitlements: appEntitlements(),
            widgetEntitlements: widgetEntitlements(),
            widgetTeam: "WRONGTEAM"
        )
        XCTAssertEqual(wrongTeam.exitCode, 1)
        XCTAssertTrue(wrongTeam.standardError.contains("unexpected signing team"))

        var wrongGroupEntitlements = appEntitlements()
        wrongGroupEntitlements["com.apple.security.application-groups"] = ["group.invalid.TinyBuddy"]
        let wrongGroup = try runSigningContract(
            in: temporaryDirectory,
            app: app,
            widget: widget,
            fakeCodesign: fakeCodesign,
            appEntitlements: wrongGroupEntitlements,
            widgetEntitlements: widgetEntitlements()
        )
        XCTAssertEqual(wrongGroup.exitCode, 1)
        XCTAssertTrue(wrongGroup.standardError.contains("only the expected App Group"))

        var wrongGetTaskAllowEntitlements = appEntitlements()
        wrongGetTaskAllowEntitlements["com.apple.security.get-task-allow"] = false
        let wrongGetTaskAllow = try runSigningContract(
            in: temporaryDirectory,
            app: app,
            widget: widget,
            fakeCodesign: fakeCodesign,
            appEntitlements: wrongGetTaskAllowEntitlements,
            widgetEntitlements: widgetEntitlements()
        )
        XCTAssertEqual(wrongGetTaskAllow.exitCode, 1)
        XCTAssertTrue(
            wrongGetTaskAllow.standardError.contains(
                "unexpected signed entitlement com.apple.security.get-task-allow"
            )
        )

        var extraEntitlements = appEntitlements()
        extraEntitlements["com.apple.security.network.client"] = true
        let extraEntitlement = try runSigningContract(
            in: temporaryDirectory,
            app: app,
            widget: widget,
            fakeCodesign: fakeCodesign,
            appEntitlements: extraEntitlements,
            widgetEntitlements: widgetEntitlements()
        )
        XCTAssertEqual(extraEntitlement.exitCode, 1)
        XCTAssertTrue(extraEntitlement.standardError.contains("unexpected top-level keys"))
    }

    func testProfileFreeLocalSigningContractUsesExactSourceEntitlements() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyLocalSigningContractTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let widget = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        let fakeCodesign = temporaryDirectory.appendingPathComponent("fake-codesign.sh")
        try writeExecutable(
            """
            #!/bin/bash
            set -eu
            signed_path="${@: -1}"
            if [ "$signed_path" = "$FAKE_APP_PATH" ]; then
              entitlements="$FAKE_APP_ENTITLEMENTS"
            elif [ "$signed_path" = "$FAKE_WIDGET_PATH" ]; then
              entitlements="$FAKE_WIDGET_ENTITLEMENTS"
            else
              exit 64
            fi
            case " $* " in
              *" --entitlements "*) /bin/cat "$entitlements" ;;
              *) printf 'TeamIdentifier=JYL9G28DP3\nAuthority=Apple Development: Local Test\n' ;;
            esac
            """,
            to: fakeCodesign
        )

        let valid = try runSigningContract(
            in: temporaryDirectory,
            app: app,
            widget: widget,
            fakeCodesign: fakeCodesign,
            appEntitlements: localAppEntitlements(),
            widgetEntitlements: localWidgetEntitlements(),
            signingMode: "local"
        )
        XCTAssertEqual(valid.exitCode, 0, valid.standardError)
        XCTAssertTrue(valid.standardOutput.contains("mode=local"))

        var injectedProfileEntitlement = localAppEntitlements()
        injectedProfileEntitlement["com.apple.developer.team-identifier"] = "JYL9G28DP3"
        let rejectedEntitlement = try runSigningContract(
            in: temporaryDirectory,
            app: app,
            widget: widget,
            fakeCodesign: fakeCodesign,
            appEntitlements: injectedProfileEntitlement,
            widgetEntitlements: localWidgetEntitlements(),
            signingMode: "local"
        )
        XCTAssertEqual(rejectedEntitlement.exitCode, 1)
        XCTAssertTrue(rejectedEntitlement.standardError.contains("unexpected top-level keys"))

        let embeddedProfile = app.appendingPathComponent("Contents/embedded.provisionprofile")
        try Data("unexpected-profile".utf8).write(to: embeddedProfile)
        let rejectedProfile = try runSigningContract(
            in: temporaryDirectory,
            app: app,
            widget: widget,
            fakeCodesign: fakeCodesign,
            appEntitlements: localAppEntitlements(),
            widgetEntitlements: localWidgetEntitlements(),
            signingMode: "local"
        )
        XCTAssertEqual(rejectedProfile.exitCode, 1)
        XCTAssertTrue(rejectedProfile.standardError.contains("rejects embedded provisioning profiles"))
    }

    func testWidgetRegistrationAddsTargetForCleanInstallAndConverges() throws {
        let probe = try runWidgetRegistrationProbe(
            startsWithStaleRecord: false,
            allowsRegistrationAdd: true
        )

        XCTAssertEqual(probe.result.exitCode, 0, probe.result.standardError)
        XCTAssertEqual(
            try String(contentsOf: probe.stateFile, encoding: .utf8),
            "\(probe.widget.path)\n"
        )
        let commands = try String(contentsOf: probe.commandLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(commands.first, "-a \(probe.widget.path)")
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(probe.result.standardOutput.contains("registered unique widget extension"))
    }

    func testWidgetRegistrationRefusesStaleRecordWithoutMutation() throws {
        let probe = try runWidgetRegistrationProbe()

        XCTAssertEqual(probe.result.exitCode, 1)
        XCTAssertTrue(probe.result.standardError.contains(
            "refusing to replace existing Widget registrations automatically"
        ))
        XCTAssertEqual(
            try String(contentsOf: probe.stateFile, encoding: .utf8),
            "/tmp/stale-tinybuddy-widget.appex\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.commandLog.path))
    }

    func testWidgetRegistrationRejectsDuplicateTargetRecords() throws {
        let probe = try runWidgetRegistrationProbe(
            duplicateTargetOnAdd: true,
            startsWithStaleRecord: false,
            allowsRegistrationAdd: true
        )

        XCTAssertEqual(probe.result.exitCode, 1)
        XCTAssertTrue(probe.result.standardError.contains("registration is not unique"))
        XCTAssertTrue(probe.result.standardError.contains("registered_count=2"))
    }

    func testProductionWidgetRegistrationParserPreservesDuplicateRecordsAtTheSamePath() throws {
        let parser = try XCTUnwrap(
            shellFunction(named: "registered_widget_paths", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyPluginKitParserTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fakePluginKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")
        let expectedPath = "/tmp/Tiny Buddy.app/Contents/PlugIns/TinyBuddyWidgetExtension.appex"
        try writeExecutable(
            """
            #!/bin/bash
            printf 'record-a\\tmetadata-a\\t  %s  \\n' "$EXPECTED_WIDGET_PATH"
            printf 'record-b\\tmetadata-b\\t%s\\n' "$EXPECTED_WIDGET_PATH"
            """,
            to: fakePluginKit
        )

        let result = try runBash("""
        set -euo pipefail
        PLUGINKIT_BIN=\(shellQuote(fakePluginKit.path))
        WIDGET_BUNDLE_ID=com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension
        EXPECTED_WIDGET_PATH=\(shellQuote(expectedPath))
        export EXPECTED_WIDGET_PATH
        \(parser)
        registered_widget_paths
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(result.standardOutput, "\(expectedPath)\n\(expectedPath)\n")
    }

    func testWidgetRegistrationRejectsExistingDuplicateTargetWithoutMutation() throws {
        let probe = try runWidgetRegistrationProbe(
            startsWithStaleRecord: false,
            startsWithDuplicateTargetRecord: true
        )

        XCTAssertEqual(probe.result.exitCode, 1)
        XCTAssertTrue(probe.result.standardError.contains(
            "refusing to replace existing Widget registrations automatically"
        ))
        XCTAssertTrue(probe.result.standardError.contains("registered_count=2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.commandLog.path))
    }

    func testInstallRegistrationIgnoresOnlyTheBuildProductRecordForACleanInstall() throws {
        let probe = try runInstallRegistrationDecision(
            initialRecords: [.buildProduct],
            installedAppExists: false,
            allowsRegistrationAdd: true
        )
        defer { try? FileManager.default.removeItem(at: probe.temporaryDirectory) }

        XCTAssertEqual(probe.result.exitCode, 0, probe.result.standardError)
        XCTAssertTrue(probe.result.standardOutput.contains("preflight=accepted"))
        XCTAssertTrue(probe.result.standardOutput.contains("registration=accepted preserved=0 attempted=1"))
        XCTAssertTrue(probe.result.standardError.contains(
            "ignoring the build-product Widget registration"
        ))
        // The ignored record is left untouched and the clean install adds the target record.
        XCTAssertEqual(probe.registeredRecords, [probe.buildArtifactRecord, probe.installedAppex.path])
        XCTAssertTrue(probe.plugInKitCommands.contains("-a \(probe.installedAppex.path)"))
        XCTAssertFalse(probe.plugInKitCommands.contains("-r "))
    }

    func testInstallRegistrationFailsClosedWhenAnExistingInstallHasOnlyTheBuildProductRecord() throws {
        let probe = try runInstallRegistrationDecision(
            initialRecords: [.buildProduct],
            installedAppExists: true
        )
        defer { try? FileManager.default.removeItem(at: probe.temporaryDirectory) }

        XCTAssertEqual(probe.result.exitCode, 0, probe.result.standardError)
        XCTAssertTrue(probe.result.standardOutput.contains("preflight=rejected"))
        XCTAssertTrue(probe.result.standardOutput.contains("registration=rejected preserved=0 attempted=0"))
        XCTAssertTrue(probe.result.standardError.contains(
            "existing installation is missing its Widget registration"
        ))
        XCTAssertTrue(probe.result.standardError.contains(
            "automatic registration is allowed only during a clean install"
        ))
        XCTAssertEqual(probe.registeredRecords, [probe.buildArtifactRecord])
        XCTAssertFalse(probe.plugInKitCommands.contains("-a "))
        XCTAssertFalse(probe.plugInKitCommands.contains("-r "))
    }

    func testInstallRegistrationPreservesTheUniqueInstalledRecordAlongsideTheBuildProduct() throws {
        let probe = try runInstallRegistrationDecision(
            initialRecords: [.buildProduct, .installedTarget],
            installedAppExists: true
        )
        defer { try? FileManager.default.removeItem(at: probe.temporaryDirectory) }

        XCTAssertEqual(probe.result.exitCode, 0, probe.result.standardError)
        XCTAssertTrue(probe.result.standardOutput.contains("preflight=accepted"))
        XCTAssertTrue(probe.result.standardOutput.contains("registration=accepted preserved=1 attempted=0"))
        XCTAssertTrue(probe.result.standardOutput.contains("decided-registrations=\(probe.installedAppex.path),"))
        XCTAssertTrue(probe.result.standardError.contains(
            "ignoring the build-product Widget registration"
        ))
        XCTAssertEqual(probe.registeredRecords, [probe.buildArtifactRecord, probe.installedAppex.path])
        XCTAssertFalse(probe.plugInKitCommands.contains("-a "))
        XCTAssertFalse(probe.plugInKitCommands.contains("-r "))
    }

    func testInstallRegistrationStillRejectsDuplicateAndStaleRecordsAlongsideTheBuildProduct() throws {
        let duplicates = try runInstallRegistrationDecision(
            initialRecords: [.buildProduct, .duplicatedInstalledTarget],
            installedAppExists: true
        )
        defer { try? FileManager.default.removeItem(at: duplicates.temporaryDirectory) }

        XCTAssertEqual(duplicates.result.exitCode, 0, duplicates.result.standardError)
        XCTAssertTrue(duplicates.result.standardOutput.contains("preflight=rejected"))
        XCTAssertTrue(duplicates.result.standardOutput.contains("registration=rejected"))
        XCTAssertTrue(duplicates.result.standardError.contains(
            "existing Widget registrations cannot be preserved safely"
        ))
        XCTAssertTrue(duplicates.result.standardError.contains("registered_count=2"))
        XCTAssertEqual(
            duplicates.registeredRecords,
            [duplicates.buildArtifactRecord, duplicates.installedAppex.path, duplicates.installedAppex.path]
        )
        XCTAssertFalse(duplicates.plugInKitCommands.contains("-a "))
        XCTAssertFalse(duplicates.plugInKitCommands.contains("-r "))

        let stale = try runInstallRegistrationDecision(
            initialRecords: [.buildProduct, .installedTarget, .stale],
            installedAppExists: true
        )
        defer { try? FileManager.default.removeItem(at: stale.temporaryDirectory) }

        XCTAssertEqual(stale.result.exitCode, 0, stale.result.standardError)
        XCTAssertTrue(stale.result.standardOutput.contains("preflight=rejected"))
        XCTAssertTrue(stale.result.standardOutput.contains("registration=rejected"))
        XCTAssertTrue(stale.result.standardError.contains(
            "Widget registrations cannot be preserved safely"
        ))
        XCTAssertTrue(stale.result.standardError.contains("registered_count=2"))
        XCTAssertEqual(
            stale.registeredRecords,
            [stale.buildArtifactRecord, stale.installedAppex.path, InstallRegistrationProbe.staleRecord]
        )
        XCTAssertFalse(stale.plugInKitCommands.contains("-a "))
        XCTAssertFalse(stale.plugInKitCommands.contains("-r "))
    }

    func testInstallRegistrationKeepsFailClosedForASymlinkDotDotAliasOfTheBuildProduct() throws {
        // A stale record can read exactly like the build artifact once `..` is folded
        // textually through a symlinked alias, while the path it physically denotes does
        // not exist. Only physical resolution may tell them apart, so this must stay
        // fail closed instead of being filtered out as this build's own record.
        let probe = try runInstallRegistrationDecision(
            initialRecords: [.dotDotAliasOfBuildProduct, .installedTarget],
            installedAppExists: true
        )
        defer { try? FileManager.default.removeItem(at: probe.temporaryDirectory) }

        XCTAssertEqual(probe.result.exitCode, 0, probe.result.standardError)
        XCTAssertTrue(probe.result.standardOutput.contains("preflight=rejected"))
        XCTAssertTrue(probe.result.standardOutput.contains("registration=rejected preserved=0 attempted=0"))
        XCTAssertTrue(probe.result.standardError.contains("registered_count=2"))
        XCTAssertFalse(probe.result.standardError.contains("ignoring the build-product Widget registration"))
        XCTAssertEqual(
            probe.registeredRecords,
            [probe.dotDotAliasRecord, probe.installedAppex.path]
        )
        XCTAssertFalse(probe.plugInKitCommands.contains("-a "))
        XCTAssertFalse(probe.plugInKitCommands.contains("-r "))

        // The pre-fix helper entered its ancestor with a logical `cd`, so the stale record
        // was mistaken for the build artifact and the very same registry state was
        // accepted. Running the reconstructed helper proves the difference is this fix.
        let beforeFix = try runInstallRegistrationDecision(
            initialRecords: [.dotDotAliasOfBuildProduct, .installedTarget],
            installedAppExists: true,
            simulatePreFixLogicalDirectoryChange: true
        )
        defer { try? FileManager.default.removeItem(at: beforeFix.temporaryDirectory) }

        XCTAssertEqual(beforeFix.result.exitCode, 0, beforeFix.result.standardError)
        XCTAssertTrue(beforeFix.result.standardOutput.contains("preflight=accepted"))
        XCTAssertTrue(beforeFix.result.standardOutput.contains("registration=accepted preserved=1 attempted=0"))
        XCTAssertTrue(beforeFix.result.standardError.contains("ignoring the build-product Widget registration"))
        XCTAssertFalse(beforeFix.plugInKitCommands.contains("-a "))
        XCTAssertFalse(beforeFix.plugInKitCommands.contains("-r "))
    }

    func testCleanInstallFailsWhenTheRegistrationCommandSucceedsButTheTargetRecordNeverAppears() throws {
        // The registration command reports success, yet the query never sees the target
        // record. The polling validation must fail rather than accept a state it could
        // not observe.
        let probe = try runInstallRegistrationDecision(
            initialRecords: [.buildProduct],
            installedAppExists: false,
            allowsRegistrationAdd: true,
            pluginSwallowsRegistrationAdd: true
        )
        defer { try? FileManager.default.removeItem(at: probe.temporaryDirectory) }

        XCTAssertEqual(probe.result.exitCode, 0, probe.result.standardError)
        XCTAssertTrue(probe.result.standardOutput.contains("preflight=accepted"))
        XCTAssertTrue(probe.result.standardOutput.contains("registration=rejected preserved=0 attempted=1"))
        XCTAssertTrue(probe.result.standardError.contains(
            "registration is not unique or does not point to the installed extension"
        ))
        XCTAssertTrue(probe.result.standardError.contains(
            "expected_widget_path=\(probe.installedAppex.path) registered_count=0"
        ))
        // Exactly one registration attempt ran, and no record was created or removed.
        let mutatingCommands = probe.plugInKitCommands
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("-a ") || $0.hasPrefix("-r ") }
        XCTAssertEqual(mutatingCommands, ["-a \(probe.installedAppex.path)"])
        XCTAssertEqual(probe.registeredRecords, [probe.buildArtifactRecord])
    }

    func testInstallRegistrationStillConvergesWhenTheBuildProductIsTheRegistrationTarget() throws {
        let probe = try runInstallRegistrationDecision(
            initialRecords: [],
            installedAppExists: false,
            allowsRegistrationAdd: true,
            buildArtifactIsRegistrationTarget: true
        )
        defer { try? FileManager.default.removeItem(at: probe.temporaryDirectory) }

        XCTAssertEqual(probe.result.exitCode, 0, probe.result.standardError)
        XCTAssertTrue(probe.result.standardOutput.contains("registration=accepted preserved=0 attempted=1"))
        XCTAssertEqual(probe.registeredRecords, [probe.buildAppex.path])
        XCTAssertTrue(probe.plugInKitCommands.contains("-a \(probe.buildAppex.path)"))
        XCTAssertFalse(probe.result.standardError.contains("ignoring the build-product Widget registration"))
    }

    func testCleanInstallActivationFailureUnregistersCandidateAndRemovesAllTransactionResidue() throws {
        let script = try buildAndRunScript()
        let functions = try [
            "find_widget_extension",
            "unregister_release_candidate_widget_registration",
            "unregister_widget_extensions",
            "rollback_release_install",
            "install_release_app"
        ].map { try XCTUnwrap(shellFunction(named: $0, in: script)) }
            .joined(separator: "\n")
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyCleanInstallRollbackTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let candidateWidget = candidateApp
            .appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let installDirectory = temporaryDirectory.appendingPathComponent("install")
        let installedApp = installDirectory.appendingPathComponent("TinyBuddy.app")
        let installedWidget = installedApp
            .appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let stateFile = temporaryDirectory.appendingPathComponent("plugin-state.txt")
        let commandLog = temporaryDirectory.appendingPathComponent("plugin-commands.log")
        let fakePluginKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")
        try FileManager.default.createDirectory(at: candidateWidget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try Data("candidate".utf8).write(to: candidateApp.appendingPathComponent("marker"))
        try Data().write(to: stateFile)
        try writeStatefulPluginKit(to: fakePluginKit)

        let result = try runBash("""
        set -euo pipefail
        APP_NAME=TinyBuddy
        APP_BUNDLE=\(shellQuote(candidateApp.path))
        INSTALL_DIR=\(shellQuote(installDirectory.path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        INSTALLED_WIDGET=\(shellQuote(installedWidget.path))
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_BUNDLE_ID=com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=\(shellQuote(fakePluginKit.path))
        FAKE_PLUGIN_STATE=\(shellQuote(stateFile.path))
        FAKE_PLUGIN_COMMAND_LOG=\(shellQuote(commandLog.path))
        FAKE_PLUGIN_FAIL_REMOVE=0
        FAKE_PLUGIN_IGNORE_REMOVE=0
        FAKE_PLUGIN_DUPLICATE_TARGET=0
        export FAKE_PLUGIN_STATE FAKE_PLUGIN_COMMAND_LOG FAKE_PLUGIN_FAIL_REMOVE
        export FAKE_PLUGIN_IGNORE_REMOVE FAKE_PLUGIN_DUPLICATE_TARGET
        RELEASE_TRANSACTION_DIR=""
        RELEASE_STAGED_APP=""
        RELEASE_BACKUP_APP=""
        RELEASE_HAD_PREVIOUS=0
        RELEASE_SWITCHED=0
        RELEASE_COMMITTED=0
        RELEASE_PREVIOUS_APP_WAS_RUNNING=0
        RELEASE_WIDGET_REGISTRATION_ATTEMPTED=0
        validate_release_install_paths() { return 0; }
        verify_widget_registration_preflight() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        release_path_identity() { /usr/bin/stat -f '%d:%i' "$1"; }
        atomic_place_release_candidate() {
          [ ! -e "$2" ] && [ ! -L "$2" ] || return 73
          /bin/mv "$1" "$2" || return $?
          printf 'TINYBUDDY_RELEASE_INSTALLER_INSTALLED\n'
        }
        registered_widget_paths() { /bin/cat "$FAKE_PLUGIN_STATE"; }
        activate_and_verify_release_app() {
          RELEASE_WIDGET_REGISTRATION_ATTEMPTED=1
          printf '%s\n' "$INSTALLED_WIDGET" >"$FAKE_PLUGIN_STATE"
          return 83
        }
        \(functions)
        install_release_app
        """)

        XCTAssertEqual(
            result.exitCode,
            83,
            "stdout:\n\(result.standardOutput)\nstderr:\n\(result.standardError)"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedApp.path))
        XCTAssertEqual(try Data(contentsOf: stateFile), Data())
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: installDirectory.path)
                .contains(where: { $0.hasPrefix(".TinyBuddy.install.") })
        )
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains("-r \(installedWidget.path)"))
        XCTAssertTrue(result.standardError.contains("removed the candidate app and Widget registration"))
    }

    func testCleanInstallStaleRegistrationFailureDoesNotMutateExistingRecords() throws {
        let script = try buildAndRunScript()
        let functions = try [
            "canonical_filesystem_path",
            "registered_install_widget_paths",
            "verify_widget_registration_preflight",
            "register_widget_extension",
            "unregister_release_candidate_widget_registration",
            "unregister_widget_extensions",
            "rollback_release_install",
            "install_release_app"
        ].map { try XCTUnwrap(shellFunction(named: $0, in: script)) }
            .joined(separator: "\n")
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyCleanInstallStaleWidgetTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let candidateWidget = candidateApp
            .appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let installDirectory = temporaryDirectory.appendingPathComponent("install")
        let installedApp = installDirectory.appendingPathComponent("TinyBuddy.app")
        let installedWidget = installedApp
            .appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let stateFile = temporaryDirectory.appendingPathComponent("plugin-state.txt")
        let commandLog = temporaryDirectory.appendingPathComponent("plugin-commands.log")
        let fakePluginKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")
        let staleRecord = "/tmp/stale-tinybuddy-widget.appex\n"
        try FileManager.default.createDirectory(at: candidateWidget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try Data("candidate".utf8).write(to: candidateApp.appendingPathComponent("marker"))
        try Data(staleRecord.utf8).write(to: stateFile)
        try writeStatefulPluginKit(to: fakePluginKit)

        let result = try runBash("""
        set -euo pipefail
        APP_NAME=TinyBuddy
        APP_BUNDLE=\(shellQuote(candidateApp.path))
        INSTALL_DIR=\(shellQuote(installDirectory.path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        INSTALLED_WIDGET=\(shellQuote(installedWidget.path))
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_BUNDLE_ID=com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=\(shellQuote(fakePluginKit.path))
        FAKE_PLUGIN_STATE=\(shellQuote(stateFile.path))
        FAKE_PLUGIN_COMMAND_LOG=\(shellQuote(commandLog.path))
        FAKE_PLUGIN_FAIL_REMOVE=0
        FAKE_PLUGIN_IGNORE_REMOVE=0
        FAKE_PLUGIN_DUPLICATE_TARGET=0
        export FAKE_PLUGIN_STATE FAKE_PLUGIN_COMMAND_LOG FAKE_PLUGIN_FAIL_REMOVE
        export FAKE_PLUGIN_IGNORE_REMOVE FAKE_PLUGIN_DUPLICATE_TARGET
        RELEASE_TRANSACTION_DIR=""
        RELEASE_STAGED_APP=""
        RELEASE_BACKUP_APP=""
        RELEASE_HAD_PREVIOUS=0
        RELEASE_SWITCHED=0
        RELEASE_COMMITTED=0
        RELEASE_PREVIOUS_APP_WAS_RUNNING=0
        RELEASE_WIDGET_REGISTRATION_ATTEMPTED=0
        RELEASE_WIDGET_REGISTRATION_PRESERVED=0
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        find_widget_extension() { printf '%s\n' "$INSTALLED_WIDGET"; }
        registered_widget_paths() { /bin/cat "$FAKE_PLUGIN_STATE"; }
        activate_and_verify_release_app() { register_widget_extension "$INSTALLED_APP"; }
        \(functions)
        install_release_app
        """)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedApp.path))
        XCTAssertEqual(try String(contentsOf: stateFile, encoding: .utf8), staleRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandLog.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: installDirectory.path)
                .contains(where: { $0.hasPrefix(".TinyBuddy.install.") })
        )
        XCTAssertTrue(result.standardError.contains(
            "existing Widget registrations cannot be preserved safely"
        ))
    }

    private func runSigningContract(
        in temporaryDirectory: URL,
        app: URL,
        widget: URL,
        fakeCodesign: URL,
        appEntitlements: [String: Any],
        widgetEntitlements: [String: Any],
        appTeam: String = "JYL9G28DP3",
        widgetTeam: String = "JYL9G28DP3",
        signingMode: String = "signed"
    ) throws -> ShellResult {
        let scenarioDirectory = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
        let appPlist = scenarioDirectory.appendingPathComponent("app-entitlements.plist")
        let widgetPlist = scenarioDirectory.appendingPathComponent("widget-entitlements.plist")
        try writePropertyList(appEntitlements, to: appPlist)
        try writePropertyList(widgetEntitlements, to: widgetPlist)
        let script = try buildAndRunScript()
        var provisioningEnvironment = ""
        if signingMode == "signed" {
            let appProfile = app.appendingPathComponent("Contents/embedded.provisionprofile")
            let widgetContents = widget.appendingPathComponent("Contents")
            let widgetProfile = widgetContents.appendingPathComponent("embedded.provisionprofile")
            try FileManager.default.createDirectory(
                at: widgetContents,
                withIntermediateDirectories: true
            )
            try Data("app".utf8).write(to: appProfile)
            try Data("widget".utf8).write(to: widgetProfile)

            let fakeSecurity = scenarioDirectory.appendingPathComponent("fake-security.sh")
            let fakePlistBuddy = scenarioDirectory.appendingPathComponent("fake-plist-buddy.sh")
            try writeExecutable(
                """
                #!/bin/bash
                set -eu
                profile="${@: -1}"
                case "$profile" in
                  *TinyBuddyWidgetExtension.appex*) printf 'widget\\n' ;;
                  *) printf 'app\\n' ;;
                esac
                """,
                to: fakeSecurity
            )
            try writeExecutable(
                """
                #!/bin/bash
                set -eu
                decoded="${@: -1}"
                kind="$(/bin/cat "$decoded")"
                case "$*" in
                  *application-identifier*)
                    if [ "$kind" = "widget" ]; then
                      printf '%s\\n' 'JYL9G28DP3.com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension'
                    else
                      printf '%s\\n' 'JYL9G28DP3.com.ryukeili.TinyBuddy'
                    fi
                    ;;
                  *application-groups*) printf '%s\\n' 'group.com.ryukeili.TinyBuddy' ;;
                  *) exit 64 ;;
                esac
                """,
                to: fakePlistBuddy
            )
            provisioningEnvironment = """
            SECURITY_BIN=\(shellQuote(fakeSecurity.path))
            PLIST_BUDDY_BIN=\(shellQuote(fakePlistBuddy.path))
            """
        }
        let functions = try [
            "verify_provisioned_app_group",
            "signing_team_identifier",
            "signing_leaf_authority",
            "extract_signed_entitlements",
            "require_boolean_entitlement",
            "require_string_entitlement",
            "require_app_group_entitlement",
            "require_entitlement_key_count",
            "verify_code_signing_contract"
        ].map { try XCTUnwrap(shellFunction(named: $0, in: script)) }
            .joined(separator: "\n")

        return try runBash("""
        set -euo pipefail
        EXPECTED_TEAM_ID=JYL9G28DP3
        EXPECTED_GET_TASK_ALLOW=true
        SIGNING_MODE=\(shellQuote(signingMode))
        BUNDLE_ID=com.ryukeili.TinyBuddy
        WIDGET_BUNDLE_ID=com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension
        APP_GROUP_ID=group.com.ryukeili.TinyBuddy
        CODESIGN_BIN=\(shellQuote(fakeCodesign.path))
        TMPDIR=\(shellQuote(scenarioDirectory.path))
        FAKE_APP_PATH=\(shellQuote(app.path))
        FAKE_WIDGET_PATH=\(shellQuote(widget.path))
        FAKE_APP_TEAM=\(shellQuote(appTeam))
        FAKE_WIDGET_TEAM=\(shellQuote(widgetTeam))
        FAKE_APP_ENTITLEMENTS=\(shellQuote(appPlist.path))
        FAKE_WIDGET_ENTITLEMENTS=\(shellQuote(widgetPlist.path))
        FAKE_SIGNING_AUTHORITY='Apple Development: Contract Test'
        \(provisioningEnvironment)
        export FAKE_APP_PATH FAKE_WIDGET_PATH FAKE_APP_TEAM FAKE_WIDGET_TEAM
        export FAKE_APP_ENTITLEMENTS FAKE_WIDGET_ENTITLEMENTS FAKE_SIGNING_AUTHORITY
        \(functions)
        verify_code_signing_contract "$FAKE_APP_PATH" "$FAKE_WIDGET_PATH"
        """)
    }

    private func runWidgetRegistrationProbe(
        duplicateTargetOnAdd: Bool = false,
        startsWithStaleRecord: Bool = true,
        startsWithDuplicateTargetRecord: Bool = false,
        allowsRegistrationAdd: Bool = false
    ) throws -> RegistrationProbe {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetRegistrationContractTests")
        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let widget = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let stateFile = temporaryDirectory.appendingPathComponent("plugin-state.txt")
        let commandLog = temporaryDirectory.appendingPathComponent("plugin-commands.log")
        let fakePluginKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        let initialState: Data
        if startsWithDuplicateTargetRecord {
            initialState = Data("\(widget.path)\n\(widget.path)\n".utf8)
        } else if startsWithStaleRecord {
            initialState = Data("/tmp/stale-tinybuddy-widget.appex\n".utf8)
        } else {
            initialState = Data()
        }
        try initialState.write(to: stateFile)
        try writeStatefulPluginKit(to: fakePluginKit)
        let registrationFunction = try XCTUnwrap(
            shellFunction(named: "register_widget_extension", in: try buildAndRunScript())
        )
        let installRegistrationFunctions = try [
            "canonical_filesystem_path",
            "registered_install_widget_paths"
        ].map { try XCTUnwrap(shellFunction(named: $0, in: try buildAndRunScript())) }
            .joined(separator: "\n")

        let result = try runBash("""
        set -euo pipefail
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_BUNDLE_ID=com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=\(shellQuote(fakePluginKit.path))
        FAKE_APPEX=\(shellQuote(widget.path))
        FAKE_PLUGIN_STATE=\(shellQuote(stateFile.path))
        FAKE_PLUGIN_COMMAND_LOG=\(shellQuote(commandLog.path))
        FAKE_PLUGIN_FAIL_REMOVE=0
        FAKE_PLUGIN_IGNORE_REMOVE=0
        FAKE_PLUGIN_DUPLICATE_TARGET=\(duplicateTargetOnAdd ? 1 : 0)
        export FAKE_APPEX FAKE_PLUGIN_STATE FAKE_PLUGIN_COMMAND_LOG FAKE_PLUGIN_FAIL_REMOVE
        export FAKE_PLUGIN_IGNORE_REMOVE FAKE_PLUGIN_DUPLICATE_TARGET
        find_widget_extension() { printf '%s\n' "$FAKE_APPEX"; }
        registered_widget_paths() { /bin/cat "$FAKE_PLUGIN_STATE"; }
        \(installRegistrationFunctions)
        \(registrationFunction)
        register_widget_extension \(shellQuote(app.path)) \(allowsRegistrationAdd ? 1 : 0)
        """)

        return RegistrationProbe(
            result: result,
            temporaryDirectory: temporaryDirectory,
            widget: widget,
            stateFile: stateFile,
            commandLog: commandLog
        )
    }

    private func writeQueryablePluginKit(to url: URL) throws {
        try writeExecutable(
            """
            #!/bin/bash
            set -eu
            printf '%s\n' "$*" >>"$FAKE_PLUGIN_COMMAND_LOG"
            case "$1" in
              -m)
                while IFS= read -r row; do
                  if [ -z "$row" ]; then
                    continue
                  fi
                  printf 'record-x\\tmetadata-x\\t%s\\n' "$row"
                done <"$FAKE_PLUGIN_STATE"
                ;;
              -a)
                if [ "${FAKE_PLUGIN_SWALLOW_ADD:-0}" -eq 1 ]; then
                  exit 0
                fi
                if [ "$FAKE_PLUGIN_DUPLICATE_TARGET" -eq 1 ]; then
                  printf '%s\\n%s\\n' "$2" "$2" >>"$FAKE_PLUGIN_STATE"
                elif ! /usr/bin/grep -Fqx "$2" "$FAKE_PLUGIN_STATE"; then
                  printf '%s\\n' "$2" >>"$FAKE_PLUGIN_STATE"
                fi
                ;;
              -r)
                /usr/bin/awk -v removed="$2" '$0 != removed { print }' \\
                  "$FAKE_PLUGIN_STATE" >"$FAKE_PLUGIN_STATE.next"
                /bin/mv "$FAKE_PLUGIN_STATE.next" "$FAKE_PLUGIN_STATE"
                ;;
              *) exit 64 ;;
            esac
            """,
            to: url
        )
    }

    /// Runs the release-install Widget registration decision against a stateful
    /// PlugInKit stub: `APP_BUNDLE` is reached through a symlinked alias while the
    /// recorded registry rows carry the physical path, so the build-product
    /// exclusion has to normalize both sides before comparing them.
    private func runInstallRegistrationDecision(
        initialRecords: [InstallRegistrationRecord],
        installedAppExists: Bool,
        allowsRegistrationAdd: Bool = false,
        buildArtifactIsRegistrationTarget: Bool = false,
        pluginSwallowsRegistrationAdd: Bool = false,
        simulatePreFixLogicalDirectoryChange: Bool = false
    ) throws -> InstallRegistrationProbe {
        let temporaryDirectory = try makeTemporaryDirectory(
            named: "TinyBuddyInstallRegistrationDecisionTests"
        )
        let physicalRoot = temporaryDirectory.appendingPathComponent("physical")
        let aliasRoot = temporaryDirectory.appendingPathComponent("alias")
        let buildApp = aliasRoot.appendingPathComponent("DerivedData/Build/Products/Debug/TinyBuddy.app")
        let physicalBuildAppex = physicalRoot
            .appendingPathComponent("DerivedData/Build/Products/Debug/TinyBuddy.app")
            .appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let buildAppex = buildApp.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let installedApp = physicalRoot.appendingPathComponent("Applications/TinyBuddy.app")
        let installedAppex = installedApp
            .appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let dotDotAliasTarget = temporaryDirectory.appendingPathComponent("nested/deep")
        let dotDotAlias = temporaryDirectory.appendingPathComponent("deep-alias")
        let stateFile = temporaryDirectory.appendingPathComponent("plugin-state.txt")
        let commandLog = temporaryDirectory.appendingPathComponent("plugin-commands.log")
        let fakePluginKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")

        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: physicalRoot)
        try FileManager.default.createDirectory(at: physicalBuildAppex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotDotAliasTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dotDotAlias, withDestinationURL: dotDotAliasTarget)
        if installedAppExists {
            try FileManager.default.createDirectory(at: installedAppex, withIntermediateDirectories: true)
        }
        // `<temp>/deep-alias/..` folds textually to `<temp>` (so the record reads like the
        // build artifact) but physically resolves to `<temp>/nested`, where nothing exists.
        let dotDotAliasRecord = "\(dotDotAlias.path)/..\(physicalBuildAppex.path.dropFirst(temporaryDirectory.path.count))"
        let records = initialRecords.flatMap { record -> [String] in
            switch record {
            case .buildProduct:
                return [physicalBuildAppex.path]
            case .dotDotAliasOfBuildProduct:
                return [dotDotAliasRecord]
            case .installedTarget:
                return [installedAppex.path]
            case .duplicatedInstalledTarget:
                return [installedAppex.path, installedAppex.path]
            case .stale:
                return [InstallRegistrationProbe.staleRecord]
            }
        }
        try Data(records.map { "\($0)\n" }.joined().utf8).write(to: stateFile)
        try writeQueryablePluginKit(to: fakePluginKit)

        let functions = try [
            "canonical_filesystem_path",
            "registered_widget_paths",
            "registered_install_widget_paths",
            "verify_widget_registration_preflight",
            "register_widget_extension"
        ].map { try XCTUnwrap(shellFunction(named: $0, in: try buildAndRunScript())) }
            .joined(separator: "\n")
        // Reconstructs the pre-fix helper (logical `cd`, which folds `..` textually) to
        // demonstrate the counterexample it allowed. The assertion also pins the physical
        // form, so reverting the script fails here instead of silently passing.
        let effectiveFunctions: String
        if simulatePreFixLogicalDirectoryChange {
            let reverted = functions.replacingOccurrences(of: "cd -P -- \"$path\"", with: "cd \"$path\"")
            XCTAssertNotEqual(
                reverted,
                functions,
                "canonical_filesystem_path must resolve its ancestor with `cd -P --`"
            )
            effectiveFunctions = reverted
        } else {
            effectiveFunctions = functions
        }
        let targetAppex = buildArtifactIsRegistrationTarget ? buildAppex : installedAppex
        let targetApp = buildArtifactIsRegistrationTarget ? buildApp : installedApp

        let result = try runBash("""
        set -euo pipefail
        APP_BUNDLE=\(shellQuote(buildApp.path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_BUNDLE_ID=com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=\(shellQuote(fakePluginKit.path))
        FAKE_PLUGIN_STATE=\(shellQuote(stateFile.path))
        FAKE_PLUGIN_COMMAND_LOG=\(shellQuote(commandLog.path))
        FAKE_PLUGIN_DUPLICATE_TARGET=0
        FAKE_PLUGIN_SWALLOW_ADD=\(pluginSwallowsRegistrationAdd ? 1 : 0)
        export FAKE_PLUGIN_STATE FAKE_PLUGIN_COMMAND_LOG FAKE_PLUGIN_DUPLICATE_TARGET FAKE_PLUGIN_SWALLOW_ADD
        RELEASE_WIDGET_REGISTRATION_PRESERVED=0
        RELEASE_WIDGET_REGISTRATION_ATTEMPTED=0
        FIND_WIDGET_TARGET=\(shellQuote(targetAppex.path))
        find_widget_extension() { printf '%s\n' "$FIND_WIDGET_TARGET"; }
        \(effectiveFunctions)
        if verify_widget_registration_preflight; then
          printf 'preflight=accepted\n'
        else
          printf 'preflight=rejected\n'
        fi
        if register_widget_extension \(shellQuote(targetApp.path)) \(allowsRegistrationAdd ? 1 : 0); then
          printf 'registration=accepted preserved=%s attempted=%s\n' "$RELEASE_WIDGET_REGISTRATION_PRESERVED" "$RELEASE_WIDGET_REGISTRATION_ATTEMPTED"
        else
          printf 'registration=rejected preserved=%s attempted=%s\n' "$RELEASE_WIDGET_REGISTRATION_PRESERVED" "$RELEASE_WIDGET_REGISTRATION_ATTEMPTED"
        fi
        printf 'decided-registrations=%s\n' "$(registered_install_widget_paths "$FIND_WIDGET_TARGET" | /usr/bin/tr '\n' ',')"
        """)

        return InstallRegistrationProbe(
            result: result,
            temporaryDirectory: temporaryDirectory,
            buildAppex: buildAppex,
            installedAppex: installedAppex,
            buildArtifactRecord: physicalBuildAppex.path,
            dotDotAliasRecord: dotDotAliasRecord,
            stateFile: stateFile,
            commandLog: commandLog
        )
    }

    private func writeStatefulPluginKit(to url: URL) throws {
        try writeExecutable(
            """
            #!/bin/bash
            set -eu
            printf '%s\n' "$*" >>"$FAKE_PLUGIN_COMMAND_LOG"
            case "$1" in
              -a)
                if [ "$FAKE_PLUGIN_DUPLICATE_TARGET" -eq 1 ]; then
                  printf '%s\n%s\n' "$2" "$2" >>"$FAKE_PLUGIN_STATE"
                elif ! /usr/bin/grep -Fqx "$2" "$FAKE_PLUGIN_STATE"; then
                  printf '%s\n' "$2" >>"$FAKE_PLUGIN_STATE"
                fi
                ;;
              -r)
                if [ "$FAKE_PLUGIN_FAIL_REMOVE" -eq 1 ]; then
                  exit 72
                fi
                if [ "$FAKE_PLUGIN_IGNORE_REMOVE" -eq 0 ]; then
                  /usr/bin/awk -v removed="$2" '$0 != removed { print }' \
                    "$FAKE_PLUGIN_STATE" >"$FAKE_PLUGIN_STATE.next"
                  /bin/mv "$FAKE_PLUGIN_STATE.next" "$FAKE_PLUGIN_STATE"
                fi
                ;;
              *) exit 64 ;;
            esac
            """,
            to: url
        )
    }

    private func appEntitlements() -> [String: Any] {
        [
            "com.apple.application-identifier": "JYL9G28DP3.com.ryukeili.TinyBuddy",
            "com.apple.developer.team-identifier": "JYL9G28DP3",
            "com.apple.security.app-sandbox": true,
            "com.apple.security.application-groups": ["group.com.ryukeili.TinyBuddy"],
            "com.apple.security.files.bookmarks.app-scope": true,
            "com.apple.security.files.user-selected.read-only": true,
            "com.apple.security.get-task-allow": true
        ]
    }

    private func widgetEntitlements() -> [String: Any] {
        [
            "com.apple.application-identifier":
                "JYL9G28DP3.com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension",
            "com.apple.developer.team-identifier": "JYL9G28DP3",
            "com.apple.security.app-sandbox": true,
            "com.apple.security.application-groups": ["group.com.ryukeili.TinyBuddy"],
            "com.apple.security.get-task-allow": true
        ]
    }

    private func localAppEntitlements() -> [String: Any] {
        [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.application-groups": ["group.com.ryukeili.TinyBuddy"],
            "com.apple.security.files.bookmarks.app-scope": true,
            "com.apple.security.files.user-selected.read-only": true
        ]
    }

    private func localWidgetEntitlements() -> [String: Any] {
        [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.application-groups": ["group.com.ryukeili.TinyBuddy"]
        ]
    }

    private func buildAndRunScript() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func shellFunction(named name: String, in script: String) -> String? {
        let startMarker = "\(name)() {"
        guard let start = script.range(of: startMarker),
              let end = script.range(of: "\n}\n", range: start.lowerBound..<script.endIndex) else {
            return nil
        }
        return String(script[start.lowerBound..<end.upperBound])
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
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func runBash(_ script: String) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let standardError = Pipe()
        let standardOutput = Pipe()
        process.standardError = standardError
        process.standardOutput = standardOutput
        try process.run()
        process.waitUntilExit()
        return ShellResult(
            exitCode: process.terminationStatus,
            standardOutput: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private struct ShellResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

/// Which raw PlugInKit records the install-registration probe starts from.
private enum InstallRegistrationRecord {
    case buildProduct
    /// A record that reads like the build artifact only after textual `..` folding
    /// through a symlinked alias; it denotes a path that does not physically exist.
    case dotDotAliasOfBuildProduct
    case installedTarget
    case duplicatedInstalledTarget
    case stale
}

private struct InstallRegistrationProbe {
    static let staleRecord = "/tmp/stale-tinybuddy-widget.appex"

    let result: ShellResult
    let temporaryDirectory: URL
    let buildAppex: URL
    let installedAppex: URL
    let buildArtifactRecord: String
    let dotDotAliasRecord: String
    let stateFile: URL
    let commandLog: URL

    var registeredRecords: [String] {
        ((try? String(contentsOf: stateFile, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    var plugInKitCommands: String {
        (try? String(contentsOf: commandLog, encoding: .utf8)) ?? ""
    }
}

private final class RegistrationProbe {
    let result: ShellResult
    let temporaryDirectory: URL
    let widget: URL
    let stateFile: URL
    let commandLog: URL

    init(
        result: ShellResult,
        temporaryDirectory: URL,
        widget: URL,
        stateFile: URL,
        commandLog: URL
    ) {
        self.result = result
        self.temporaryDirectory = temporaryDirectory
        self.widget = widget
        self.stateFile = stateFile
        self.commandLog = commandLog
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}
