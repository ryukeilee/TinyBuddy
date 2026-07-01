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
        HStack(alignment: .center, spacing: 13) {
            arcReactorCore
                .frame(width: 100, height: 100)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TINYBUDDY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(hudGold.opacity(0.92))
                        Text("COMPANION HUD")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
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

                HStack(spacing: 8) {
                    Text("STATUS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hudGold.opacity(0.82))
                    Text(presentation.statusTitle)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(mediumStatusAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(hudPanelFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(mediumStatusAccent.opacity(0.48), lineWidth: 1)
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
                        energyBlueWhite.opacity(0.18),
                        .clear
                    ],
                    center: UnitPoint(x: 0.26, y: 0.48),
                    startRadius: 2,
                    endRadius: 120
                )

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color(red: 0.95, green: 0.42, blue: 0.24).opacity(0.05),
                        Color.black.opacity(0.28)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.softLight)

                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(index.isMultiple(of: 2) ? hudGold.opacity(0.07) : reactorRed.opacity(0.08))
                        .frame(height: 0.7)
                        .offset(y: CGFloat(index) * 26 - 52)
                }
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
        switch entry.snapshot.status {
        case .idle:
            return hudGold
        case .focusing:
            return energyBlueWhite
        case .completedOnce:
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

    private var arcReactorCore: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            darkMetal.opacity(0.98),
                            Color(red: 0.11, green: 0.025, blue: 0.03),
                            Color.black.opacity(0.92)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 50
                    )
                )
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    hudGold.opacity(0.54),
                                    reactorRed.opacity(0.62),
                                    Color.black.opacity(0.36)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                )
                .shadow(color: reactorRed.opacity(0.42), radius: 16)

            Circle()
                .stroke(reactorRed.opacity(0.34), lineWidth: 9)
                .frame(width: 80, height: 80)

            ForEach(0..<24, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 3) ? hudGold.opacity(0.86) : reactorRed.opacity(0.58))
                    .frame(width: 2, height: index.isMultiple(of: 3) ? 12 : 7)
                    .offset(y: -43)
                    .rotationEffect(.degrees(Double(index) * 15))
            }

            Circle()
                .stroke(hudGold.opacity(0.62), lineWidth: 1.4)
                .frame(width: 86, height: 86)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            energyBlueWhite.opacity(0.18),
                            .white.opacity(0.92),
                            energyBlueWhite.opacity(0.90),
                            energyBlueWhite.opacity(0.18)
                        ],
                        center: .center
                    ),
                    lineWidth: 5
                )
                .frame(width: 72, height: 72)
                .shadow(color: energyBlueWhite.opacity(0.54), radius: 11)

            Circle()
                .stroke(reactorRed.opacity(0.78), lineWidth: 1.2)
                .frame(width: 54, height: 54)

            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.94),
                                energyBlueWhite.opacity(0.70)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 4, height: 18)
                    .offset(y: -18)
                    .rotationEffect(.degrees(Double(index) * 60))
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white,
                            energyBlueWhite.opacity(0.96),
                            Color(red: 0.18, green: 0.50, blue: 0.68).opacity(0.52)
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 20
                    )
                )
                .frame(width: 30, height: 30)
                .shadow(color: energyBlueWhite.opacity(0.85), radius: 12)
        }
        .overlay(alignment: .bottom) {
            Text("CORE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(hudGold.opacity(0.88))
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
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(hudGold.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(value)")
                .font(.system(size: 23, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
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
