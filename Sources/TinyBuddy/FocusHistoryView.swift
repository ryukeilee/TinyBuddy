import SwiftUI
import TinyBuddyCore

/// Read-only Settings surface for the revision-bound, session-derived history
/// publication. This view deliberately has no access to `FocusSession` data.
struct FocusHistoryView: View {
    let publicationProvider: () -> FocusHistoryPublication?
    let refresh: () -> Void

    @State private var publication: FocusHistoryPublication?

    init(
        publicationProvider: @escaping () -> FocusHistoryPublication?,
        refresh: @escaping () -> Void
    ) {
        self.publicationProvider = publicationProvider
        self.refresh = refresh
        _publication = State(initialValue: publicationProvider())
    }

    var body: some View {
        Group {
            if let publication {
                history(publication.snapshot)
            } else {
                ContentUnavailableView(
                    "专注历史尚未就绪",
                    systemImage: "chart.bar.xaxis",
                    description: Text("无法读取已确认会话的历史汇总。")
                )
            }
        }
        .padding()
        .onAppear(perform: refreshHistory)
        .onReceive(NotificationCenter.default.publisher(
            for: .focusSessionSnapshotSynchronizationDidFinish
        )) { _ in
            // The publication was already committed by the producer. Re-read
            // it only; re-emitting here would create a notification loop.
            publication = publicationProvider()
        }
    }

    @ViewBuilder
    private func history(_ snapshot: FocusHistorySnapshot) -> some View {
        switch snapshot.state {
        case .noHistory:
            ContentUnavailableView(
                "暂无专注历史",
                systemImage: "clock",
                description: Text("已确认的专注会话会在这里汇总为最近七天和本周趋势。")
            )
        case .unknown:
            ContentUnavailableView(
                "专注历史未知",
                systemImage: "exclamationmark.triangle",
                description: Text("权威会话记录暂时不可用；不会以 0 代替未知结果。")
            )
        case .available, .partial:
            Form {
                if snapshot.state == .partial {
                    Section {
                        Label("部分历史尚未确认；未知日期不会计为 0。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("最近七天") {
                    ForEach(snapshot.recentDays, id: \.dayIdentifier) { day in
                        recentDayRow(day)
                    }
                }

                Section("本周") {
                    Text("目标进度按当前每日目标设置计算；修改目标不会改写已确认会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    weekSummary(snapshot.currentWeek, streak: snapshot.currentGoalStreakDays)
                }

                Section("主要项目") {
                    projectDistribution(snapshot.currentWeek.projectDistribution)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func recentDayRow(_ day: FocusHistoryDay) -> some View {
        HStack {
            Text(day.dayIdentifier)
                .frame(minWidth: 90, alignment: .leading)

            switch day.state {
            case .noSessions:
                Text("无记录")
                    .foregroundStyle(.secondary)
            case .unknown:
                Text("未知")
                    .foregroundStyle(.secondary)
            case .sessions:
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(duration(day.focusDuration)) · \(count(day.completedSessionCount)) 个会话")
                    goalText(rate: day.goalCompletionRate, goalMinutes: day.goalMinutes)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func weekSummary(_ week: FocusHistoryWeek, streak: Int?) -> some View {
        LabeledContent("周区间", value: "\(week.startDayIdentifier) – \(week.endDayIdentifier)")
        LabeledContent("总专注", value: duration(week.focusDuration))
        LabeledContent("完成会话", value: count(week.completedSessionCount))

        if let rate = week.goalCompletionRate {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("目标进度", value: percent(rate))
                ProgressView(value: rate)
                if let met = week.goalMetDayCount, let configured = week.configuredGoalDayCount {
                    Text("达标 \(met) / \(configured) 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent("目标进度", value: week.state == .unknown ? "未知" : "未设置或未知")
        }

        LabeledContent("连续达标", value: streak.map { "\($0) 天" } ?? "未知或未设置")

        if week.state == .partial {
            Text("本周汇总仅涵盖已确认的日期。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func projectDistribution(_ projects: [FocusHistoryProject]?) -> some View {
        if let projects {
            if projects.isEmpty {
                Text("无记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(projects.prefix(4).enumerated()), id: \.offset) { _, project in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(project.displayName)
                            if project.isHistoricalArchive == true {
                                Text("历史项目")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if project.isHistoricalArchive == nil {
                                Text("项目状态未知")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(percent(project.focusShare))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: project.focusShare)
                        Text("\(duration(project.focusDuration)) · \(project.completedSessionCount) 个会话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("未知")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func goalText(rate: Double?, goalMinutes: Int?) -> some View {
        if let rate {
            Text("目标 \(percent(rate))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if goalMinutes == nil {
            Text("目标未设置")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("目标未知")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshHistory() {
        refresh()
        publication = publicationProvider()
    }

    private func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "未知" }
        let minutes = max(0, Int(value / 60))
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private func count(_ value: Int?) -> String {
        value.map(String.init) ?? "未知"
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}
