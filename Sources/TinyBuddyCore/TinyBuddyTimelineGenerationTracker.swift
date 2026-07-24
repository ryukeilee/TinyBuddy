import Foundation
import OSLog

/// Tracks the logical generation of widget timeline reloads to prevent stale
/// or delayed callbacks from overwriting newer committed state.
///
/// Each Widget timeline reload carries a generation counter.  When the
/// generation stored in the committed snapshot is older than the latest
/// reload generation, the timeline entry is known to have been built from
/// up-to-date data and the widget's TimelineProvider can skip expensive
/// fallback paths.  When the snapshot generation is *newer*, it means the
/// timeline was built from older data and the widget should still render
/// the latest snapshot but flag a diagnostic.
///
/// The generation is stored as part of the combined snapshot metadata.  It
/// advances monotonically within each app launch session and crosses process
/// boundaries through the App Group shared preferences.
public enum TinyBuddyTimelineGenerationTracker {
    public enum Key {
        public static let timelineGeneration = "tinybuddy.timeline.generation"
        public static let timelineGenerationTimestamp = "tinybuddy.timeline.generation.timestamp"
    }

    private static let logger = Logger(
        subsystem: "local.tinybuddy",
        category: "TimelineGeneration"
    )

    /// Returns the current timeline generation from the App Group store.
    /// Returns 0 when no generation has been recorded yet.
    public static func currentGeneration(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> Int64 {
        let raw = userDefaults.object(forKey: Key.timelineGeneration) as? Int64 ?? 0
        guard raw >= 0 else { return 0 }
        return raw
    }

    /// Returns the timestamp of the last generation advance, or `distantPast`
    /// when no generation has been recorded yet.
    public static func currentGenerationTimestamp(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> Date {
        let interval = userDefaults.double(forKey: Key.timelineGenerationTimestamp)
        guard interval > 0 else { return .distantPast }
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    /// Advances the timeline generation and records the timestamp atomically.
    /// Returns the new generation value.
    @discardableResult
    public static func advanceGeneration(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> Int64 {
        let current = currentGeneration(userDefaults: userDefaults)
        let next = current + 1
        userDefaults.set(next, forKey: Key.timelineGeneration)
        userDefaults.set(
            Date.timeIntervalSinceReferenceDate,
            forKey: Key.timelineGenerationTimestamp
        )
        logger.notice(
            "timeline generation advanced: \(current, privacy: .public) -> \(next, privacy: .public)"
        )
        return next
    }

    /// Returns `true` when the timeline generation in the snapshot is at least
    /// as recent as the global generation, meaning the snapshot was committed
    /// after the last timeline reload request.
    public static func isSnapshotCurrent(
        snapshotGeneration: Int64,
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> Bool {
        let globalGeneration = currentGeneration(userDefaults: userDefaults)
        return snapshotGeneration >= globalGeneration
    }

    /// Resets the generation counter.  Intended for testing only.
    public static func resetForTesting(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) {
        userDefaults.removeObject(forKey: Key.timelineGeneration)
        userDefaults.removeObject(forKey: Key.timelineGenerationTimestamp)
    }
}
