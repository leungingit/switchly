//
//  GachaHeaderViews.swift
//  Switchly
//
//  Header pieces of the gacha card: animated weather glyphs (the number shows
//  on hover) and the glowing "Again" button. Motion stops under Reduce Motion.
//

import SwiftUI

/// Condition, temperature, wind and season as small animated symbols.
struct WeatherGlyphBar: View {
    let weather: WeatherSnapshot
    let language: AppLanguage

    private struct Glyph: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let value: String
        let motion: (Double) -> (dx: CGFloat, dy: CGFloat, angle: Double, scale: CGFloat, opacity: Double)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: MotionTokens.reduceMotion)) { context in
            let t = MotionTokens.reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(glyphs) { glyph in
                    WeatherGlyphView(symbol: glyph.symbol, tint: glyph.tint, value: glyph.value, motion: glyph.motion(t))
                }
            }
        }
    }

    private var glyphs: [Glyph] {
        let temp = weather.temperatureCelsius, wind = weather.windSpeedKmh
        let windPace = 1.5 + min(wind, 80) / 12
        let windReach = CGFloat(1.5 + min(wind, 80) / 30)
        let tempSymbol = temp <= 5 ? "thermometer.snowflake" : (temp <= 24 ? "thermometer" : "thermometer.sun")
        let tempTint: Color = temp <= 5 ? .cyan : (temp <= 24 ? .green : (temp <= 32 ? .orange : .red))
        return [
            Glyph(id: "condition", symbol: weather.condition.symbol, tint: conditionTint,
                  value: t(weather.condition.titleKey), motion: conditionMotion),
            Glyph(id: "temperature", symbol: tempSymbol, tint: tempTint, value: "\(Int(temp)) °C") { t in
                (0, 0, 0, 1 + 0.08 * CGFloat(sin(t * (2 + max(temp, 0) / 15))), 1)
            },
            Glyph(id: "wind", symbol: "wind", tint: .teal, value: "\(Int(wind)) km/h") { t in
                (windReach * CGFloat(sin(t * windPace)), 0, sin(t * windPace) * 4, 1, 1)
            },
            Glyph(id: "season", symbol: seasonSymbol, tint: seasonTint, value: t(weather.season.titleKey)) { t in
                (CGFloat(sin(t * 1.6)) * 1.5, CGFloat(sin(t * 3.2)) * 1.2, sin(t * 1.6) * 16, 1, 1)
            }
        ]
    }

    private var conditionTint: Color {
        switch weather.condition {
        case .clear: return .yellow
        case .cloudy: return .gray
        case .rain: return .blue
        case .snow: return .cyan
        case .fog: return .secondary
        case .storm: return .indigo
        }
    }

    private func conditionMotion(_ t: Double) -> (dx: CGFloat, dy: CGFloat, angle: Double, scale: CGFloat, opacity: Double) {
        switch weather.condition {
        case .clear: return (0, 0, t * 40, 1 + 0.08 * CGFloat(sin(t * 2)), 1)
        case .cloudy: return (CGFloat(sin(t * 1.1)) * 2.5, 0, 0, 1, 1)
        case .rain: return (0, CGFloat(sin(t * 5)) * 1.6, 0, 1, 1)
        case .snow: return (CGFloat(sin(t * 1.4)) * 1.5, CGFloat(sin(t * 2.2)) * 1.5, sin(t * 1.4) * 14, 1, 1)
        case .fog: return (0, 0, 0, 1, 0.55 + 0.45 * sin(t * 1.3))
        case .storm: return (0, 0, 0, 1, 0.45 + 0.55 * pow(max(0, sin(t * 4.5)), 8))
        }
    }

    private var seasonSymbol: String {
        switch weather.season {
        case .spring: return "leaf"
        case .summer: return "flame"
        case .autumn: return "leaf.fill"
        case .winter: return "snowflake"
        }
    }

    private var seasonTint: Color {
        switch weather.season {
        case .spring: return .green
        case .summer: return .orange
        case .autumn: return .brown
        case .winter: return .cyan
        }
    }

    private func t(_ key: String) -> String { language.localizedString(key) }
}

/// One symbol; hovering expands it to show the real value next to it.
private struct WeatherGlyphView: View {
    let symbol: String
    let tint: Color
    let value: String
    let motion: (dx: CGFloat, dy: CGFloat, angle: Double, scale: CGFloat, opacity: Double)
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .shadow(color: tint.opacity(isHovered ? 0.9 : 0.45), radius: isHovered ? 5 : 2.5)
                .rotationEffect(.degrees(motion.angle))
                .scaleEffect(motion.scale)
                .offset(x: motion.dx, y: motion.dy)
                .opacity(motion.opacity)
                .frame(width: 18, height: 18)
            if isHovered {
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
                    .fixedSize()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.horizontal, isHovered ? 6 : 2)
        .background(Capsule().fill(tint.opacity(isHovered ? 0.16 : 0)))
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(MotionTokens.animated(.spring(response: 0.3, dampingFraction: 0.75))) { isHovered = hovering }
        }
        .help(value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value)
    }
}

/// Glowing capsule with a travelling sheen; the arrow spins on hover.
struct GachaAgainButton: View {
    let title: String
    var isCompact = false
    let action: () -> Void
    @State private var isHovered = false
    @State private var spin = 0.0

    private var palette: [Color] { GachaRarity.epic.palette }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise")
                    .rotationEffect(.degrees(spin))
                Text(title)
            }
            .font((isCompact ? Font.caption : Font.callout).weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, isCompact ? DesignTokens.Spacing.md : DesignTokens.Spacing.lg)
            .padding(.vertical, isCompact ? 4 : DesignTokens.Spacing.sm)
            .background(
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: MotionTokens.reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    // Sheen sweeps left to right every ~2.4 s.
                    let sweep = CGFloat(t.truncatingRemainder(dividingBy: 2.4) / 2.4)
                    ZStack {
                        Capsule().fill(LinearGradient(colors: palette, startPoint: .leading, endPoint: .trailing))
                        if !MotionTokens.reduceMotion {
                            GeometryReader { geo in
                                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: geo.size.width * 0.35)
                                    .rotationEffect(.degrees(20))
                                    .offset(x: -geo.size.width * 0.35 + sweep * geo.size.width * 1.7)
                            }
                            .clipShape(Capsule())
                        }
                        Capsule().strokeBorder(.white.opacity(isHovered ? 0.85 : 0.45), lineWidth: 1)
                    }
                }
            )
            .shadow(color: GachaRarity.epic.glow.opacity(isHovered ? 0.9 : 0.55), radius: isHovered ? 10 : 6)
            .scaleEffect(isHovered ? 1.06 : 1)
        }
        .buttonStyle(GachaPressStyle())
        .onHover { hovering in
            withAnimation(MotionTokens.animated(.spring(response: 0.3, dampingFraction: 0.65))) {
                isHovered = hovering
                if hovering { spin -= 360 }
            }
        }
        .accessibilityLabel(title)
    }
}

private struct GachaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.microDuration)), value: configuration.isPressed)
    }
}
