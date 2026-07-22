import Foundation
import OSLog

// MARK: - Calibration Outcome

/// Describes what the calibrator concluded during a calibration check.
public enum TinyBuddyCalibrationOutcome: Equatable, Sendable {
    /// Time context is stable and consistent with the previous observation.
    case stable(continuity: TinyBuddyTimeContinuityRecord)
    /// The local day identifier changed from the previous observation
    /// (normal midnight rollover or timezone-induced day change).
    case dayChanged(
        from: String,
        to: String,
        continuity: TinyBuddyTimeContinuityRecord
    )
    /// A clock discontinuity was detected: either a manual clock adjustment,
    /// a DST transition that is not a simple day change, or a system time
    /// jump that caused the wall clock to diverge from the monotonic clock.
    case discontinuityDetected(
        previousDay: String,
        currentDay: String,
        previousZone: String,
        currentZone: String,
        continuity: TinyBuddyTimeContinuityRecord
    )
    /// Time-zone changed without a day-identifier change.
    case timeZoneChanged(
        from: String,
        to: String,
        continuity: TinyBuddyTimeContinuityRecord
    )
    /// The calibrator could not produce a valid time context.
    case invalid
}

// MARK: - Calibrator

/// Unifies time-environment capture, clock-discontinuity detection, and
/// cross-process continuity persistence so that App and Widget always
/// agree on the current local day and time scope.
///
/// ## Thread safety
/// `TinyBuddyTimeCalibrator` is `@unchecked Sendable` because it uses an
/// internal `NSLock` for thread-safe mutation of its continuity state.
public final class TinyBuddyTimeCalibrator: @unchecked Sendable {
    public typealias MonotonicProvider = () -> TimeInterval

    private let lock = NSLock()
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let userDefaults: UserDefaults
    private let monotonicProvider: MonotonicProvider
    private let discontinuityThreshold: TimeInterval
    private let logger: Logger

    /// Callback invoked when calibration detects a meaningful change.
    /// Set this once, before calling `calibrate()`.
    public var onChange: (@Sendable (TinyBuddyCalibrationOutcome) -> Void)?

    private var lastContinuity: TinyBuddyTimeContinuityRecord

    // MARK: - Init

    public init(
        timeEnvironment: TinyBuddyTimeEnvironment = TinyBuddyTimeEnvironment(),
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        monotonicProvider: @escaping MonotonicProvider = {
            ProcessInfo.processInfo.systemUptime
        },
        discontinuityThreshold: TimeInterval = 5.0,
        onChange: (@Sendable (TinyBuddyCalibrationOutcome) -> Void)? = nil
    ) {
        self.timeEnvironment = timeEnvironment
        self.userDefaults = userDefaults
        self.monotonicProvider = monotonicProvider
        self.discontinuityThreshold = max(0.1, discontinuityThreshold)
        self.onChange = onChange
        self.lastContinuity = TinyBuddyTimeContinuityRecord.load(
            userDefaults: userDefaults
        )
        self.logger = Logger(
            subsystem: "local.tinybuddy",
            category: "TimeCalibrator"
        )
    }

    // MARK: - Public API

    /// Returns the shared defaults–backed continuity record without capturing
    /// a new time context. Useful for Widget and read-only callers that want
    /// to check whether the time scope has changed since their last timeline.
    public var continuityRecord: TinyBuddyTimeContinuityRecord {
        lock.lock()
        defer { lock.unlock() }
        return lastContinuity
    }

    /// Captures the current time context, compares it against the last known
    /// continuity record, detects discontinuities, persists the updated record,
    /// and emits `onChange` when meaningful.
    ///
    /// Thread-safe.
    @discardableResult
    public func calibrate() -> TinyBuddyCalibrationOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard let context = timeEnvironment.capture() else {
            logger.error("Calibrator: got nil time context")
            let outcome = TinyBuddyCalibrationOutcome.invalid
            onChange?(outcome)
            return outcome
        }

        return calibrateLocked(with: context)
    }

    /// Captures the current time context and returns it together with the
    /// calibration outcome in one call.  Convenience for callers that need
    /// both values synchronously.
    public func calibratedContext() -> (TinyBuddyTimeContext?, TinyBuddyCalibrationOutcome) {
        lock.lock()
        defer { lock.unlock() }

        guard let context = timeEnvironment.capture() else {
            return (nil, .invalid)
        }

        let outcome = calibrateLocked(with: context)
        return (context, outcome)
    }

    /// Overrides the continuity record (e.g. after app reset or first launch).
    /// Does **not** trigger `onChange`.
    public func resetContinuity() {
        lock.lock()
        defer { lock.unlock() }

        lastContinuity = TinyBuddyTimeContinuityRecord(
            lastObservedDayIdentifier: "",
            lastObservedTimeZoneIdentifier: "",
            lastMonotonicTime: 0
        )
        lastContinuity.save(userDefaults: userDefaults)
    }

    /// Force-advance the generation without changing the stored time
    /// fingerprint.  Used when the refresh coordinator invalidates its
    /// time scope; the generation bump lets cross-process readers detect
    /// that something changed even if the day/timezone look the same.
    public func bumpGeneration() {
        lock.lock()
        defer { lock.unlock() }

        lastContinuity.calibrationGeneration += 1
        lastContinuity.lastCalibrationDate = Date()
        lastContinuity.save(userDefaults: userDefaults)
    }

    // MARK: - Internal

    private func calibrateLocked(
        with context: TinyBuddyTimeContext
    ) -> TinyBuddyCalibrationOutcome {
        let previousGeneration = lastContinuity.calibrationGeneration
        let previousDay = lastContinuity.lastObservedDayIdentifier
        let previousZone = lastContinuity.lastObservedTimeZoneIdentifier
        let currentDay = context.dayIdentifier
        let currentZone = context.timeZone.identifier
        let currentScope = context.signature.portableScopeIdentifier

        // Use the captured context's instant as the wall-clock reference.
        // This keeps the calibrator consistent with the time environment and
        // avoids mixing fixed test times with real `Date()` values.
        let now = context.now
        let currentMonotonic = monotonicProvider()

        // ---- Clock discontinuity detection via monotonic clock ----
        //
        // If the last calibration was recent and stored a monotonic reference,
        // compare wall-clock elapsed against monotonic elapsed to detect
        // manual time changes (clock jumps).
        let clockJumped: Bool
        if lastContinuity.lastMonotonicTime > 0,
           lastContinuity.lastCalibrationDate.timeIntervalSince1970 > 0 {
            let monotonicElapsed = currentMonotonic - lastContinuity.lastMonotonicTime
            let wallElapsed = now.timeIntervalSince(lastContinuity.lastCalibrationDate)
            let drift = abs(wallElapsed - monotonicElapsed)

            // Only consider it a jump when both elapsed times are within a
            // reasonable range (avoids false positives during sleep/wake).
            let withinReasonableRange = wallElapsed > 0
                && wallElapsed < 86_400 // within 24 hours
                && monotonicElapsed >= 0
                && monotonicElapsed < 86_400
            clockJumped = withinReasonableRange && drift > discontinuityThreshold
        } else {
            clockJumped = false
        }

        // ---- DST transition day detection ----
        //
        // Compute the actual local day length and compare against the standard
        // 86400-second day.  Spring-forward days have 82800 seconds (23h);
        // fall-back days have 90000 seconds (25h).  The value is recorded in
        // the continuity record for diagnostics and widget-coordination but
        // does NOT change the calibration outcome — day-identifier and
        // timezone checks already correctly handle DST boundaries.
        let standardDay: TimeInterval = 86_400
        let dayLength = context.localDayLength
        let dstDayLengthSeconds: Int? = abs(dayLength - standardDay) > 1.0
            ? Int(dayLength.rounded())
            : nil

        // ---- Assemble updated record ----
        var updated = lastContinuity
        updated.lastObservedDayIdentifier = currentDay
        updated.lastObservedTimeZoneIdentifier = currentZone
        updated.lastScopeIdentifier = currentScope
        updated.lastCalibrationDate = now
        updated.lastMonotonicTime = currentMonotonic
        updated.calibrationGeneration = previousGeneration + 1
        updated.lastObservedDayLengthSeconds = dstDayLengthSeconds

        // ---- Classify outcome ----
        let outcome: TinyBuddyCalibrationOutcome

        if clockJumped {
            updated.discontinuityCount += 1
            outcome = .discontinuityDetected(
                previousDay: previousDay,
                currentDay: currentDay,
                previousZone: previousZone,
                currentZone: currentZone,
                continuity: updated
            )
        } else if !previousDay.isEmpty, previousDay != currentDay {
            outcome = .dayChanged(
                from: previousDay,
                to: currentDay,
                continuity: updated
            )
        } else if !previousZone.isEmpty, previousZone != currentZone {
            outcome = .timeZoneChanged(
                from: previousZone,
                to: currentZone,
                continuity: updated
            )
        } else {
            outcome = .stable(continuity: updated)
        }

        // ---- Persist ----
        lastContinuity = updated
        updated.save(userDefaults: userDefaults)

        // ---- Emit callback for meaningful changes ----
        switch outcome {
        case .stable:
            // Only emit on the first ever calibration (initial continuity).
            if previousDay.isEmpty {
                onChange?(outcome)
            }
        case .dayChanged, .discontinuityDetected, .timeZoneChanged:
            let dayChangedStr = previousDay != currentDay
                ? "day=\(previousDay)->\(currentDay)" : ""
            let zoneChangedStr = previousZone != currentZone
                ? "zone=\(previousZone)->\(currentZone)" : ""
            let driftStr = clockJumped ? "clock-jump" : ""
            let detail = [dayChangedStr, zoneChangedStr, driftStr]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            logger.notice("Calibration triggered: \(detail, privacy: .public)")
            onChange?(outcome)
        case .invalid:
            break
        }

        return outcome
    }
}
