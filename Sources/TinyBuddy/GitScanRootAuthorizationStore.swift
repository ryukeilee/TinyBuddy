import AppKit
import Darwin
import Foundation
import TinyBuddyCore

final class ScopedGitScanRoot {
    let url: URL
    private let lock = NSLock()
    private var stopAccessingAction: (() -> Void)?

    init(url: URL, stopAccessingAction: @escaping () -> Void = {}) {
        self.url = url
        self.stopAccessingAction = stopAccessingAction
    }

    func stopAccessing() {
        let action: (() -> Void)?
        lock.lock()
        action = stopAccessingAction
        stopAccessingAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        stopAccessing()
    }
}

struct ResolvedScopedGitScanRoot {
    let root: ScopedGitScanRoot
    let bookmarkDataIsStale: Bool
}

enum GitScanRootAuthorizationFailureReason: Equatable {
    case bookmarkCorruptOrRevoked
    case directoryUnavailable
    case permissionDenied
    case bookmarkRefreshFailed
    case scopeTooBroad
}

enum GitScanRootAuthorizationState: Equatable {
    case available
    case unavailable(GitScanRootAuthorizationFailureReason)
}

struct GitScanRootAuthorization: Identifiable, Equatable {
    let id: String
    let displayName: String
    let lastKnownPath: String
    let state: GitScanRootAuthorizationState
}

extension GitScanRootAuthorization {
    /// A diagnostic-safe authorization record with the real path replaced by a
    /// stable identifier and brief path suffix.
    var diagnosticSummary: String {
        let stableID = TinyBuddyPrivacyRedactor.stableIdentifier(for: lastKnownPath)
        let brief = TinyBuddyPrivacyRedactor.briefPath(lastKnownPath)
        let stateLabel: String
        switch state {
        case .available:
            stateLabel = "available"
        case .unavailable(let reason):
            stateLabel = "unavailable(\(reason))"
        }
        return "id=\(stableID) path=\(brief) display=\(displayName) state=\(stateLabel)"
    }
}

enum GitScanRootAccessIssue: Equatable {
    case authorizationRequired
    case authorizationInvalid
}

struct GitScanRootAccessResult {
    let roots: [ScopedGitScanRoot]
    let issue: GitScanRootAccessIssue?
    let authorizations: [GitScanRootAuthorization]

    init(
        roots: [ScopedGitScanRoot],
        issue: GitScanRootAccessIssue?,
        authorizations: [GitScanRootAuthorization] = []
    ) {
        self.roots = roots
        self.issue = issue
        self.authorizations = authorizations
    }
}

final class GitScanRootAuthorizationStore {
    enum Constants {
        // Legacy key. Keep this stable so installed versions can migrate their bookmarks.
        static let bookmarkDataKey = "tinybuddy.gitScanRoots.bookmarkData"
        static let authorizationRecordsKey = "tinybuddy.gitScanRoots.records.v2"
    }

    typealias BookmarkDataCreator = (URL) throws -> Data
    typealias ScopedRootResolver = (Data) throws -> ResolvedScopedGitScanRoot?
    typealias RootUsabilityChecker = (URL) -> GitScanRootAuthorizationFailureReason?

    private struct AuthorizationRecord: Equatable {
        let id: String
        var bookmarkData: Data
        var displayName: String
        var lastKnownPath: String

        var propertyListValue: [String: Any] {
            [
                "id": id,
                "bookmarkData": bookmarkData,
                "displayName": displayName,
                "lastKnownPath": lastKnownPath
            ]
        }

        init(id: String, bookmarkData: Data, displayName: String, lastKnownPath: String) {
            self.id = id
            self.bookmarkData = bookmarkData
            self.displayName = displayName
            self.lastKnownPath = lastKnownPath
        }

        init(propertyListValue: Any) {
            let dictionary = propertyListValue as? [String: Any]
            let storedID = dictionary?["id"] as? String
            id = storedID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            bookmarkData = dictionary?["bookmarkData"] as? Data ?? Data()
            displayName = dictionary?["displayName"] as? String ?? "无效授权"
            lastKnownPath = dictionary?["lastKnownPath"] as? String ?? ""
        }
    }

    private let userDefaults: UserDefaults
    private let bookmarkDataCreator: BookmarkDataCreator
    private let scopedRootResolver: ScopedRootResolver
    private let rootUsabilityChecker: RootUsabilityChecker

    init(
        userDefaults: UserDefaults = .standard,
        bookmarkDataCreator: @escaping BookmarkDataCreator = GitScanRootAuthorizationStore.makeSecurityScopedBookmarkData(for:),
        scopedRootResolver: @escaping ScopedRootResolver = GitScanRootAuthorizationStore.resolveSecurityScopedRoot(from:),
        rootUsabilityChecker: @escaping RootUsabilityChecker = GitScanRootAuthorizationStore.scanRootUsabilityIssue(for:)
    ) {
        self.userDefaults = userDefaults
        self.bookmarkDataCreator = bookmarkDataCreator
        self.scopedRootResolver = scopedRootResolver
        self.rootUsabilityChecker = rootUsabilityChecker
        migrateLegacyBookmarksIfNeeded()
        normalizeAuthorizationRecordsIfNeeded()
    }

    var hasAuthorizedRoots: Bool {
        !authorizationRecords().isEmpty
    }

    @discardableResult
    func replaceAuthorizedRoots(_ urls: [URL]) throws -> Bool {
        let uniqueURLs = Self.uniqueStandardizedDirectoryURLs(from: urls)
        let currentRecords = authorizationRecords()
        var currentRecordsByPath: [String: AuthorizationRecord] = [:]
        for record in currentRecords where !record.lastKnownPath.isEmpty {
            currentRecordsByPath[record.lastKnownPath] = record
        }

        let newRecords = try uniqueURLs.map { url in
            let path = url.path
            return AuthorizationRecord(
                id: currentRecordsByPath[path]?.id ?? UUID().uuidString,
                bookmarkData: try bookmarkDataCreator(url),
                displayName: Self.displayName(for: url),
                lastKnownPath: path
            )
        }

        guard newRecords != currentRecords else {
            return false
        }
        persist(newRecords)
        return true
    }

    @discardableResult
    func addAuthorizedRoots(_ urls: [URL]) throws -> Bool {
        var records = authorizationRecords()
        var knownPaths = Set(records.compactMap { $0.lastKnownPath.isEmpty ? nil : $0.lastKnownPath })
        var knownBookmarkData = Set(records.map(\.bookmarkData))
        var recordsToAdd: [AuthorizationRecord] = []

        for url in Self.uniqueStandardizedDirectoryURLs(from: urls) {
            guard !knownPaths.contains(url.path) else {
                continue
            }

            let record = try makeAuthorizationRecord(for: url)
            guard !knownBookmarkData.contains(record.bookmarkData) else {
                continue
            }
            knownPaths.insert(url.path)
            knownBookmarkData.insert(record.bookmarkData)
            recordsToAdd.append(record)
        }

        guard !recordsToAdd.isEmpty else {
            return false
        }
        records.append(contentsOf: recordsToAdd)
        persist(records)
        return true
    }

    @discardableResult
    func replaceAuthorizedRoot(id: String, with url: URL) throws -> Bool {
        let normalizedURL = Self.normalizedScanRootURL(url)
        guard Self.isAllowedScanRoot(normalizedURL) else {
            return false
        }

        var records = authorizationRecords()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let bookmarkData = try bookmarkDataCreator(normalizedURL)
        let replacement = AuthorizationRecord(
            id: id,
            bookmarkData: bookmarkData,
            displayName: Self.displayName(for: normalizedURL),
            lastKnownPath: normalizedURL.path
        )
        guard records[index] != replacement else {
            return false
        }
        records[index] = replacement
        persist(records)
        return true
    }

    @discardableResult
    func removeAuthorizedRoot(id: String) -> Bool {
        var records = authorizationRecords()
        let originalCount = records.count
        records.removeAll { $0.id == id }
        guard records.count != originalCount else {
            return false
        }
        persist(records)
        return true
    }

    @discardableResult
    func removeAllAuthorizedRoots() -> Bool {
        guard hasAuthorizedRoots else {
            return false
        }
        persist([])
        return true
    }

    func authorizationStatuses() -> [GitScanRootAuthorization] {
        let result = accessAuthorizedRootResult()
        result.roots.forEach { $0.stopAccessing() }
        return result.authorizations
    }

    func accessAuthorizedRoots() -> [ScopedGitScanRoot] {
        accessAuthorizedRootResult().roots
    }

    func accessAuthorizedRootResult() -> GitScanRootAccessResult {
        var records = authorizationRecords()
        var roots: [ScopedGitScanRoot] = []
        var authorizations: [GitScanRootAuthorization] = []
        var recordsChanged = false

        for index in records.indices {
            let resolution: ResolvedScopedGitScanRoot
            do {
                guard let resolvedRoot = try scopedRootResolver(records[index].bookmarkData) else {
                    authorizations.append(authorization(from: records[index], unavailable: .permissionDenied))
                    continue
                }
                resolution = resolvedRoot
            } catch {
                authorizations.append(authorization(from: records[index], unavailable: .bookmarkCorruptOrRevoked))
                continue
            }

            let scopedRoot = resolution.root
            guard Self.isAllowedScanRoot(scopedRoot.url) else {
                scopedRoot.stopAccessing()
                authorizations.append(authorization(from: records[index], unavailable: .scopeTooBroad))
                continue
            }
            if let usabilityIssue = rootUsabilityChecker(scopedRoot.url) {
                scopedRoot.stopAccessing()
                authorizations.append(authorization(from: records[index], unavailable: usabilityIssue))
                continue
            }

            let normalizedURL = Self.normalizedScanRootURL(scopedRoot.url)
            if resolution.bookmarkDataIsStale {
                do {
                    records[index].bookmarkData = try bookmarkDataCreator(normalizedURL)
                    recordsChanged = true
                } catch {
                    scopedRoot.stopAccessing()
                    authorizations.append(authorization(from: records[index], unavailable: .bookmarkRefreshFailed))
                    continue
                }
            }

            let displayName = Self.displayName(for: normalizedURL)
            if records[index].displayName != displayName || records[index].lastKnownPath != normalizedURL.path {
                records[index].displayName = displayName
                records[index].lastKnownPath = normalizedURL.path
                recordsChanged = true
            }

            roots.append(scopedRoot)
            authorizations.append(authorization(from: records[index], unavailable: nil))
        }

        if recordsChanged {
            persist(records)
        }

        let hasUnavailableAuthorization = authorizations.contains {
            if case .unavailable = $0.state {
                return true
            }
            return false
        }
        let issue: GitScanRootAccessIssue?
        if records.isEmpty {
            issue = .authorizationRequired
        } else if hasUnavailableAuthorization {
            issue = .authorizationInvalid
            NSLog("TinyBuddy: one or more saved Git scan roots are temporarily unavailable")
        } else {
            issue = nil
        }

        return GitScanRootAccessResult(roots: roots, issue: issue, authorizations: authorizations)
    }

    private func authorization(
        from record: AuthorizationRecord,
        unavailable reason: GitScanRootAuthorizationFailureReason?
    ) -> GitScanRootAuthorization {
        GitScanRootAuthorization(
            id: record.id,
            displayName: record.displayName,
            lastKnownPath: record.lastKnownPath,
            state: reason.map(GitScanRootAuthorizationState.unavailable) ?? .available
        )
    }

    private func makeAuthorizationRecord(for url: URL) throws -> AuthorizationRecord {
        AuthorizationRecord(
            id: UUID().uuidString,
            bookmarkData: try bookmarkDataCreator(url),
            displayName: Self.displayName(for: url),
            lastKnownPath: url.path
        )
    }

    private func authorizationRecords() -> [AuthorizationRecord] {
        guard let values = userDefaults.array(forKey: Constants.authorizationRecordsKey) else {
            return []
        }
        return values.map(AuthorizationRecord.init(propertyListValue:))
    }

    private func persist(_ records: [AuthorizationRecord]) {
        userDefaults.set(records.map(\.propertyListValue), forKey: Constants.authorizationRecordsKey)
        userDefaults.synchronize()
    }

    private func migrateLegacyBookmarksIfNeeded() {
        guard userDefaults.object(forKey: Constants.authorizationRecordsKey) == nil,
              let legacyValue = userDefaults.object(forKey: Constants.bookmarkDataKey) else {
            return
        }

        let legacyValues = legacyValue as? [Any] ?? [legacyValue]
        let records = legacyValues.map { value -> AuthorizationRecord in
            AuthorizationRecord(
                id: UUID().uuidString,
                bookmarkData: value as? Data ?? Data(),
                displayName: "已授权目录",
                lastKnownPath: ""
            )
        }
        persist(records)
        userDefaults.removeObject(forKey: Constants.bookmarkDataKey)
        userDefaults.synchronize()
    }

    private func normalizeAuthorizationRecordsIfNeeded() {
        guard let storedValue = userDefaults.object(forKey: Constants.authorizationRecordsKey) else {
            return
        }

        guard let values = storedValue as? [Any] else {
            persist([AuthorizationRecord(propertyListValue: storedValue)])
            return
        }
        guard values.contains(where: { !Self.isWellFormedAuthorizationRecord($0) }) else {
            return
        }
        persist(values.map(AuthorizationRecord.init(propertyListValue:)))
    }

    private static func isWellFormedAuthorizationRecord(_ value: Any) -> Bool {
        guard let dictionary = value as? [String: Any],
              let id = dictionary["id"] as? String,
              !id.isEmpty,
              dictionary["bookmarkData"] is Data,
              dictionary["displayName"] is String,
              dictionary["lastKnownPath"] is String else {
            return false
        }
        return true
    }

    private static func uniqueStandardizedDirectoryURLs(from urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []

        for url in urls {
            let normalizedURL = normalizedScanRootURL(url)
            let path = normalizedURL.path
            guard isAllowedScanRoot(normalizedURL), !seenPaths.contains(path) else {
                continue
            }

            seenPaths.insert(path)
            uniqueURLs.append(normalizedURL)
        }

        return uniqueURLs
    }

    static func isAllowedScanRoot(_ url: URL) -> Bool {
        let path = normalizedScanRootURL(url).path
        let homePath = resolvedUserHomeDirectoryPath()
        return !path.contains("\n")
            && !path.contains("\r")
            && path != "/"
            && path != "/Users"
            && path != homePath
    }

    private static func scanRootUsabilityIssue(for url: URL) -> GitScanRootAuthorizationFailureReason? {
        guard isAllowedScanRoot(url) else {
            return .scopeTooBroad
        }

        let path = normalizedScanRootURL(url).path
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .directoryUnavailable
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return .permissionDenied
        }
        return nil
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private static func normalizedScanRootURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func resolvedUserHomeDirectoryPath() -> String {
        if let homeDirectory = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }),
           !homeDirectory.isEmpty {
            return normalizedScanRootURL(URL(fileURLWithPath: homeDirectory)).path
        }

        return normalizedScanRootURL(FileManager.default.homeDirectoryForCurrentUser).path
    }

    private static func makeSecurityScopedBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func resolveSecurityScopedRoot(from bookmarkData: Data) throws -> ResolvedScopedGitScanRoot? {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }

        return ResolvedScopedGitScanRoot(
            root: ScopedGitScanRoot(url: url) {
                url.stopAccessingSecurityScopedResource()
            },
            bookmarkDataIsStale: isStale
        )
    }
}

@MainActor
struct GitScanRootAuthorizationRequestResult: Equatable {
    let didChangeAuthorization: Bool
    let didCompleteOnboarding: Bool

    var requiresStandaloneWidgetReload: Bool {
        didCompleteOnboarding && !didChangeAuthorization
    }
}

@MainActor
final class GitScanRootAuthorizationController {
    typealias AuthorizationSelectionProvider = @MainActor (_ allowsMultipleSelection: Bool) -> [URL]?

    private let store: GitScanRootAuthorizationStore
    private let onboardingStore: TinyBuddyOnboardingStore
    private let panelProvider: @MainActor () -> NSOpenPanel
    private let selectedURLsProvider: @MainActor (NSOpenPanel) -> [URL]
    private let panelConfigurator: @MainActor (NSOpenPanel, Bool) -> Void
    private let authorizationSelectionProvider: AuthorizationSelectionProvider?

    init(
        store: GitScanRootAuthorizationStore,
        onboardingStore: TinyBuddyOnboardingStore = TinyBuddyOnboardingStore(),
        panelProvider: @escaping @MainActor () -> NSOpenPanel = { NSOpenPanel() },
        selectedURLsProvider: @escaping @MainActor (NSOpenPanel) -> [URL] = { $0.urls },
        panelConfigurator: (@MainActor (NSOpenPanel, Bool) -> Void)? = nil,
        authorizationSelectionProvider: AuthorizationSelectionProvider? = nil
    ) {
        self.store = store
        self.onboardingStore = onboardingStore
        self.panelProvider = panelProvider
        self.selectedURLsProvider = selectedURLsProvider
        self.panelConfigurator = panelConfigurator ?? { panel, allowsMultipleSelection in
            Self.configure(panel, allowsMultipleSelection: allowsMultipleSelection)
        }
        self.authorizationSelectionProvider = authorizationSelectionProvider
    }

    @discardableResult
    func requestAuthorization() -> Bool {
        requestAuthorizationResult().didChangeAuthorization
    }

    func requestAuthorizationResult() -> GitScanRootAuthorizationRequestResult {
        let urls = requestedURLs(allowsMultipleSelection: true)
        let didCompleteOnboarding = onboardingStore.markCompleted()
        guard let urls else {
            return GitScanRootAuthorizationRequestResult(
                didChangeAuthorization: false,
                didCompleteOnboarding: didCompleteOnboarding
            )
        }

        do {
            return GitScanRootAuthorizationRequestResult(
                didChangeAuthorization: try store.addAuthorizedRoots(urls),
                didCompleteOnboarding: didCompleteOnboarding
            )
        } catch {
            NSLog("TinyBuddy: failed to save Git scan root authorization (details redacted)")
            return GitScanRootAuthorizationRequestResult(
                didChangeAuthorization: false,
                didCompleteOnboarding: didCompleteOnboarding
            )
        }
    }

    @discardableResult
    func reauthorizeAuthorizedRoot(id: String) -> Bool {
        guard let url = requestedURLs(allowsMultipleSelection: false)?.first else {
            return false
        }

        do {
            _ = try store.replaceAuthorizedRoot(id: id, with: url)
            // A fresh user selection restores the security scope even when the
            // serialized bookmark happens to compare equal. Always rescan.
            return true
        } catch {
            NSLog("TinyBuddy: failed to refresh Git scan root authorization (details redacted)")
            return false
        }
    }

    @discardableResult
    func requestReauthorization(for id: String) -> Bool {
        reauthorizeAuthorizedRoot(id: id)
    }

    @discardableResult
    func requestReauthorizationForFirstUnavailableRoot() -> Bool {
        guard let authorization = store.authorizationStatuses().first(where: {
            if case .unavailable = $0.state {
                return true
            }
            return false
        }) else {
            return requestAuthorization()
        }

        return requestReauthorization(for: authorization.id)
    }

    @discardableResult
    func removeAuthorizedRoot(id: String) -> Bool {
        store.removeAuthorizedRoot(id: id)
    }

    @discardableResult
    func removeAuthorization(id: String) -> Bool {
        removeAuthorizedRoot(id: id)
    }

    @discardableResult
    func removeAllAuthorizedRoots() -> Bool {
        store.removeAllAuthorizedRoots()
    }

    @discardableResult
    func removeAllAuthorizations() -> Bool {
        removeAllAuthorizedRoots()
    }

    private func configuredPanel(allowsMultipleSelection: Bool) -> NSOpenPanel {
        let panel = panelProvider()
        panelConfigurator(panel, allowsMultipleSelection)
        return panel
    }

    private func requestedURLs(allowsMultipleSelection: Bool) -> [URL]? {
        if let authorizationSelectionProvider {
            return authorizationSelectionProvider(allowsMultipleSelection)
        }

        let panel = configuredPanel(allowsMultipleSelection: allowsMultipleSelection)
        guard panel.runModal() == .OK else {
            return nil
        }
        return selectedURLsProvider(panel)
    }

    private static func configure(_ panel: NSOpenPanel, allowsMultipleSelection: Bool) {
        panel.title = "选择 Git 扫描目录"
        panel.message = "请选择一个或多个开发目录，TinyBuddy 只会扫描这些目录中的 Git 元数据。"
        panel.prompt = "授权"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
    }
}
