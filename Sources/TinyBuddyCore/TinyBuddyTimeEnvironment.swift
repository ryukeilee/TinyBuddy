import Foundation

public struct TinyBuddyTimeEnvironmentSignature: Equatable, Sendable {
    public let timeZoneIdentifier: String
    public let localeIdentifier: String
    public let calendarIdentifier: String

    public init(
        timeZoneIdentifier: String,
        localeIdentifier: String,
        calendarIdentifier: String
    ) {
        self.timeZoneIdentifier = Self.sanitizedIdentifier(timeZoneIdentifier)
        self.localeIdentifier = Self.sanitizedIdentifier(localeIdentifier)
        self.calendarIdentifier = Self.sanitizedIdentifier(calendarIdentifier)
    }

    /// A stable, diagnostics-safe scope key for values derived from local time.
    public var scopeIdentifier: String {
        "tz=\(escaped(timeZoneIdentifier))|locale=\(escaped(localeIdentifier))|calendar=\(escaped(calendarIdentifier))"
    }

    /// An ASCII identifier safe for environment variables and tabular caches.
    public var portableScopeIdentifier: String {
        Data(scopeIdentifier.utf8).base64EncodedString()
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? "_"
                : Character(String(scalar))
        })
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

public struct TinyBuddyTimeContext: Sendable {
    public let now: Date
    public let signature: TinyBuddyTimeEnvironmentSignature
    public let timeZone: TimeZone
    public let dayIdentifier: String
    public let nextDayBoundary: Date
    public let epochSeconds: Int64

    private let businessCalendar: Calendar

    /// The source locale and calendar are fingerprinted, but daily business
    /// semantics always use the Gregorian calendar and ASCII ISO day keys.
    public init?(
        now: Date,
        timeZone: TimeZone,
        locale: Locale,
        sourceCalendar: Calendar
    ) {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSince1970.isFinite,
              let epochSeconds = Self.epochSeconds(for: now) else {
            return nil
        }

        var businessCalendar = Calendar(identifier: .gregorian)
        businessCalendar.locale = Locale(identifier: "en_US_POSIX")
        businessCalendar.timeZone = timeZone

        guard let dayIdentifier = Self.dayIdentifier(for: now, calendar: businessCalendar) else {
            return nil
        }

        let startOfToday = businessCalendar.startOfDay(for: now)
        guard startOfToday.timeIntervalSinceReferenceDate.isFinite,
              let nextDayBoundary = businessCalendar.date(byAdding: .day, value: 1, to: startOfToday),
              nextDayBoundary.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }

        self.now = now
        self.timeZone = timeZone
        self.signature = TinyBuddyTimeEnvironmentSignature(
            timeZoneIdentifier: timeZone.identifier,
            localeIdentifier: locale.identifier,
            calendarIdentifier: String(describing: sourceCalendar.identifier)
        )
        self.dayIdentifier = dayIdentifier
        self.nextDayBoundary = nextDayBoundary
        self.epochSeconds = epochSeconds
        self.businessCalendar = businessCalendar
    }

    public func dayIdentifier(for date: Date) -> String? {
        Self.dayIdentifier(for: date, calendar: businessCalendar)
    }

    /// The length of the current local day in seconds, computed as the
    /// difference between `nextDayBoundary` and the start of the current
    /// local day.  On standard days this equals 86400; on DST spring-forward
    /// days it equals 82800 (23h); on DST fall-back days it equals 90000 (25h).
    public var localDayLength: TimeInterval {
        let startOfToday = businessCalendar.startOfDay(for: now)
        return nextDayBoundary.timeIntervalSince(startOfToday)
    }

    /// Returns `true` when the current local day length differs from the
    /// standard 86400 seconds by more than the given tolerance, indicating
    /// a DST transition day (spring-forward or fall-back).
    public func isDSTTransitionDay(tolerance: TimeInterval = 1.0) -> Bool {
        abs(localDayLength - 86_400) > tolerance
    }

    public func isSameLocalDay(_ lhs: Date, _ rhs: Date) -> Bool {
        guard let lhsDay = dayIdentifier(for: lhs),
              let rhsDay = dayIdentifier(for: rhs) else {
            return false
        }
        return lhsDay == rhsDay
    }

    /// Returns the earlier of the next local midnight and a positive refresh
    /// interval from the captured instant. Invalid intervals fall back to midnight.
    public func nextRefreshDate(maxInterval: TimeInterval) -> Date {
        guard maxInterval.isFinite, maxInterval > 0 else {
            return nextDayBoundary
        }

        let intervalDate = now.addingTimeInterval(maxInterval)
        guard intervalDate.timeIntervalSinceReferenceDate.isFinite else {
            return nextDayBoundary
        }
        return min(nextDayBoundary, intervalDate)
    }

    public static func isValidDayIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }) else {
            return false
        }

        let year = Int(String(decoding: bytes[0..<4], as: UTF8.self))
        let month = Int(String(decoding: bytes[5..<7], as: UTF8.self))
        let day = Int(String(decoding: bytes[8..<10], as: UTF8.self))
        guard let year, let month, let day, (1...9_999).contains(year) else {
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12

        guard let date = calendar.date(from: components),
              let normalized = Self.dayIdentifier(for: date, calendar: calendar) else {
            return false
        }
        return normalized == value
    }

    private static func epochSeconds(for date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        let lowerBound = Double(Int64.min)
        let upperExclusiveBound = -lowerBound
        // Int64.min is exactly representable as Double. The positive bound is
        // exclusive because its Double representation is one second beyond
        // Int64.max, so conversion cannot trap on an extreme Date.
        guard seconds.isFinite,
              seconds >= lowerBound,
              seconds < upperExclusiveBound else {
            return nil
        }
        return Int64(seconds.rounded(.towardZero))
    }

    private static func dayIdentifier(for date: Date, calendar: Calendar) -> String? {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }

        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard components.era == 1,
              let year = components.year,
              let month = components.month,
              let day = components.day,
              (1...9_999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }

        return "\(fourDigits(year))-\(twoDigits(month))-\(twoDigits(day))"
    }

    private static func fourDigits(_ value: Int) -> String {
        String(repeating: "0", count: max(0, 4 - String(value).count)) + String(value)
    }

    private static func twoDigits(_ value: Int) -> String {
        String(repeating: "0", count: max(0, 2 - String(value).count)) + String(value)
    }
}

public struct TinyBuddyTimeEnvironment {
    private let captureProvider: () -> TinyBuddyTimeContext?

    /// Uses the system's current instant and auto-updating regional fingerprint.
    public init() {
        self.init(capture: {
            TinyBuddyTimeContext(
                now: Date(),
                timeZone: .autoupdatingCurrent,
                locale: .autoupdatingCurrent,
                sourceCalendar: .autoupdatingCurrent
            )
        })
    }

    /// Compatibility adapter for existing Calendar/dateProvider injection sites.
    public init(
        calendar: Calendar,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.init(capture: {
            TinyBuddyTimeContext(
                now: dateProvider(),
                timeZone: calendar.timeZone,
                locale: calendar.locale ?? .autoupdatingCurrent,
                sourceCalendar: calendar
            )
        })
    }

    public init(capture: @escaping () -> TinyBuddyTimeContext?) {
        self.captureProvider = capture
    }

    public func capture() -> TinyBuddyTimeContext? {
        captureProvider()
    }

    /// A deterministic convenience for tests and previews.
    public static func fixed(
        now: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        sourceCalendar: Calendar = Calendar(identifier: .gregorian)
    ) -> TinyBuddyTimeEnvironment {
        TinyBuddyTimeEnvironment(capture: {
            TinyBuddyTimeContext(
                now: now,
                timeZone: timeZone,
                locale: locale,
                sourceCalendar: sourceCalendar
            )
        })
    }
}
