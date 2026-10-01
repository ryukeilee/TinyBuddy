import Foundation
import SwiftUI
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

@MainActor
final class GitScanRootAuthorizationControllerTests: XCTestCase {
    func testInitialAuthorizationCancelCompletesOnboardingAndRequiresOneWidgetReload() {
        let defaults = makeDefaults()
        let sharedDefaults = makeDefaults()
        let onboardingStore = TinyBuddyOnboardingStore(
            userDefaults: defaults,
            sharedDefaults: sharedDefaults
        )
        let store = makeStore(userDefaults: defaults)
        let controller = GitScanRootAuthorizationController(
            store: store,
            onboardingStore: onboardingStore,
            authorizationSelectionProvider: { _ in nil }
        )

        let result = controller.requestAuthorizationResult()

        XCTAssertFalse(result.didChangeAuthorization)
        XCTAssertTrue(result.didCompleteOnboarding)
        XCTAssertTrue(result.requiresStandaloneWidgetReload)
        XCTAssertFalse(store.hasAuthorizedRoots)
        XCTAssertTrue(onboardingStore.isCompleted)
    }

    func testRepeatedAuthorizationCancelDoesNotRequireAnotherWidgetReload() {
        let defaults = makeDefaults()
        let sharedDefaults = makeDefaults()
        let onboardingStore = TinyBuddyOnboardingStore(
            userDefaults: defaults,
            sharedDefaults: sharedDefaults
        )
        let controller = GitScanRootAuthorizationController(
            store: makeStore(userDefaults: defaults),
            onboardingStore: onboardingStore,
            authorizationSelectionProvider: { _ in nil }
        )

        XCTAssertTrue(controller.requestAuthorizationResult().requiresStandaloneWidgetReload)

        let repeatedResult = controller.requestAuthorizationResult()
        XCTAssertFalse(repeatedResult.didChangeAuthorization)
        XCTAssertFalse(repeatedResult.didCompleteOnboarding)
        XCTAssertFalse(repeatedResult.requiresStandaloneWidgetReload)
    }

    func testRequestAuthorizationIfNeededPresentsPanelOnlyWhenNeverAuthorized() {
        let store = makeStore(userDefaults: makeDefaults())
        var selectionProviderCallCount = 0
        let controller = GitScanRootAuthorizationController(
            store: store,
            authorizationSelectionProvider: { _ in
                selectionProviderCallCount += 1
                return nil
            }
        )

        controller.requestAuthorizationIfNeeded()

        XCTAssertEqual(selectionProviderCallCount, 1)
    }

    func testRequestAuthorizationIfNeededDoesNotPresentPanelWhenSavedAuthorizationIsInvalid() throws {
        let defaults = makeDefaults()
        let store = makeStore(userDefaults: defaults, resolver: { _ in nil })
        try store.replaceAuthorizedRoots([URL(fileURLWithPath: "/Authorized/StaleProject")])
        var selectionProviderCallCount = 0
        let controller = GitScanRootAuthorizationController(
            store: store,
            authorizationSelectionProvider: { _ in
                selectionProviderCallCount += 1
                return nil
            }
        )

        controller.requestAuthorizationIfNeeded()

        XCTAssertEqual(selectionProviderCallCount, 0)
    }

    func testRequestAuthorizationCancelReturnsFalseWithoutChangingStore() {
        let store = makeStore(userDefaults: makeDefaults())
        let controller = GitScanRootAuthorizationController(
            store: store,
            authorizationSelectionProvider: { _ in nil }
        )

        XCTAssertFalse(controller.requestAuthorization())
        XCTAssertFalse(store.hasAuthorizedRoots)
    }

    func testRequestAuthorizationAddsWithoutReplacingExistingRoot() throws {
        let defaults = makeDefaults()
        let existing = URL(fileURLWithPath: "/Authorized/Existing")
        let added = URL(fileURLWithPath: "/Authorized/Added")
        let store = makeStore(userDefaults: defaults)
        try store.replaceAuthorizedRoots([existing])
        let controller = GitScanRootAuthorizationController(
            store: store,
            authorizationSelectionProvider: { _ in [added] }
        )

        XCTAssertTrue(controller.requestAuthorization())

        XCTAssertEqual(store.authorizationStatuses().map(\.lastKnownPath), [existing.path, added.path])
    }

    func testRequestReauthorizationReplacesOneRootWithoutDroppingOthers() throws {
        let defaults = makeDefaults()
        let first = URL(fileURLWithPath: "/Authorized/First")
        let second = URL(fileURLWithPath: "/Authorized/Second")
        let replacement = URL(fileURLWithPath: "/Authorized/Replacement")
        let store = makeStore(userDefaults: defaults)
        try store.replaceAuthorizedRoots([first, second])
        let firstID = try XCTUnwrap(store.authorizationStatuses().first?.id)
        var allowsMultipleSelection: Bool?
        let controller = GitScanRootAuthorizationController(
            store: store,
            authorizationSelectionProvider: { value in
                allowsMultipleSelection = value
                return [replacement]
            }
        )

        XCTAssertTrue(controller.requestReauthorization(for: firstID))

        let statuses = store.authorizationStatuses()
        XCTAssertEqual(statuses.map(\.lastKnownPath), [replacement.path, second.path])
        XCTAssertEqual(statuses.first?.id, firstID)
        XCTAssertEqual(allowsMultipleSelection, false)
    }

    func testReauthorizationForSameDirectoryStillRequestsImmediateRescan() throws {
        let root = URL(fileURLWithPath: "/Authorized/RecoveredInPlace")
        let store = makeStore(userDefaults: makeDefaults())
        try store.replaceAuthorizedRoots([root])
        let identifier = try XCTUnwrap(store.authorizationStatuses().first?.id)
        let controller = GitScanRootAuthorizationController(
            store: store,
            authorizationSelectionProvider: { _ in [root] }
        )

        XCTAssertTrue(controller.requestReauthorization(for: identifier))
        XCTAssertEqual(store.authorizationStatuses().first?.lastKnownPath, root.path)
    }

    func testDirectRepairReauthorizesFirstUnavailableRootWithoutRestarting() throws {
        let defaults = makeDefaults()
        let stale = URL(fileURLWithPath: "/Authorized/Stale")
        let replacement = URL(fileURLWithPath: "/Authorized/Recovered")
        var readablePath = replacement.path
        let store = GitScanRootAuthorizationStore(
            userDefaults: defaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                guard let path = String(data: data, encoding: .utf8) else { return nil }
                return ResolvedScopedGitScanRoot(
                    root: ScopedGitScanRoot(url: URL(fileURLWithPath: path)),
                    bookmarkDataIsStale: false
                )
            },
            rootUsabilityChecker: { url in
                url.path == readablePath ? nil : .permissionDenied
            }
        )
        try store.replaceAuthorizedRoots([stale])
        let controller = GitScanRootAuthorizationController(
            store: store,
            authorizationSelectionProvider: { _ in [replacement] }
        )

        XCTAssertEqual(store.authorizationStatuses().first?.state, .unavailable(.permissionDenied))
        XCTAssertTrue(controller.requestReauthorizationForFirstUnavailableRoot())
        XCTAssertEqual(store.authorizationStatuses().first?.lastKnownPath, replacement.path)
        XCTAssertEqual(store.authorizationStatuses().first?.state, .available)
        readablePath = ""
    }

    func testRemoveOneAndRemoveAllReturnWhetherAuthorizationChanged() throws {
        let store = makeStore(userDefaults: makeDefaults())
        try store.replaceAuthorizedRoots([
            URL(fileURLWithPath: "/Authorized/First"),
            URL(fileURLWithPath: "/Authorized/Second")
        ])
        let firstID = try XCTUnwrap(store.authorizationStatuses().first?.id)
        let controller = GitScanRootAuthorizationController(store: store)

        XCTAssertTrue(controller.removeAuthorization(id: firstID))
        XCTAssertFalse(controller.removeAuthorization(id: firstID))
        XCTAssertTrue(controller.removeAllAuthorizations())
        XCTAssertFalse(controller.removeAllAuthorizations())
    }

    func testSettingsViewModelPublishesScopedAuthorizationCommands() {
        let notificationCenter = NotificationCenter()
        let store = makeStore(userDefaults: makeDefaults())
        let viewModel = GitScanRootSettingsViewModel(
            store: store,
            notificationCenter: notificationCenter
        )
        var received: [(Notification.Name, String?)] = []
        let names: [Notification.Name] = [
            .gitScanRootAuthorizationAddRequested,
            .gitScanRootAuthorizationReauthorizationRequested,
            .gitScanRootAuthorizationRemovalRequested,
            .gitScanRootAuthorizationRemoveAllRequested
        ]
        let observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { notification in
                received.append((
                    notification.name,
                    notification.userInfo?[GitScanRootAuthorizationCommand.authorizationIdentifierKey] as? String
                ))
            }
        }
        defer { observers.forEach(notificationCenter.removeObserver) }

        viewModel.requestAuthorization()
        viewModel.requestReauthorization(for: "reauthorize-id")
        viewModel.removeAuthorization(id: "remove-id")
        viewModel.removeAllAuthorizations()

        XCTAssertEqual(received.map(\.0), names)
        XCTAssertEqual(received.map(\.1), [nil, "reauthorize-id", "remove-id", nil])
    }

    func testSettingsViewModelPersistsNormalizedExclusionsAndPublishesConfigChange() throws {
        let notificationCenter = NotificationCenter()
        let storage = GitSettingsConfigStorage()
        let configStore = TinyBuddyConfigStore(
            directPreferencesProvider: { storage.values },
            synchronizeReads: {},
            writeValue: { value, key in storage.values[key] = value; return true },
            synchronizeWrites: { true },
            readFailureProvider: { nil }
        )
        XCTAssertEqual(
            configStore.save(TinyBuddyAppConfig(configVersion: 1, dayIdentifier: "2026-07-20")),
            .saved
        )
        let viewModel = GitScanRootSettingsViewModel(
            store: makeStore(userDefaults: makeDefaults()),
            configStore: configStore,
            notificationCenter: notificationCenter
        )
        var changeCount = 0
        let observer = notificationCenter.addObserver(
            forName: .tinyBuddySettingsDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if notification.userInfo?[GitScanRootAuthorizationCommand.exclusionsDidChangeKey] as? Bool == true {
                changeCount += 1
            }
        }
        defer { notificationCenter.removeObserver(observer) }

        XCTAssertTrue(viewModel.addExclusionRule(pattern: " ./Teams/Private/ "))
        XCTAssertFalse(viewModel.addExclusionRule(pattern: "Teams/Private"))
        XCTAssertFalse(viewModel.addExclusionRule(pattern: "../Outside"))
        XCTAssertNil(viewModel.exclusionRuleSaveErrorMessage)
        XCTAssertEqual(viewModel.exclusionRules.map(\.pattern), ["Teams/Private"])
        XCTAssertEqual(configStore.load()?.exclusionRules.map(\.pattern), ["Teams/Private"])

        let identifier = try XCTUnwrap(viewModel.exclusionRules.first?.id)
        XCTAssertTrue(viewModel.removeExclusionRule(id: identifier))
        XCTAssertFalse(viewModel.removeExclusionRule(id: identifier))
        XCTAssertNil(viewModel.exclusionRuleSaveErrorMessage)
        XCTAssertEqual(configStore.load()?.exclusionRules, [])
        XCTAssertEqual(changeCount, 2)
    }

    func testSettingsViewModelReportsAndClearsExclusionSaveFailure() throws {
        let saveFailureMessage =
            "无法确认排除规则已保存。配置写入可能部分完成，当前状态可能无法读取。请重启 TinyBuddy 并检查规则，再决定是否重新修改。"
        let notificationCenter = NotificationCenter()
        let storage = GitSettingsConfigStorage()
        let configStore = makeConfigStore(storage: storage)
        let initialConfig = TinyBuddyAppConfig(
            configVersion: 1,
            exclusionRules: [TinyBuddyExclusionRule(pattern: "Existing")],
            dayIdentifier: "2026-07-20"
        )
        XCTAssertEqual(configStore.save(initialConfig), .saved)
        let viewModel = GitScanRootSettingsViewModel(
            store: makeStore(userDefaults: makeDefaults()),
            configStore: configStore,
            notificationCenter: notificationCenter
        )
        viewModel.loginItemErrorMessage = "登录项状态仍由登录项设置管理。"

        var changeCount = 0
        let observer = notificationCenter.addObserver(
            forName: .tinyBuddySettingsDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if notification.userInfo?[GitScanRootAuthorizationCommand.exclusionsDidChangeKey] as? Bool == true {
                changeCount += 1
            }
        }
        defer { notificationCenter.removeObserver(observer) }

        storage.rejectPayloadWrites = true
        XCTAssertFalse(viewModel.addExclusionRule(pattern: "New/Rule"))
        XCTAssertEqual(viewModel.exclusionRules.map(\.pattern), ["Existing"])
        XCTAssertEqual(configStore.load(), initialConfig)
        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(
            viewModel.exclusionRuleSaveErrorMessage,
            saveFailureMessage
        )
        XCTAssertEqual(viewModel.loginItemErrorMessage, "登录项状态仍由登录项设置管理。")

        let settingsView = GitScanRootSettingsView(viewModel: viewModel)
        let renderedStrings = reflectedStrings(in: settingsView.body)
        XCTAssertTrue(
            renderedStrings.contains { $0.contains(saveFailureMessage) },
            "Expected the settings view body to contain the bound save feedback; got: \(renderedStrings)"
        )

        XCTAssertFalse(viewModel.addExclusionRule(pattern: "Existing"))
        XCTAssertFalse(viewModel.addExclusionRule(pattern: "../Outside"))
        XCTAssertEqual(viewModel.exclusionRules.map(\.pattern), ["Existing"])
        XCTAssertEqual(changeCount, 0)

        storage.rejectPayloadWrites = false
        XCTAssertTrue(viewModel.addExclusionRule(pattern: "New/Rule"))
        XCTAssertNil(viewModel.exclusionRuleSaveErrorMessage)
        XCTAssertEqual(viewModel.exclusionRules.map(\.pattern), ["Existing", "New/Rule"])
        XCTAssertEqual(configStore.load()?.exclusionRules.map(\.pattern), ["Existing", "New/Rule"])
        XCTAssertEqual(changeCount, 1)
        let recoveredViewStrings = reflectedStrings(
            in: GitScanRootSettingsView(viewModel: viewModel).body
        )
        XCTAssertFalse(
            recoveredViewStrings.contains { $0.contains("无法确认排除规则已保存") },
            "Expected the settings view to clear feedback after persistence recovers."
        )

        let existingID = try XCTUnwrap(viewModel.exclusionRules.first?.id)
        storage.rejectPayloadWrites = true
        XCTAssertFalse(viewModel.removeExclusionRule(id: existingID))
        XCTAssertEqual(viewModel.exclusionRules.map(\.pattern), ["Existing", "New/Rule"])
        XCTAssertEqual(configStore.load()?.exclusionRules.map(\.pattern), ["Existing", "New/Rule"])
        XCTAssertEqual(changeCount, 1)
        XCTAssertNotNil(viewModel.exclusionRuleSaveErrorMessage)
        XCTAssertEqual(viewModel.loginItemErrorMessage, "登录项状态仍由登录项设置管理。")

        storage.rejectPayloadWrites = false
        XCTAssertTrue(viewModel.removeExclusionRule(id: existingID))
        XCTAssertNil(viewModel.exclusionRuleSaveErrorMessage)
        XCTAssertEqual(viewModel.exclusionRules.map(\.pattern), ["New/Rule"])
        XCTAssertEqual(configStore.load()?.exclusionRules.map(\.pattern), ["New/Rule"])
        XCTAssertEqual(changeCount, 2)
    }

    func testSettingsViewModelReportsUnconfirmedSynchronizationAndReadback() {
        for failure in ["synchronize", "readback"] {
            let notificationCenter = NotificationCenter()
            let storage = GitSettingsConfigStorage()
            let configStore = makeConfigStore(storage: storage)
            let initialConfig = TinyBuddyAppConfig(
                configVersion: 1,
                exclusionRules: [TinyBuddyExclusionRule(pattern: "Existing")],
                dayIdentifier: "2026-07-20"
            )
            XCTAssertEqual(configStore.save(initialConfig), .saved)
            let viewModel = GitScanRootSettingsViewModel(
                store: makeStore(userDefaults: makeDefaults()),
                configStore: configStore,
                notificationCenter: notificationCenter
            )
            var changeCount = 0
            let observer = notificationCenter.addObserver(
                forName: .tinyBuddySettingsDidChange,
                object: nil,
                queue: nil
            ) { _ in changeCount += 1 }

            if failure == "synchronize" {
                storage.failNextSynchronization = true
            } else {
                storage.hideNextPayloadReadback = true
            }

            XCTAssertFalse(viewModel.addExclusionRule(pattern: "New/Rule"), "\(failure)")
            XCTAssertEqual(viewModel.exclusionRules.map(\.pattern), ["Existing"], "\(failure)")
            XCTAssertEqual(
                configStore.load(),
                initialConfig,
                "\(failure) failure keeps the prior committed pair readable after recovery"
            )
            XCTAssertNotNil(viewModel.exclusionRuleSaveErrorMessage, "\(failure)")
            XCTAssertEqual(changeCount, 0, "\(failure)")
            notificationCenter.removeObserver(observer)
        }
    }

    func testSettingsViewModelReloadsRecoveredAuthorizationState() async throws {
        let notificationCenter = NotificationCenter()
        let root = URL(fileURLWithPath: "/Authorized/Recovering")
        var isReadable = false
        let store = GitScanRootAuthorizationStore(
            userDefaults: makeDefaults(),
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: { data in
                guard let path = String(data: data, encoding: .utf8) else { return nil }
                return ResolvedScopedGitScanRoot(
                    root: ScopedGitScanRoot(url: URL(fileURLWithPath: path)),
                    bookmarkDataIsStale: false
                )
            },
            rootUsabilityChecker: { _ in isReadable ? nil : .permissionDenied }
        )
        try store.replaceAuthorizedRoots([root])
        let viewModel = GitScanRootSettingsViewModel(
            store: store,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(viewModel.authorizations.first?.state, .unavailable(.permissionDenied))

        isReadable = true
        notificationCenter.post(name: .gitScanRootAuthorizationsDidChange, object: nil)
        await Task.yield()

        XCTAssertEqual(viewModel.authorizations.first?.state, .available)
    }

    private func makeStore(
        userDefaults: UserDefaults,
        resolver: @escaping GitScanRootAuthorizationStore.ScopedRootResolver = { data in
            guard let path = String(data: data, encoding: .utf8) else {
                return nil
            }
            return ResolvedScopedGitScanRoot(
                root: ScopedGitScanRoot(url: URL(fileURLWithPath: path)),
                bookmarkDataIsStale: false
            )
        }
    ) -> GitScanRootAuthorizationStore {
        GitScanRootAuthorizationStore(
            userDefaults: userDefaults,
            bookmarkDataCreator: { Data($0.path.utf8) },
            scopedRootResolver: resolver,
            rootUsabilityChecker: { _ in nil }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TinyBuddyGitScanRootAuthorizationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeConfigStore(storage: GitSettingsConfigStorage) -> TinyBuddyConfigStore {
        TinyBuddyConfigStore(
            directPreferencesProvider: { storage.readValues() },
            synchronizeReads: {},
            writeValue: { value, key in storage.writeValue(value, forKey: key) },
            synchronizeWrites: { storage.synchronizeWrites() },
            readFailureProvider: { nil }
        )
    }

    private func reflectedStrings(in value: Any, depth: Int = 0) -> [String] {
        if let string = value as? String {
            return [string]
        }
        guard depth < 32 else { return [] }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return [] }
        return mirror.children.prefix(256).flatMap { child in
            reflectedStrings(in: child.value, depth: depth + 1)
        }
    }
}

private final class GitSettingsConfigStorage: @unchecked Sendable {
    var values: [String: Any] = [:]
    var rejectPayloadWrites = false
    var failNextSynchronization = false
    var hideNextPayloadReadback = false
    private var hidePayloadInNextSnapshot = false

    func readValues() -> [String: Any] {
        var snapshot = values
        if hidePayloadInNextSnapshot {
            snapshot.removeValue(forKey: TinyBuddyConfigStore.Key.configPayload)
            hidePayloadInNextSnapshot = false
        }
        return snapshot
    }

    func writeValue(_ value: Any, forKey key: String) -> Bool {
        if key == TinyBuddyConfigStore.Key.configPayload && rejectPayloadWrites {
            return false
        }
        values[key] = value
        if key == TinyBuddyConfigStore.Key.configPayload && hideNextPayloadReadback {
            hideNextPayloadReadback = false
            hidePayloadInNextSnapshot = true
        }
        return true
    }

    func synchronizeWrites() -> Bool {
        guard failNextSynchronization else { return true }
        failNextSynchronization = false
        return false
    }
}
