import Foundation
import XCTest

final class BuildAndRunScriptTests: XCTestCase {
    func testAppConfigurationProhibitsConcurrentSemanticWriters() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistData = try Data(contentsOf: repositoryURL
            .appendingPathComponent("Resources/TinyBuddyApp/Info.plist"))
        let infoPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoPlistData, format: nil)
                as? [String: Any]
        )
        let project = try String(
            contentsOf: repositoryURL.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertEqual(infoPlist["LSMultipleInstancesProhibited"] as? Bool, true)
        XCTAssertTrue(project.contains("LSMultipleInstancesProhibited: true"))
    }

    func testOptionalGitPreRefreshWarnsAndReturnsSuccessWhenRefreshFails() throws {
        let script = try buildAndRunScript()
        let function = try XCTUnwrap(
            shellFunction(named: "run_optional_git_pre_refresh", in: script),
            "build_and_run.sh must define an optional pre-refresh wrapper"
        )
        let probe = """
        update_git_completion_count() { return 23; }
        \(function)
        run_optional_git_pre_refresh
        """

        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("warning: git pre-refresh failed with exit code 23"))
        XCTAssertTrue(result.standardError.contains("continuing"))
    }

    func testRunModesUseOptionalPreRefreshButReleaseModesRelyOnSandboxApp() throws {
        let script = try buildAndRunScript()

        XCTAssertTrue(modeBlock("run", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertTrue(modeBlock("--verify|verify", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertFalse(modeBlock("release-install|--release-install", in: script).contains("run_optional_git_pre_refresh"))
        XCTAssertFalse(modeBlock("release-verify|--release-verify", in: script).contains("run_optional_git_pre_refresh"))
    }

    func testXcodeBuildDefaultsToBoundedSummaryOutputWithVerboseOptOut() throws {
        let script = try buildAndRunScript()
        let function = try XCTUnwrap(
            shellFunction(named: "run_xcode_build", in: script)
        )

        XCTAssertTrue(script.contains("BUILD_LOG_MODE=\"${TINYBUDDY_BUILD_LOG_MODE:-summary}\""))
        XCTAssertTrue(function.contains("verbose)"))
        XCTAssertTrue(function.contains(">\"$log_file\" 2>&1"))
        XCTAssertTrue(function.contains("/usr/bin/tail -n 80"))
        XCTAssertTrue(function.contains("$BUILD_FAILURE_TAIL_LINES"))
        XCTAssertTrue(function.contains("full log:"))
    }

    func testXcodeBuildSummaryKeepsFullLogButBoundsFailureOutput() throws {
        let function = try XCTUnwrap(
            shellFunction(named: "run_xcode_build", in: try buildAndRunScript())
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyBuildLogTests.\(UUID().uuidString)")
        let fakeXcodebuild = temporaryDirectory.appendingPathComponent("fake-xcodebuild.sh")
        let logDirectory = temporaryDirectory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fakeCommand = """
        #!/bin/bash
        index=1
        while [ "$index" -le 200 ]; do
          echo "build-line-$index"
          index=$((index + 1))
        done
        echo "error: focused diagnostic" >&2
        exit 37
        """
        try Data(fakeCommand.utf8).write(to: fakeXcodebuild)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeXcodebuild.path
        )

        let probe = """
        set -euo pipefail
        XCODEBUILD_BIN=\(shellQuote(fakeXcodebuild.path))
        BUILD_CONFIGURATION=Debug
        DERIVED_DATA_DIR=\(shellQuote(temporaryDirectory.appendingPathComponent("derived-data").path))
        SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
        BUILD_LOG_MODE=summary
        BUILD_FAILURE_TAIL_LINES=3
        BUILD_LOG_DIR=\(shellQuote(logDirectory.path))
        APP_NAME=TinyBuddy
        report_release_signing_failure() { return 0; }
        \(function)
        run_xcode_build
        """

        let result = try runBash(probe)
        let logFiles = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)

        XCTAssertEqual(result.exitCode, 37)
        XCTAssertTrue(result.standardError.contains("error: focused diagnostic"))
        XCTAssertTrue(result.standardError.contains("build-line-200"))
        XCTAssertFalse(result.standardError.contains("build-line-100"))
        XCTAssertEqual(logFiles.count, 1)
        XCTAssertTrue(
            try String(contentsOf: XCTUnwrap(logFiles.first), encoding: .utf8)
                .contains("build-line-100")
        )
    }

    func testBuildCurrentAppStopsAfterTheFirstFailedBuildStep() throws {
        let function = try XCTUnwrap(
            shellFunction(named: "build_current_app", in: try buildAndRunScript())
        )
        let result = try runBash("""
        set -euo pipefail
        MODE=release-acceptance
        generate_xcode_project() { echo generate; return 0; }
        clear_release_metadata() { echo clear; return 0; }
        run_xcode_build() { echo build; return 23; }
        sign_local_release_bundle() { echo sign; return 0; }
        build_release_verifier() { echo verifier; return 0; }
        \(function)
        build_current_app
        """)

        XCTAssertEqual(result.exitCode, 23)
        XCTAssertEqual(result.standardOutput, "generate\nclear\nbuild\n")
        XCTAssertFalse(result.standardOutput.contains("sign"))
        XCTAssertFalse(result.standardOutput.contains("verifier"))
    }

    func testLocalSigningIdentityResolverIsFingerprintExactAndFailClosed() throws {
        let resolver = try XCTUnwrap(
            shellFunction(named: "resolve_local_code_sign_identity", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyLocalIdentityTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fakeSecurity = temporaryDirectory.appendingPathComponent("fake-security.sh")
        let identities = temporaryDirectory.appendingPathComponent("identities.txt")
        try Data("""
        #!/bin/bash
        set -eu
        [ "$*" = "find-identity -v -p codesigning" ]
        /bin/cat "$FAKE_IDENTITY_OUTPUT"
        """.utf8).write(to: fakeSecurity)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSecurity.path)

        let first = "C6B16796CD59EF90EDF3005A05276634FC8F27EA"
        let second = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        func run(_ output: String, requested: String? = nil) throws
            -> (exitCode: Int32, standardOutput: String, standardError: String) {
            try Data(output.utf8).write(to: identities)
            let request = requested.map {
                "TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY=\(shellQuote($0)); export TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY"
            } ?? "unset TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY || true"
            return try runBash("""
            set -euo pipefail
            SECURITY_BIN=\(shellQuote(fakeSecurity.path))
            FAKE_IDENTITY_OUTPUT=\(shellQuote(identities.path))
            export FAKE_IDENTITY_OUTPUT
            \(request)
            \(resolver)
            resolve_local_code_sign_identity
            """)
        }

        let unique = try run("  1) \(first) \"Apple Development: Local One\"\n     1 valid identities found\n")
        XCTAssertEqual(unique.exitCode, 0, unique.standardError)
        XCTAssertEqual(unique.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), first)

        let multipleOutput = """
          1) \(first) "Apple Development: Local One"
          2) \(second) "Apple Development: Local Two"
             2 valid identities found
        """
        let ambiguous = try run(multipleOutput)
        XCTAssertEqual(ambiguous.exitCode, 1)
        XCTAssertTrue(ambiguous.standardError.contains("found=2"))

        let explicit = try run(multipleOutput, requested: second.lowercased())
        XCTAssertEqual(explicit.exitCode, 0, explicit.standardError)
        XCTAssertEqual(explicit.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), second)

        let invalid = try run(multipleOutput, requested: "Apple Development: Local Two")
        XCTAssertEqual(invalid.exitCode, 2)
        XCTAssertTrue(invalid.standardError.contains("40-character SHA-1 fingerprint"))
    }

    func testLocalReleaseSigningUsesCompatibleHostAndSignsWidgetBeforeApp() throws {
        let script = try buildAndRunScript()
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let functions = try [
            "resolve_local_code_sign_identity",
            "require_local_signing_host_compatibility",
            "sign_local_release_bundle"
        ].map { try XCTUnwrap(shellFunction(named: $0, in: script)) }
            .joined(separator: "\n")
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyLocalSigningTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let widget = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let fakeSecurity = temporaryDirectory.appendingPathComponent("fake-security.sh")
        let fakeSwVers = temporaryDirectory.appendingPathComponent("fake-sw-vers.sh")
        let fakeCodesign = temporaryDirectory.appendingPathComponent("fake-codesign.sh")
        let commandLog = temporaryDirectory.appendingPathComponent("codesign.log")
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        try Data("""
        #!/bin/bash
        printf '%s\n' '  1) C6B16796CD59EF90EDF3005A05276634FC8F27EA "Apple Development: Local"'
        """.utf8).write(to: fakeSecurity)
        try Data("#!/bin/bash\nprintf '%s\n' \"${FAKE_MACOS_VERSION}\"\n".utf8).write(to: fakeSwVers)
        try Data("#!/bin/bash\nprintf '%s\n' \"$*\" >>\"$FAKE_CODESIGN_LOG\"\n".utf8).write(to: fakeCodesign)
        for executable in [fakeSecurity, fakeSwVers, fakeCodesign] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let result = try runBash("""
        set -euo pipefail
        SIGNING_MODE=local
        APP_BUNDLE=\(shellQuote(app.path))
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        ROOT_DIR=\(shellQuote(repositoryURL.path))
        SECURITY_BIN=\(shellQuote(fakeSecurity.path))
        SW_VERS_BIN=\(shellQuote(fakeSwVers.path))
        CODESIGN_BIN=\(shellQuote(fakeCodesign.path))
        FAKE_MACOS_VERSION=14.8.7
        FAKE_CODESIGN_LOG=\(shellQuote(commandLog.path))
        export FAKE_MACOS_VERSION FAKE_CODESIGN_LOG
        unset TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY || true
        \(functions)
        sign_local_release_bundle
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("macOS=14.8.7"))
        XCTAssertTrue(result.standardOutput.contains("identity=C6B16796CD59EF90EDF3005A05276634FC8F27EA"))
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(commands[0].contains("--generate-entitlement-der"))
        XCTAssertTrue(commands[0].hasSuffix(widget.path))
        XCTAssertTrue(commands[1].contains("--generate-entitlement-der"))
        XCTAssertTrue(commands[1].hasSuffix(app.path))
        XCTAssertTrue(commands[2].contains("--verify --deep --strict"))
        XCTAssertTrue(commands[2].hasSuffix(app.path))

        let incompatible = try runBash("""
        set -euo pipefail
        SIGNING_MODE=local
        SW_VERS_BIN=\(shellQuote(fakeSwVers.path))
        FAKE_MACOS_VERSION=15.0
        export FAKE_MACOS_VERSION
        \(try XCTUnwrap(shellFunction(named: "require_local_signing_host_compatibility", in: script)))
        require_local_signing_host_compatibility
        """)
        XCTAssertEqual(incompatible.exitCode, 1)
        XCTAssertTrue(incompatible.standardError.contains("cannot preserve the group.com App Group contract"))
    }

    func testReleaseVerifierBinaryCanBeResolvedAfterAnIsolatedBuildStage() throws {
        let resolveFunction = try XCTUnwrap(
            shellFunction(named: "resolve_release_verifier_binary", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyVerifierResolutionTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let scriptDirectory = temporaryDirectory.appendingPathComponent("script")
        let binaryDirectory = temporaryDirectory.appendingPathComponent("bin")
        let swiftPM = scriptDirectory.appendingPathComponent("swiftpm.sh")
        let verifier = binaryDirectory.appendingPathComponent("TinyBuddyReleaseVerifier")
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        try Data("""
        #!/bin/bash
        printf '%s\n' \(shellQuote(binaryDirectory.path))
        """.utf8).write(to: swiftPM)
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: verifier)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftPM.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: verifier.path)

        let result = try runBash("""
        set -euo pipefail
        ROOT_DIR=\(shellQuote(temporaryDirectory.path))
        RELEASE_VERIFIER_BINARY=""
        \(resolveFunction)
        resolve_release_verifier_binary
        printf '%s\n' "$RELEASE_VERIFIER_BINARY"
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            verifier.path
        )
    }

    func testReleaseInstallerBinaryCanBeResolvedAfterAnIsolatedBuildStage() throws {
        let resolveFunction = try XCTUnwrap(
            shellFunction(named: "resolve_release_installer_binary", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyInstallerResolutionTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let scriptDirectory = temporaryDirectory.appendingPathComponent("script")
        let binaryDirectory = temporaryDirectory.appendingPathComponent("bin")
        let swiftPM = scriptDirectory.appendingPathComponent("swiftpm.sh")
        let installer = binaryDirectory.appendingPathComponent("TinyBuddyReleaseInstaller")
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        try Data("""
        #!/bin/bash
        printf '%s\n' \(shellQuote(binaryDirectory.path))
        """.utf8).write(to: swiftPM)
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: installer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftPM.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.path)

        let result = try runBash("""
        set -euo pipefail
        ROOT_DIR=\(shellQuote(temporaryDirectory.path))
        RELEASE_INSTALLER_BINARY=""
        \(resolveFunction)
        resolve_release_installer_binary
        printf '%s\n' "$RELEASE_INSTALLER_BINARY"
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            installer.path
        )
    }

    func testReplacementInstallUsesAtomicExchangeWithoutMovingTheInstalledBundleAway() throws {
        let script = try buildAndRunScript()
        let installFunction = try XCTUnwrap(
            shellFunction(named: "install_release_app", in: script)
        )
        let rollbackFunction = try XCTUnwrap(
            shellFunction(named: "rollback_release_install", in: script)
        )

        XCTAssertTrue(installFunction.contains(
            "RELEASE_STAGED_APP=\"$RELEASE_TRANSACTION_DIR/$APP_NAME.candidate\""
        ))
        XCTAssertTrue(installFunction.contains(
            "atomic_exchange_release_apps"
        ))
        XCTAssertTrue(installFunction.contains(
            "atomic_place_release_candidate"
        ))
        XCTAssertTrue(installFunction.contains(
            "\"$INSTALLED_APP\" >\"$RELEASE_EXCHANGE_STATUS_FILE\""
        ))
        XCTAssertFalse(installFunction.contains(
            "/bin/mv \"$INSTALLED_APP\" \"$RELEASE_BACKUP_APP\""
        ))
        XCTAssertFalse(installFunction.contains(
            "/bin/mv \"$RELEASE_STAGED_APP\" \"$INSTALLED_APP\""
        ))
        XCTAssertTrue(rollbackFunction.contains(
            "atomic_exchange_release_apps \"$RELEASE_BACKUP_APP\" \"$INSTALLED_APP\""
        ))
    }

    func testReleaseRegistrationPreflightRunsBeforeStoppingInstalledRuntime() throws {
        let script = try buildAndRunScript()
        for functionName in ["install_release_app", "verify_release_app_fresh"] {
            let function = try XCTUnwrap(shellFunction(named: functionName, in: script))
            let preflightOffset = try XCTUnwrap(
                function.range(of: "verify_widget_registration_preflight")
            ).lowerBound.utf16Offset(in: function)
            let stopOffset = try XCTUnwrap(
                function.range(of: "stop_release_runtime")
            ).lowerBound.utf16Offset(in: function)

            XCTAssertLessThan(preflightOffset, stopOffset, functionName)
        }
    }

    func testReleaseRegistrationPreflightAllowsMissingRecordOnlyForCleanInstall() throws {
        let preflightFunction = try XCTUnwrap(
            shellFunction(named: "verify_widget_registration_preflight", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetPreflightTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let installedApp = temporaryDirectory.appendingPathComponent("TinyBuddy.app")

        let result = try runBash("""
        set -euo pipefail
        INSTALLED_APP=\(shellQuote(installedApp.path))
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        registered_widget_paths() { return 0; }
        \(preflightFunction)
        verify_widget_registration_preflight
        printf 'clean-install-safe\n'
        /bin/mkdir "$INSTALLED_APP"
        if verify_widget_registration_preflight; then
          exit 91
        fi
        printf 'existing-install-refused\n'
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(
            result.standardOutput,
            "clean-install-safe\nexisting-install-refused\n"
        )
        XCTAssertTrue(result.standardError.contains("missing its Widget registration"))
    }

    func testReleaseInstallRollsBackPreviousBundleWhenActivationFails() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(
            shellFunction(named: "rollback_release_install", in: script)
        )
        let installFunction = try XCTUnwrap(
            shellFunction(named: "install_release_app", in: script)
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyBuddyReleaseInstallTests.\(UUID().uuidString)")
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        try FileManager.default.createDirectory(at: candidateApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: candidateApp.appendingPathComponent("marker"))
        try Data("old".utf8).write(to: installedApp.appendingPathComponent("marker"))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let probe = """
        set -euo pipefail
        APP_NAME=TinyBuddy
        APP_BUNDLE=\(shellQuote(candidateApp.path))
        INSTALL_DIR=\(shellQuote(installedApp.deletingLastPathComponent().path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        RELEASE_TRANSACTION_DIR=""
        RELEASE_STAGED_APP=""
        RELEASE_BACKUP_APP=""
        RELEASE_HAD_PREVIOUS=0
        RELEASE_SWITCHED=0
        RELEASE_PREVIOUS_APP_WAS_RUNNING=0
        validate_release_install_paths() { return 0; }
        verify_widget_registration_preflight() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { return 0; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        \(atomicExchangeReleaseAppsStub)
        activate_and_verify_release_app() { return 47; }
        restore_release_runtime() { return 0; }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """

        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 47)
        XCTAssertEqual(
            try String(contentsOf: installedApp.appendingPathComponent("marker"), encoding: .utf8),
            "old"
        )
        XCTAssertTrue(result.standardError.contains("rolled back"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: installedApp.deletingLastPathComponent().path
            ).contains(where: { $0.hasPrefix(".TinyBuddy.install.") })
        )
    }

    func testResolveSavedGitScanRootsUsesValidV2RecordsWithoutLegacyFallback() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyGitScanRootTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let authorizedRoot = temporaryDirectory.appendingPathComponent("authorized-root")
        try FileManager.default.createDirectory(at: authorizedRoot, withIntermediateDirectories: true)
        let validBookmark = try bookmarkData(for: authorizedRoot)
        let preferencesPlist = temporaryDirectory.appendingPathComponent("preferences.plist")
        try writePropertyList([
            "tinybuddy.gitScanRoots.records.v2": [
                [
                    "id": "valid-root",
                    "bookmarkData": validBookmark,
                    "displayName": "Authorized Root",
                    "lastKnownPath": authorizedRoot.path
                ],
                [
                    "id": "corrupt-root",
                    "bookmarkData": "not-bookmark-data",
                    "displayName": "Corrupt Root",
                    "lastKnownPath": "/not-used"
                ]
            ],
            "tinybuddy.gitScanRoots.bookmarkData": [Data("legacy-must-not-be-read".utf8)]
        ], to: preferencesPlist)

        let result = try runBash(resolveSavedGitScanRootsProbe(preferencesPlist))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, normalizedPath(for: authorizedRoot))
    }

    func testResolveSavedGitScanRootsFallsBackToLegacyOnlyWhenV2IsMissing() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyGitScanRootTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let authorizedRoot = temporaryDirectory.appendingPathComponent("legacy-root")
        try FileManager.default.createDirectory(at: authorizedRoot, withIntermediateDirectories: true)
        let preferencesPlist = temporaryDirectory.appendingPathComponent("preferences.plist")
        try writePropertyList([
            "tinybuddy.gitScanRoots.bookmarkData": [try bookmarkData(for: authorizedRoot)]
        ], to: preferencesPlist)

        let result = try runBash(resolveSavedGitScanRootsProbe(preferencesPlist))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, normalizedPath(for: authorizedRoot))
    }

    func testResolveSavedGitScanRootsReturnsEmptyForMalformedPlist() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyGitScanRootTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let preferencesPlist = temporaryDirectory.appendingPathComponent("preferences.plist")
        try Data("not a property list".utf8).write(to: preferencesPlist)

        let result = try runBash(resolveSavedGitScanRootsProbe(preferencesPlist))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "")
    }

    func testReleaseInstallSucceedsForFirstAndReplacementInstallWithoutTransactionResidue() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(
            shellFunction(named: "rollback_release_install", in: script)
        )
        let installFunction = try XCTUnwrap(
            shellFunction(named: "install_release_app", in: script)
        )

        try assertSuccessfulReleaseInstall(
            rollbackFunction: rollbackFunction,
            installFunction: installFunction,
            previousMarker: nil
        )
        try assertSuccessfulReleaseInstall(
            rollbackFunction: rollbackFunction,
            installFunction: installFunction,
            previousMarker: "old"
        )
    }

    func testReleaseInstallPreservesPreexistingTransactionResidue() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(
            shellFunction(named: "rollback_release_install", in: script)
        )
        let installFunction = try XCTUnwrap(
            shellFunction(named: "install_release_app", in: script)
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseResidueCollisionTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installDirectory = temporaryDirectory.appendingPathComponent("install")
        let installedApp = installDirectory.appendingPathComponent("TinyBuddy.app")
        try replaceTestBundle(at: candidateApp, version: "2.0", build: "2")
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let probe = releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        STALE_TRANSACTION="$INSTALL_DIR/.TinyBuddy.install.$$"
        /bin/mkdir "$STALE_TRANSACTION"
        printf 'preserved-recovery\n' >"$STALE_TRANSACTION/recovery-marker"
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        activate_and_verify_release_app() { return 0; }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        /bin/cat "$STALE_TRANSACTION/recovery-marker"
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(try bundleBuild(at: installedApp), "2")
        XCTAssertTrue(result.standardOutput.contains("preserved-recovery"))
        let residues = try FileManager.default.contentsOfDirectory(atPath: installDirectory.path)
            .filter { $0.hasPrefix(".TinyBuddy.install.") }
        XCTAssertEqual(residues.count, 1)
        let recoveryMarker = installDirectory
            .appendingPathComponent(try XCTUnwrap(residues.first))
            .appendingPathComponent("recovery-marker")
        XCTAssertEqual(
            try String(contentsOf: recoveryMarker, encoding: .utf8),
            "preserved-recovery\n"
        )
    }

    func testCleanInstallDestinationRacePreservesTheAppearingApp() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(
            shellFunction(named: "rollback_release_install", in: script)
        )
        let installFunction = try XCTUnwrap(
            shellFunction(named: "install_release_app", in: script)
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyCleanInstallRaceTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let appearingApp = temporaryDirectory.appendingPathComponent("appearing/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        try replaceTestBundle(at: candidateApp, version: "2.0", build: "2")
        try replaceTestBundle(at: appearingApp, version: "9.0", build: "9")
        try FileManager.default.createDirectory(
            at: installedApp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let probe = releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        APPEARING_APP=\(shellQuote(appearingApp.path))
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        activate_and_verify_release_app() { echo unexpected-activation; return 0; }
        atomic_place_release_candidate() {
          /usr/bin/ditto "$APPEARING_APP" "$2"
          return 73
        }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 73)
        XCTAssertEqual(try bundleBuild(at: installedApp), "9")
        XCTAssertFalse(result.standardOutput.contains("unexpected-activation"))
        XCTAssertFalse(try transactionResidueExists(in: installedApp.deletingLastPathComponent()))
    }

    func testReleaseInstallMatrixPreservesUserDataAndAuthorizationsAcrossReinstallAndUpgrades() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(shellFunction(named: "rollback_release_install", in: script))
        let installFunction = try XCTUnwrap(shellFunction(named: "install_release_app", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseInstallMatrixTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        let appPreferences = temporaryDirectory.appendingPathComponent("container/app.plist")
        let groupPreferences = temporaryDirectory.appendingPathComponent("container/group.plist")
        let appSentinel = Data("user-settings-sentinel".utf8)
        let groupSentinel = Data("authorization-records-sentinel".utf8)
        try FileManager.default.createDirectory(at: candidateApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try appSentinel.write(to: appPreferences)
        try groupSentinel.write(to: groupPreferences)

        for (version, build, expectedScenario) in [
            ("1.0", "1", "clean-install"),
            ("1.0", "1", "same-version-reinstall"),
            ("1.0", "2", "older-version-upgrade"),
            ("2.0", "3", "older-version-upgrade"),
            ("3.0", "4", "older-version-upgrade")
        ] {
            try replaceTestBundle(at: candidateApp, version: version, build: build)
            XCTAssertEqual(
                try releaseInstallScenario(candidateApp: candidateApp, installedApp: installedApp),
                expectedScenario
            )
            let result = try runReleaseInstallProbe(
                rollbackFunction: rollbackFunction,
                installFunction: installFunction,
                candidateApp: candidateApp,
                installedApp: installedApp
            )

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertEqual(try bundleVersion(at: installedApp), version)
            XCTAssertEqual(try bundleBuild(at: installedApp), build)
            XCTAssertEqual(try Data(contentsOf: appPreferences), appSentinel)
            XCTAssertEqual(try Data(contentsOf: groupPreferences), groupSentinel)
            XCTAssertFalse(try transactionResidueExists(in: installedApp.deletingLastPathComponent()))
        }

        try replaceTestBundle(at: candidateApp, version: "2.0", build: "4")
        XCTAssertEqual(
            try releaseInstallScenario(candidateApp: candidateApp, installedApp: installedApp),
            "version-downgrade"
        )
    }

    func testReleaseInstallTermInterruptRunsExitRollbackAndCleansTransaction() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(shellFunction(named: "rollback_release_install", in: script))
        let installFunction = try XCTUnwrap(shellFunction(named: "install_release_app", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseInstallInterruptTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        try replaceTestBundle(at: candidateApp, version: "2.0", build: "2")
        try replaceTestBundle(at: installedApp, version: "1.0", build: "1")

        let probe = releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        activate_and_verify_release_app() { kill -TERM "$$"; }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 143)
        XCTAssertEqual(try bundleBuild(at: installedApp), "1")
        XCTAssertTrue(result.standardError.contains("rolled back"))
        XCTAssertFalse(try transactionResidueExists(in: installedApp.deletingLastPathComponent()))
    }

    func testReleaseInstallTermAfterAtomicExchangeUsesStatusMarkerToRollback() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(shellFunction(named: "rollback_release_install", in: script))
        let installFunction = try XCTUnwrap(shellFunction(named: "install_release_app", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseExchangeInterruptTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        try replaceTestBundle(at: candidateApp, version: "2.0", build: "2")
        try replaceTestBundle(at: installedApp, version: "1.0", build: "1")

        let probe = releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        activate_and_verify_release_app() { echo unexpected-activation; return 0; }
        EXCHANGE_CALL_COUNT=0
        atomic_exchange_release_apps() {
          EXCHANGE_CALL_COUNT=$((EXCHANGE_CALL_COUNT + 1))
          local temporary_path="$1.exchange-interrupt"
          /bin/mv "$1" "$temporary_path"
          /bin/mv "$2" "$1"
          /bin/mv "$temporary_path" "$2"
          printf 'TINYBUDDY_RELEASE_INSTALLER_EXCHANGED\n'
          if [ "$EXCHANGE_CALL_COUNT" -eq 1 ]; then
            kill -TERM "$$"
          fi
        }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 143)
        XCTAssertEqual(try bundleBuild(at: installedApp), "1")
        XCTAssertFalse(result.standardOutput.contains("unexpected-activation"))
        XCTAssertTrue(result.standardError.contains("rolled back"))
        XCTAssertFalse(try transactionResidueExists(in: installedApp.deletingLastPathComponent()))
    }

    func testReleaseInstallerUncertainExitForcesPreviousBundleRollback() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(shellFunction(named: "rollback_release_install", in: script))
        let installFunction = try XCTUnwrap(shellFunction(named: "install_release_app", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseUncertainExchangeTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        try replaceTestBundle(at: candidateApp, version: "2.0", build: "2")
        try replaceTestBundle(at: installedApp, version: "1.0", build: "1")

        let probe = releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        activate_and_verify_release_app() { echo unexpected-activation; return 0; }
        EXCHANGE_CALL_COUNT=0
        atomic_exchange_release_apps() {
          EXCHANGE_CALL_COUNT=$((EXCHANGE_CALL_COUNT + 1))
          local temporary_path="$1.exchange-uncertain"
          /bin/mv "$1" "$temporary_path"
          /bin/mv "$2" "$1"
          /bin/mv "$temporary_path" "$2"
          if [ "$EXCHANGE_CALL_COUNT" -eq 1 ]; then
            return 75
          fi
          printf 'TINYBUDDY_RELEASE_INSTALLER_EXCHANGED\n'
        }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 75)
        XCTAssertEqual(try bundleBuild(at: installedApp), "1")
        XCTAssertFalse(result.standardOutput.contains("unexpected-activation"))
        XCTAssertTrue(result.standardError.contains("rolled back"))
        XCTAssertFalse(try transactionResidueExists(in: installedApp.deletingLastPathComponent()))
    }

    func testReleaseInstallerUncertainExitPreservesOldBundleWhenRollbackFails() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(shellFunction(named: "rollback_release_install", in: script))
        let installFunction = try XCTUnwrap(shellFunction(named: "install_release_app", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseUncertainRecoveryTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installDirectory = temporaryDirectory.appendingPathComponent("install")
        let installedApp = installDirectory.appendingPathComponent("TinyBuddy.app")
        try replaceTestBundle(at: candidateApp, version: "2.0", build: "2")
        try replaceTestBundle(at: installedApp, version: "1.0", build: "1")

        let probe = releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        activate_and_verify_release_app() { echo unexpected-activation; return 0; }
        EXCHANGE_CALL_COUNT=0
        atomic_exchange_release_apps() {
          EXCHANGE_CALL_COUNT=$((EXCHANGE_CALL_COUNT + 1))
          if [ "$EXCHANGE_CALL_COUNT" -gt 1 ]; then
            return 93
          fi
          local temporary_path="$1.exchange-uncertain"
          /bin/mv "$1" "$temporary_path"
          /bin/mv "$2" "$1"
          /bin/mv "$temporary_path" "$2"
          return 75
        }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 75)
        XCTAssertEqual(try bundleBuild(at: installedApp), "2")
        XCTAssertFalse(result.standardOutput.contains("unexpected-activation"))
        XCTAssertTrue(result.standardError.contains("rollback was incomplete"))
        let residueName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: installDirectory.path)
                .first(where: { $0.hasPrefix(".TinyBuddy.install.") })
        )
        let preservedPreviousApp = installDirectory
            .appendingPathComponent(residueName)
            .appendingPathComponent("TinyBuddy.candidate")
        XCTAssertEqual(try bundleBuild(at: preservedPreviousApp), "1")
    }

    func testReleaseInstallerNonProtocolExitPreservesBothBundlesForRecovery() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(shellFunction(named: "rollback_release_install", in: script))
        let installFunction = try XCTUnwrap(shellFunction(named: "install_release_app", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseCrashedExchangeTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installDirectory = temporaryDirectory.appendingPathComponent("install")
        let installedApp = installDirectory.appendingPathComponent("TinyBuddy.app")
        try replaceTestBundle(at: candidateApp, version: "2.0", build: "2")
        try replaceTestBundle(at: installedApp, version: "1.0", build: "1")

        let probe = releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        activate_and_verify_release_app() { echo unexpected-activation; return 0; }
        atomic_exchange_release_apps() {
          local temporary_path="$1.exchange-crash"
          /bin/mv "$1" "$temporary_path"
          /bin/mv "$2" "$1"
          /bin/mv "$temporary_path" "$2"
          return 99
        }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 99)
        XCTAssertEqual(try bundleBuild(at: installedApp), "2")
        XCTAssertFalse(result.standardOutput.contains("unexpected-activation"))
        XCTAssertTrue(result.standardError.contains("exchange state is uncertain"))
        XCTAssertTrue(result.standardError.contains("rollback was incomplete"))
        let residueName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: installDirectory.path)
                .first(where: { $0.hasPrefix(".TinyBuddy.install.") })
        )
        let preservedPreviousApp = installDirectory
            .appendingPathComponent(residueName)
            .appendingPathComponent("TinyBuddy.candidate")
        XCTAssertEqual(try bundleBuild(at: preservedPreviousApp), "1")
    }

    func testReleaseInstallRollsBackWhenWidgetRegistrationFails() throws {
        let script = try buildAndRunScript()
        let rollbackFunction = try XCTUnwrap(shellFunction(named: "rollback_release_install", in: script))
        let installFunction = try XCTUnwrap(shellFunction(named: "install_release_app", in: script))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetRegistrationFailureTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        try replaceTestBundle(at: candidateApp, version: "2.0", build: "2")
        try replaceTestBundle(at: installedApp, version: "1.0", build: "1")

        let probe = releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        restore_release_runtime() { return 0; }
        register_widget_extension() { return 71; }
        activate_and_verify_release_app() { register_widget_extension "$INSTALLED_APP"; }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 71)
        XCTAssertEqual(try bundleBuild(at: installedApp), "1")
        XCTAssertTrue(result.standardError.contains("rolled back"))
        XCTAssertFalse(try transactionResidueExists(in: installedApp.deletingLastPathComponent()))
    }

    func testStopReleaseRuntimeTerminatesAppAndWidgetProcesses() throws {
        let stopFunction = try XCTUnwrap(shellFunction(named: "stop_release_runtime", in: try buildAndRunScript()))
        let result = try runBash("""
        set -euo pipefail
        APP_NAME=TinyBuddy
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        APP_RUNTIME_TIMEOUT=7
        WIDGET_RUNTIME_TIMEOUT=11
        terminate_release_process() { echo "$1:$2"; }
        \(stopFunction)
        stop_release_runtime
        """)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "TinyBuddy:7\nTinyBuddyWidgetExtension:11\n")
    }

    func testInstalledReleaseLaunchBypassesLaunchServicesForPreservedRegistration() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyInstalledLaunchTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let installedApp = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let installedExecutable = installedApp.appendingPathComponent("Contents/MacOS/TinyBuddy")
        let commandLog = temporaryDirectory.appendingPathComponent("open-commands.log")
        let fakeOpen = temporaryDirectory.appendingPathComponent("fake-open.sh")
        try FileManager.default.createDirectory(
            at: installedExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        #!/bin/bash
        if { : <&9; } 2>/dev/null; then
          printf 'fd9:open\\n' >> "$FAKE_OPEN_COMMAND_LOG"
        else
          printf 'fd9:closed\\n' >> "$FAKE_OPEN_COMMAND_LOG"
        fi
        kill -HUP "$$"
        printf 'direct:%s\\n' "$0" >> "$FAKE_OPEN_COMMAND_LOG"
        kill -TERM "$$"
        printf 'survived-term\\n' >> "$FAKE_OPEN_COMMAND_LOG"
        """.utf8).write(to: installedExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedExecutable.path
        )
        try Data("""
        #!/bin/bash
        printf 'open:%s\n' "$*" >> "$FAKE_OPEN_COMMAND_LOG"
        """.utf8).write(to: fakeOpen)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
        let launchFunction = try XCTUnwrap(
            shellFunction(named: "launch_installed_release_app", in: try buildAndRunScript())
        ).replacingOccurrences(of: "/usr/bin/open", with: shellQuote(fakeOpen.path))
        XCTAssertTrue(
            launchFunction.contains(
                "trap - INT TERM\n      trap '' HUP\n      exec 9>&-\n      exec \"$app_executable\""
            )
        )

        let result = try runBash("""
        set -euo pipefail
        APP_NAME=TinyBuddy
        INSTALLED_APP=\(shellQuote(installedApp.path))
        FAKE_OPEN_COMMAND_LOG=\(shellQuote(commandLog.path))
        export FAKE_OPEN_COMMAND_LOG
        exec 9<>\(shellQuote(temporaryDirectory.appendingPathComponent("release-lock").path))
        \(launchFunction)
        trap '' HUP INT TERM
        RELEASE_WIDGET_REGISTRATION_PRESERVED=1
        launch_installed_release_app
        launched_pid=$!
        set +e
        wait "$launched_pid"
        direct_status=$?
        set -e
        printf 'direct-status:%s\n' "$direct_status" >> "$FAKE_OPEN_COMMAND_LOG"
        trap - HUP INT TERM
        RELEASE_WIDGET_REGISTRATION_PRESERVED=0
        launch_installed_release_app
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(
            try String(contentsOf: commandLog, encoding: .utf8),
            "fd9:closed\ndirect:\(installedExecutable.path)\ndirect-status:143\nopen:-n \(installedApp.path)\n"
        )
    }

    func testProcessIdsMatchesFullWidgetExecutableNameBeyondPgrepLimit() throws {
        let processIDsFunction = try XCTUnwrap(
            shellFunction(named: "process_ids", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyProcessIDTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fakePS = temporaryDirectory.appendingPathComponent("fake-ps.sh")
        try Data("""
        #!/bin/bash
        echo '  101 501 /Applications/TinyBuddy.app/Contents/PlugIns/TinyBuddyWidgetExtension.appex/Contents/MacOS/TinyBuddyWidgetExtension'
        echo '  102 501 /tmp/TinyBuddyWidgetExtensionHelper'
        echo '  103 501 /Applications/TinyBuddy.app/Contents/MacOS/TinyBuddy'
        echo '  104 502 /tmp/Old/TinyBuddy.app/Contents/PlugIns/TinyBuddyWidgetExtension.appex/Contents/MacOS/TinyBuddyWidgetExtension'
        echo '  105 501 TinyBuddyWidgetExtension'
        """.utf8).write(to: fakePS)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakePS.path
        )

        let result = try runBash("""
        set -euo pipefail
        PS_BIN=\(shellQuote(fakePS.path))
        CURRENT_USER_UID=501
        APP_NAME=TinyBuddy
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        \(processIDsFunction)
        process_ids TinyBuddyWidgetExtension
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(result.standardOutput, "101 ", result.standardError)
        XCTAssertFalse(processIDsFunction.contains("pgrep"))
    }

    func testWidgetSnapshotConsumptionRequiresExactRevisionAfterChangeAndCompatibleRevisionWhenStable() throws {
        let verificationFunction = try XCTUnwrap(
            shellFunction(named: "verify_widget_snapshot_consumption", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetLogTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fakeLog = temporaryDirectory.appendingPathComponent("fake-log.sh")
        try Data("""
        #!/bin/bash
        echo "snapshot consumed schema=$FAKE_SCHEMA revision=$FAKE_REVISION day=$FAKE_DAY"
        """.utf8).write(to: fakeLog)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeLog.path
        )

        func run(
            revision: String,
            schema: String = "2",
            day: String = "2026-07-17",
            contentChanged: Bool = true
        ) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
            try runBash("""
            set -euo pipefail
            LOG_BIN=\(shellQuote(fakeLog.path))
            FAKE_SCHEMA=\(shellQuote(schema))
            FAKE_REVISION=\(shellQuote(revision))
            FAKE_DAY=\(shellQuote(day))
            export FAKE_SCHEMA FAKE_REVISION FAKE_DAY
            WIDGET_RUNTIME_TIMEOUT=0
            \(verificationFunction)
            verify_widget_snapshot_consumption 999 2 4 2026-07-17 \(contentChanged)
            """)
        }

        let prefixCollision = try run(revision: "42")
        XCTAssertEqual(prefixCollision.exitCode, 1)
        XCTAssertTrue(prefixCollision.standardError.contains("did not log consumption"))

        let exactMatch = try run(revision: "4")
        XCTAssertEqual(exactMatch.exitCode, 0)
        XCTAssertTrue(exactMatch.standardOutput.contains("revision=4 day=2026-07-17"))

        let stablePriorRevision = try run(revision: "3", contentChanged: false)
        XCTAssertEqual(stablePriorRevision.exitCode, 0)
        XCTAssertTrue(stablePriorRevision.standardOutput.contains("consumed_revision=3"))
        XCTAssertTrue(stablePriorRevision.standardOutput.contains("current_revision=4"))

        let futureRevision = try run(revision: "5", contentChanged: false)
        XCTAssertEqual(futureRevision.exitCode, 1)
        XCTAssertTrue(futureRevision.standardError.contains("compatible stable shared snapshot"))

        let wrongSchema = try run(revision: "3", schema: "3", contentChanged: false)
        XCTAssertEqual(wrongSchema.exitCode, 1)

        let wrongDay = try run(revision: "3", day: "2026-07-16", contentChanged: false)
        XCTAssertEqual(wrongDay.exitCode, 1)
    }

    func testHUDSnapshotConsumptionRequiresExactRevisionAndDay() throws {
        let verificationFunction = try XCTUnwrap(
            shellFunction(named: "verify_hud_snapshot_consumption", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyHUDSnapshotLogTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fakeLog = temporaryDirectory.appendingPathComponent("fake-log.sh")
        try Data("""
        #!/bin/bash
        case " $* " in
          *" --info "*) ;;
          *) exit 64 ;;
        esac
        echo "HUD consumed schema=2 revision=$FAKE_REVISION day=2026-07-17"
        """.utf8).write(to: fakeLog)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeLog.path
        )

        func run(revision: String) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
            try runBash("""
            set -euo pipefail
            LOG_BIN=\(shellQuote(fakeLog.path))
            FAKE_REVISION=\(shellQuote(revision))
            export FAKE_REVISION
            APP_RUNTIME_TIMEOUT=0
            SANDBOX_RECOVERY_TIMEOUT=0
            \(verificationFunction)
            verify_hud_snapshot_consumption 998 2 4 2026-07-17
            """)
        }

        let prefixCollision = try run(revision: "42")
        XCTAssertEqual(prefixCollision.exitCode, 1)
        XCTAssertTrue(prefixCollision.standardError.contains("did not log consumption"))

        let exactMatch = try run(revision: "4")
        XCTAssertEqual(exactMatch.exitCode, 0)
        XCTAssertTrue(exactMatch.standardOutput.contains("revision=4 day=2026-07-17"))
    }

    func testTelemetryModeIncludesReleaseHUDAndWidgetSubsystem() throws {
        let script = try buildAndRunScript()

        XCTAssertTrue(
            script.contains(
                #"--predicate "subsystem == \"$BUNDLE_ID\" OR subsystem == \"local.tinybuddy\"""#
            )
        )
    }

    func testHUDVerificationRequiresExactTelemetryFromTheFreshAppProcess() throws {
        let verificationFunction = try XCTUnwrap(
            shellFunction(named: "verify_hud_window", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyHUDLogTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fakeLog = temporaryDirectory.appendingPathComponent("fake-log.sh")
        try Data("""
        #!/bin/bash
        echo "$FAKE_HUD_MESSAGE"
        """.utf8).write(to: fakeLog)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeLog.path
        )

        func run(message: String) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
            try runBash("""
            set -euo pipefail
            LOG_BIN=\(shellQuote(fakeLog.path))
            FAKE_HUD_MESSAGE=\(shellQuote(message))
            export FAKE_HUD_MESSAGE
            APP_RUNTIME_TIMEOUT=0
            \(verificationFunction)
            verify_hud_window 4242
            """)
        }

        let unrelatedWindow = try run(message: "HUD ready identifier=Settings width=284 height=520")
        XCTAssertEqual(unrelatedWindow.exitCode, 1)
        XCTAssertTrue(unrelatedWindow.standardError.contains("did not publish exact HUD-ready telemetry"))

        let exactHUD = try run(message: "HUD ready identifier=TinyBuddy.HUDWindow width=284 height=520")
        XCTAssertEqual(exactHUD.exitCode, 0)
        XCTAssertTrue(exactHUD.standardOutput.contains("pid=4242 width=284 height=520"))
    }

    func testFindWidgetExtensionRejectsDuplicateExtensions() throws {
        let findFunction = try XCTUnwrap(shellFunction(named: "find_widget_extension", in: try buildAndRunScript()))
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyDuplicateWidgetTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Extensions/TinyBuddyWidgetExtension.appex"), withIntermediateDirectories: true)
        let result = try runBash("""
        set -euo pipefail
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        \(findFunction)
        find_widget_extension \(shellQuote(app.path))
        """)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.standardError.contains("expected exactly one TinyBuddyWidgetExtension.appex"))
        XCTAssertTrue(result.standardError.contains("found 2"))
    }

    func testWidgetRegistrationPreservesTheUniqueInstalledRecordWithoutMutation() throws {
        let registrationFunction = try XCTUnwrap(
            shellFunction(named: "register_widget_extension", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetRegistrationTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let appex = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)

        let result = try runBash("""
        set -euo pipefail
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=/usr/bin/false
        RELEASE_WIDGET_REGISTRATION_PRESERVED=0
        find_widget_extension() { printf '%s\n' \(shellQuote(appex.path)); }
        registered_widget_paths() { printf '%s\n' \(shellQuote(appex.path)); }
        \(registrationFunction)
        register_widget_extension \(shellQuote(app.path))
        printf 'preserved=%s\n' "$RELEASE_WIDGET_REGISTRATION_PRESERVED"
        """)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("preserved existing widget extension registration"))
        XCTAssertTrue(result.standardOutput.contains("preserved=1"))
    }

    func testWidgetRegistrationAddFailureIsReturnedForCleanInstall() throws {
        let registrationFunction = try XCTUnwrap(
            shellFunction(named: "register_widget_extension", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetRegistrationTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let appex = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let fakePlugInKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")
        let commandLog = temporaryDirectory.appendingPathComponent("commands.log")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try Data("""
        #!/bin/bash
        echo "$*" >> "$FAKE_PLUGIN_COMMAND_LOG"
        if [ "$1" = "-a" ]; then
          exit 71
        fi
        exit 0
        """.utf8).write(to: fakePlugInKit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakePlugInKit.path
        )

        let result = try runBash("""
        set -euo pipefail
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=\(shellQuote(fakePlugInKit.path))
        FAKE_PLUGIN_COMMAND_LOG=\(shellQuote(commandLog.path))
        export FAKE_PLUGIN_COMMAND_LOG
        find_widget_extension() { printf '%s\n' \(shellQuote(appex.path)); }
        registered_widget_paths() { return 0; }
        \(registrationFunction)
        register_widget_extension \(shellQuote(app.path)) 1
        """)

        XCTAssertEqual(result.exitCode, 71)
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains("-a \(appex.path)"))
        XCTAssertFalse(commands.contains("-r "))
    }

    func testWidgetRegistrationRefusesMissingRecordOutsideCleanInstallWithoutMutation() throws {
        let registrationFunction = try XCTUnwrap(
            shellFunction(named: "register_widget_extension", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetRegistrationTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let appex = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let commandLog = temporaryDirectory.appendingPathComponent("commands.log")
        let fakePluginKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try Data("""
        #!/bin/bash
        echo "$*" >> "$FAKE_PLUGIN_COMMAND_LOG"
        exit 0
        """.utf8).write(to: fakePluginKit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakePluginKit.path
        )

        let result = try runBash("""
        set -euo pipefail
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=\(shellQuote(fakePluginKit.path))
        FAKE_PLUGIN_COMMAND_LOG=\(shellQuote(commandLog.path))
        export FAKE_PLUGIN_COMMAND_LOG
        find_widget_extension() { printf '%s\n' \(shellQuote(appex.path)); }
        registered_widget_paths() { return 0; }
        \(registrationFunction)
        register_widget_extension \(shellQuote(app.path))
        """)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.standardError.contains("allowed only during a clean install"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandLog.path))
    }

    func testWidgetRegistrationRefusesStaleRecordsWithoutMutation() throws {
        let registrationFunction = try XCTUnwrap(
            shellFunction(named: "register_widget_extension", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyWidgetRegistrationTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let app = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let appex = app.appendingPathComponent("Contents/PlugIns/TinyBuddyWidgetExtension.appex")
        let commandLog = temporaryDirectory.appendingPathComponent("commands.log")
        let fakePluginKit = temporaryDirectory.appendingPathComponent("fake-pluginkit.sh")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try Data("""
        #!/bin/bash
        echo "$*" >> "$FAKE_PLUGIN_COMMAND_LOG"
        exit 0
        """.utf8).write(to: fakePluginKit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakePluginKit.path
        )

        let result = try runBash("""
        set -euo pipefail
        WIDGET_EXTENSION_NAME=TinyBuddyWidgetExtension
        WIDGET_RUNTIME_TIMEOUT=0
        PLUGINKIT_BIN=\(shellQuote(fakePluginKit.path))
        FAKE_PLUGIN_COMMAND_LOG=\(shellQuote(commandLog.path))
        export FAKE_PLUGIN_COMMAND_LOG
        find_widget_extension() { printf '%s\n' \(shellQuote(appex.path)); }
        registered_widget_paths() { printf '%s\n' /tmp/stale.appex; }
        \(registrationFunction)
        register_widget_extension \(shellQuote(app.path))
        """)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.standardError.contains("refusing to replace existing Widget registrations"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandLog.path))
    }

    func testRunReleaseStageReportsStageCommandAndLogAndPreservesExitCode() throws {
        let script = try buildAndRunScript()
        let stageFunctions = try [
            "write_release_status_file",
            "write_release_stage_status",
            "run_release_stage"
        ].map { try XCTUnwrap(shellFunction(named: $0, in: script)) }
            .joined(separator: "\n")
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseStageTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let result = try runBash("""
        set -euo pipefail
        RELEASE_EVIDENCE_DIR=\(shellQuote(temporaryDirectory.path))
        RELEASE_STAGE_INDEX=0
        RELEASE_ACTIVE_STAGE_PID=""
        RELEASE_SIGNAL_NAME=""
        RELEASE_SIGNAL_STATUS=0
        RELEASE_SIGNAL_FORWARDED=0
        forward_pending_release_signal_to_stage() { return 0; }
        failing_stage() { echo 'error: injected failure' >&2; return 37; }
        \(stageFunctions)
        run_release_stage injected-stage failing_stage
        """)

        XCTAssertEqual(result.exitCode, 37)
        XCTAssertTrue(result.standardError.contains("release stage failed: stage=injected-stage exit=37"))
        XCTAssertTrue(result.standardError.contains("failed command: failing_stage"))
        XCTAssertTrue(result.standardError.contains("stage log: \(temporaryDirectory.path)/01-injected-stage.log"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("01-injected-stage.log").path))
        let status = try String(
            contentsOf: temporaryDirectory.appendingPathComponent("01-injected-stage.status"),
            encoding: .utf8
        )
        XCTAssertTrue(status.contains("state=failed"))
        XCTAssertTrue(status.contains("exit_status=37"))
        XCTAssertTrue(status.contains("command=failing_stage"))
    }

    func testReleaseAcceptanceRunsFullOrderedGateAndReleaseModesRequireLocalOrSignedSigning() throws {
        let script = try buildAndRunScript()
        let acceptance = try XCTUnwrap(shellFunction(named: "run_release_acceptance_stages", in: script))
        let requiredStages = [
            "swift-test",
            "release-build",
            "candidate-contract",
            "environment-preflight",
            "primary-install",
            "same-version-reinstall",
            "final-fresh-verification"
        ]
        var previousOffset = -1
        for stage in requiredStages {
            let offset = try XCTUnwrap(acceptance.range(of: stage)?.lowerBound).utf16Offset(in: acceptance)
            XCTAssertGreaterThan(offset, previousOffset)
            previousOffset = offset
        }
        XCTAssertTrue(
            modeBlock("release-acceptance|--release-acceptance", in: script)
                .contains("run_locked_release_workflow run_release_acceptance_stages")
        )
        XCTAssertTrue(script.contains("SIGNING_MODE=\"${TINYBUDDY_SIGNING_MODE:-local}\""))
        XCTAssertTrue(script.contains("local|signed)"))
        XCTAssertTrue(script.contains("$MODE requires TINYBUDDY_SIGNING_MODE=local or signed"))
        XCTAssertTrue(script.contains("SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)"))
    }

    func testReleaseVerificationRequiresRunningAppAndWidgetFromInstalledBundle() throws {
        let script = try buildAndRunScript()
        let verificationFunction = try XCTUnwrap(
            shellFunction(named: "verify_release_app", in: script)
        )

        XCTAssertTrue(verificationFunction.contains("verify_installed_matches_build"))
        XCTAssertTrue(verificationFunction.contains("wait_for_running_bundle_process"))
        XCTAssertTrue(verificationFunction.contains("$APP_NAME"))
        XCTAssertTrue(verificationFunction.contains("$WIDGET_EXTENSION_NAME"))
        XCTAssertTrue(verificationFunction.contains("verify_installed_sandbox_bookmark_recovery"))
        XCTAssertTrue(verificationFunction.contains("verify_hud_window"))
        XCTAssertTrue(verificationFunction.contains("verify_authorization_record_preservation"))
        XCTAssertTrue(verificationFunction.contains("verify_shared_snapshot_contract"))
        XCTAssertTrue(verificationFunction.contains("verify_hud_snapshot_consumption"))
        XCTAssertTrue(verificationFunction.contains("verify_widget_snapshot_consumption"))
        XCTAssertTrue(verificationFunction.contains("$RELEASE_REFRESH_WIDGET_CONTENT_CHANGED"))
        XCTAssertTrue(verificationFunction.contains("verify_running_bundle_process"))
        XCTAssertTrue(verificationFunction.contains("${RELEASE_HAD_PREVIOUS:-0}"))
        XCTAssertTrue(verificationFunction.contains("${RELEASE_SWITCHED:-0}"))
        XCTAssertTrue(verificationFunction.contains("allow_widget_registration_add=1"))
        XCTAssertTrue(verificationFunction.contains("$allow_widget_registration_add"))
        let appWaitOffset = try XCTUnwrap(
            verificationFunction.range(of: "wait_for_running_bundle_process \"$APP_NAME\"")
        ).lowerBound.utf16Offset(in: verificationFunction)
        let hudOffset = try XCTUnwrap(
            verificationFunction.range(of: "verify_hud_window")
        ).lowerBound.utf16Offset(in: verificationFunction)
        let widgetWaitOffset = try XCTUnwrap(
            verificationFunction.range(of: "wait_for_running_bundle_process \"$WIDGET_EXTENSION_NAME\"")
        ).lowerBound.utf16Offset(in: verificationFunction)
        XCTAssertLessThan(appWaitOffset, hudOffset)
        XCTAssertLessThan(hudOffset, widgetWaitOffset)
        let sharedSnapshotOffset = try XCTUnwrap(
            verificationFunction.range(of: "verify_shared_snapshot_contract")
        ).lowerBound.utf16Offset(in: verificationFunction)
        let hudConsumptionOffset = try XCTUnwrap(
            verificationFunction.range(of: "verify_hud_snapshot_consumption")
        ).lowerBound.utf16Offset(in: verificationFunction)
        let widgetConsumptionOffset = try XCTUnwrap(
            verificationFunction.range(of: "verify_widget_snapshot_consumption")
        ).lowerBound.utf16Offset(in: verificationFunction)
        XCTAssertLessThan(sharedSnapshotOffset, hudConsumptionOffset)
        XCTAssertLessThan(hudConsumptionOffset, widgetConsumptionOffset)
        let refreshedWidgetWaitOffset = try XCTUnwrap(
            verificationFunction.range(
                of: "wait_for_running_bundle_process \\",
                range: verificationFunction.index(
                    verificationFunction.startIndex,
                    offsetBy: hudConsumptionOffset
                )..<verificationFunction.endIndex
            )
        ).lowerBound.utf16Offset(in: verificationFunction)
        XCTAssertLessThan(hudConsumptionOffset, refreshedWidgetWaitOffset)
        XCTAssertLessThan(refreshedWidgetWaitOffset, widgetConsumptionOffset)
        let finalAppProcessOffset = try XCTUnwrap(
            verificationFunction.range(of: "verify_running_bundle_process")
        ).lowerBound.utf16Offset(in: verificationFunction)
        let finalWidgetProcessOffset = try XCTUnwrap(
            verificationFunction.range(
                of: "verify_running_bundle_process",
                range: verificationFunction.index(
                    verificationFunction.startIndex,
                    offsetBy: finalAppProcessOffset + 1
                )..<verificationFunction.endIndex
            )
        ).lowerBound.utf16Offset(in: verificationFunction)
        XCTAssertLessThan(widgetConsumptionOffset, finalAppProcessOffset)
        XCTAssertLessThan(finalAppProcessOffset, finalWidgetProcessOffset)
        XCTAssertTrue(
            verificationFunction[
                verificationFunction.index(
                    verificationFunction.startIndex,
                    offsetBy: finalWidgetProcessOffset
                )...
            ].contains("$widget_executable")
        )
    }

    func testReleaseBundleRequiresExpectedSigningIdentityEntitlementsAndUniqueWidget() throws {
        let script = try buildAndRunScript()
        let bundleVerification = try XCTUnwrap(
            shellFunction(named: "verify_release_bundle", in: script)
        )
        let signingVerification = try XCTUnwrap(
            shellFunction(named: "verify_code_signing_contract", in: script)
        )

        XCTAssertTrue(bundleVerification.contains("verify_code_signing_contract"))
        XCTAssertTrue(bundleVerification.contains("verify_widget_extension_bundle"))
        XCTAssertTrue(signingVerification.contains("$EXPECTED_TEAM_ID"))
        XCTAssertTrue(signingVerification.contains("com.apple.security.app-sandbox"))
        XCTAssertTrue(signingVerification.contains("com.apple.security.files.bookmarks.app-scope"))
        XCTAssertTrue(signingVerification.contains("com.apple.security.files.user-selected.read-only"))
        XCTAssertTrue(signingVerification.contains("require_app_group_entitlement"))
        XCTAssertTrue(signingVerification.contains("signing_leaf_authority"))
        XCTAssertTrue(signingVerification.contains("Apple Development:"))
        XCTAssertTrue(signingVerification.contains("SIGNING_MODE\" = \"local"))
        XCTAssertTrue(signingVerification.contains("embedded.provisionprofile"))
        XCTAssertTrue(signingVerification.contains("require_entitlement_key_count \"$app_entitlements\" 4"))
        XCTAssertTrue(signingVerification.contains("require_entitlement_key_count \"$widget_entitlements\" 2"))
        XCTAssertTrue(signingVerification.contains("com.apple.application-identifier"))
        XCTAssertTrue(signingVerification.contains("com.apple.developer.team-identifier"))
        XCTAssertTrue(signingVerification.contains("com.apple.security.get-task-allow"))
        XCTAssertTrue(signingVerification.contains("require_entitlement_key_count \"$app_entitlements\" 7"))
        XCTAssertTrue(signingVerification.contains("require_entitlement_key_count \"$widget_entitlements\" 5"))
    }

    func testEntitlementAllowlistRejectsAnAdditionalFileAccessKey() throws {
        let keyCountFunction = try XCTUnwrap(
            shellFunction(named: "require_entitlement_key_count", in: try buildAndRunScript())
        )
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyEntitlementTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let expected = temporaryDirectory.appendingPathComponent("expected.plist")
        let unexpected = temporaryDirectory.appendingPathComponent("unexpected.plist")
        var entitlements: [String: Any] = [
            "com.apple.application-identifier": "JYL9G28DP3.com.ryukeili.TinyBuddy",
            "com.apple.developer.team-identifier": "JYL9G28DP3",
            "com.apple.security.app-sandbox": true,
            "com.apple.security.application-groups": ["group.com.ryukeili.TinyBuddy"],
            "com.apple.security.files.bookmarks.app-scope": true,
            "com.apple.security.files.user-selected.read-only": true,
            "com.apple.security.get-task-allow": true
        ]
        try writePropertyList(entitlements, to: expected)
        entitlements["com.apple.security.files.user-selected.read-write"] = true
        try writePropertyList(entitlements, to: unexpected)

        func run(plist: URL) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
            try runBash("""
            set -euo pipefail
            \(keyCountFunction)
            require_entitlement_key_count \(shellQuote(plist.path)) 7
            """)
        }

        XCTAssertEqual(try run(plist: expected).exitCode, 0)
        let rejected = try run(plist: unexpected)
        XCTAssertEqual(rejected.exitCode, 1)
        XCTAssertTrue(rejected.standardError.contains("unexpected top-level keys"))
    }


    func testHUDReadyTelemetryRequiresAVisibleExactSizeHUDWindow() throws {
        let appSource = try tinyBuddyAppSource()

        XCTAssertTrue(appSource.contains("window.isVisible"))
        XCTAssertTrue(appSource.contains("!window.isMiniaturized"))
        XCTAssertTrue(appSource.contains("window.screen != nil"))
        XCTAssertTrue(appSource.contains("window.alphaValue > 0"))
        XCTAssertTrue(appSource.contains("abs(window.contentLayoutRect.width - targetSize.width) < 0.5"))
        XCTAssertTrue(appSource.contains("publishTinyBuddyHUDReadyWhenVisible(window)"))
    }

    func testSandboxBookmarkRecoveryVerificationRequiresFreshSuccessfulSandboxStatus() throws {
        let statusDate = Date(timeIntervalSince1970: 1_700_000_100)
        let successful = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: Date(timeIntervalSince1970: 1_700_000_050),
            outcome: "partial",
            authorizedRootCount: 2,
            savedRecordCount: 2,
            trigger: "reopen",
            widgetContentChanged: false,
            widgetReloaded: false
        )

        XCTAssertEqual(successful.exitCode, 0)
        XCTAssertTrue(successful.standardOutput.contains("verified sandbox bookmark recovery"))
        XCTAssertTrue(successful.standardOutput.contains("authorized_roots=2"))
        XCTAssertTrue(successful.standardOutput.contains("outcome=partial"))
        XCTAssertTrue(successful.standardOutput.contains("trigger=reopen"))
        XCTAssertTrue(successful.standardOutput.contains("widget_content_changed=false"))
        XCTAssertTrue(successful.standardOutput.contains("widget_reloaded=false"))

        let firstLaunch = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: Date(timeIntervalSince1970: 1_700_000_050),
            outcome: "skipped",
            authorizedRootCount: 0,
            savedRecordCount: 0,
            diagnosticReason: "authorizationRequired"
        )

        XCTAssertEqual(firstLaunch.exitCode, 0)
        XCTAssertTrue(firstLaunch.standardOutput.contains("verified first-launch authorization state"))
        XCTAssertTrue(firstLaunch.standardOutput.contains("trigger=launch"))
        XCTAssertTrue(firstLaunch.standardOutput.contains("widget_reloaded=true"))

        let reusedBaseline = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: statusDate,
            outcome: "succeeded",
            authorizedRootCount: 2,
            savedRecordCount: 2
        )

        XCTAssertEqual(reusedBaseline.exitCode, 1)
        XCTAssertTrue(reusedBaseline.standardError.contains("did not publish a fresh"))

        let unrelatedTrigger = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: Date(timeIntervalSince1970: 1_700_000_050),
            outcome: "succeeded",
            authorizedRootCount: 2,
            savedRecordCount: 2,
            trigger: "timer",
            widgetContentChanged: false,
            widgetReloaded: false
        )

        XCTAssertEqual(unrelatedTrigger.exitCode, 1)
        XCTAssertTrue(unrelatedTrigger.standardError.contains("did not publish a fresh"))

        let failedRequiredReload = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: Date(timeIntervalSince1970: 1_700_000_050),
            outcome: "succeeded",
            authorizedRootCount: 2,
            savedRecordCount: 2,
            trigger: "launch",
            widgetContentChanged: true,
            widgetReloaded: false
        )

        XCTAssertEqual(failedRequiredReload.exitCode, 1)
        XCTAssertTrue(failedRequiredReload.standardError.contains("observed_widget_content_changed=true"))
        XCTAssertTrue(failedRequiredReload.standardError.contains("observed_widget_reloaded=false"))

        let corruptSavedAuthorization = try runSandboxRecoveryProbe(
            executableDate: Date(timeIntervalSince1970: 1_700_000_000),
            statusDate: statusDate,
            baselineDate: Date(timeIntervalSince1970: 1_700_000_050),
            outcome: "failed",
            authorizedRootCount: 0,
            savedRecordCount: 1
        )

        XCTAssertEqual(corruptSavedAuthorization.exitCode, 1)
        XCTAssertFalse(corruptSavedAuthorization.standardOutput.contains("check skipped"))
    }

    func testSavedGitScanRootRecordCountIncludesMalformedPersistedEntries() throws {
        let preferences = try makeTemporaryDirectory(named: "TinyBuddySavedRootRecordCountTests")
            .appendingPathComponent("preferences.plist")
        defer { try? FileManager.default.removeItem(at: preferences.deletingLastPathComponent()) }
        try writePropertyList([
            "tinybuddy.gitScanRoots.records.v2": [
                ["bookmarkData": Data("valid-shape-not-required".utf8)],
                "malformed-record"
            ]
        ], to: preferences)

        let function = try XCTUnwrap(
            scriptSection(
                startingAt: "saved_git_scan_root_record_count() {",
                endingBefore: "\ngit_refresh_status_value() {",
                in: try buildAndRunScript()
            )
        )
        let probe = """
        set -euo pipefail
        APP_PREFERENCES_PLIST=\(shellQuote(preferences.path))
        GIT_SCAN_ROOT_RECORDS_KEY=tinybuddy.gitScanRoots.records.v2
        GIT_SCAN_ROOT_BOOKMARK_KEY=tinybuddy.gitScanRoots.bookmarkData
        \(function)
        saved_git_scan_root_record_count
        """

        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    private func buildAndRunScript() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/build_and_run.sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func tinyBuddyAppSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TinyBuddy/TinyBuddyApp.swift")
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

    private func resolveSavedGitScanRootsProbe(_ preferencesPlist: URL) throws -> String {
        let function = try XCTUnwrap(
            scriptSection(
                startingAt: "resolve_saved_git_scan_roots() {",
                endingBefore: "\nSIGNING_ARGS=()",
                in: try buildAndRunScript()
            )
        )
        return """
        set -euo pipefail
        APP_PREFERENCES_PLIST=\(shellQuote(preferencesPlist.path))
        GIT_SCAN_ROOT_RECORDS_KEY=tinybuddy.gitScanRoots.records.v2
        GIT_SCAN_ROOT_BOOKMARK_KEY=tinybuddy.gitScanRoots.bookmarkData
        \(function)
        resolve_saved_git_scan_roots
        """
    }

    private func runSandboxRecoveryProbe(
        executableDate: Date,
        statusDate: Date,
        baselineDate: Date,
        outcome: String,
        authorizedRootCount: Int,
        savedRecordCount: Int,
        diagnosticReason: String = "",
        trigger: String = "launch",
        widgetContentChanged: Bool = true,
        widgetReloaded: Bool = true
    ) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
        let script = try buildAndRunScript()
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddySandboxRecoveryTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let installedApp = temporaryDirectory.appendingPathComponent("TinyBuddy.app")
        let executable = installedApp.appendingPathComponent("Contents/MacOS/TinyBuddy")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("binary".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.modificationDate: executableDate],
            ofItemAtPath: executable.path
        )

        let groupPreferences = temporaryDirectory.appendingPathComponent("group.plist")
        try writePropertyList([
            "tinybuddy.gitRefreshStatus.refreshedAt": statusDate,
            "tinybuddy.gitRefreshStatus.trigger": trigger,
            "tinybuddy.gitRefreshStatus.outcome": outcome,
            "tinybuddy.gitRefreshStatus.diagnostic.reason": diagnosticReason,
            "tinybuddy.gitRefreshStatus.metrics.authorizedRootCount": authorizedRootCount,
            "tinybuddy.gitRefreshStatus.metrics.repositoryCount": 3,
            "tinybuddy.gitRefreshStatus.metrics.cacheHitCount": 1,
            "tinybuddy.gitRefreshStatus.metrics.recomputedRepositoryCount": 2,
            "tinybuddy.gitRefreshStatus.metrics.invalidRepositoryCount": 0,
            "tinybuddy.gitRefreshStatus.metrics.sharedDataWritten": true,
            "tinybuddy.gitRefreshStatus.metrics.widgetContentChanged": widgetContentChanged,
            "tinybuddy.gitRefreshStatus.metrics.widgetReloaded": widgetReloaded
        ], to: groupPreferences)

        let functions = try [
            "git_refresh_status_value",
            "git_refresh_status_epoch",
            "verify_installed_sandbox_bookmark_recovery"
        ].map { name in
            try XCTUnwrap(shellFunction(named: name, in: script))
        }.joined(separator: "\n")
        let probe = """
        set -euo pipefail
        APP_NAME=TinyBuddy
        INSTALLED_APP=\(shellQuote(installedApp.path))
        APP_GROUP_PREFERENCES_PLIST=\(shellQuote(groupPreferences.path))
        GIT_REFRESH_STATUS_DATE_KEY=tinybuddy.gitRefreshStatus.refreshedAt
        GIT_REFRESH_STATUS_TRIGGER_KEY=tinybuddy.gitRefreshStatus.trigger
        GIT_REFRESH_STATUS_OUTCOME_KEY=tinybuddy.gitRefreshStatus.outcome
        GIT_REFRESH_STATUS_DIAGNOSTIC_REASON_KEY=tinybuddy.gitRefreshStatus.diagnostic.reason
        GIT_REFRESH_STATUS_AUTHORIZED_ROOT_COUNT_KEY=tinybuddy.gitRefreshStatus.metrics.authorizedRootCount
        GIT_REFRESH_STATUS_REPOSITORY_COUNT_KEY=tinybuddy.gitRefreshStatus.metrics.repositoryCount
        GIT_REFRESH_STATUS_CACHE_HIT_COUNT_KEY=tinybuddy.gitRefreshStatus.metrics.cacheHitCount
        GIT_REFRESH_STATUS_RECOMPUTED_REPOSITORY_COUNT_KEY=tinybuddy.gitRefreshStatus.metrics.recomputedRepositoryCount
        GIT_REFRESH_STATUS_INVALID_REPOSITORY_COUNT_KEY=tinybuddy.gitRefreshStatus.metrics.invalidRepositoryCount
        GIT_REFRESH_STATUS_SHARED_DATA_WRITTEN_KEY=tinybuddy.gitRefreshStatus.metrics.sharedDataWritten
        GIT_REFRESH_STATUS_WIDGET_CONTENT_CHANGED_KEY=tinybuddy.gitRefreshStatus.metrics.widgetContentChanged
        GIT_REFRESH_STATUS_WIDGET_RELOADED_KEY=tinybuddy.gitRefreshStatus.metrics.widgetReloaded
        SANDBOX_RECOVERY_TIMEOUT=0
        \(functions)
        verify_installed_sandbox_bookmark_recovery \
          \(savedRecordCount) \
          \(Int(baselineDate.timeIntervalSince1970)) \
          \(Int(executableDate.timeIntervalSince1970))
        """
        return try runBash(probe)
    }

    private func assertSuccessfulReleaseInstall(
        rollbackFunction: String,
        installFunction: String,
        previousMarker: String?
    ) throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "TinyBuddyReleaseInstallTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let candidateApp = temporaryDirectory.appendingPathComponent("candidate/TinyBuddy.app")
        let installedApp = temporaryDirectory.appendingPathComponent("install/TinyBuddy.app")
        let preferencesSentinel = temporaryDirectory
            .appendingPathComponent("container/Library/Preferences/com.ryukeili.TinyBuddy.plist")
        try FileManager.default.createDirectory(at: candidateApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: installedApp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: preferencesSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: candidateApp.appendingPathComponent("marker"))
        let initialPreferences = Data("authorized-bookmark-sentinel".utf8)
        try initialPreferences.write(to: preferencesSentinel)
        if let previousMarker {
            try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
            try Data(previousMarker.utf8).write(to: installedApp.appendingPathComponent("marker"))
        }

        let probe = """
        set -euo pipefail
        APP_NAME=TinyBuddy
        APP_BUNDLE=\(shellQuote(candidateApp.path))
        INSTALL_DIR=\(shellQuote(installedApp.deletingLastPathComponent().path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        RELEASE_TRANSACTION_DIR=""
        RELEASE_STAGED_APP=""
        RELEASE_BACKUP_APP=""
        RELEASE_HAD_PREVIOUS=0
        RELEASE_SWITCHED=0
        RELEASE_PREVIOUS_APP_WAS_RUNNING=0
        validate_release_install_paths() { return 0; }
        verify_widget_registration_preflight() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        \(atomicExchangeReleaseAppsStub)
        activate_and_verify_release_app() { return 0; }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """
        let result = try runBash(probe)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: installedApp.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertEqual(try Data(contentsOf: preferencesSentinel), initialPreferences)
        XCTAssertTrue(result.standardOutput.contains("transactionally installed"))
        XCTAssertFalse(result.standardError.contains("rolled back"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: installedApp.deletingLastPathComponent().path)
                .contains(where: { $0.hasPrefix(".TinyBuddy.install.") })
        )
    }

    private func runReleaseInstallProbe(
        rollbackFunction: String,
        installFunction: String,
        candidateApp: URL,
        installedApp: URL
    ) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
        try runBash(releaseInstallProbePreamble(candidateApp: candidateApp, installedApp: installedApp) + """
        validate_release_install_paths() { return 0; }
        saved_git_scan_root_record_count() { echo 1; }
        saved_git_scan_root_record_identity() { echo v2:test-identity; }
        verify_release_bundle() { [ -d "$1" ]; }
        capture_release_runtime() { return 0; }
        stop_release_runtime() { return 0; }
        activate_and_verify_release_app() { return 0; }
        \(rollbackFunction)
        \(installFunction)
        install_release_app
        """)
    }

    private func releaseInstallProbePreamble(candidateApp: URL, installedApp: URL) -> String {
        """
        set -euo pipefail
        APP_NAME=TinyBuddy
        APP_BUNDLE=\(shellQuote(candidateApp.path))
        INSTALL_DIR=\(shellQuote(installedApp.deletingLastPathComponent().path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        RELEASE_TRANSACTION_DIR=""
        RELEASE_STAGED_APP=""
        RELEASE_BACKUP_APP=""
        RELEASE_HAD_PREVIOUS=0
        RELEASE_SWITCHED=0
        RELEASE_PREVIOUS_APP_WAS_RUNNING=0
        verify_widget_registration_preflight() { return 0; }
        \(atomicExchangeReleaseAppsStub)
        """ + "\n"
    }

    private var atomicExchangeReleaseAppsStub: String {
        """
        release_path_identity() {
          /usr/bin/stat -f '%d:%i' "$1"
        }
        atomic_place_release_candidate() {
          local source_path="$1"
          local destination_path="$2"
          if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
            return 73
          fi
          /bin/mv "$source_path" "$destination_path" || return $?
          printf 'TINYBUDDY_RELEASE_INSTALLER_INSTALLED\n'
        }
        atomic_exchange_release_apps() {
          local first_path="$1"
          local second_path="$2"
          local temporary_path="$1.exchange"
          /bin/mv "$first_path" "$temporary_path" || return $?
          if ! /bin/mv "$second_path" "$first_path"; then
            /bin/mv "$temporary_path" "$first_path" || true
            return 1
          fi
          /bin/mv "$temporary_path" "$second_path" || return $?
          printf 'TINYBUDDY_RELEASE_INSTALLER_EXCHANGED\n'
        }
        """
    }

    private func replaceTestBundle(at app: URL, version: String, build: String) throws {
        if FileManager.default.fileExists(atPath: app.path) {
            try FileManager.default.removeItem(at: app)
        }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePropertyList([
            "CFBundleIdentifier": "com.ryukeili.TinyBuddy",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ], to: plist)
        try Data("\(version)+\(build)".utf8).write(to: app.appendingPathComponent("marker"))
    }

    private func bundleVersion(at app: URL) throws -> String {
        try bundleValue(at: app, key: "CFBundleShortVersionString")
    }

    private func bundleBuild(at app: URL) throws -> String {
        try bundleValue(at: app, key: "CFBundleVersion")
    }

    private func bundleValue(at app: URL, key: String) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(plist[key] as? String)
    }

    private func releaseInstallScenario(candidateApp: URL, installedApp: URL) throws -> String {
        let script = try buildAndRunScript()
        let functions = try ["compare_numeric_versions", "release_install_scenario"]
            .map { try XCTUnwrap(shellFunction(named: $0, in: script)) }
            .joined(separator: "\n")
        let result = try runBash("""
        set -euo pipefail
        APP_BUNDLE=\(shellQuote(candidateApp.path))
        INSTALLED_APP=\(shellQuote(installedApp.path))
        \(functions)
        release_install_scenario
        """)
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transactionResidueExists(in installDirectory: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: installDirectory.path)
            .contains(where: { $0.hasPrefix(".TinyBuddy.install.") })
    }

    private func scriptSection(startingAt startMarker: String, endingBefore endMarker: String, in script: String) -> String? {
        guard let start = script.range(of: startMarker),
              let end = script.range(of: endMarker, range: start.upperBound..<script.endIndex) else {
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

    private func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func writePropertyList(_ propertyList: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try data.write(to: url)
    }

    private func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func modeBlock(_ label: String, in script: String) -> String {
        let startMarker = "  \(label))"
        guard let start = script.range(of: startMarker, options: .backwards),
              let end = script.range(of: "    ;;", range: start.upperBound..<script.endIndex) else {
            return ""
        }
        return String(script[start.lowerBound..<end.upperBound])
    }

    private func runBash(_ script: String) throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
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
