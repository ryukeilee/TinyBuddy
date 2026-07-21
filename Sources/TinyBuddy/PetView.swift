import SwiftUI
import TinyBuddyCore

private typealias HUDTheme = TinyBuddyHUDTheme

@MainActor
struct PetView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityEnabled) private var accessibilityEnabled

    @FocusState private var focusedField: PetViewFocusField?
    @StateObject private var viewModel: PetViewModel
    @State private var lowPowerModeEnabled: Bool

    private let fixedWidth: CGFloat = 284
    private let hudHeight: CGFloat = 520

    enum PetViewFocusField: Hashable {
        case settings
        case statusButton(PetStatus)
        case actionButton
    }

    init(viewModel: PetViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? PetViewModel())
        _lowPowerModeEnabled = State(
            initialValue: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private var presentation: TinyBuddyDisplayPresentation {
        viewModel.displayPresentation
    }

    private var focusWeekSummary: String? {
        guard let history = viewModel.focusHistoryPublication else { return nil }
        switch history.snapshot.state {
        case .unknown:
            return "本周专注历史未知"
        case .noHistory:
            return "本周暂无专注历史"
        case .available, .partial:
            guard let seconds = history.snapshot.currentWeek.focusDuration else {
                return "本周专注历史未知"
            }
            let minutes = Int(seconds / 60)
            return "本周专注 \(minutes / 60) 小时 \(minutes % 60) 分"
        }
    }

    /// The legacy daily counter is retained for compatibility, but its value
    /// is shown only when the shared history publication establishes that the
    /// current day is known. This prevents a fallback zero from masquerading
    /// as a confirmed focus result after a journal migration/read failure.
    private var focusMetricText: String {
        focusMetricIsKnown ? presentation.focusCountText : "未知"
    }

    private var focusMetricNumericValue: Int {
        focusMetricIsKnown ? presentation.focusCount : 0
    }

    private var focusMetricIsKnown: Bool {
        guard let day = viewModel.focusHistoryPublication?.snapshot.recentDays.last else {
            return false
        }
        return day.state != .unknown && day.completedSessionCount != nil
    }

    private var increasedContrast: Bool {
        colorSchemeContrast == .increased
    }

    private var displayLayout: TinyBuddyDisplayLayout {
        TinyBuddyDisplayLayout(
            presentation: presentation,
            environment: TinyBuddyDisplayEnvironment(
                size: .standard,
                textScale: dynamicTypeSize.isAccessibilitySize ? .accessibility : .standard,
                increasedContrast: increasedContrast,
                reduceMotion: accessibilityReduceMotion,
                lowPower: lowPowerModeEnabled
            )
        )
    }

    private var statusAccent: Color {
        HUDTheme.statusAccent(
            for: presentation.accentRole,
            colorScheme: colorScheme,
            increasedContrast: increasedContrast
        )
    }

    private var primaryText: Color {
        HUDTheme.primaryTextColor(
            for: colorScheme,
            increasedContrast: increasedContrast
        )
    }

    private var secondaryText: Color {
        HUDTheme.secondaryTextColor(
            for: colorScheme,
            increasedContrast: increasedContrast
        )
    }

    private var semanticAnimation: Animation? {
        displayLayout.allowsMotion ? .easeOut(duration: 0.18) : nil
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                Capsule()
                    .fill(HUDTheme.hudGold.opacity(increasedContrast ? 0.82 : 0.45))
                    .frame(width: 48, height: 5)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                header
                    .focusable(false)
                heroPanel
                    .focusable(false)
                if displayLayout.showsMetrics {
                    metricsPanel
                        .focusable(false)
                }
                displayStatePanel
                    .focusSection()
                statusButtons
                    .focusSection()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, minHeight: hudHeight, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .frame(width: fixedWidth, height: hudHeight, alignment: .top)
        .background(hudBackground)
        .overlay(hudChrome)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(WindowConfigurator())
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSProcessInfoPowerStateDidChange
            )
        ) { _ in
            updateLowPowerMode()
        }
        .transaction { transaction in
            if displayLayout.allowsMotion == false {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }

    }

    private func updateLowPowerMode() {
        let currentValue = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard lowPowerModeEnabled != currentValue else {
            return
        }
        lowPowerModeEnabled = currentValue
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("TINYBUDDY")
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(HUDTheme.brandTextColor(
                        for: colorScheme,
                        increasedContrast: increasedContrast
                    ))
                Text("COMPANION HUD")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("TinyBuddy Companion HUD")

            Spacer(minLength: 4)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(statusAccent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(HUDTheme.panelFill(
                        for: colorScheme,
                        increasedContrast: increasedContrast
                    )))
                    .overlay(
                        Circle().stroke(
                            HUDTheme.panelBorder(
                                for: colorScheme,
                                increasedContrast: increasedContrast
                            ),
                            lineWidth: increasedContrast ? 2 : 1
                        )
                    )
            }
            .buttonStyle(.plain)
            .help("打开设置")
            .accessibilityLabel("设置")
            .accessibilityHint("打开 TinyBuddy 设置窗口")
            .focused($focusedField, equals: .settings)

            Label(presentation.statusTitle, systemImage: presentation.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(statusAccent)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityLabel("当前状态：\(presentation.statusTitle)")
        }
    }

    private var heroPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            if displayLayout.showsExpression {
                TinyBuddyArcReactorCore(showsLabel: false)
                    .frame(width: 104, height: 104)
                    .overlay {
                        Text(presentation.expression)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(HUDTheme.darkMetal.opacity(0.86))
                            .lineLimit(1)
                    }
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CURRENT STATE")
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(HUDTheme.brandTextColor(
                        for: colorScheme,
                        increasedContrast: increasedContrast
                    ))
                    .accessibilityHidden(true)

                Text(presentation.statusTitle)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(0.78)

                if displayLayout.showsProject,
                   let recentProjectName = presentation.recentProjectName {
                    Text(recentProjectName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let focusWeekSummary {
                    Text(focusWeekSummary)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }

                Label(presentation.statusTitle, systemImage: presentation.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusAccent)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(heroAccessibilityLabel)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(10)
        .background(panelFill)
        .overlay(panelBorder)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(semanticAnimation, value: presentation.transitionIdentity)
    }

    private var heroAccessibilityLabel: String {
        var parts = ["状态：\(presentation.statusTitle)"]
        if let projectName = presentation.recentProjectName {
            parts.append("最近项目：\(projectName)")
        }
        if focusMetricIsKnown, focusMetricNumericValue > 0 {
            parts.append("专注：\(focusMetricText)")
        } else if !focusMetricIsKnown {
            parts.append("今日专注未知")
        }
        if presentation.completionCount > 0 {
            parts.append("完成：\(presentation.completionCountText)")
        }
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    private var metricsPanel: some View {
        let metrics = Group {
            CounterView(
                title: "今日专注",
                value: focusMetricText,
                numericValue: focusMetricNumericValue,
                accent: HUDTheme.energyBlueWhite,
                primaryText: primaryText,
                secondaryText: secondaryText,
                panelFill: panelFill,
                border: HUDTheme.panelBorder(
                    for: colorScheme,
                    increasedContrast: increasedContrast
                ),
                animation: semanticAnimation
            )
            CounterView(
                title: "今日完成",
                value: presentation.completionCountText,
                numericValue: presentation.completionCount,
                accent: statusAccent,
                primaryText: primaryText,
                secondaryText: secondaryText,
                panelFill: panelFill,
                border: HUDTheme.panelBorder(
                    for: colorScheme,
                    increasedContrast: increasedContrast
                ),
                animation: semanticAnimation
            )
        }

        if displayLayout.stacksMetricsVertically {
            VStack(spacing: 8) {
                metrics
            }
        } else {
            HStack(spacing: 8) {
                metrics
            }
        }
    }

    private var displayStatePanel: some View {
        ZStack(alignment: .topLeading) {
            UnifiedDisplayStateView(
                presentation: presentation,
                layout: displayLayout,
                accent: statusAccent,
                primaryText: primaryText,
                secondaryText: secondaryText,
                action: viewModel.performGitActivityAction
            )
            .id(presentation.transitionIdentity)
            .transition(.opacity)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize ? 138 : 122,
            alignment: .topLeading
        )
        .padding(10)
        .background(panelFill)
        .overlay(panelBorder)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(semanticAnimation, value: presentation.transitionIdentity)
    }

    @ViewBuilder
    private var statusButtons: some View {
        let buttons = ForEach(PetStatus.allCases) { status in
            Button {
                viewModel.select(status)
            } label: {
                Text(status.title)
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            .buttonStyle(
                StatusButtonStyle(
                    isSelected: viewModel.selectedStatus == status,
                    accent: accentColor(for: status),
                    primaryText: primaryText,
                    border: HUDTheme.panelBorder(
                        for: colorScheme,
                        increasedContrast: increasedContrast
                    )
                )
            )
            .accessibilityLabel(statusButtonAccessibilityLabel(for: status))
            .accessibilityAddTraits(
                viewModel.selectedStatus == status ? .isSelected : []
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(statusButtonAccessibilityHint(for: status))
            .focused($focusedField, equals: .statusButton(status))
        }

        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                buttons
            }
            .accessibilityLabel("状态选择")
        } else {
            HStack(spacing: 8) {
                buttons
            }
            .accessibilityLabel("状态选择")
        }
    }

    private func statusButtonAccessibilityLabel(for status: PetStatus) -> String {
        switch status {
        case .idle:
            return "待机状态"
        case .focusing:
            return "专注中状态"
        case .completedOnce:
            return "完成一次状态"
        }
    }

    private func statusButtonAccessibilityHint(for status: PetStatus) -> String {
        let isSelected = viewModel.selectedStatus == status
        let selectionState = isSelected ? "当前已选中" : "轻点切换到此状态"
        switch status {
        case .idle:
            return "\(selectionState)。TinyBuddy 处于待机模式。"
        case .focusing:
            return "\(selectionState)。标记为专注中。"
        case .completedOnce:
            return "\(selectionState)。标记为已完成一次。"
        }
    }

    private var panelFill: some ShapeStyle {
        HUDTheme.panelFill(
            for: colorScheme,
            increasedContrast: increasedContrast
        )
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(
                statusAccent.opacity(increasedContrast ? 0.88 : 0.48),
                lineWidth: increasedContrast ? 2 : 1
            )
    }

    private var hudBackground: some View {
        TinyBuddyHUDBackground(
            redGlowCenter: .bottomTrailing,
            blueGlowCenter: .topLeading,
            redGlowRadius: 260,
            blueGlowRadius: 140,
            redGlowOpacity: colorScheme == .dark ? 0.34 : 0.12,
            blueGlowOpacity: colorScheme == .dark ? 0.16 : 0.08,
            scanLineCount: increasedContrast ? 3 : 5
        )
        .shadow(color: .black.opacity(0.24), radius: 20, x: 0, y: 12)
    }

    private var hudChrome: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(
                HUDTheme.panelBorder(
                    for: colorScheme,
                    increasedContrast: increasedContrast
                ),
                lineWidth: increasedContrast ? 2 : 1
            )
    }

    private func accentColor(for status: PetStatus) -> Color {
        switch status {
        case .idle:
            return HUDTheme.statusAccent(
                for: .neutral,
                colorScheme: colorScheme,
                increasedContrast: increasedContrast
            )
        case .focusing:
            return HUDTheme.statusAccent(
                for: .focus,
                colorScheme: colorScheme,
                increasedContrast: increasedContrast
            )
        case .completedOnce:
            return HUDTheme.statusAccent(
                for: .success,
                colorScheme: colorScheme,
                increasedContrast: increasedContrast
            )
        }
    }
}

private struct UnifiedDisplayStateView: View {
    let presentation: TinyBuddyDisplayPresentation
    let layout: TinyBuddyDisplayLayout
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(accent)
                Text(presentation.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(primaryText)
                    .lineLimit(2)

                Spacer(minLength: 4)

                Text("刷新中")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                    .opacity(presentation.isRefreshing ? 1 : 0)
                    .accessibilityHidden(presentation.isRefreshing == false)
                    .accessibilityLabel(presentation.isRefreshing ? "数据正在刷新" : "")
            }

            if layout.showsMessage {
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .lineLimit(layout.messageLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center, spacing: 8) {
                if let actionTitle = presentation.actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .accessibilityLabel(actionTitle)
                        .accessibilityHint(presentation.message)
                        .accessibilityAddTraits(.isButton)
                }

                Spacer(minLength: 0)

                if layout.showsDataDate,
                   let dataDateText = presentation.dataDateText {
                    Text(dataDateText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                        .accessibilityLabel("数据日期：\(dataDateText)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct CounterView<PanelFill: ShapeStyle>: View {
    let title: String
    let value: String
    let numericValue: Int
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let panelFill: PanelFill
    let border: Color
    let animation: Animation?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.heavy).monospacedDigit())
                .foregroundStyle(primaryText)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Label("TODAY", systemImage: "circle.fill")
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(accent)
                .labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(animation, value: numericValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }
}

private struct StatusButtonStyle: ButtonStyle {
    let isSelected: Bool
    let accent: Color
    let primaryText: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 8)
            .foregroundStyle(primaryText.opacity(isSelected ? 1 : 0.78))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? accent.opacity(configuration.isPressed ? 0.54 : 0.38)
                            : border.opacity(configuration.isPressed ? 0.20 : 0.10)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accent : border, lineWidth: isSelected ? 2 : 1)
            )
    }
}
