import SwiftUI

public enum TinyBuddyHUDTheme {
    public static let hudGold: Color = Color(red: 0.94, green: 0.70, blue: 0.36)
    public static let reactorRed: Color = Color(red: 0.90, green: 0.13, blue: 0.13)
    public static let emberRed: Color = Color(red: 0.34, green: 0.015, blue: 0.025)
    public static let energyBlueWhite: Color = Color(red: 0.72, green: 0.96, blue: 1.0)
    public static let darkMetal: Color = Color(red: 0.035, green: 0.032, blue: 0.036)
    public static let warmWhite: Color = Color(red: 1.0, green: 0.93, blue: 0.77)
    public static let completedGold: Color = Color(red: 0.98, green: 0.86, blue: 0.54)
    public static let warningAmber: Color = Color(red: 0.98, green: 0.56, blue: 0.16)

    public static func backgroundFill(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> LinearGradient {
        LinearGradient(
            colors: backgroundColors(
                for: colorScheme,
                increasedContrast: increasedContrast
            ),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func backgroundColors(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> [Color] {
        switch colorScheme {
        case .dark:
            return [
                Color(red: 0.05, green: 0.005, blue: 0.012),
                Color(red: 0.17, green: 0.018, blue: 0.035),
                Color(red: 0.015, green: 0.012, blue: 0.016)
            ]
        default:
            return increasedContrast
                ? [
                    Color(red: 0.98, green: 0.95, blue: 0.91),
                    Color(red: 0.92, green: 0.84, blue: 0.82),
                    Color(red: 0.96, green: 0.93, blue: 0.90)
                ]
                : [
                    Color(red: 1.0, green: 0.97, blue: 0.93),
                    Color(red: 0.96, green: 0.88, blue: 0.86),
                    Color(red: 0.99, green: 0.96, blue: 0.93)
                ]
        }
    }

    public static var backgroundFill: LinearGradient {
        backgroundFill(for: .dark)
    }

    public static func panelFill(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> LinearGradient {
        LinearGradient(
            colors: panelColors(
                for: colorScheme,
                increasedContrast: increasedContrast
            ),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func panelColors(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> [Color] {
        switch colorScheme {
        case .dark:
            return [
                Color.white.opacity(increasedContrast ? 0.14 : 0.075),
                Color(red: 0.25, green: 0.025, blue: 0.035)
                    .opacity(increasedContrast ? 0.62 : 0.42),
                Color.black.opacity(increasedContrast ? 0.34 : 0.22)
            ]
        default:
            return [
                Color.white.opacity(increasedContrast ? 0.92 : 0.78),
                Color(red: 0.94, green: 0.76, blue: 0.72)
                    .opacity(increasedContrast ? 0.78 : 0.52),
                Color(red: 0.72, green: 0.20, blue: 0.18)
                    .opacity(increasedContrast ? 0.20 : 0.10)
            ]
        }
    }

    public static var panelFill: LinearGradient {
        panelFill(for: .dark)
    }

    public static func primaryTextColor(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> Color {
        switch colorScheme {
        case .dark:
            return warmWhite.opacity(increasedContrast ? 1.0 : 0.94)
        default:
            return Color(red: 0.16, green: 0.035, blue: 0.055)
                .opacity(increasedContrast ? 1.0 : 0.90)
        }
    }

    public static func secondaryTextColor(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> Color {
        switch colorScheme {
        case .dark:
            return Color(red: 0.84, green: 0.78, blue: 0.69)
                .opacity(increasedContrast ? 0.98 : 0.72)
        default:
            return Color(red: 0.30, green: 0.12, blue: 0.14)
                .opacity(increasedContrast ? 0.94 : 0.74)
        }
    }

    /// Semantic text color for fixed HUD brand labels. Unlike `hudGold`, this
    /// remains legible on every supported light and dark background/panel stop.
    public static func brandTextColor(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> Color {
        switch colorScheme {
        case .dark:
            return increasedContrast
                ? Color(red: 1.0, green: 0.90, blue: 0.65)
                : Color(red: 1.0, green: 0.84, blue: 0.54)
        default:
            return increasedContrast
                ? Color(red: 0.22, green: 0.06, blue: 0.01)
                : Color(red: 0.32, green: 0.12, blue: 0.03)
        }
    }

    public static func panelBorder(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> Color {
        switch colorScheme {
        case .dark:
            return hudGold.opacity(increasedContrast ? 0.82 : 0.38)
        default:
            return reactorRed.opacity(increasedContrast ? 0.78 : 0.38)
        }
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
        for accentRole: TinyBuddyDisplayAccentRole,
        colorScheme: ColorScheme,
        increasedContrast: Bool = false
    ) -> Color {
        if colorScheme != .dark {
            switch accentRole {
            case .neutral:
                return increasedContrast
                    ? Color(red: 0.36, green: 0.18, blue: 0.0)
                    : Color(red: 0.55, green: 0.34, blue: 0.05)
            case .focus, .loading:
                return increasedContrast
                    ? Color(red: 0.0, green: 0.25, blue: 0.42)
                    : Color(red: 0.04, green: 0.38, blue: 0.58)
            case .success:
                return increasedContrast
                    ? Color(red: 0.32, green: 0.20, blue: 0.0)
                    : Color(red: 0.48, green: 0.33, blue: 0.02)
            case .warning:
                return increasedContrast
                    ? Color(red: 0.43, green: 0.16, blue: 0.0)
                    : Color(red: 0.62, green: 0.27, blue: 0.0)
            case .error:
                return increasedContrast
                    ? Color(red: 0.46, green: 0.0, blue: 0.02)
                    : Color(red: 0.67, green: 0.06, blue: 0.07)
            }
        }

        switch accentRole {
        case .neutral:
            return increasedContrast
                ? Color(red: 1.0, green: 0.78, blue: 0.30)
                : hudGold
        case .focus:
            return increasedContrast
                ? Color(red: 0.54, green: 0.94, blue: 1.0)
                : energyBlueWhite
        case .success:
            return increasedContrast
                ? Color(red: 1.0, green: 0.88, blue: 0.40)
                : completedGold
        case .warning:
            return increasedContrast
                ? Color(red: 1.0, green: 0.64, blue: 0.18)
                : warningAmber
        case .error:
            return increasedContrast
                ? Color(red: 1.0, green: 0.32, blue: 0.28)
                : reactorRed
        case .loading:
            return increasedContrast
                ? Color(red: 0.60, green: 0.94, blue: 1.0)
                : energyBlueWhite
        }
    }

    public static func statusAccent(
        for accentRole: TinyBuddyDisplayAccentRole,
        increasedContrast: Bool = false
    ) -> Color {
        statusAccent(
            for: accentRole,
            colorScheme: .dark,
            increasedContrast: increasedContrast
        )
    }

    public static func statusAccent(
        for displayState: TinyBuddyWidgetPresentation.DisplayState
    ) -> Color {
        switch displayState {
        case .idle:
            return statusAccent(for: .neutral)
        case .focusing:
            return statusAccent(for: .focus)
        case .completed, .active:
            return statusAccent(for: .success)
        }
    }
}

public struct TinyBuddyHUDBackground: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

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
        let increasedContrast = colorSchemeContrast == .increased

        ZStack {
            TinyBuddyHUDTheme.backgroundFill(
                for: colorScheme,
                increasedContrast: increasedContrast
            )

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
                .opacity(colorScheme == .dark ? 1 : 0.34)
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
