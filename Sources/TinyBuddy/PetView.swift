import SwiftUI
import TinyBuddyCore

@MainActor
struct PetView: View {
    @StateObject private var viewModel: PetViewModel

    init(viewModel: PetViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? PetViewModel())
    }

    var body: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 48, height: 5)
                .padding(.top, 10)

            VStack(spacing: 8) {
                Text("TinyBuddy")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(viewModel.status.shortMood)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            PetFace(status: viewModel.status)
                .frame(width: 148, height: 132)
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                CounterView(title: "今日专注", value: viewModel.stats.focusCount)
                CounterView(title: "今日完成", value: viewModel.stats.completionCount)
            }

            HStack(spacing: 8) {
                ForEach(PetStatus.allCases) { status in
                    Button {
                        viewModel.select(status)
                    } label: {
                        Text(status.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(StatusButtonStyle(isSelected: viewModel.status == status))
                }
            }
        }
        .padding(14)
        .frame(width: 260, height: 320)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 1)
        )
        .background(WindowConfigurator())
    }
}

private struct PetFace: View {
    let status: PetStatus

    private var bodyColor: Color {
        switch status {
        case .idle:
            return Color(red: 0.98, green: 0.77, blue: 0.42)
        case .focusing:
            return Color(red: 0.43, green: 0.75, blue: 0.91)
        case .completedOnce:
            return Color(red: 0.47, green: 0.82, blue: 0.57)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(bodyColor.opacity(0.18))
                .frame(width: 132, height: 132)

            Circle()
                .fill(bodyColor)
                .frame(width: 110, height: 110)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Color.white.opacity(0.34))
                        .frame(width: 38, height: 38)
                        .offset(x: 18, y: 16)
                }

            HStack(spacing: 54) {
                Circle()
                    .fill(bodyColor)
                    .frame(width: 36, height: 36)
                    .offset(y: -52)
                    .rotationEffect(.degrees(-16))
                Circle()
                    .fill(bodyColor)
                    .frame(width: 36, height: 36)
                    .offset(y: -52)
                    .rotationEffect(.degrees(16))
            }

            HStack(spacing: 22) {
                Eye(status: status)
                Eye(status: status)
            }
            .offset(y: -10)

            Mouth(status: status)
                .stroke(Color.black.opacity(0.72), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 38, height: 22)
                .offset(y: 22)
        }
    }
}

private struct Eye: View {
    let status: PetStatus

    var body: some View {
        switch status {
        case .idle:
            Circle()
                .fill(Color.black.opacity(0.74))
                .frame(width: 12, height: 12)
        case .focusing:
            Capsule()
                .fill(Color.black.opacity(0.74))
                .frame(width: 16, height: 5)
        case .completedOnce:
            Text("★")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.74))
        }
    }
}

private struct Mouth: Shape {
    let status: PetStatus

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch status {
        case .idle:
            path.move(to: CGPoint(x: rect.minX + 8, y: rect.midY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - 8, y: rect.midY),
                control: CGPoint(x: rect.midX, y: rect.maxY - 2)
            )
        case .focusing:
            path.move(to: CGPoint(x: rect.minX + 8, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.midY))
        case .completedOnce:
            path.move(to: CGPoint(x: rect.minX + 6, y: rect.minY + 4))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - 6, y: rect.minY + 4),
                control: CGPoint(x: rect.midX, y: rect.maxY + 6)
            )
        }
        return path
    }
}

private struct CounterView: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.28))
        )
    }
}

private struct StatusButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.white.opacity(configuration.isPressed ? 0.42 : 0.24))
            )
    }
}
