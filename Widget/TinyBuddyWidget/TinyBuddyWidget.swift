import SwiftUI
import TinyBuddyCore
import WidgetKit

struct TinyBuddyEntry: TimelineEntry {
    let date: Date
    let snapshot: TinyBuddySnapshot
    let gitTodayFocusBlockCount: Int?
    let gitTodayCommitCount: Int?
}

struct TinyBuddyProvider: TimelineProvider {
    private let store = DailyStatsStore()
    private let gitFocusBlockCountStore = GitTodayFocusBlockCountStore()
    private let gitCommitCountStore = GitTodayCommitCountStore()

    func placeholder(in context: Context) -> TinyBuddyEntry {
        TinyBuddyEntry(
            date: Date(),
            snapshot: TinyBuddySnapshot(
                status: .idle,
                stats: DailyStats(dayIdentifier: "2026-07-01", focusCount: 0, completionCount: 0)
            ),
            gitTodayFocusBlockCount: 0,
            gitTodayCommitCount: 0
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
        TinyBuddyEntry(
            date: date,
            snapshot: store.loadSnapshot(),
            gitTodayFocusBlockCount: gitFocusBlockCountStore.loadTodayCount(),
            gitTodayCommitCount: gitCommitCountStore.loadTodayCount()
        )
    }
}

struct TinyBuddyWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TinyBuddyEntry

    private var smallPresentation: TinyBuddyWidgetPresentation {
        TinyBuddyWidgetPresentation(snapshot: entry.snapshot)
    }

    private var mediumPresentation: TinyBuddyWidgetPresentation {
        TinyBuddyWidgetPresentation(
            snapshot: entry.snapshot,
            focusCountOverride: entry.gitTodayFocusBlockCount ?? 0,
            completionCountOverride: entry.gitTodayCommitCount ?? 0
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
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(smallPresentation.expression)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(statusColor.opacity(0.22)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("TinyBuddy")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(smallPresentation.statusTitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                metric(title: "今日专注", value: smallPresentation.focusCount)
                metric(title: "今日完成", value: smallPresentation.completionCount)
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
                    hudMetric(title: "今日专注", value: mediumPresentation.focusCount)
                    hudMetric(title: "今日完成", value: mediumPresentation.completionCount)
                }

                HStack(spacing: 8) {
                    Text("STATUS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hudGold.opacity(0.82))
                    Text(mediumPresentation.statusTitle)
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
                .shadow(color: reactorRed.opacity(0.22), radius: 11)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.16),
                            energyBlueWhite.opacity(0.58),
                            energyBlueWhite.opacity(0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 56
                    )
                )
                .scaleEffect(1.08)
                .blur(radius: 10)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.08),
                            energyBlueWhite.opacity(0.28),
                            .clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 64
                    )
                )
                .scaleEffect(1.24)
                .blur(radius: 15)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            hudGold.opacity(0.60),
                            reactorRed.opacity(0.72),
                            Color.black.opacity(0.38)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3.2
                )
                .frame(width: 94, height: 94)

            ForEach(0..<12, id: \.self) { index in
                Circle()
                    .trim(from: 0.02, to: 0.066)
                    .stroke(
                        LinearGradient(
                            colors: index.isMultiple(of: 4) ? [
                                hudGold.opacity(0.96),
                                Color(red: 0.70, green: 0.28, blue: 0.14),
                                reactorRed.opacity(0.72)
                            ] : [
                                Color(red: 0.42, green: 0.12, blue: 0.10),
                                hudGold.opacity(0.72),
                                reactorRed.opacity(0.64)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: StrokeStyle(
                            lineWidth: index.isMultiple(of: 4) ? 6.5 : 5.2,
                            lineCap: .round
                        )
                    )
                    .frame(width: 82, height: 82)
                    .rotationEffect(.degrees(Double(index) * 30 - 90))
                    .shadow(
                        color: index.isMultiple(of: 4) ? hudGold.opacity(0.18) : reactorRed.opacity(0.14),
                        radius: 2
                    )
            }

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            energyBlueWhite.opacity(0.16),
                            .white.opacity(0.95),
                            energyBlueWhite.opacity(0.96),
                            Color(red: 0.45, green: 0.82, blue: 0.95).opacity(0.68),
                            energyBlueWhite.opacity(0.16)
                        ],
                        center: .center
                    ),
                    lineWidth: 4.8
                )
                .frame(width: 72, height: 72)
                .shadow(color: energyBlueWhite.opacity(0.62), radius: 12)

            Circle()
                .stroke(energyBlueWhite.opacity(0.24), lineWidth: 1.2)
                .frame(width: 88, height: 88)
                .blur(radius: 0.2)

            Circle()
                .stroke(hudGold.opacity(0.50), lineWidth: 1.2)
                .frame(width: 62, height: 62)

            ForEach(0..<3, id: \.self) { index in
                ReactorBraceShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.19, green: 0.06, blue: 0.05),
                                hudGold.opacity(0.92),
                                reactorRed.opacity(0.72),
                                darkMetal.opacity(0.96)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        ReactorBraceShape()
                            .stroke(hudGold.opacity(0.34), lineWidth: 0.8)
                    }
                    .frame(width: 28, height: 34)
                    .offset(y: -15)
                    .rotationEffect(.degrees(Double(index) * 120))
                    .shadow(color: reactorRed.opacity(0.24), radius: 4, y: 1)
            }

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            .white.opacity(0.98),
                            energyBlueWhite.opacity(0.94),
                            .white.opacity(0.82),
                            energyBlueWhite.opacity(0.36)
                        ],
                        center: .center
                    ),
                    lineWidth: 5.2
                )
                .frame(width: 46, height: 46)
                .shadow(color: energyBlueWhite.opacity(0.68), radius: 9)

            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .trim(from: 0.12, to: 0.20)
                    .stroke(
                        index.isMultiple(of: 2) ? hudGold.opacity(0.88) : reactorRed.opacity(0.64),
                        style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
                    )
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(Double(index) * 60 - 90))
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white,
                            energyBlueWhite.opacity(0.96),
                            Color(red: 0.18, green: 0.50, blue: 0.68).opacity(0.56),
                            Color(red: 0.07, green: 0.16, blue: 0.22).opacity(0.28)
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 21
                    )
                )
                .frame(width: 28, height: 28)
                .shadow(color: energyBlueWhite.opacity(0.95), radius: 13)

            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 11, height: 11)
                .blur(radius: 0.5)

            ForEach(0..<3, id: \.self) { index in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(hudGold.opacity(0.92))
                        .frame(width: 10, height: 1.8)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(reactorRed.opacity(0.68))
                        .frame(width: 6, height: 1.4)
                }
                .offset(y: -43)
                .rotationEffect(.degrees(Double(index) * 120))
            }
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

private struct ReactorBraceShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = CGPoint(x: rect.midX, y: rect.minY)
        let lowerLeft = CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY - rect.height * 0.18)
        let notch = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.38)
        let lowerRight = CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY - rect.height * 0.18)

        path.move(to: top)
        path.addLine(to: lowerLeft)
        path.addQuadCurve(
            to: notch,
            control: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY + rect.height * 0.04)
        )
        path.addQuadCurve(
            to: lowerRight,
            control: CGPoint(x: rect.maxX - rect.width * 0.34, y: rect.maxY + rect.height * 0.04)
        )
        path.addLine(to: top)
        path.closeSubpath()

        return path
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
                    gitTodayFocusBlockCount: 4,
                    gitTodayCommitCount: 7
                )
            )
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium HUD")
        }
    }

    private static func previewEntry(
        status: PetStatus,
        focusCount: Int,
        completionCount: Int,
        gitTodayFocusBlockCount: Int? = nil,
        gitTodayCommitCount: Int? = nil
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
            gitTodayFocusBlockCount: gitTodayFocusBlockCount,
            gitTodayCommitCount: gitTodayCommitCount
        )
    }
}
#endif
