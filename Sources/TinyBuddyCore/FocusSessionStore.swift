import Foundation

/// Abstraction over focus session persistence so the engine can be tested with
/// an in-memory store.
public protocol FocusSessionPersisting: Sendable {
    func load() -> [FocusSession]?
    @discardableResult func save(_ sessions: [FocusSession]) -> Bool
}

/// File-backed store using atomic temp+rename writes.  A crash mid-write cannot
/// corrupt the previous valid archive because the old file is preserved until
/// the temp file has been fully written and moved into place.
public final class FocusSessionFileStore: FocusSessionPersisting {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.fileURL = fileURL
        self.encoder = encoder
        self.decoder = decoder
    }

    public func load() -> [FocusSession]? {
        guard let data = try? Data(contentsOf: fileURL) else {
            // fall back to backup if main file does not exist
            let backupURL = backupURL
            guard let data = try? Data(contentsOf: backupURL) else { return nil }
            // promote backup → main silently (recovery)
            try? data.write(to: fileURL, options: .withoutOverwriting)
            try? FileManager.default.removeItem(at: backupURL)
            return try? decoder.decode([FocusSession].self, from: data)
        }
        return try? decoder.decode([FocusSession].self, from: data)
    }

    @discardableResult
    public func save(_ sessions: [FocusSession]) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent("\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let backupURL = self.backupURL
        do {
            let data = try encoder.encode(sessions)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: tempURL, options: .atomic)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Keep old as backup, then swap; if swap fails, old is still accessible as backup.
                try? FileManager.default.removeItem(at: backupURL)
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
                try? FileManager.default.removeItem(at: backupURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    private var backupURL: URL {
        let directory = fileURL.deletingLastPathComponent()
        return directory.appendingPathComponent("\(fileURL.lastPathComponent).bak")
    }
}
