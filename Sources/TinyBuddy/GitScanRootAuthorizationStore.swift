import AppKit
import Darwin
import Foundation

struct ScopedGitScanRoot {
    let url: URL
    private let stopAccessingAction: () -> Void

    init(url: URL, stopAccessingAction: @escaping () -> Void = {}) {
        self.url = url
        self.stopAccessingAction = stopAccessingAction
    }

    func stopAccessing() {
        stopAccessingAction()
    }
}

final class GitScanRootAuthorizationStore {
    enum Constants {
        static let bookmarkDataKey = "tinybuddy.gitScanRoots.bookmarkData"
    }

    typealias BookmarkDataCreator = (URL) throws -> Data
    typealias ScopedRootResolver = (Data) throws -> ScopedGitScanRoot?

    private let userDefaults: UserDefaults
    private let bookmarkDataCreator: BookmarkDataCreator
    private let scopedRootResolver: ScopedRootResolver

    init(
        userDefaults: UserDefaults = .standard,
        bookmarkDataCreator: @escaping BookmarkDataCreator = GitScanRootAuthorizationStore.makeSecurityScopedBookmarkData(for:),
        scopedRootResolver: @escaping ScopedRootResolver = GitScanRootAuthorizationStore.resolveSecurityScopedRoot(from:)
    ) {
        self.userDefaults = userDefaults
        self.bookmarkDataCreator = bookmarkDataCreator
        self.scopedRootResolver = scopedRootResolver
    }

    var hasAuthorizedRoots: Bool {
        !bookmarkDataList().isEmpty
    }

    func replaceAuthorizedRoots(_ urls: [URL]) throws {
        let bookmarkData = try Self.uniqueStandardizedDirectoryURLs(from: urls).map(bookmarkDataCreator)
        userDefaults.set(bookmarkData, forKey: Constants.bookmarkDataKey)
    }

    func accessAuthorizedRoots() -> [ScopedGitScanRoot] {
        let bookmarkData = bookmarkDataList()
        var resolvedBookmarkData: [Data] = []
        var roots: [ScopedGitScanRoot] = []

        for bookmarkDatum in bookmarkData {
            guard let root = try? scopedRootResolver(bookmarkDatum) else {
                continue
            }
            guard Self.isAllowedScanRoot(root.url) else {
                root.stopAccessing()
                continue
            }

            resolvedBookmarkData.append(bookmarkDatum)
            roots.append(root)
        }

        if resolvedBookmarkData.count != bookmarkData.count {
            userDefaults.set(resolvedBookmarkData, forKey: Constants.bookmarkDataKey)
            NSLog("TinyBuddy: one or more Git scan root bookmarks could not be resolved")
        }

        return roots
    }

    private func bookmarkDataList() -> [Data] {
        userDefaults.array(forKey: Constants.bookmarkDataKey) as? [Data] ?? []
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

    private static func resolveSecurityScopedRoot(from bookmarkData: Data) throws -> ScopedGitScanRoot? {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard !isStale else {
            return nil
        }

        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }

        return ScopedGitScanRoot(url: url) {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
final class GitScanRootAuthorizationController {
    private let store: GitScanRootAuthorizationStore
    private let panelProvider: @MainActor () -> NSOpenPanel

    init(
        store: GitScanRootAuthorizationStore,
        panelProvider: @escaping @MainActor () -> NSOpenPanel = { NSOpenPanel() }
    ) {
        self.store = store
        self.panelProvider = panelProvider
    }

    func requestAuthorizationIfNeeded() {
        let roots = store.accessAuthorizedRoots()
        roots.forEach { $0.stopAccessing() }

        guard roots.isEmpty else {
            return
        }

        requestAuthorization()
    }

    func requestAuthorization() {
        let panel = panelProvider()
        panel.title = "选择 Git 扫描目录"
        panel.message = "请选择一个或多个开发目录，TinyBuddy 只会扫描这些目录中的 Git 元数据。"
        panel.prompt = "授权"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else {
            return
        }

        do {
            try store.replaceAuthorizedRoots(panel.urls)
        } catch {
            NSLog("TinyBuddy: failed to save Git scan root authorization: %@", error.localizedDescription)
        }
    }
}
