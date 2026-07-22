import Foundation

/// The result of a version upgrade check.
public struct TinyBuddyVersionUpgradeState: Equatable, Sendable {
    /// True when the app version (short version or build) differs from the
    /// last recorded launch version.
    public let isUpgrade: Bool

    /// The short version string previously recorded (e.g. "1.0"). Nil on first launch.
    public let previousShortVersion: String?

    /// The current short version string from the running bundle.
    public let currentShortVersion: String?

    /// The build number previously recorded (e.g. "1"). Nil on first launch.
    public let previousBuildVersion: String?

    /// The current build number from the running bundle.
    public let currentBuildVersion: String?

    public init(
        isUpgrade: Bool,
        previousShortVersion: String? = nil,
        currentShortVersion: String? = nil,
        previousBuildVersion: String? = nil,
        currentBuildVersion: String? = nil
    ) {
        self.isUpgrade = isUpgrade
        self.previousShortVersion = previousShortVersion
        self.currentShortVersion = currentShortVersion
        self.previousBuildVersion = previousBuildVersion
        self.currentBuildVersion = currentBuildVersion
    }
}

/// Tracks app version changes between launches. Uses the App Group shared
/// UserDefaults so both the main app and the widget extension can detect
/// version upgrades.
///
/// - Important: Only the primary app instance should call ``recordCurrentVersion``.
///   Widget extensions must remain read-only consumers.
public enum TinyBuddyVersionUpgradeTracker {
    private enum Key {
        static let shortVersion = "tinybuddy.lastLaunchedShortVersion"
        static let buildVersion = "tinybuddy.lastLaunchedBuildVersion"
        static let needsPostUpgradeRebuild = "tinybuddy.needsPostUpgradeRebuild"
    }

    /// Checks whether the app version has changed since the last recorded launch.
    ///
    /// - Parameters:
    ///   - userDefaults: The shared UserDefaults to read from. Defaults to App Group.
    ///   - bundle: The running bundle. Defaults to ``.main``.
    /// - Returns: An upgrade state describing the version change.
    public static func checkForUpgrade(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        bundle: Bundle = .main
    ) -> TinyBuddyVersionUpgradeState {
        let currentShort = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        let previousShort = userDefaults.string(forKey: Key.shortVersion)
        let previousBuild = userDefaults.string(forKey: Key.buildVersion)

        let isUpgrade: Bool
        if previousShort == nil, previousBuild == nil {
            // First launch ever — not an upgrade.
            isUpgrade = false
        } else {
            isUpgrade = (currentShort != previousShort) || (currentBuild != previousBuild)
        }

        if isUpgrade {
            setPostUpgradeRebuildRequired(userDefaults: userDefaults)
        }

        return TinyBuddyVersionUpgradeState(
            isUpgrade: isUpgrade,
            previousShortVersion: previousShort,
            currentShortVersion: currentShort,
            previousBuildVersion: previousBuild,
            currentBuildVersion: currentBuild
        )
    }

    /// Records the current bundle version as the last launched version.
    /// Should be called once per launch, after upgrade-related work is complete.
    ///
    /// - Parameters:
    ///   - userDefaults: The shared UserDefaults to write to. Defaults to App Group.
    ///   - bundle: The running bundle. Defaults to ``.main``.
    public static func recordCurrentVersion(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        bundle: Bundle = .main
    ) {
        if let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            userDefaults.set(shortVersion, forKey: Key.shortVersion)
        }
        if let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            userDefaults.set(buildVersion, forKey: Key.buildVersion)
        }
    }

    /// Removes any persisted version information. Intended for testing or reset.
    ///
    /// - Parameter userDefaults: The shared UserDefaults to clean. Defaults to App Group.
    public static func clearRecordedVersion(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) {
        userDefaults.removeObject(forKey: Key.shortVersion)
        userDefaults.removeObject(forKey: Key.buildVersion)
        userDefaults.removeObject(forKey: Key.needsPostUpgradeRebuild)
    }

    // MARK: - Post-Upgrade Rebuild Flag

    /// Returns `true` when the app has detected a version upgrade and the
    /// primary instance has not yet completed a full state rebuild.
    /// Both the main app and the Widget extension can read this flag.
    public static func isPostUpgradeRebuildRequired(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) -> Bool {
        userDefaults.bool(forKey: Key.needsPostUpgradeRebuild)
    }

    /// Sets the post-upgrade rebuild flag. Called automatically by
    /// ``checkForUpgrade`` when an upgrade is detected.
    public static func setPostUpgradeRebuildRequired(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) {
        userDefaults.set(true, forKey: Key.needsPostUpgradeRebuild)
    }

    /// Clears the post-upgrade rebuild flag. The primary app instance should
    /// call this after a successful refresh has committed fresh state.
    public static func clearPostUpgradeRebuildRequired(
        userDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults()
    ) {
        userDefaults.removeObject(forKey: Key.needsPostUpgradeRebuild)
    }
}
