import SwiftUI
import TinyBuddyCore

@MainActor
struct PetView: View {
    @StateObject private var viewModel: PetViewModel

    private let fixedWidth: CGFloat = 284
    private let hudHeight: CGFloat = 520
    private let hudGold = Color(red: 0.94, green: 0.70, blue: 0.36)
    private let reactorRed = Color(red: 0.78, green: 0.06, blue: 0.06)
    private let emberRed = Color(red: 0.34, green: 0.015, blue: 0.025)
    private let energyBlueWhite = Color(red: 0.72, green: 0.96, blue: 1.0)
    init(viewModel: PetViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? PetViewModel())
    }

    private var statusAccent: Color {
        switch viewModel.displayState {
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
                Color.white.opacity(0.08),
                Color(red: 0.25, green: 0.025, blue: 0.035).opacity(0.42),
                Color.black.opacity(0.26)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(hudGold.opacity(0.45))
                .frame(width: 48, height: 5)
                .padding(.top, 4)

            header
            heroPanel

            HStack(spacing: 8) {
                CounterView(
                    title: "今日专注",
                    value: viewModel.hudPresentation.focusCount,
                    accent: energyBlueWhite,
                    hudGold: hudGold,
                    hudPanelFill: hudPanelFill
                )
                CounterView(
                    title: "今日完成",
                    value: viewModel.hudPresentation.completionCount,
                    accent: statusAccent,
                    hudGold: hudGold,
                    hudPanelFill: hudPanelFill
                )
            }

            RefreshDiagnosticsView(
                diagnostics: viewModel.refreshDiagnostics,
                hudGold: hudGold,
                panelFill: hudPanelFill,
                authorizationAction: viewModel.requestGitScanAuthorization
            )

            HStack(spacing: 8) {
                ForEach(PetStatus.allCases) { status in
                    Button {
                        viewModel.select(status)
                    } label: {
                        Text(status.title)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .buttonStyle(
                        StatusButtonStyle(
                            isSelected: viewModel.selectedStatus == status,
                            accent: accentColor(for: status),
                            hudGold: hudGold
                        )
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: fixedWidth, height: hudHeight, alignment: .top)
        .background(hudBackground)
        .overlay(hudChrome)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(WindowConfigurator())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TINYBUDDY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(hudGold.opacity(0.92))
                Text("COMPANION HUD")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.93, blue: 0.77))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusAccent)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusAccent.opacity(0.8), radius: 5)
                    Text("STATUS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hudGold.opacity(0.82))
                }

                Text(viewModel.hudPresentation.statusTitle)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(statusAccent)
                    .lineLimit(1)
            }
        }
    }

    private var heroPanel: some View {
        HStack(alignment: .center, spacing: 14) {
            TinyBuddyArcReactorCore()
                .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                hudLabel("MOOD")

                Text(viewModel.hudPresentation.statusDisplayTitle)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(heroMessage)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusAccent)
                        .frame(width: 6, height: 6)
                    Text(viewModel.hudPresentation.statusTitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(statusAccent)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hudPanelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusAccent.opacity(0.42), lineWidth: 1)
        )
    }

    private var hudBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.005, blue: 0.012),
                        Color(red: 0.17, green: 0.018, blue: 0.035),
                        Color(red: 0.015, green: 0.012, blue: 0.016)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                reactorRed.opacity(0.34),
                                emberRed.opacity(0.16),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 170
                        )
                    )
                    .frame(width: 220, height: 220)
                    .offset(x: 70, y: 84)
            }
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                energyBlueWhite.opacity(0.16),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 90
                        )
                    )
                    .frame(width: 120, height: 120)
                    .offset(x: -24, y: -20)
            }
            .shadow(color: .black.opacity(0.38), radius: 20, x: 0, y: 12)
    }

    private var hudChrome: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        hudGold.opacity(0.62),
                        reactorRed.opacity(0.56),
                        Color.white.opacity(0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    .padding(4)
            }
            .overlay {
                VStack(spacing: 24) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle()
                            .fill(hudGold.opacity(0.07))
                            .frame(height: 0.7)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
    }

    private func hudLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(hudGold.opacity(0.78))
    }

    private var heroMessage: String {
        switch viewModel.displayState {
        case .idle:
            return "今天还没开始，选个状态让 TinyBuddy 陪你进入节奏。"
        case .focusing:
            return "保持当前专注，今天的投入会持续累积到专注统计。"
        case .completed:
            return "今天已经有完成记录，继续推进下一项也不错。"
        case .active:
            return "今天既有专注也有完成，继续保持当前节奏。"
        }
    }

    private func accentColor(for status: PetStatus) -> Color {
        switch status {
        case .idle:
            return hudGold
        case .focusing:
            return energyBlueWhite
        case .completedOnce:
            return Color(red: 0.47, green: 0.82, blue: 0.57)
        }
    }
}

private struct RefreshDiagnosticsView: View {
    let diagnostics: PetViewModel.RefreshDiagnostics
    let hudGold: Color
    let panelFill: AnyShapeStyle
    let authorizationAction: () -> Void

    init(
        diagnostics: PetViewModel.RefreshDiagnostics,
        hudGold: Color,
        panelFill: some ShapeStyle,
        authorizationAction: @escaping () -> Void
    ) {
        self.diagnostics = diagnostics
        self.hudGold = hudGold
        self.panelFill = AnyShapeStyle(panelFill)
        self.authorizationAction = authorizationAction
    }

    private var badgeColor: Color {
        switch diagnostics.outcome {
        case .succeeded:
            return Color(red: 0.31, green: 0.68, blue: 0.44)
        case .skipped:
            return Color(red: 0.89, green: 0.66, blue: 0.23)
        case .failed:
            return Color(red: 0.84, green: 0.34, blue: 0.29)
        case nil:
            return Color.white.opacity(0.42)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("REFRESH DIAGNOSTICS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hudGold.opacity(0.78))

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: badgeColor.opacity(0.75), radius: 5)
                    Text(diagnostics.badgeTitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.26))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(badgeColor.opacity(0.62), lineWidth: 1)
                )
            }

            Text(diagnostics.summary)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(diagnostics.detail)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let reason = diagnostics.reason {
                Text(reason)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(badgeColor.opacity(0.92))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle = diagnostics.actionTitle {
                Button(actionTitle, action: authorizationAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.3))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(badgeColor.opacity(0.7), lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(badgeColor.opacity(0.42), lineWidth: 1)
        )
    }
}

private struct CounterView: View {
    let title: String
    let value: Int
    let accent: Color
    let hudGold: Color
    let hudPanelFill: AnyShapeStyle

    init(title: String, value: Int, accent: Color, hudGold: Color, hudPanelFill: some ShapeStyle) {
        self.title = title
        self.value = value
        self.accent = accent
        self.hudGold = hudGold
        self.hudPanelFill = AnyShapeStyle(hudPanelFill)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(hudGold.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            Text("\(value)")
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                Text("TODAY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.92))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hudPanelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(0.36), lineWidth: 1)
        )
    }
}

private struct StatusButtonStyle: ButtonStyle {
    let isSelected: Bool
    let accent: Color
    let hudGold: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.76))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    accent.opacity(configuration.isPressed ? 0.72 : 0.88),
                                    Color.black.opacity(0.30)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.12 : 0.08))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? accent.opacity(0.72) : hudGold.opacity(0.22),
                        lineWidth: 1
                    )
            )
    }
}
