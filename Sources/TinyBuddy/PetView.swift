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
    @State private var showProjectPicker = false
    @State private var showRecognitionExplanation = false
    private let registeredProjectsProvider: () -> [TinyBuddyProject]

    private let fixedWidth: CGFloat = 284
    private let hudHeight: CGFloat = 520

    enum PetViewFocusField: Hashable {
        case settings
        case statusButton(PetStatus)
        case actionButton
    }

    init(
        viewModel: PetViewModel? = nil,
        registeredProjectsProvider: @escaping () -> [TinyBuddyProject] = { [] }
    ) {
        _viewModel = StateObject(wrappedValue: viewModel ?? PetViewModel())
        _lowPowerModeEnabled = State(
            initialValue: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        self.registeredProjectsProvider = registeredProjectsProvider
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

    /// Today's duration comes only from the revision-bound session-history
    /// publication shared with the Widget. Git focus-block counts are activity
    /// metadata, not elapsed focus time, so they never stand in for this value.
    private var focusHistoryDay: FocusHistoryDay? {
        viewModel.focusHistoryPublication?.snapshot.recentDays.last
    }

    private var focusMetricText: String {
        FocusHistoryDurationFormatter.text(for: focusHistoryDay?.focusDuration)
    }

    private var focusMetricNumericValue: Int {
        max(0, Int((focusHistoryDay?.focusDuration ?? 0) / 60))
    }

    private var focusMetricIsKnown: Bool {
        focusHistoryDay?.focusDuration != nil
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
                developmentResumePanel
                statusButtons
                    .focusSection()
                manualFocusControlPanel
                    .focusSection()
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
        if focusMetricIsKnown {
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
                animation: semanticAnimation,
                isUnknown: !focusMetricIsKnown
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
            // Keep the panel subtree stable. Replacing it with `.id` causes
            // rapid A→B→A publications to stack opacity transitions and
            // briefly reveal the window background. Content transitions keep
            // the same layout/gesture tree while animating only semantic text
            // and image changes.
            .contentTransition(.opacity)
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
    private var developmentResumePanel: some View {
        if let snapshot = viewModel.developmentInterruptionSnapshot {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let interruption = DevelopmentInterruptionPresentation(
                    snapshot: snapshot,
                    now: context.date
                )
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .foregroundStyle(statusAccent)
                            Text("继续上次开发")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(primaryText)
                            Spacer(minLength: 4)
                            Text(interruption.awayDurationText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                        }

                        HStack(spacing: 5) {
                            Text(interruption.repositoryName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                            Text("·")
                                .foregroundStyle(secondaryText)
                            Label(interruption.branchName, systemImage: "arrow.triangle.branch")
                                .font(.caption2.monospaced())
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Text(interruption.workingTreeText)
                            .font(.caption2)
                            .foregroundStyle(
                                snapshot.workingTree.isClean ? secondaryText : statusAccent
                            )
                            .lineLimit(2)

                        if let recentCommitText = interruption.recentCommitText {
                            Label(recentCommitText, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.caption2)
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "继续上次开发，\(interruption.repositoryName)，分支 \(interruption.branchName)，\(interruption.workingTreeText)，\(interruption.recentCommitText ?? "暂无提交")，\(interruption.awayDurationText)"
                    )

                    developmentResumeActionRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(panelFill)
                .overlay(panelBorder)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// The action/state row of the development-interruption card. Only the
    /// exact-match `.available` state renders a start control; every other
    /// state is read-only and the resume action itself is a safe no-op.
    @ViewBuilder
    private var developmentResumeActionRow: some View {
        switch viewModel.developmentInterruptionResumeState {
        case .available(let project):
            Button {
                viewModel.resumeDevelopmentInterruption()
            } label: {
                Label("继续专注", systemImage: "play.circle.fill")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(statusAccent)
            .accessibilityLabel("继续专注：\(project.displayName)")
        case .inProgress(let project, let status):
            Label(
                status == .active
                    ? "专注中 · \(project.displayName)"
                    : "已暂停 · \(project.displayName)",
                systemImage: status == .active ? "scope" : "pause.circle.fill"
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(statusAccent)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(
                status == .active
                    ? "专注中：\(project.displayName)"
                    : "已暂停：\(project.displayName)"
            )
        case .blocked:
            EmptyView()
        }
    }

    @ViewBuilder
    // MARK: - Manual Focus Control Panel

    private var manualFocusControlPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("FOCUS CONTROL")
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(HUDTheme.brandTextColor(
                        for: colorScheme,
                        increasedContrast: increasedContrast
                    ))
                Spacer(minLength: 4)
                Button {
                    // On demand: recompute the explanation from the engine's
                    // live gate state at open time, then show the popover.
                    viewModel.refreshFocusRecognitionExplanation()
                    showRecognitionExplanation = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusAccent)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("专注识别原因说明")
                .accessibilityLabel("专注识别原因说明")
                .popover(isPresented: $showRecognitionExplanation) {
                    FocusRecognitionExplanationView(
                        explanation: viewModel.focusRecognitionExplanation,
                        accent: statusAccent,
                        primaryText: primaryText,
                        secondaryText: secondaryText,
                        onRefresh: {
                            viewModel.refreshFocusRecognitionExplanation()
                        }
                    )
                    .frame(width: 260)
                    .padding()
                }
            }

            switch viewModel.manualControlState {
            case .idle:
                // No manual session; show project picker button.
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "play.circle")
                            .foregroundStyle(statusAccent)
                        Text("手动专注")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(primaryText)
                        Spacer()
                        Button("选择项目") {
                            showProjectPicker = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(statusAccent)
                        .accessibilityLabel("选择项目开始手动专注")
                    }

                    if let recentProjectName = presentation.recentProjectName {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.caption2)
                                .foregroundStyle(secondaryText)
                            Text("最近：\(recentProjectName)")
                                .font(.caption2)
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                }
                .popover(isPresented: $showProjectPicker) {
                    ManualFocusProjectPicker(
                        recentProjectName: presentation.recentProjectName,
                        registeredProjects: registeredProjectsProvider(),
                        onSubmit: { project in
                            viewModel.startManualFocus(project: project)
                            showProjectPicker = false
                        }
                    )
                    .frame(width: 260)
                    .padding()
                }

            case .focusing(let project, _, let duration):
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "scope")
                            .foregroundStyle(statusAccent)
                        Text("手动专注中")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(primaryText)
                        Spacer()
                    }
                    HStack {
                        Text(project.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text(formatDuration(duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(statusAccent)
                    }
                    HStack(spacing: 8) {
                        Button {
                            viewModel.pauseManualFocus()
                        } label: {
                            Label("暂停", systemImage: "pause.circle")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(statusAccent)

                        Button {
                            viewModel.endManualFocus()
                        } label: {
                            Label("结束", systemImage: "stop.circle")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        Spacer()
                    }
                }

            case .paused(let project, _, _, let duration):
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                        Text("手动专注已暂停")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(primaryText)
                        Spacer()
                    }
                    HStack {
                        Text(project.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text(formatDuration(duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        Button {
                            viewModel.resumeManualFocus()
                        } label: {
                            Label("继续", systemImage: "play.circle")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(statusAccent)

                        Button {
                            viewModel.endManualFocus()
                        } label: {
                            Label("结束", systemImage: "stop.circle")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        Spacer()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(panelFill)
        .overlay(panelBorder)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(semanticAnimation, value: viewModel.manualControlState.transitionIdentity)
    }

    private var defaultManualProject: FocusProjectContext {
        if let name = presentation.recentProjectName {
            return FocusProjectContext(key: "manual.\(name)", displayName: name)
        }
        return FocusProjectContext(key: "manual.untitled", displayName: "未命名项目")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Status Buttons

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

        return Group {
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
    var isUnknown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(secondaryText)
                .lineLimit(1)
            Text(value)
                .font(isUnknown ? .title2.weight(.heavy) : .title3.weight(.heavy).monospacedDigit())
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

private struct FocusRecognitionExplanationView: View {
    let explanation: FocusRecognitionExplanation?
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("专注识别原因")
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(primaryText)
                Spacer(minLength: 4)
                Button("刷新", action: onRefresh)
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
                    .accessibilityLabel("刷新识别说明")
            }

            if let explanation {
                Label(explanation.title, systemImage: iconName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel(explanation.title)

                Text(explanation.detail)
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if let last = explanation.lastDecision {
                    Divider()
                    Text("最近判断")
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(primaryText)
                    Text(last.explanation)
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("最近判断：\(last.explanation)")
                }
            } else {
                Text("引擎未运行，暂时无法获取识别说明。")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconName: String {
        switch explanation?.posture {
        case .recognizing:
            return "waveform.path.ecg"
        case .confirmed:
            return "scope"
        case .switched:
            return "arrow.left.arrow.right"
        case .notEntered, .none:
            return "questionmark.circle"
        }
    }
}
