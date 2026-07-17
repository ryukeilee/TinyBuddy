import Foundation
import TinyBuddyCore

enum GitActivityExperienceAction: Equatable {
    case chooseDirectories
    case reauthorize
    case addDirectory
    case rescan
}

struct GitActivityExperiencePresentation: Equatable {
    let state: GitActivityExperienceState
    let title: String
    let message: String
    let systemImage: String
    let action: GitActivityExperienceAction?
    let actionTitle: String?

    static func make(
        refreshStatus: GitActivityRefreshStatus?,
        activitySnapshot: GitTodayActivitySnapshot,
        isRefreshing: Bool,
        onboardingCompleted: Bool
    ) -> GitActivityExperiencePresentation {
        guard onboardingCompleted else {
            return GitActivityExperiencePresentation(
                state: .authorizationRequired,
                title: "从选择仓库目录开始",
                message: "TinyBuddy 只读取你授权目录中的 Git 元数据。选择开发目录后会立即扫描。",
                systemImage: "folder.badge.plus",
                action: .chooseDirectories,
                actionTitle: "选择仓库目录"
            )
        }

        let state = GitActivityExperienceState(
            refreshStatus: refreshStatus,
            activitySnapshot: activitySnapshot,
            isRefreshing: isRefreshing
        )

        switch state {
        case .loading:
            return GitActivityExperiencePresentation(
                state: state,
                title: "正在加载 Git 活动",
                message: "TinyBuddy 正在扫描已授权目录，完成后会自动更新 HUD 与 Widget。",
                systemImage: "arrow.triangle.2.circlepath",
                action: nil,
                actionTitle: nil
            )
        case .authorizationRequired:
            return GitActivityExperiencePresentation(
                state: state,
                title: "需要仓库目录授权",
                message: "当前没有可读取的目录。重新选择后即可恢复扫描，无需重启 App。",
                systemImage: "folder.badge.questionmark",
                action: .chooseDirectories,
                actionTitle: "选择仓库目录"
            )
        case .authorizationInvalid:
            return GitActivityExperiencePresentation(
                state: state,
                title: "仓库目录授权已失效",
                message: "目录可能被移动、移除或权限已撤销。重新选择该目录即可立即恢复。",
                systemImage: "lock.trianglebadge.exclamationmark",
                action: .reauthorize,
                actionTitle: "重新授权"
            )
        case .noRepositories:
            return GitActivityExperiencePresentation(
                state: state,
                title: "未发现 Git 仓库",
                message: "已授权目录中没有可识别的 Git 仓库。可以添加另一个开发目录。",
                systemImage: "folder.badge.minus",
                action: .addDirectory,
                actionTitle: "添加 Git 目录"
            )
        case .noActivity:
            return GitActivityExperiencePresentation(
                state: state,
                title: "今日暂无 Git 活动",
                message: "仓库读取正常，但今天还没有提交、合并或专注记录。",
                systemImage: "moon.zzz",
                action: .rescan,
                actionTitle: "重新扫描"
            )
        case .failed:
            return GitActivityExperiencePresentation(
                state: state,
                title: "仓库读取失败",
                message: "本次扫描未能生成可信数据，TinyBuddy 会保留上次完整结果。",
                systemImage: "exclamationmark.triangle",
                action: .rescan,
                actionTitle: "重试扫描"
            )
        case .partial:
            if refreshStatus?.diagnostic?.reason == .partialAuthorizationRecovery {
                return GitActivityExperiencePresentation(
                    state: state,
                    title: "部分仓库目录授权已失效",
                    message: "可用仓库已更新。重新授权失效目录后会立即补充扫描。",
                    systemImage: "lock.trianglebadge.exclamationmark",
                    action: .reauthorize,
                    actionTitle: "重新授权"
                )
            }
            return GitActivityExperiencePresentation(
                state: state,
                title: "部分仓库读取失败",
                message: "可用仓库已更新，失效目录或异常仓库已跳过。",
                systemImage: "exclamationmark.circle",
                action: .rescan,
                actionTitle: "重新扫描"
            )
        case .ready:
            return GitActivityExperiencePresentation(
                state: state,
                title: "Git 活动已更新",
                message: "HUD 与 Widget 正在使用同一份已提交快照。",
                systemImage: "checkmark.circle",
                action: nil,
                actionTitle: nil
            )
        }
    }
}
