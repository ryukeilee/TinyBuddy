import SwiftUI

private typealias HUDTheme = TinyBuddyHUDTheme

public struct TinyBuddyArcReactorCore: View {
    public var showsLabel: Bool

    public init(showsLabel: Bool = true) {
        self.showsLabel = showsLabel
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            HUDTheme.darkMetal.opacity(0.98),
                            Color(red: 0.11, green: 0.025, blue: 0.03),
                            Color.black.opacity(0.92)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 50
                    )
                )
                .shadow(color: HUDTheme.reactorRed.opacity(0.22), radius: 11)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.16),
                            HUDTheme.energyBlueWhite.opacity(0.58),
                            HUDTheme.energyBlueWhite.opacity(0.18),
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
                            HUDTheme.energyBlueWhite.opacity(0.28),
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
                            HUDTheme.hudGold.opacity(0.60),
                            HUDTheme.reactorRed.opacity(0.72),
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
                                HUDTheme.hudGold.opacity(0.96),
                                Color(red: 0.70, green: 0.28, blue: 0.14),
                                HUDTheme.reactorRed.opacity(0.72)
                            ] : [
                                Color(red: 0.42, green: 0.12, blue: 0.10),
                                HUDTheme.hudGold.opacity(0.72),
                                HUDTheme.reactorRed.opacity(0.64)
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
                        color: index.isMultiple(of: 4)
                        ? HUDTheme.hudGold.opacity(0.18)
                        : HUDTheme.reactorRed.opacity(0.14),
                        radius: 2
                    )
            }

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            HUDTheme.energyBlueWhite.opacity(0.16),
                            .white.opacity(0.95),
                            HUDTheme.energyBlueWhite.opacity(0.96),
                            Color(red: 0.45, green: 0.82, blue: 0.95).opacity(0.68),
                            HUDTheme.energyBlueWhite.opacity(0.16)
                        ],
                        center: .center
                    ),
                    lineWidth: 4.8
                )
                .frame(width: 72, height: 72)
                .shadow(color: HUDTheme.energyBlueWhite.opacity(0.62), radius: 12)

            Circle()
                .stroke(HUDTheme.energyBlueWhite.opacity(0.24), lineWidth: 1.2)
                .frame(width: 88, height: 88)
                .blur(radius: 0.2)

            Circle()
                .stroke(HUDTheme.hudGold.opacity(0.50), lineWidth: 1.2)
                .frame(width: 62, height: 62)

            ForEach(0..<3, id: \.self) { index in
                TinyBuddyReactorBraceShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.19, green: 0.06, blue: 0.05),
                                HUDTheme.hudGold.opacity(0.92),
                                HUDTheme.reactorRed.opacity(0.72),
                                HUDTheme.darkMetal.opacity(0.96)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        TinyBuddyReactorBraceShape()
                            .stroke(HUDTheme.hudGold.opacity(0.34), lineWidth: 0.8)
                    }
                    .frame(width: 28, height: 34)
                    .offset(y: -15)
                    .rotationEffect(.degrees(Double(index) * 120))
                    .shadow(color: HUDTheme.reactorRed.opacity(0.24), radius: 4, y: 1)
            }

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            .white.opacity(0.98),
                            HUDTheme.energyBlueWhite.opacity(0.94),
                            .white.opacity(0.82),
                            HUDTheme.energyBlueWhite.opacity(0.36)
                        ],
                        center: .center
                    ),
                    lineWidth: 5.2
                )
                .frame(width: 46, height: 46)
                .shadow(color: HUDTheme.energyBlueWhite.opacity(0.68), radius: 9)

            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .trim(from: 0.12, to: 0.20)
                    .stroke(
                        index.isMultiple(of: 2)
                        ? HUDTheme.hudGold.opacity(0.88)
                        : HUDTheme.reactorRed.opacity(0.64),
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
                            HUDTheme.energyBlueWhite.opacity(0.96),
                            Color(red: 0.18, green: 0.50, blue: 0.68).opacity(0.56),
                            Color(red: 0.07, green: 0.16, blue: 0.22).opacity(0.28)
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 21
                    )
                )
                .frame(width: 28, height: 28)
                .shadow(color: HUDTheme.energyBlueWhite.opacity(0.95), radius: 13)

            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 11, height: 11)
                .blur(radius: 0.5)

            ForEach(0..<3, id: \.self) { index in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(HUDTheme.hudGold.opacity(0.92))
                        .frame(width: 10, height: 1.8)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(HUDTheme.reactorRed.opacity(0.68))
                        .frame(width: 6, height: 1.4)
                }
                .offset(y: -43)
                .rotationEffect(.degrees(Double(index) * 120))
            }
        }
        .overlay(alignment: .bottom) {
            if showsLabel {
                Text("CORE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(HUDTheme.hudGold.opacity(0.88))
            }
        }
    }
}

public struct TinyBuddyReactorBraceShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
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
