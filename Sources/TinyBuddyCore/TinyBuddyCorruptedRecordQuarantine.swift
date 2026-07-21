import Foundation

// MARK: - Quarantine Storage

/// Manages isolation and retrieval of corrupted records that could not be safely
/// auto-repaired. Records are preserved with redacted diagnostics so they are
/// never silently discarded, but also never re-enter the active data path.
///
/// Thread safety: all operations are serialized via an internal lock.
public final class TinyBuddyCorruptedRecordQuarantine: @unchecked Sendable {
    private let storageURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    private static let quarantineFileName = "corrupted_records.json"
    private static let maxEntries = 500

    // MARK: - Init

    public init(
        storageURL: URL? = nil,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
            )
            self.storageURL = (container ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("com.ryukeili.TinyBuddy", isDirectory: true)
                .appendingPathComponent("Quarantine", isDirectory: true)
                .appendingPathComponent(Self.quarantineFileName)
        }

        self.encoder = encoder
        self.decoder = decoder
    }

    // MARK: - Public API

    /// Isolates one or more corrupted records. Returns the quarantine entry IDs.
    /// The entry preserves the original data (redacted) so it can be inspected
    /// but never automatically reimported.
    @discardableResult
    public func isolate(entries: [TinyBuddyCorruptedRecordEntry]) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !entries.isEmpty else { return true }

        var existing = loadAllLocked()
        existing.append(contentsOf: entries)

        // Enforce max entries (drop oldest)
        if existing.count > Self.maxEntries {
            existing = Array(existing.suffix(Self.maxEntries))
        }

        return saveLocked(existing)
    }

    /// Isolates a single corrupted record. Convenience wrapper.
    @discardableResult
    public func isolate(
        domain: TinyBuddyDataDomain,
        violationKind: TinyBuddyDataInvariantKind,
        redactedOriginalData: String,
        diagnosticKey: String
    ) -> TinyBuddyCorruptedRecordEntry? {
        let entry = TinyBuddyCorruptedRecordEntry(
            domain: domain,
            violationKind: violationKind,
            redactedOriginalData: redactedOriginalData,
            diagnosticKey: diagnosticKey
        )
        return isolate(entries: [entry]) ? entry : nil
    }

    /// Returns all currently quarantined entries (read-only).
    public func loadAll() -> [TinyBuddyCorruptedRecordEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadAllLocked()
    }

    /// Removes quarantined entries older than the given date.
    @discardableResult
    public func prune(before date: Date) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var entries = loadAllLocked()
        let beforeCount = entries.count
        entries.removeAll { $0.isolatedAt < date }
        let removed = beforeCount - entries.count
        if removed > 0 {
            _ = saveLocked(entries)
        }
        return removed
    }

    /// Removes a specific quarantined entry by ID.
    @discardableResult
    public func removeEntry(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var entries = loadAllLocked()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return saveLocked(entries)
    }

    /// Clears all quarantined records.
    @discardableResult
    public func clearAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveLocked([])
    }

    /// Returns the number of quarantined entries.
    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loadAllLocked().count
    }

    /// Returns stable redacted diagnostic summaries for telemetry.
    /// Each entry contains only the diagnostic key and violation type — no user data.
    public func diagnosticSummaries() -> [(diagnosticKey: String, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        let entries = loadAllLocked()
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.diagnosticKey, default: 0] += 1
        }
        let result: [(diagnosticKey: String, count: Int)] = counts.map {
            (diagnosticKey: $0.key, count: $0.value)
        }.sorted { left, right in left.diagnosticKey < right.diagnosticKey }
        return result
    }

    // MARK: - Private

    private func quarantineDirectory() -> URL {
        storageURL.deletingLastPathComponent()
    }

    private func ensureDirectoryExists() -> Bool {
        let dir = quarantineDirectory()
        guard !FileManager.default.fileExists(atPath: dir.path) else { return true }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private func loadAllLocked() -> [TinyBuddyCorruptedRecordEntry] {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let entries = try? decoder.decode([TinyBuddyCorruptedRecordEntry].self, from: data) else {
            return []
        }
        return entries
    }

    @discardableResult
    private func saveLocked(_ entries: [TinyBuddyCorruptedRecordEntry]) -> Bool {
        guard ensureDirectoryExists() else { return false }
        let tempURL = storageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(storageURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let data = try encoder.encode(entries)
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: storageURL.path) {
                _ = try FileManager.default.replaceItemAt(storageURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: storageURL)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}
