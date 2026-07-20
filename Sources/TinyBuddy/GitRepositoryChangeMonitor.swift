import CoreServices
import Foundation

protocol GitRepositoryChangeMonitoring: AnyObject {
    var isRunning: Bool { get }

    @discardableResult
    func start() -> Bool
    func stop()
}

protocol GitRepositoryChangeEventStream: AnyObject {
    @discardableResult
    func start() -> Bool
    func stop()
    func invalidate()
}

struct GitRepositoryChangeImpact: Equatable, Sendable {
    let requiresRepositoryDiscoveryRescan: Bool
    let affectedRootPaths: [String]
}

final class GitRepositoryChangeMonitor: GitRepositoryChangeMonitoring {
    typealias AuthorizedRootsProvider = () -> GitScanRootAccessResult
    typealias EventStreamFactory = (
        _ watchedPaths: [String],
        _ handleEventPaths: @escaping ([String]) -> Void
    ) -> GitRepositoryChangeEventStream?
    typealias ChangeHandler = (GitRepositoryChangeImpact) -> Void

    private struct ActiveResources {
        let stream: GitRepositoryChangeEventStream
        let roots: [ScopedGitScanRoot]
    }

    private let authorizedRootsProvider: AuthorizedRootsProvider
    private let eventStreamFactory: EventStreamFactory
    private let changeHandler: ChangeHandler
    private let stateLock = NSLock()
    private var activeResources: ActiveResources?

    init(
        authorizedRootsProvider: @escaping AuthorizedRootsProvider,
        changeHandler: @escaping ChangeHandler,
        eventStreamFactory: @escaping EventStreamFactory = GitRepositoryChangeMonitor.makeFSEventStream
    ) {
        self.authorizedRootsProvider = authorizedRootsProvider
        self.changeHandler = changeHandler
        self.eventStreamFactory = eventStreamFactory
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeResources != nil
    }

    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        guard activeResources == nil else {
            stateLock.unlock()
            return true
        }
        stateLock.unlock()

        let accessResult = authorizedRootsProvider()
        let roots = accessResult.roots
        guard !roots.isEmpty else {
            return false
        }

        guard let stream = eventStreamFactory(
            roots.map { $0.url.standardizedFileURL.path },
            { [weak self] eventPaths in
                self?.handle(eventPaths: eventPaths)
            }
        ) else {
            Self.stopAccessing(roots)
            return false
        }

        stateLock.lock()
        guard activeResources == nil else {
            stateLock.unlock()
            stream.stop()
            stream.invalidate()
            Self.stopAccessing(roots)
            return true
        }
        activeResources = ActiveResources(stream: stream, roots: roots)
        let didStart = stream.start()
        if !didStart {
            activeResources = nil
        }
        stateLock.unlock()

        guard didStart else {
            stream.stop()
            stream.invalidate()
            Self.stopAccessing(roots)
            return false
        }
        return true
    }

    func stop() {
        let resources: ActiveResources?
        stateLock.lock()
        resources = activeResources
        activeResources = nil
        stateLock.unlock()

        guard let resources else {
            return
        }
        resources.stream.stop()
        resources.stream.invalidate()
        Self.stopAccessing(resources.roots)
    }

    static func isRelevantGitMetadataChange(path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        if components.last == ".gitmodules" {
            return true
        }

        guard let gitDirectoryIndex = components.lastIndex(where: {
            $0 == ".git" || ($0.hasSuffix(".git") && $0.count > ".git".count)
        }) else {
            return false
        }

        let metadataComponents = components.dropFirst(gitDirectoryIndex + 1)
        guard let firstMetadataComponent = metadataComponents.first else {
            return true
        }

        return firstMetadataComponent == "logs"
            || firstMetadataComponent == "reflog"
            || firstMetadataComponent == "refs"
            || firstMetadataComponent == "HEAD"
            || firstMetadataComponent.hasPrefix("HEAD.")
            || firstMetadataComponent == "index"
            || firstMetadataComponent.hasPrefix("index.")
            || firstMetadataComponent == "config"
            || firstMetadataComponent.hasPrefix("config.")
    }

    static func requiresRepositoryDiscoveryRescan(path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        if components.last == ".gitmodules" || components.last == ".git" {
            return true
        }

        guard let gitDirectoryIndex = components.lastIndex(where: {
            $0 == ".git" || ($0.hasSuffix(".git") && $0.count > ".git".count)
        }) else {
            return false
        }
        let metadataComponents = components.dropFirst(gitDirectoryIndex + 1)
        guard let firstMetadataComponent = metadataComponents.first else {
            return true
        }
        return firstMetadataComponent == "config"
            || firstMetadataComponent.hasPrefix("config.")
    }

    private func handle(eventPaths: [String]) {
        let relevantPaths = eventPaths.filter(Self.isRelevantGitMetadataChange(path:))
        guard !relevantPaths.isEmpty else {
            return
        }
        let requiresDiscoveryRescan = relevantPaths.contains(
            where: Self.requiresRepositoryDiscoveryRescan(path:)
        )
        let watchedRoots: [String]
        stateLock.lock()
        watchedRoots = activeResources?.roots.map { $0.url.standardizedFileURL.path } ?? []
        stateLock.unlock()
        let affectedRoots = requiresDiscoveryRescan
            ? Self.affectedRootPaths(for: relevantPaths, watchedRoots: watchedRoots)
            : []
        changeHandler(GitRepositoryChangeImpact(
            requiresRepositoryDiscoveryRescan: requiresDiscoveryRescan,
            affectedRootPaths: affectedRoots
        ))
    }

    static func affectedRootPaths(for eventPaths: [String], watchedRoots: [String]) -> [String] {
        var affected = Set<String>()
        for eventPath in eventPaths {
            let normalizedEventPath = URL(fileURLWithPath: eventPath).standardizedFileURL.path
            if let root = watchedRoots
                .map({ URL(fileURLWithPath: $0).standardizedFileURL.path })
                .filter({ normalizedEventPath == $0 || normalizedEventPath.hasPrefix($0 + "/") })
                .max(by: { $0.count < $1.count }) {
                affected.insert(root)
            }
        }
        return affected.sorted()
    }

    private static func stopAccessing(_ roots: [ScopedGitScanRoot]) {
        roots.forEach { $0.stopAccessing() }
    }

    private static func makeFSEventStream(
        watchedPaths: [String],
        handleEventPaths: @escaping ([String]) -> Void
    ) -> GitRepositoryChangeEventStream? {
        FSEventGitRepositoryChangeEventStream(
            watchedPaths: watchedPaths,
            handleEventPaths: handleEventPaths
        )
    }
}

private final class FSEventGitRepositoryChangeEventStream: GitRepositoryChangeEventStream {
    private var stream: FSEventStreamRef?
    private let handleEventPaths: ([String]) -> Void

    init?(watchedPaths: [String], handleEventPaths: @escaping ([String]) -> Void) {
        guard !watchedPaths.isEmpty else {
            return nil
        }

        self.handleEventPaths = handleEventPaths
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(
            stream,
            DispatchQueue(label: "TinyBuddy.GitRepositoryChangeMonitor", qos: .utility)
        )
    }

    deinit {
        stop()
        invalidate()
    }

    @discardableResult
    func start() -> Bool {
        guard let stream else {
            return false
        }
        return FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
    }

    func invalidate() {
        guard let stream else {
            return
        }
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else {
            return
        }
        let eventStream = Unmanaged<FSEventGitRepositoryChangeEventStream>
            .fromOpaque(info)
            .takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        eventStream.handleEventPaths(paths)
    }
}
