import Foundation

// MARK: - Deterministic Random

/// A deterministic pseudo-random number generator using the Squirrel3 algorithm.
///
/// - Fixed seed produces identical sequences across runs.
/// - Records the seed and generates reproducible fault injection schedules.
/// - Outputs the seed on failure so race conditions can be reproduced.
public struct DeterministicRandom: Sendable {

    // MARK: State

    private var state: UInt64
    private let initialSeed: UInt64

    // MARK: Initialization

    /// Creates a generator with an explicit seed.
    public init(seed: UInt64) {
        self.initialSeed = seed
        self.state = seed
    }

    /// Creates a generator with a seed derived from a string.
    public init(seedString: String) {
        var hash: UInt64 = 5381
        for byte in seedString.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        self.init(seed: hash)
    }

    /// Creates a generator from the current time. Use only for exploration;
    /// record the seed for reproducibility.
    public init() {
        let seed = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        self.init(seed: seed)
    }

    // MARK: Properties

    /// The seed used to initialize this generator.
    public var seed: UInt64 { initialSeed }

    // MARK: Core Generator (Squirrel3)

    /// Advances the state and returns a random `UInt64`.
    @discardableResult
    public mutating func next() -> UInt64 {
        state &*= 0xB5297A4D  // 3,037,000,493
        state &+= 0x68E31DA4  // 1,757,729,956
        var result = state
        result ^= result >> 8
        result &+= 0x79D3E5F4  // 2,043,853,300
        result ^= result << 12
        result &+= 0x70E2D73B  // 1,892,588,347
        result ^= result >> 16
        return result
    }

    /// Returns a random `Double` in [0, 1).
    public mutating func nextDouble() -> Double {
        let raw = next()
        // Use the top 53 bits for full double precision.
        let value = raw >> 11
        return Double(value) / Double(1 << 53)
    }

    /// Returns a random integer in the range [0, upperBound).
    public mutating func nextInt(in range: Range<Int>) -> Int {
        let value = next()
        return Int(value % UInt64(range.upperBound - range.lowerBound)) + range.lowerBound
    }

    /// Returns a random integer in the closed range [lowerBound, upperBound].
    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let count = UInt64(range.upperBound - range.lowerBound + 1)
        let value = next()
        return Int(value % count) + range.lowerBound
    }

    /// Returns a random `TimeInterval` in the range [0, maxValue).
    public mutating func nextTimeInterval(upTo maxValue: TimeInterval) -> TimeInterval {
        nextDouble() * maxValue
    }

    /// Returns a random `TimeInterval` in the closed range.
    public mutating func nextTimeInterval(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        let value = nextDouble()
        return range.lowerBound + value * (range.upperBound - range.lowerBound)
    }

    /// Returns a random element from an array, or nil if empty.
    public mutating func randomElement<T>(from array: [T]) -> T? {
        guard !array.isEmpty else { return nil }
        let index = nextInt(in: 0..<array.count)
        return array[index]
    }

    /// Returns a random boolean.
    public mutating func nextBool() -> Bool {
        next() % 2 == 0
    }

    /// Returns `true` with the given probability.
    public mutating func nextBool(probability: Double) -> Bool {
        nextDouble() < probability
    }

    // MARK: Fault Scenario Generation

    /// Available fault types for random generation.
    public static let availableFaults: [FaultScenario.Fault] = [
        .gitTimeout(afterScriptRun: 1),
        .gitPartial(afterScriptRun: 1),
        .gitFailed(afterScriptRun: 1),
        .gitCancelled(afterScriptRun: 1),
        .permissionRevoked(afterScriptRun: 2),
        .permissionInvalid(afterScriptRun: 2),
        .snapshotWriteFailed(afterWrite: 1),
        .snapshotReadCorrupted(afterRead: 1),
        .monitorInterrupted(afterSeconds: 3),
        .powerStateLow(),
        .sleepWake(afterSeconds: 5),
        .crossDayBoundary(afterSeconds: 10),
        .taskCancellation(afterScriptRun: 2),
        .widgetReloadFailed(afterReload: 1),
        .directoryOffline(afterScriptRun: 2)
    ]

    /// Generates a random fault scenario with the given number of faults
    /// spread across the specified duration.
    public mutating func generateFaultScenario(
        name: String = "Random Fault Scenario",
        faultCount: Int = 3,
        duration: TimeInterval = 30
    ) -> FaultScenario {
        var faults: [FaultScenario.ScheduledFault] = []

        for _ in 0..<faultCount {
            let injectTime = nextTimeInterval(in: 0.1...duration)
            let faultType = Self.availableFaults[nextInt(in: 0..<Self.availableFaults.count)]
            faults.append(.at(injectTime, inject: faultType))
        }

        return FaultScenario(
            name: name,
            faults: faults,
            seed: initialSeed
        )
    }

    /// Generates multiple random fault scenarios for race exploration.
    public mutating func generateRaceExplorationScenarios(
        count: Int = 10,
        faultsPerScenario: Int = 2,
        duration: TimeInterval = 10
    ) -> [FaultScenario] {
        var scenarios: [FaultScenario] = []
        for i in 0..<count {
            let scenario = generateFaultScenario(
                name: "Race Exploration #\(i + 1)",
                faultCount: faultsPerScenario,
                duration: duration
            )
            scenarios.append(scenario)
        }
        return scenarios
    }
}

// MARK: - Seed Reporting

/// Records the seed and generation metadata for reproducibility.
public struct RandomSeedRecord: Sendable, CustomStringConvertible {
    public let seed: UInt64
    public let scenarioName: String
    public let generationTimestamp: Date

    public init(seed: UInt64, scenarioName: String) {
        self.seed = seed
        self.scenarioName = scenarioName
        self.generationTimestamp = Date()
    }

    public var description: String {
        "SeedRecord(seed=\(seed), scenario=\"\(scenarioName)\", generated=\(generationTimestamp))"
    }

    /// The seed as a hex string for easy copy-paste.
    public var seedHex: String {
        String(format: "%016llX", seed)
    }

    /// Instructions for reproducing with this seed.
    public var reproductionCommand: String {
        "TINYBUDDY_TEST_SEED=\(seed) // Scenario: \(scenarioName)"
    }
}
