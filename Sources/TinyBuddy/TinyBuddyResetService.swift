import Foundation
import TinyBuddyCore

/// User-visible reset scopes. Every scope is limited to data owned by
/// TinyBuddy; no selected Git directory, repository, or Git metadata is ever
/// enumerated or modified.
enum TinyBuddyResetLevel: String, CaseIterable {
    case runtimeState
    case settings
    case allAppData

    var title: String {
        switch self {
        case .runtimeState: "重置运行状态"
        case .settings: "重置设置"
        case .allAppData: "清除全部 App 数据"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .runtimeState:
            "将删除今日状态、Git 活动快照、缓存、诊断记录、迁移备份与 TinyBuddy 临时文件。保留已授权目录、偏好设置和登录启动项。不会修改任何 Git 仓库或 Git 数据。"
        case .settings:
            "将删除 TinyBuddy 的偏好设置、已保存的目录授权（security-scoped bookmarks）和窗口位置；引导将重置为首次引导，并关闭登录启动项。保留当前统计快照和缓存。不会修改任何 Git 仓库或 Git 数据。"
        case .allAppData:
            "将删除 TinyBuddy 创建的全部配置、目录授权、共享快照、缓存、诊断记录、迁移备份和临时文件，并关闭登录启动项。不会修改任何 Git 仓库或 Git 数据。"
        }
    }

    fileprivate var clearsRuntimeState: Bool {
        self == .runtimeState || self == .allAppData
    }

    fileprivate var clearsSettings: Bool {
        self == .settings || self == .allAppData
    }
}

struct TinyBuddyResetResult: Equatable {
    let level: TinyBuddyResetLevel
    let removedPreferenceKeyCount: Int
    let removedFileCount: Int
}

enum TinyBuddyResetError: Error, LocalizedError, Equatable {
    case journalPersistenceFailed
    case journalCorrupt
    case launchItemUnregisterFailed
    case removalFailed

    var errorDescription: String? {
        switch self {
        case .journalPersistenceFailed:
            "无法记录重置状态；为避免产生无法判定的数据状态，未开始清理。"
        case .journalCorrupt:
            "检测到损坏的重置状态记录。TinyBuddy 未自动覆盖它，以免掩盖部分清理；请退出后重新安装或联系支持。"
        case .launchItemUnregisterFailed:
            "无法关闭登录启动项；未继续清理，以免留下无法判定的启动状态。"
        case .removalFailed:
            "部分 TinyBuddy 数据当前无法删除。应用保持停止状态；请修复文件访问权限后重试，或退出后重新打开以恢复清理。"
        }
    }
}

/// Idempotent, allow-list based cleanup. The journal deliberately stays in the
/// app's own standard defaults until every requested step succeeds, so a crash
/// or permission failure is recoverable on the next launch instead of being
/// misreported as success.
@MainActor
final class TinyBuddyResetService {
    private enum Key {
        static let journal = "tinybuddy.reset.journal.v1"
    }

    private enum JournalState {
        case none
        case level(TinyBuddyResetLevel)
        case corrupt
    }

    private let standardDefaults: UserDefaults
    private let sharedDefaults: UserDefaults
    private let fileManager: FileManager
    private let appGroupContainerProvider: () -> URL?
    private let temporaryDirectoryProvider: () -> URL
    private let removeOwnedItem: (URL) throws -> Void
    private let unregisterLoginItem: (() throws -> Void)?

    init(
        standardDefaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults = TinyBuddySharedData.makeUserDefaults(),
        fileManager: FileManager = .default,
        appGroupContainerProvider: @escaping () -> URL? = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: TinyBuddySharedData.appGroupIdentifier
            )
        },
        temporaryDirectoryProvider: @escaping () -> URL = {
            FileManager.default.temporaryDirectory
        },
        removeOwnedItem: @escaping (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        unregisterLoginItem: (() throws -> Void)? = nil
    ) {
        self.standardDefaults = standardDefaults
        self.sharedDefaults = sharedDefaults
        self.fileManager = fileManager
        self.appGroupContainerProvider = appGroupContainerProvider
        self.temporaryDirectoryProvider = temporaryDirectoryProvider
        self.removeOwnedItem = removeOwnedItem
        self.unregisterLoginItem = unregisterLoginItem
    }

    /// Completes an interrupted reset, if one exists. It never starts a new
    /// reset and never retries in a loop; a single caller-controlled attempt is
    /// made at launch before stores can migrate or publish state.
    @discardableResult
    func recoverInterruptedResetIfNeeded() -> Result<TinyBuddyResetResult?, TinyBuddyResetError> {
        switch journalState {
        case .none:
            return .success(nil)
        case .level(let level):
            return perform(level: level, journalAlreadyPersisted: true).map(Optional.some)
        case .corrupt:
            return .failure(.journalCorrupt)
        }
    }

    @discardableResult
    func perform(level: TinyBuddyResetLevel) -> Result<TinyBuddyResetResult, TinyBuddyResetError> {
        perform(level: level, journalAlreadyPersisted: false)
    }

    private var journalLevel: TinyBuddyResetLevel? {
        standardDefaults.string(forKey: Key.journal).flatMap(TinyBuddyResetLevel.init(rawValue:))
    }

    private var journalState: JournalState {
        guard standardDefaults.object(forKey: Key.journal) != nil else { return .none }
        guard let level = journalLevel else { return .corrupt }
        return .level(level)
    }

    private func perform(
        level: TinyBuddyResetLevel,
        journalAlreadyPersisted: Bool
    ) -> Result<TinyBuddyResetResult, TinyBuddyResetError> {
        if !journalAlreadyPersisted {
            if case .corrupt = journalState {
                return .failure(.journalCorrupt)
            }
            standardDefaults.set(level.rawValue, forKey: Key.journal)
            _ = standardDefaults.synchronize()
            guard journalLevel == level else {
                return .failure(.journalPersistenceFailed)
            }
        }

        if level.clearsSettings {
            do {
                if let unregisterLoginItem {
                    try unregisterLoginItem()
                } else {
                    // This method is MainActor-isolated, so the production
                    // login-item call remains on its required actor. Keep the
                    // injectable closure only for deterministic failure tests.
                    try TinyBuddyLoginItemManager.shared.setEnabled(false)
                }
            } catch {
                return .failure(.launchItemUnregisterFailed)
            }
        }

        var removedPreferenceKeyCount = 0
        if level.clearsRuntimeState {
            removedPreferenceKeyCount += remove(keys: runtimeSharedKeys, from: sharedDefaults)
            removedPreferenceKeyCount += remove(keys: runtimeStandardKeys, from: standardDefaults)
        }
        if level.clearsSettings {
            removedPreferenceKeyCount += remove(keys: settingsSharedKeys, from: sharedDefaults)
            removedPreferenceKeyCount += remove(keys: settingsStandardKeys, from: standardDefaults)
            // A deliberate settings reset must win over legacy-installation
            // heuristics when runtime snapshots were intentionally retained.
            standardDefaults.set(TinyBuddyOnboardingStore.State.pending.rawValue,
                                 forKey: TinyBuddyOnboardingStore.Key.state)
            TinyBuddyDisplaySharedState.saveOnboardingCompleted(false, userDefaults: sharedDefaults)
        }

        _ = sharedDefaults.synchronize()
        _ = standardDefaults.synchronize()
        guard requestedKeys(for: level).allSatisfy({ sharedDefaults.object(forKey: $0) == nil })
            && requestedStandardKeys(for: level).allSatisfy({ standardDefaults.object(forKey: $0) == nil })
            && (!level.clearsSettings || onboardingWasReset()) else {
            return .failure(.removalFailed)
        }

        let removal = removeOwnedFiles(for: level)
        guard removal.didSucceed else {
            return .failure(.removalFailed)
        }

        // Remove only after all data and side-effect steps are complete.
        standardDefaults.removeObject(forKey: Key.journal)
        _ = standardDefaults.synchronize()
        guard journalLevel == nil else {
            return .failure(.removalFailed)
        }
        return .success(TinyBuddyResetResult(
            level: level,
            removedPreferenceKeyCount: removedPreferenceKeyCount,
            removedFileCount: removal.removedFileCount
        ))
    }

    private func remove(keys: [String], from defaults: UserDefaults) -> Int {
        var removed = 0
        for key in keys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removed += 1
        }
        return removed
    }

    private func requestedKeys(for level: TinyBuddyResetLevel) -> [String] {
        (level.clearsRuntimeState ? runtimeSharedKeys : [])
            + (level.clearsSettings ? settingsSharedKeys : [])
    }

    private func requestedStandardKeys(for level: TinyBuddyResetLevel) -> [String] {
        (level.clearsRuntimeState ? runtimeStandardKeys : [])
            + (level.clearsSettings ? settingsStandardKeys : [])
    }

    private func onboardingWasReset() -> Bool {
        standardDefaults.string(forKey: TinyBuddyOnboardingStore.Key.state)
            == TinyBuddyOnboardingStore.State.pending.rawValue
            && TinyBuddyDisplaySharedState.onboardingCompleted(userDefaults: sharedDefaults) == false
    }

    private func removeOwnedFiles(for level: TinyBuddyResetLevel) -> (didSucceed: Bool, removedFileCount: Int) {
        guard level.clearsRuntimeState else { return (true, 0) }
        var ownedURLs = temporaryOwnedURLs()
        if let containerURL = appGroupContainerProvider() {
            let preferences = containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Preferences", isDirectory: true)
            let caches = containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("com.ryukeili.TinyBuddy", isDirectory: true)
            ownedURLs += [
                caches,
                preferences.appendingPathComponent(".tinybuddy-git-repository-cache", isDirectory: true),
                preferences.appendingPathComponent(".tinybuddy-time-scope")
            ]
        }

        var removedFileCount = 0
        for url in ownedURLs where fileManager.fileExists(atPath: url.path) {
            do {
                let count = (try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).count) ?? 1
                try removeOwnedItem(url)
                removedFileCount += max(1, count)
            } catch {
                return (false, removedFileCount)
            }
        }
        TinyBuddyDebugLogManager.shared.disable()
        return (true, removedFileCount)
    }

    private func temporaryOwnedURLs() -> [URL] {
        let temporaryDirectory = temporaryDirectoryProvider()
        return [
            temporaryDirectory.appendingPathComponent("TinyBuddyBuildLogs", isDirectory: true),
            temporaryDirectory.appendingPathComponent("TinyBuddyReleaseEvidence", isDirectory: true),
            temporaryDirectory.appendingPathComponent("TinyBuddyRegressionEvidence", isDirectory: true)
        ]
    }

    private let runtimeSharedKeys = [
        TinyBuddyCombinedSnapshotStore.Key.snapshot,
        TinyBuddyCombinedSnapshotStore.Key.highestRevision,
        TinyBuddyCombinedSnapshotStore.Key.highestRevisionV2,
        TinyBuddyCombinedSnapshotStore.Key.committedRevisionV2,
        TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotA,
        TinyBuddyCombinedSnapshotStore.Key.snapshotV2SlotB,
        TinyBuddyCombinedSnapshotStore.Key.schemaVersion,
        TinyBuddyCombinedSnapshotStore.Key.migrationBackupV1,
        GitTodayActivityTrustedSnapshotStore.Key.snapshot,
        "tinybuddy.dailyStats.dayIdentifier",
        "tinybuddy.dailyStats.focusCount",
        "tinybuddy.dailyStats.completionCount",
        "tinybuddy.currentStatus",
        "tinybuddy.currentStatus.dayIdentifier",
        GitTodayFocusBlockCountStore.Key.dayIdentifier,
        GitTodayFocusBlockCountStore.Key.count,
        GitTodayCommitCountStore.Key.dayIdentifier,
        GitTodayCommitCountStore.Key.count,
        GitTodayRecentProjectStore.Key.dayIdentifier,
        GitTodayRecentProjectStore.Key.projectName,
        GitActivityRefreshStatusStore.Key.refreshedAt,
        GitActivityRefreshStatusStore.Key.trigger,
        GitActivityRefreshStatusStore.Key.outcome,
        GitActivityRefreshStatusStore.Key.reason,
        GitActivityRefreshStatusStore.Key.diagnosticSource,
        GitActivityRefreshStatusStore.Key.diagnosticStage,
        GitActivityRefreshStatusStore.Key.diagnosticReason,
        GitActivityRefreshStatusStore.Key.durationMilliseconds,
        GitActivityRefreshStatusStore.Key.authorizedRootCount,
        GitActivityRefreshStatusStore.Key.repositoryCount,
        GitActivityRefreshStatusStore.Key.cacheHitCount,
        GitActivityRefreshStatusStore.Key.reflogUnchangedSkipCount,
        GitActivityRefreshStatusStore.Key.recomputedRepositoryCount,
        GitActivityRefreshStatusStore.Key.invalidRepositoryCount,
        GitActivityRefreshStatusStore.Key.sharedDataWritten,
        GitActivityRefreshStatusStore.Key.widgetContentChanged,
        GitActivityRefreshStatusStore.Key.widgetReloaded,
        GitActivityRefreshStatusStore.Key.metricsReason
    ]

    private let runtimeStandardKeys = [
        GitTodayFocusBlockCountStore.Key.dayIdentifier,
        GitTodayFocusBlockCountStore.Key.count,
        GitTodayCommitCountStore.Key.dayIdentifier,
        GitTodayCommitCountStore.Key.count,
        GitTodayRecentProjectStore.Key.dayIdentifier,
        GitTodayRecentProjectStore.Key.projectName
    ]

    private let settingsSharedKeys = [
        TinyBuddyConfigStore.Key.configPayload,
        TinyBuddyConfigStore.Key.configCommittedVersion
    ]

    private let settingsStandardKeys = [
        GitScanRootAuthorizationStore.Constants.bookmarkDataKey,
        GitScanRootAuthorizationStore.Constants.authorizationRecordsKey,
        HUDWindowOriginStore.Key.origin
    ]
}
