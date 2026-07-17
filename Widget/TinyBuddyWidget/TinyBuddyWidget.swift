import SwiftUI
import TinyBuddyCore
import WidgetKit
import OSLog

private typealias HUDTheme = TinyBuddyHUDTheme

struct TinyBuddyEntry: TimelineEntry {
    let date: Date
    let snapshot: TinyBuddySnapshot
    let activitySnapshot: GitTodayActivitySnapshot
    let refreshStatus: GitActivityRefreshStatus?
}

struct TinyBuddyProvider: TimelineProvider {
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let store: DailyStatsStore
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private static let logger = Logger(subsystem: "local.tinybuddy", category: "SharedSnapshot")

    init() {
        let timeEnvironment = TinyBuddyTimeEnvironment()
        self.timeEnvironment = timeEnvironment
        self.store = DailyStatsStore(timeEnvironment: timeEnvironment)
        self.combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(repairOnLoad: false)
        self.refreshStatusStore = GitActivityRefreshStatusStore(
            timeEnvironment: timeEnvironment
        )
    }

    func placeholder(in context: Context) -> TinyBuddyEntry {
        let now = timeEnvironment.capture()?.now ?? Date(timeIntervalSince1970: 0)
        return TinyBuddyEntry(
            date: now,
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 0,
                commitCount: 0,
                recentProjectName: "TinyBuddy"
            ),
            refreshStatus: GitActivityRefreshStatus(
                refreshedAt: now,
                trigger: .launch,
                outcome: .succeeded,
                metrics: GitActivityRefreshMetrics(authorizedRootCount: 1, repositoryCount: 1)
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TinyBuddyEntry) -> Void) {
        completion(makeEntry(for: currentTimeContext()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TinyBuddyEntry>) -> Void) {
        let timeContext = currentTimeContext()
        let entry = makeEntry(for: timeContext)
        let nextRefresh = timeContext.nextRefreshDate(maxInterval: 15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func makeEntry(for timeContext: TinyBuddyTimeContext) -> TinyBuddyEntry {
        let date = timeContext.now
        let expectedDayIdentifier = timeContext.dayIdentifier
        let refreshStatus = refreshStatusStore.load()
        let combinedRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        if let observation = combinedRead.observation {
            Self.logger.error(
                "shared snapshot id=\(observation.identifier, privacy: .public) phase=\(observation.phase.rawValue, privacy: .public) reason=\(observation.reason.rawValue, privacy: .public) recovery=\(observation.recovery.rawValue, privacy: .public) attempt=\(observation.attemptCount, privacy: .public)"
            )
        }
        if let combinedSnapshot = combinedRead.snapshot {
            return TinyBuddyEntry(
                date: date,
                snapshot: combinedSnapshot.snapshot,
                activitySnapshot: combinedSnapshot.activitySnapshot,
                refreshStatus: refreshStatus
            )
        }

        if let observation = combinedRead.observation,
           observation.reason == .staleData,
           let retainedSnapshot = combinedSnapshotStore.loadReadOnly(
               minimumDayIdentifier: expectedDayIdentifier
           ) {
            return TinyBuddyEntry(
                date: date,
                snapshot: retainedSnapshot.snapshot,
                activitySnapshot: retainedSnapshot.activitySnapshot,
                refreshStatus: refreshStatus
            )
        }

        if let observation = combinedRead.observation,
           observation.reason == .staleData || observation.reason == .snapshotCorrupt {
            return TinyBuddyEntry(
                date: date,
                snapshot: store.loadSnapshot(),
                activitySnapshot: neutralActivitySnapshot,
                refreshStatus: refreshStatus
            )
        }

        return TinyBuddyEntry(
            date: date,
            snapshot: neutralSnapshot(dayIdentifier: expectedDayIdentifier),
            activitySnapshot: neutralActivitySnapshot,
            refreshStatus: refreshStatus
        )
    }

    private var neutralActivitySnapshot: GitTodayActivitySnapshot {
        GitTodayActivitySnapshot(
            focusBlockCount: nil,
            commitCount: nil,
            recentProjectName: nil
        )
    }

    private func neutralSnapshot(dayIdentifier: String) -> TinyBuddySnapshot {
        TinyBuddySnapshot(
            status: .idle,
            stats: DailyStats(dayIdentifier: dayIdentifier, focusCount: 0, completionCount: 0)
        )
    }

    private func currentTimeContext() -> TinyBuddyTimeContext {
        if let context = timeEnvironment.capture() {
            return context
        }
        let timeZone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return TinyBuddyTimeContext(
            now: Date(timeIntervalSince1970: 0),
            timeZone: timeZone,
            locale: Locale(identifier: "en_US_POSIX"),
            sourceCalendar: calendar
        )!
    }
}

struct TinyBuddyWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TinyBuddyEntry

    private var presentation: TinyBuddyWidgetPresentation {
        TinyBuddyWidgetPresentation(
            snapshot: entry.snapshot,
            activitySnapshot: entry.activitySnapshot
        )
    }

    private var gitActivityState: GitActivityExperienceState {
        GitActivityExperienceState(
            refreshStatus: entry.refreshStatus,
            activitySnapshot: entry.activitySnapshot
        )
    }

    private var recentProjectName: String {
        let trimmedName = entry.activitySnapshot.recentProjectName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        return "最近无活跃项目"
    }

    var body: some View {
        Group {
            if gitActivityState.showsActivityMetrics {
                switch family {
                case .systemMedium:
                    mediumBody
                default:
                    smallBody
                }
            } else {
                stateBody
            }
        }
    }

    private var stateBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: stateContent.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(stateAccent)
                Text("GIT ACTIVITY")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(HUDTheme.hudGold.opacity(0.88))
            }

            Text(stateContent.title)
                .font(.system(size: family == .systemMedium ? 16 : 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(stateContent.message)
                .font(.system(size: family == .systemMedium ? 11 : 9, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(family == .systemMedium ? 3 : 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .containerBackground(for: .widget) {
            TinyBuddyHUDBackground(
                blueGlowCenter: .topLeading,
                redGlowRadius: 190,
                blueGlowRadius: 90,
                scanLineCount: 3
            )
        }
    }

    private var stateContent: (title: String, message: String, systemImage: String) {
        switch gitActivityState {
        case .loading:
            return ("正在加载 Git 活动", "扫描完成后会自动更新。", "arrow.triangle.2.circlepath")
        case .authorizationRequired:
            return ("需要仓库目录授权", "打开 TinyBuddy 选择仓库目录。", "folder.badge.questionmark")
        case .authorizationInvalid:
            return ("仓库授权已失效", "打开 TinyBuddy 直接重新授权。", "lock.trianglebadge.exclamationmark")
        case .noRepositories:
            return ("未发现 Git 仓库", "已授权目录中没有可识别的仓库。", "folder.badge.minus")
        case .noActivity:
            return ("今日暂无 Git 活动", "仓库读取正常，今天还没有活动。", "moon.zzz")
        case .failed:
            return ("仓库读取失败", "打开 TinyBuddy 重试扫描。", "exclamationmark.triangle")
        case .partial:
            if entry.refreshStatus?.diagnostic?.reason == .partialAuthorizationRecovery {
                return ("部分目录授权已失效", "可用仓库已更新；打开 TinyBuddy 重新授权。", "lock.trianglebadge.exclamationmark")
            }
            return ("部分仓库读取失败", "可用仓库已更新。", "exclamationmark.circle")
        case .ready:
            return ("Git 活动已更新", "", "checkmark.circle")
        }
    }

    private var stateAccent: Color {
        switch gitActivityState {
        case .loading:
            return HUDTheme.energyBlueWhite
        case .failed:
            return Color(red: 0.84, green: 0.34, blue: 0.29)
        case .noActivity:
            return HUDTheme.hudGold
        default:
            return Color(red: 0.89, green: 0.66, blue: 0.23)
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                TinyBuddyArcReactorCore(showsLabel: false)
                    .scaleEffect(0.58)
                    .frame(width: 56, height: 56)
                    .overlay {
                        Text(presentation.expression)
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .foregroundStyle(HUDTheme.darkMetal.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("TINYBUDDY")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(HUDTheme.hudGold.opacity(0.92))
                    Text("HUD CORE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(HUDTheme.warmWhite)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusAccent)
                            .frame(width: 6, height: 6)
                            .shadow(color: statusAccent.opacity(0.8), radius: 4)

                        Text(presentation.statusTitle)
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(statusAccent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
                .layoutPriority(1)
            }

            HStack(spacing: 6) {
                hudMetric(title: "今日专注", value: presentation.focusCount)
                hudMetric(title: "今日完成", value: presentation.completionCount)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .containerBackground(for: .widget) {
            TinyBuddyHUDBackground(
                blueGlowCenter: UnitPoint(x: 0.34, y: 0.36),
                redGlowRadius: 168,
                blueGlowRadius: 84,
                redGlowOpacity: 0.44,
                blueGlowOpacity: 0.15,
                scanLineCount: 3
            )
        }
    }

    private var mediumBody: some View {
        HStack(alignment: .center, spacing: 10) {
            TinyBuddyArcReactorCore()
                .frame(width: 94, height: 94)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TINYBUDDY")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(HUDTheme.hudGold.opacity(0.88))
                        Text("COMPANION HUD")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(HUDTheme.warmWhite)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 4)

                    Circle()
                        .fill(statusAccent)
                        .frame(width: 7, height: 7)
                        .shadow(color: statusAccent.opacity(0.8), radius: 5)
                }

                HStack(spacing: 8) {
                    hudMetric(title: "今日专注", value: presentation.focusCount)
                    hudMetric(title: "今日完成", value: presentation.completionCount)
                }

                VStack(alignment: .leading, spacing: 5) {
                    hudStatusRow

                    VStack(alignment: .leading, spacing: 2) {
                        hudPanelLabel("RECENT PROJECT")

                        Text(recentProjectName)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .lineSpacing(0)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                .background(HUDTheme.panelFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(statusAccent.opacity(0.42), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .containerBackground(for: .widget) {
            TinyBuddyHUDBackground(
                blueGlowCenter: UnitPoint(x: 0.26, y: 0.48),
                redGlowRadius: 220,
                blueGlowRadius: 104,
                scanLineCount: 4
            )
        }
    }

    private var statusAccent: Color {
        HUDTheme.statusAccent(for: presentation.displayState)
    }

    private func hudMetric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(HUDTheme.hudGold.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(value)")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(HUDTheme.panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(HUDTheme.metricBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var hudStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            hudPanelLabel("STATUS")

            Text(presentation.statusTitle)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(statusAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 0)
        }
    }

    private func hudPanelLabel(
        _ text: String
    ) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(HUDTheme.hudGold.opacity(0.82))
    }
}

struct TinyBuddyWidget: Widget {
    let kind = "TinyBuddyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TinyBuddyProvider()) { entry in
            TinyBuddyWidgetView(entry: entry)
        }
        .configurationDisplayName("TinyBuddy")
        .description("显示当前宠物状态和今日专注统计。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TinyBuddyWidgetBundle: WidgetBundle {
    var body: some Widget {
        TinyBuddyWidget()
    }
}

#if DEBUG
struct TinyBuddyWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            TinyBuddyWidgetView(entry: previewEntry(status: .idle, focusCount: 2, completionCount: 1))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Small")

            TinyBuddyWidgetView(
                entry: previewEntry(
                    status: .focusing,
                    focusCount: 5,
                    completionCount: 3,
                    activitySnapshot: GitTodayActivitySnapshot(
                        focusBlockCount: 4,
                        commitCount: 7,
                        recentProjectName: "TinyBuddy"
                    )
                )
            )
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium HUD")

            TinyBuddyWidgetView(
                entry: previewEntry(
                    status: .completedOnce,
                    focusCount: 3,
                    completionCount: 8,
                    activitySnapshot: GitTodayActivitySnapshot(
                        focusBlockCount: 3,
                        commitCount: 8,
                        recentProjectName: "TinyBuddyDesktopWidgetPrototype"
                    )
                )
            )
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium Long Project")
        }
    }

    private static func previewEntry(
        status: PetStatus,
        focusCount: Int,
        completionCount: Int,
        activitySnapshot: GitTodayActivitySnapshot = GitTodayActivitySnapshot(
            focusBlockCount: 0,
            commitCount: 0,
            recentProjectName: nil
        )
    ) -> TinyBuddyEntry {
        TinyBuddyEntry(
            date: Date(),
            snapshot: TinyBuddySnapshot(
                status: status,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: focusCount,
                    completionCount: completionCount
                )
            ),
            activitySnapshot: activitySnapshot,
            refreshStatus: GitActivityRefreshStatus(
                refreshedAt: Date(),
                trigger: .launch,
                outcome: .succeeded,
                metrics: GitActivityRefreshMetrics(authorizedRootCount: 1, repositoryCount: 1)
            )
        )
    }
}
#endif
