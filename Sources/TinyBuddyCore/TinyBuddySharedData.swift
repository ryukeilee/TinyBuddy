import Foundation

struct TinyBuddyAppGroupPreferencesRead {
    let values: [String: Any]?
    let failure: TinyBuddySharedSnapshotReason?
}

public enum TinyBuddySharedData {
    public static let appGroupIdentifier = "group.com.ryukeili.TinyBuddy"

    public static func makeUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// Tests whether this process has a real App Group container without
    /// exposing the container path to diagnostics callers.
    public static func isAppGroupContainerAvailable(
        fileManager: FileManager = .default
    ) -> Bool {
        appGroupContainerURL(fileManager: fileManager) != nil
    }

    static func isAppGroupDefaultsAvailable() -> Bool {
        UserDefaults(suiteName: appGroupIdentifier) != nil
    }

    private static func appGroupContainerURL(
        fileManager: FileManager
    ) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    public static func appGroupPreferencesPlistURL(fileManager: FileManager = .default) -> URL? {
        guard let containerURL = appGroupContainerURL(fileManager: fileManager) else {
            return nil
        }

        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(appGroupIdentifier).plist")
    }

    public static func timeScopeTokenURL(fileManager: FileManager = .default) -> URL? {
        guard let containerURL = appGroupContainerURL(fileManager: fileManager) else {
            return nil
        }

        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(".tinybuddy-time-scope")
    }

    public static func loadTimeScopeToken(fileManager: FileManager = .default) -> String? {
        guard let tokenURL = timeScopeTokenURL(fileManager: fileManager),
              let value = try? String(contentsOf: tokenURL, encoding: .utf8),
              let token = value.split(whereSeparator: \.isNewline).first.map(String.init),
              !token.isEmpty,
              token.count <= 128,
              token.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else {
            return nil
        }
        return token
    }

    public static func loadAppGroupPreferencesDictionary(
        fileManager: FileManager = .default
    ) -> [String: Any]? {
        readAppGroupPreferences(fileManager: fileManager).values
    }

    static func readAppGroupPreferences(
        fileManager: FileManager = .default,
        dataLoader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> TinyBuddyAppGroupPreferencesRead {
        readAppGroupPreferences(
            at: appGroupPreferencesPlistURL(fileManager: fileManager),
            dataLoader: dataLoader
        )
    }

    static func readAppGroupPreferences(
        at preferencesURL: URL?,
        dataLoader: @escaping (URL) throws -> Data
    ) -> TinyBuddyAppGroupPreferencesRead {
        guard let url = preferencesURL else {
            return TinyBuddyAppGroupPreferencesRead(
                values: nil,
                failure: .appGroupUnavailable
            )
        }

        let data: Data
        do {
            data = try dataLoader(url)
        } catch {
            if isMissingPreferencesFile(error) {
                // A suite without a persistent domain is a normal first-launch
                // state, not an App Group failure.
                return TinyBuddyAppGroupPreferencesRead(values: nil, failure: nil)
            }
            return TinyBuddyAppGroupPreferencesRead(
                values: nil,
                failure: readFailureReason(for: error)
            )
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            return TinyBuddyAppGroupPreferencesRead(
                values: nil,
                failure: .snapshotCorrupt
            )
        }

        return TinyBuddyAppGroupPreferencesRead(values: plist, failure: nil)
    }

    private static func isMissingPreferencesFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileNoSuchFileError
    }

    private static func readFailureReason(
        for error: Error
    ) -> TinyBuddySharedSnapshotReason {
        let nsError = error as NSError
        let deniedCocoaCodes = [NSFileReadNoPermissionError, NSFileWriteNoPermissionError]
        let deniedPOSIXCodes = [1, 13] // EPERM and EACCES, kept platform-neutral here.
        if (nsError.domain == NSCocoaErrorDomain && deniedCocoaCodes.contains(nsError.code))
            || (nsError.domain == NSPOSIXErrorDomain && deniedPOSIXCodes.contains(nsError.code)) {
            return .sandboxReadDenied
        }
        return .appGroupUnavailable
    }
}

/// Process-local fence for readers in the app process. WidgetKit runs in a
/// separate process and falls back to the atomically published app-group token.
public final class TinyBuddyTimeScopeState: @unchecked Sendable {
    public static let shared = TinyBuddyTimeScopeState()

    private let lock = NSLock()
    private var processToken: String?

    private init() {}

    public func replaceProcessToken(_ token: String) {
        lock.lock()
        processToken = token
        lock.unlock()
    }

    public func currentToken() -> String? {
        lock.lock()
        let token = processToken
        lock.unlock()
        return token ?? TinyBuddySharedData.loadTimeScopeToken()
    }
}

public struct TinyBuddySnapshot: Equatable, Sendable {
    public let status: PetStatus
    public let stats: DailyStats

    public init(status: PetStatus, stats: DailyStats) {
        self.status = status
        self.stats = stats
    }
}
