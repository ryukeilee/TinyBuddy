import OSLog
import SwiftUI
import TinyBuddyCore
import WidgetKit

private typealias HUDTheme = TinyBuddyHUDTheme

struct TinyBuddyEntry: TimelineEntry {
    let date: Date
    let presentation: TinyBuddyDisplayPresentation
    let focusSessionSnapshot: FocusSessionDerivedSnapshot?

    init(
        date: Date,
        presentation: TinyBuddyDisplayPresentation,
        focusSessionSnapshot: FocusSessionDerivedSnapshot? = nil
    ) {
        self.date = date
        self.presentation = presentation
        self.focusSessionSnapshot = focusSessionSnapshot
    }
}

struct TinyBuddyProvider: TimelineProvider {
    private let timeEnvironment: TinyBuddyTimeEnvironment
    private let store: DailyStatsStore
    private let combinedSnapshotStore: TinyBuddyCombinedSnapshotStore
    private let refreshStatusStore: GitActivityRefreshStatusStore
    private let sharedDefaults: UserDefaults
    private static let logger = Logger(subsystem: "local.tinybuddy", category: "SharedSnapshot")

    private let configStore: TinyBuddyConfigStore

    init() {
        let timeEnvironment = TinyBuddyTimeEnvironment()
        self.timeEnvironment = timeEnvironment
        self.store = DailyStatsStore(timeEnvironment: timeEnvironment)
        self.combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(repairOnLoad: false)
        self.refreshStatusStore = GitActivityRefreshStatusStore(
            timeEnvironment: timeEnvironment
        )
        self.sharedDefaults = TinyBuddySharedData.makeUserDefaults()
        self.configStore = TinyBuddyConfigStore()
    }

    func placeholder(in context: Context) -> TinyBuddyEntry {
        let timeContext = currentTimeContext()
        return entry(
            at: timeContext.now,
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
                refreshedAt: timeContext.now,
                trigger: .launch,
                outcome: .succeeded,
                metrics: GitActivityRefreshMetrics(authorizedRootCount: 1, repositoryCount: 1)
            ),
            dataAvailability: .available,
            timeContext: timeContext
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TinyBuddyEntry) -> Void) {
        completion(makeEntry(for: currentTimeContext()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TinyBuddyEntry>) -> Void) {
        let timeContext = currentTimeContext()
        let entry = makeEntry(for: timeContext)
        let rolloverContext = makeTimeContext(
            at: timeContext.nextDayBoundary,
            basedOn: timeContext
        )
        var entries = [entry]
        if let rolloverContext {
            entries.append(makeRolloverEntry(for: rolloverContext))
        }
        // Shared-data writers explicitly reload this timeline when its semantic
        // content changes. A prebuilt midnight entry prevents yesterday's data
        // from surviving across the local-day boundary without creating a
        // periodic WidgetKit wakeup when nothing changed.
        completion(Timeline(entries: entries, policy: .never))
    }

    private func makeRolloverEntry(for timeContext: TinyBuddyTimeContext) -> TinyBuddyEntry {
        entry(
            at: timeContext.now,
            snapshot: neutralSnapshot(dayIdentifier: timeContext.dayIdentifier),
            activitySnapshot: neutralActivitySnapshot,
            refreshStatus: nil,
            dataAvailability: .available,
            timeContext: timeContext
        )
    }

    private func makeEntry(for timeContext: TinyBuddyTimeContext) -> TinyBuddyEntry {
        let expectedDayIdentifier = timeContext.dayIdentifier
        let refreshStatus = refreshStatusStore.load().flatMap { status in
            status.isForDisplayDay(in: timeContext) ? status : nil
        }

        let configVersion = configStore.loadConfigVersion()
        let configState: String
        if let configVersion {
            configState = "loaded version=\(configVersion)"
        } else {
            configState = "unavailable"
        }
        Self.logger.notice("app config \(configState, privacy: .public)")

        let combinedRead = combinedSnapshotStore.readValidated(
            expectedDayIdentifier: expectedDayIdentifier
        )
        if let observation = combinedRead.observation {
            Self.logger.error(
                "shared snapshot id=\(observation.identifier, privacy: .public) phase=\(observation.phase.rawValue, privacy: .public) reason=\(observation.reason.rawValue, privacy: .public) recovery=\(observation.recovery.rawValue, privacy: .public) attempt=\(observation.attemptCount, privacy: .public)"
            )
        }
        if let combinedSnapshot = combinedRead.snapshot {
            Self.logger.notice(
                "snapshot consumed schema=\(TinyBuddyCombinedSnapshotStore.currentSchemaVersion, privacy: .public) revision=\(combinedSnapshot.revision, privacy: .public) day=\(combinedSnapshot.dayIdentifier, privacy: .public)"
            )
            return entry(
                at: timeContext.now,
                snapshot: combinedSnapshot.snapshot,
                activitySnapshot: combinedSnapshot.activitySnapshot,
                refreshStatus: refreshStatus,
                dataAvailability: TinyBuddyDisplayDataAvailability(
                    observation: combinedRead.observation,
                    hasSnapshot: true
                ),
                timeContext: timeContext,
                focusSessionSnapshot: combinedSnapshot.focusSessionSnapshot
            )
        }

        if let observation = combinedRead.observation,
           observation.reason == .staleData,
           let retainedSnapshot = combinedSnapshotStore.loadReadOnly(
               minimumDayIdentifier: expectedDayIdentifier
           ) {
            return entry(
                at: timeContext.now,
                snapshot: retainedSnapshot.snapshot,
                activitySnapshot: retainedSnapshot.activitySnapshot,
                refreshStatus: refreshStatus,
                dataAvailability: .stale,
                timeContext: timeContext
            )
        }

        if let observation = combinedRead.observation,
           observation.reason == .staleData || observation.reason == .snapshotCorrupt {
            let fallbackSnapshot = store.loadSnapshot()
            return entry(
                at: timeContext.now,
                snapshot: fallbackSnapshot.stats.dayIdentifier == expectedDayIdentifier
                    ? fallbackSnapshot
                    : neutralSnapshot(dayIdentifier: expectedDayIdentifier),
                activitySnapshot: neutralActivitySnapshot,
                refreshStatus: refreshStatus,
                dataAvailability: TinyBuddyDisplayDataAvailability(
                    observation: observation,
                    hasSnapshot: false
                ),
                timeContext: timeContext
            )
        }

        return entry(
            at: timeContext.now,
            snapshot: neutralSnapshot(dayIdentifier: expectedDayIdentifier),
            activitySnapshot: neutralActivitySnapshot,
            refreshStatus: refreshStatus,
            dataAvailability: TinyBuddyDisplayDataAvailability(
                observation: combinedRead.observation,
                hasSnapshot: false
            ),
            timeContext: timeContext
        )
    }

    private func entry(
        at date: Date,
        snapshot: TinyBuddySnapshot,
        activitySnapshot: GitTodayActivitySnapshot,
        refreshStatus: GitActivityRefreshStatus?,
        dataAvailability: TinyBuddyDisplayDataAvailability,
        timeContext: TinyBuddyTimeContext,
        focusSessionSnapshot: FocusSessionDerivedSnapshot? = nil
    ) -> TinyBuddyEntry {
        TinyBuddyEntry(
            date: date,
            presentation: TinyBuddyDisplayPresentation(
                snapshot: snapshot,
                activitySnapshot: activitySnapshot,
                refreshStatus: refreshStatus,
                dataAvailability: dataAvailability,
                onboardingCompleted: TinyBuddyDisplaySharedState.onboardingCompleted(
                    userDefaults: sharedDefaults
                ) ?? true,
                locale: Locale(identifier: timeContext.signature.localeIdentifier),
                timeZone: timeContext.timeZone
            ),
            focusSessionSnapshot: focusSessionSnapshot
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

    private func makeTimeContext(
        at date: Date,
        basedOn context: TinyBuddyTimeContext
    ) -> TinyBuddyTimeContext? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        return TinyBuddyTimeContext(
            now: date,
            timeZone: context.timeZone,
            locale: Locale(identifier: context.signature.localeIdentifier),
            sourceCalendar: calendar
        )
    }
}

struct TinyBuddyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let entry: TinyBuddyEntry

    private var presentation: TinyBuddyDisplayPresentation {
        entry.presentation
    }

    private var focusSessionSummary: String? {
        guard let focus = entry.focusSessionSnapshot, focus.focusDuration > 0 else { return nil }
        let minutes = Int(focus.focusDuration / 60)
        return "已专注 \(minutes / 60) 小时 \(minutes % 60) 分 · \(focus.completedSessionCount) 段"
    }

    private var displayEnvironment: TinyBuddyDisplayEnvironment {
        TinyBuddyDisplayEnvironment(
            size: family == .systemMedium ? .expanded : .compact,
            textScale: dynamicTypeSize.isAccessibilitySize ? .accessibility : .standard,
            increasedContrast: colorSchemeContrast == .increased,
            reduceMotion: accessibilityReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private var layout: TinyBuddyDisplayLayout {
        TinyBuddyDisplayLayout(presentation: presentation, environment: displayEnvironment)
    }

    private var statusAccent: Color {
        HUDTheme.statusAccent(
            for: presentation.accentRole,
            colorScheme: colorScheme,
            increasedContrast: layout.usesEnhancedContrast
        )
    }

    private var primaryText: Color {
        HUDTheme.primaryTextColor(
            for: colorScheme,
            increasedContrast: layout.usesEnhancedContrast
        )
    }

    private var secondaryText: Color {
        HUDTheme.secondaryTextColor(
            for: colorScheme,
            increasedContrast: layout.usesEnhancedContrast
        )
    }

    private var panelFill: LinearGradient {
        HUDTheme.panelFill(
            for: colorScheme,
            increasedContrast: layout.usesEnhancedContrast
        )
    }

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumBody
            default:
                smallBody
            }
        }
        .containerBackground(for: .widget) {
            HUDTheme.backgroundFill(
                for: colorScheme,
                increasedContrast: layout.usesEnhancedContrast
            )
        }
        .transaction { transaction in
            if layout.allowsMotion == false {
                transaction.disablesAnimations = true
            }
        }
        .accessibilityLabel(widgetAccessibilityLabel)
    }

    private var widgetAccessibilityLabel: String {
        var parts = ["TinyBuddy"]
        parts.append(presentation.statusTitle)
        if presentation.focusCount > 0 {
            parts.append("今日专注 \(presentation.focusCountText)")
        }
        if presentation.completionCount > 0 {
            parts.append("今日完成 \(presentation.completionCountText)")
        }
        if let project = presentation.recentProjectName {
            parts.append("最近项目 \(project)")
        }
        return parts.joined(separator: "，")
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if layout.showsExpression {
                    TinyBuddyArcReactorCore(showsLabel: false)
                        .scaleEffect(0.58)
                        .frame(width: 56, height: 56)
                        .overlay {
                            Text(presentation.expression)
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(HUDTheme.darkMetal.opacity(0.82))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                }

                statusContent(compact: true)
            }

            if layout.showsMetrics {
                metrics
            }

            if layout.showsDataDate, let dataDateText = presentation.dataDateText {
                Text(dataDateText)
                    .font(.caption2)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(12)
    }

    private var mediumBody: some View {
        HStack(alignment: .center, spacing: 10) {
            if layout.showsExpression {
                TinyBuddyArcReactorCore()
                    .frame(width: 94, height: 94)
            }

            VStack(alignment: .leading, spacing: 7) {
                statusContent(compact: false)

                if layout.showsMetrics {
                    metrics
                }

                if layout.showsProject || layout.showsDataDate {
                    HStack(spacing: 8) {
                        if layout.showsProject, let recentProjectName = presentation.recentProjectName {
                            Text(recentProjectName)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                        }

                        if layout.showsDataDate, let dataDateText = presentation.dataDateText {
                            Text(dataDateText)
                                .font(.caption2)
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(panelFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                HUDTheme.panelBorder(
                                    for: colorScheme,
                                    increasedContrast: layout.usesEnhancedContrast
                                ),
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(mediumBodyBottomPanelLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(12)
    }

    private func statusContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            if layout.showsBrandLabel {
                Text("TINYBUDDY")
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(secondaryText)
                    .accessibilityHidden(true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: presentation.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusAccent)
                    .accessibilityHidden(true)

                Text(presentation.statusTitle)
                    .font(compact ? .headline.weight(.heavy) : .title3.weight(.heavy))
                    .foregroundStyle(statusAccent)
                    .lineLimit(layout.titleLineLimit)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(2)
            }

            if layout.showsMessage {
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .lineLimit(layout.messageLineLimit)
                    .layoutPriority(1)
            }
            if let focusSessionSummary {
                Text(focusSessionSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var metrics: some View {
        if layout.stacksMetricsVertically {
            VStack(spacing: 6) {
                metric(title: "今日专注", value: presentation.focusCountText)
                metric(title: "今日完成", value: presentation.completionCountText)
            }
        } else {
            HStack(spacing: 6) {
                metric(title: "今日专注", value: presentation.focusCountText)
                metric(title: "今日完成", value: presentation.completionCountText)
            }
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.title3.weight(.heavy))
                .foregroundStyle(primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusAccent.opacity(layout.usesEnhancedContrast ? 0.76 : 0.42), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }

    private func panelLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospaced())
            .foregroundStyle(secondaryText)
    }

    private var mediumBodyBottomPanelLabel: String {
        var parts: [String] = []
        if let project = presentation.recentProjectName {
            parts.append("最近项目：\(project)")
        }
        if let date = presentation.dataDateText {
            parts.append("\(date)")
        }
        return parts.joined(separator: "，")
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
        let date = Date()
        return TinyBuddyEntry(
            date: date,
            presentation: TinyBuddyDisplayPresentation(
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
                    refreshedAt: date,
                    trigger: .launch,
                    outcome: .succeeded,
                    metrics: GitActivityRefreshMetrics(authorizedRootCount: 1, repositoryCount: 1)
                ),
                locale: Locale(identifier: "zh_CN"),
                timeZone: .current
            )
        )
    }
}
#endif
