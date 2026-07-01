import SwiftUI
import TinyBuddyCore
import WidgetKit

struct TinyBuddyEntry: TimelineEntry {
    let date: Date
    let snapshot: TinyBuddySnapshot
}

struct TinyBuddyProvider: TimelineProvider {
    private let store = DailyStatsStore()

    func placeholder(in context: Context) -> TinyBuddyEntry {
        TinyBuddyEntry(
            date: Date(),
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TinyBuddyEntry) -> Void) {
        completion(TinyBuddyEntry(date: Date(), snapshot: store.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TinyBuddyEntry>) -> Void) {
        let entry = TinyBuddyEntry(date: Date(), snapshot: store.loadSnapshot())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct TinyBuddyWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TinyBuddyEntry

    private var presentation: TinyBuddyWidgetPresentation {
        TinyBuddyWidgetPresentation(snapshot: entry.snapshot)
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
        HStack(spacing: 18) {
            arcReactorCore
                .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TINYBUDDY")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(hudCyan)
                        Text("COMPANION HUD")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }

                    Spacer(minLength: 8)

                    Text(presentation.expression)
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(statusColor.opacity(0.24)))
                        .overlay(Circle().stroke(statusColor.opacity(0.72), lineWidth: 1))
                }

                HStack(spacing: 8) {
                    hudMetric(title: "今日专注", value: presentation.focusCount)
                    hudMetric(title: "今日完成", value: presentation.completionCount)
                }

                HStack(spacing: 8) {
                    Text("STATUS")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hudCyan.opacity(0.78))
                    Text(presentation.statusTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hudPanelFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(statusColor.opacity(0.48), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.05, blue: 0.08),
                        Color(red: 0.05, green: 0.12, blue: 0.16),
                        Color(red: 0.04, green: 0.04, blue: 0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        hudCyan.opacity(0.22),
                        .clear
                    ],
                    center: .leading,
                    startRadius: 8,
                    endRadius: 210
                )
            }
        }
    }

    private var statusColor: Color {
        switch entry.snapshot.status {
        case .idle:
            return Color(red: 0.98, green: 0.77, blue: 0.42)
        case .focusing:
            return Color(red: 0.43, green: 0.75, blue: 0.91)
        case .completedOnce:
            return Color(red: 0.47, green: 0.82, blue: 0.57)
        }
    }

    private var hudCyan: Color {
        Color(red: 0.31, green: 0.91, blue: 1.0)
    }

    private var hudPanelFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(0.13),
                hudCyan.opacity(0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var arcReactorCore: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white,
                            hudCyan.opacity(0.92),
                            hudCyan.opacity(0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 58
                    )
                )
                .shadow(color: hudCyan.opacity(0.78), radius: 18)

            ForEach(0..<24, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 3) ? Color.white.opacity(0.9) : hudCyan.opacity(0.58))
                    .frame(width: 2, height: index.isMultiple(of: 3) ? 15 : 9)
                    .offset(y: -49)
                    .rotationEffect(.degrees(Double(index) * 15))
            }

            Circle()
                .stroke(hudCyan.opacity(0.62), lineWidth: 2)
                .frame(width: 84, height: 84)

            Circle()
                .stroke(Color.white.opacity(0.84), lineWidth: 2)
                .frame(width: 42, height: 42)

            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .shadow(color: .white.opacity(0.85), radius: 9)
        }
        .overlay(alignment: .bottom) {
            Text("CORE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(hudCyan.opacity(0.88))
                .offset(y: 10)
        }
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(hudCyan.opacity(0.76))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(value)")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(hudPanelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hudCyan.opacity(0.34), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

            TinyBuddyWidgetView(entry: previewEntry(status: .focusing, focusCount: 5, completionCount: 3))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium HUD")
        }
    }

    private static func previewEntry(status: PetStatus, focusCount: Int, completionCount: Int) -> TinyBuddyEntry {
        TinyBuddyEntry(
            date: Date(),
            snapshot: TinyBuddySnapshot(
                status: status,
                stats: DailyStats(
                    dayIdentifier: "2026-07-01",
                    focusCount: focusCount,
                    completionCount: completionCount
                )
            )
        )
    }
}
#endif
