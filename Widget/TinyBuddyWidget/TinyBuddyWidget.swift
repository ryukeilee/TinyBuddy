import SwiftUI
import TinyBuddyCore
import WidgetKit
import OSLog

struct TinyBuddyEntry: TimelineEntry {
    let date: Date
    let snapshot: TinyBuddySnapshot
    let activitySnapshot: GitTodayActivitySnapshot
}

struct TinyBuddyProvider: TimelineProvider {
    private let store = DailyStatsStore()
    private let combinedSnapshotStore = TinyBuddyCombinedSnapshotStore(repairOnLoad: false)
    private static let logger = Logger(subsystem: "local.tinybuddy", category: "SharedSnapshot")

    func placeholder(in context: Context) -> TinyBuddyEntry {
        return TinyBuddyEntry(
            date: Date(),
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
            ),
            activitySnapshot: GitTodayActivitySnapshot(
                focusBlockCount: 0,
                commitCount: 0,
                recentProjectName: "TinyBuddy"
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TinyBuddyEntry) -> Void) {
        completion(makeEntry(for: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TinyBuddyEntry>) -> Void) {
        let entry = makeEntry(for: Date())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func makeEntry(for date: Date) -> TinyBuddyEntry {
        let expectedDayIdentifier = Self.dayIdentifier(for: date)
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
                activitySnapshot: combinedSnapshot.activitySnapshot
            )
        }

        if let observation = combinedRead.observation,
           observation.reason == .staleData || observation.reason == .snapshotCorrupt {
            return TinyBuddyEntry(
                date: date,
                snapshot: store.loadSnapshot(),
                activitySnapshot: neutralActivitySnapshot
            )
        }

        return TinyBuddyEntry(
            date: date,
            snapshot: neutralSnapshot(dayIdentifier: expectedDayIdentifier),
            activitySnapshot: neutralActivitySnapshot
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

    private static func dayIdentifier(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
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
            switch family {
            case .systemMedium:
                mediumBody
            default:
                smallBody
            }
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(presentation.expression)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(statusColor.opacity(0.22)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("TinyBuddy")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(presentation.statusTitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                metric(title: "今日专注", value: presentation.focusCount)
                metric(title: "今日完成", value: presentation.completionCount)
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.97, blue: 0.93),
                    Color(red: 0.82, green: 0.91, blue: 0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
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
                            .foregroundStyle(hudGold.opacity(0.88))
                        Text("COMPANION HUD")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(red: 1.0, green: 0.93, blue: 0.77))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 4)

                    Circle()
                        .fill(mediumStatusAccent)
                        .frame(width: 7, height: 7)
                        .shadow(color: mediumStatusAccent.opacity(0.8), radius: 5)
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
                .background(hudPanelFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(mediumStatusAccent.opacity(0.42), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.005, blue: 0.012),
                        Color(red: 0.17, green: 0.018, blue: 0.035),
                        Color(red: 0.015, green: 0.012, blue: 0.016)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        reactorRed.opacity(0.40),
                        emberRed.opacity(0.18),
                        .clear
                    ],
                    center: .bottomTrailing,
                    startRadius: 8,
                    endRadius: 220
                )

                RadialGradient(
                    colors: [
                        energyBlueWhite.opacity(0.12),
                        .clear
                    ],
                    center: UnitPoint(x: 0.26, y: 0.48),
                    startRadius: 2,
                    endRadius: 104
                )

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color(red: 0.95, green: 0.42, blue: 0.24).opacity(0.03),
                        Color.black.opacity(0.22)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.softLight)

                ForEach(0..<4, id: \.self) { index in
                    Rectangle()
                        .fill(index.isMultiple(of: 2) ? hudGold.opacity(0.05) : reactorRed.opacity(0.06))
                        .frame(height: 0.7)
                        .offset(y: CGFloat(index) * 28 - 42)
                }
            }
        }
    }

    private var statusColor: Color {
        switch presentation.displayState {
        case .idle:
            return Color(red: 0.98, green: 0.77, blue: 0.42)
        case .focusing:
            return Color(red: 0.43, green: 0.75, blue: 0.91)
        case .completed, .active:
            return Color(red: 0.47, green: 0.82, blue: 0.57)
        }
    }

    private var energyBlueWhite: Color {
        Color(red: 0.72, green: 0.96, blue: 1.0)
    }

    private var hudGold: Color {
        Color(red: 0.94, green: 0.70, blue: 0.36)
    }

    private var reactorRed: Color {
        Color(red: 0.78, green: 0.06, blue: 0.06)
    }

    private var emberRed: Color {
        Color(red: 0.34, green: 0.015, blue: 0.025)
    }

    private var darkMetal: Color {
        Color(red: 0.035, green: 0.032, blue: 0.036)
    }

    private var mediumStatusAccent: Color {
        switch presentation.displayState {
        case .idle:
            return hudGold
        case .focusing:
            return energyBlueWhite
        case .completed, .active:
            return Color(red: 0.98, green: 0.86, blue: 0.54)
        }
    }

    private var hudPanelFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(0.075),
                Color(red: 0.25, green: 0.025, blue: 0.035).opacity(0.42),
                Color.black.opacity(0.20)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func metric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hudMetric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(hudGold.opacity(0.78))
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
        .background(hudPanelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    LinearGradient(
                        colors: [
                            hudGold.opacity(0.38),
                            reactorRed.opacity(0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var hudStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            hudPanelLabel("STATUS")

            Text(presentation.statusTitle)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(mediumStatusAccent)
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
            .foregroundStyle(hudGold.opacity(0.82))
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
            activitySnapshot: activitySnapshot
        )
    }
}
#endif
