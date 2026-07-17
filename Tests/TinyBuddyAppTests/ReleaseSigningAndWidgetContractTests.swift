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

    func testWidgetRegistrationAddsTargetThenRemovesStaleRecordAndConverges() throws {
        let probe = try runWidgetRegistrationProbe()

        XCTAssertEqual(probe.result.exitCode, 0, probe.result.standardError)
        XCTAssertEqual(
            try String(contentsOf: probe.stateFile, encoding: .utf8),
            "\(probe.widget.path)\n"
        )
        let commands = try String(contentsOf: probe.commandLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(commands.first, "-a \(probe.widget.path)")
        XCTAssertEqual(commands.dropFirst().first, "-r /tmp/stale-tinybuddy-widget.appex")
        XCTAssertTrue(probe.result.standardOutput.contains("registered unique widget extension"))
    }

    func testWidgetRegistrationFailsWhenStaleRecordCannotBeRemoved() throws {
        let probe = try runWidgetRegistrationProbe(staleRemovalFails: true)

        XCTAssertEqual(probe.result.exitCode, 1)
        XCTAssertTrue(probe.result.standardError.contains("failed to unregister stale Widget record"))
        XCTAssertTrue(
            try String(contentsOf: probe.stateFile, encoding: .utf8)
                .contains("/tmp/stale-tinybuddy-widget.appex")
        )
    }

    func testWidgetRegistrationRejectsDuplicateTargetRecords() throws {
        let probe = try runWidgetRegistrationProbe(duplicateTargetOnAdd: true, startsWithStaleRecord: false)

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

    func testWidgetRegistrationFailsWhenRemovalDoesNotConverge() throws {
        let probe = try runWidgetRegistrationProbe(ignoreRemoval: true)

        XCTAssertEqual(probe.result.exitCode, 1)
        XCTAssertTrue(probe.result.standardError.contains("does not point to the installed extension"))
        XCTAssertTrue(probe.result.standardError.contains("registered_count=2"))
    }

    func testCleanInstallActivationFailureUnregistersCandidateAndRemovesAllTransactionResidue() throws {
        let script = try buildAndRunScript()
        let functions = try [
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
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        registered_widget_paths() { /bin/cat "$FAKE_PLUGIN_STATE"; }
        activate_and_verify_release_app() {
          printf '%s\n' "$INSTALLED_WIDGET" >"$FAKE_PLUGIN_STATE"
          return 83
        }
        \(functions)
        install_release_app
        """)

        XCTAssertEqual(result.exitCode, 83)
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
        let functions = try [
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
        export FAKE_APP_PATH FAKE_WIDGET_PATH FAKE_APP_TEAM FAKE_WIDGET_TEAM
        export FAKE_APP_ENTITLEMENTS FAKE_WIDGET_ENTITLEMENTS FAKE_SIGNING_AUTHORITY
        \(functions)
        verify_code_signing_contract "$FAKE_APP_PATH" "$FAKE_WIDGET_PATH"
        """)
    }

    private func runWidgetRegistrationProbe(
        staleRemovalFails: Bool = false,
        ignoreRemoval: Bool = false,
        duplicateTargetOnAdd: Bool = false,
        startsWithStaleRecord: Bool = true
    ) throws -> RegistrationProbe {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetRegistrationContractTests")
        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let widget = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let stateFile = temporaryDirectory.appendingPathComponent("plugin-state.txt")
        let commandLog = temporaryDirectory.appendingPathComponent("plugin-commands.log")
        let fakePluginKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        let initialState = startsWithStaleRecord
            ? Data("/tmp/stale-tinybuddy-widget.appex\n".utf8)
            : Data()
        try initialState.write(to: stateFile)
        try writeStatefulPluginKit(to: fakePluginKit)
        let registrationFunction = try XCTUnwrap(
            shellFunction(named: "register_widget_extension", in: try buildAndRunScript())
        )

        let result = try runBash("""
        set -euo pipefail
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_BUNDLE_ID=com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=\(shellQuote(fakePluginKit.path))
        FAKE_APPEX=\(shellQuote(widget.path))
        FAKE_PLUGIN_STATE=\(shellQuote(stateFile.path))
        FAKE_PLUGIN_COMMAND_LOG=\(shellQuote(commandLog.path))
        FAKE_PLUGIN_FAIL_REMOVE=\(staleRemovalFails ? 1 : 0)
        FAKE_PLUGIN_IGNORE_REMOVE=\(ignoreRemoval ? 1 : 0)
        FAKE_PLUGIN_DUPLICATE_TARGET=\(duplicateTargetOnAdd ? 1 : 0)
        export FAKE_APPEX FAKE_PLUGIN_STATE FAKE_PLUGIN_COMMAND_LOG FAKE_PLUGIN_FAIL_REMOVE
        export FAKE_PLUGIN_IGNORE_REMOVE FAKE_PLUGIN_DUPLICATE_TARGET
        find_widget_extension() { printf '%s\n' "$FAKE_APPEX"; }
        registered_widget_paths() { /bin/cat "$FAKE_PLUGIN_STATE"; }
        \(registrationFunction)
        register_widget_extension \(shellQuote(app.path))
        """)

        return RegistrationProbe(
            result: result,
            temporaryDirectory: temporaryDirectory,
            widget: widget,
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
