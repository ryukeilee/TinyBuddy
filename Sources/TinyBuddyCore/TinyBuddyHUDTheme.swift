import SwiftUI

public enum TinyBuddyHUDTheme {
    public static let hudGold: Color = Color(red: 0.94, green: 0.70, blue: 0.36)
    public static let reactorRed: Color = Color(red: 0.78, green: 0.06, blue: 0.06)
    public static let emberRed: Color = Color(red: 0.34, green: 0.015, blue: 0.025)
    public static let energyBlueWhite: Color = Color(red: 0.72, green: 0.96, blue: 1.0)
    public static let darkMetal: Color = Color(red: 0.035, green: 0.032, blue: 0.036)
    public static let warmWhite: Color = Color(red: 1.0, green: 0.93, blue: 0.77)
    public static let completedGold: Color = Color(red: 0.98, green: 0.86, blue: 0.54)

    public static var backgroundFill: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.005, blue: 0.012),
                Color(red: 0.17, green: 0.018, blue: 0.035),
                Color(red: 0.015, green: 0.012, blue: 0.016)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var panelFill: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.075),
                Color(red: 0.25, green: 0.025, blue: 0.035).opacity(0.42),
                Color.black.opacity(0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var metricBorder: LinearGradient {
        LinearGradient(
            colors: [
                hudGold.opacity(0.38),
                reactorRed.opacity(0.34)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var chromeBorder: LinearGradient {
        LinearGradient(
            colors: [
                hudGold.opacity(0.62),
                reactorRed.opacity(0.56),
                Color.white.opacity(0.20)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var metalSheen: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.05),
                Color(red: 0.95, green: 0.42, blue: 0.24).opacity(0.03),
                Color.black.opacity(0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static func statusAccent(
        for displayState: TinyBuddyWidgetPresentation.DisplayState
    ) -> Color {
        switch displayState {
        case .idle:
            return hudGold
        case .focusing:
            return energyBlueWhite
        case .completed, .active:
            return completedGold
        }
    }
}

public struct TinyBuddyHUDBackground: View {
    private let redGlowCenter: UnitPoint
    private let blueGlowCenter: UnitPoint
    private let redGlowRadius: CGFloat
    private let blueGlowRadius: CGFloat
    private let redGlowOpacity: Double
    private let blueGlowOpacity: Double
    private let scanLineCount: Int

    public init(
        redGlowCenter: UnitPoint = .bottomTrailing,
        blueGlowCenter: UnitPoint = UnitPoint(x: 0.24, y: 0.38),
        redGlowRadius: CGFloat = 220,
        blueGlowRadius: CGFloat = 104,
        redGlowOpacity: Double = 0.40,
        blueGlowOpacity: Double = 0.12,
        scanLineCount: Int = 4
    ) {
        self.redGlowCenter = redGlowCenter
        self.blueGlowCenter = blueGlowCenter
        self.redGlowRadius = max(redGlowRadius, 1)
        self.blueGlowRadius = max(blueGlowRadius, 1)
        self.redGlowOpacity = redGlowOpacity
        self.blueGlowOpacity = blueGlowOpacity
        self.scanLineCount = max(scanLineCount, 0)
    }

    public var body: some View {
        ZStack {
            TinyBuddyHUDTheme.backgroundFill

            RadialGradient(
                colors: [
                    TinyBuddyHUDTheme.reactorRed.opacity(redGlowOpacity),
                    TinyBuddyHUDTheme.emberRed.opacity(redGlowOpacity * 0.45),
                    .clear
                ],
                center: redGlowCenter,
                startRadius: 8,
                endRadius: redGlowRadius
            )

            RadialGradient(
                colors: [
                    TinyBuddyHUDTheme.energyBlueWhite.opacity(blueGlowOpacity),
                    .clear
                ],
                center: blueGlowCenter,
                startRadius: 2,
                endRadius: blueGlowRadius
            )

            TinyBuddyHUDTheme.metalSheen
                .blendMode(.softLight)

            VStack(spacing: 0) {
                ForEach(0..<scanLineCount, id: \.self) { index in
                    Rectangle()
                        .fill(
                            index.isMultiple(of: 2)
                            ? TinyBuddyHUDTheme.hudGold.opacity(0.05)
                            : TinyBuddyHUDTheme.reactorRed.opacity(0.06)
                        )
                        .frame(height: 0.7)

                    if index < scanLineCount - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
    }
}
