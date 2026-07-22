import Foundation

/// Preserves the last validated time-environment fingerprint across process
/// boundaries so the App and Widget can detect clock discontinuities (manual
/// time changes, timezone shifts, DST transitions) and react consistently.
///
/// Stored in the shared App Group UserDefaults so both the app target and the
/// Widget extension can read/write the same continuity record without a
/// dedicated XPC or file coordination layer.
public struct TinyBuddyTimeContinuityRecord: Codable, Equatable, Sendable {
    /// The last local day identifier that was committed.
    public var lastObservedDayIdentifier: String

    /// The last time-zone identifier (e.g. "America/Los_Angeles").
    public var lastObservedTimeZoneIdentifier: String

    /// Monotonically increasing generation. Each detected discontinuity or
    /// cross-day boundary signal advances this value.
    public var calibrationGeneration: Int64

    /// The wall-clock date when this record was last updated.
    public var lastCalibrationDate: Date

    /// Cumulative discontinuity count since first install or explicit reset.
    public var discontinuityCount: Int64

    /// An opaque scope hint that lets readers cheaply detect that the time
    /// environment has changed since their last observation without parsing
    /// the full signature.  Matches the `portableScopeIdentifier` of the
    /// calibrator's current `TinyBuddyTimeContext`.
    public var lastScopeIdentifier: String

    /// The system uptime (monotonic time) when this record was last updated.
    /// Used together with `lastCalibrationDate` to detect manual clock
    /// adjustments by comparing wall-clock and monotonic elapsed times.
    public var lastMonotonicTime: TimeInterval

    /// The observed length of the last local day in seconds.
    /// `nil` = normal day or unknown; `82800` = spring-forward (23h);
    /// `90000` = fall-back (25h). Set by the calibrator during capture
    /// when the difference from 86400 exceeds the DST detection threshold.
    public var lastObservedDayLengthSeconds: Int?

    public init(
        lastObservedDayIdentifier: String,
        lastObservedTimeZoneIdentifier: String,
        calibrationGeneration: Int64 = 0,
        lastCalibrationDate: Date = Date(timeIntervalSince1970: 0),
        discontinuityCount: Int64 = 0,
        lastScopeIdentifier: String = "",
        lastMonotonicTime: TimeInterval = 0,
        lastObservedDayLengthSeconds: Int? = nil
    ) {
        self.lastObservedDayIdentifier = lastObservedDayIdentifier
        self.lastObservedTimeZoneIdentifier = lastObservedTimeZoneIdentifier
        self.calibrationGeneration = calibrationGeneration
        self.lastCalibrationDate = lastCalibrationDate
        self.discontinuityCount = discontinuityCount
        self.lastScopeIdentifier = lastScopeIdentifier
        self.lastMonotonicTime = lastMonotonicTime
        self.lastObservedDayLengthSeconds = lastObservedDayLengthSeconds
    }
}

// MARK: - Shared Prefs Persistence

extension TinyBuddyTimeContinuityRecord {
    public enum Key {
        /// Binary-plist-encoded `TinyBuddyTimeContinuityRecord`.
        public static let continuityRecord = "tinybuddy.timeContinuityRecord.v1"
    }

    /// Loads the continuity record from the shared App Group defaults.
    /// Returns a default (empty) record when no prior state exists.
    public static func load(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> TinyBuddyTimeContinuityRecord {
        guard let data = userDefaults.data(forKey: Key.continuityRecord),
              let record = try? PropertyListDecoder().decode(
                TinyBuddyTimeContinuityRecord.self,
                from: data
              ) else {
            return TinyBuddyTimeContinuityRecord(
                lastObservedDayIdentifier: "",
                lastObservedTimeZoneIdentifier: ""
            )
        }
        return record
    }

    /// Returns the current calibration generation from the shared continuity
    /// record without loading the full record.  Convenience for Widget and
    /// lightweight readers that only need to detect time-scope changes.
    public static func currentCalibrationGeneration(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> Int64 {
        load(userDefaults: userDefaults).calibrationGeneration
    }

    /// Saves the continuity record to the shared App Group defaults.
    @discardableResult
    public func save(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> Bool {
        guard let data = try? PropertyListEncoder().encode(self) else {
            return false
        }
        userDefaults.set(data, forKey: Key.continuityRecord)
        userDefaults.synchronize()
        return true
    }

    /// Removes the continuity record from shared defaults.
    public static func remove(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) {
        userDefaults.removeObject(forKey: Key.continuityRecord)
        userDefaults.synchronize()
    }
}
