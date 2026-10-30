//
//  GachaCardView.swift
//  Switchly
//
//  One gacha card. Rarity sets the material: common is cool matte glass,
//  rare adds a drifting sheen, epic a holographic gradient with a pulsing
//  glow. The kind (mood / genre / scene) sets the symbol and tag.
//

import SwiftUI

extension GachaRarity {
    var palette: [Color] {
        switch self {
        case .common: return [Color(red: 0.43, green: 0.66, blue: 1.0), Color(red: 0.25, green: 0.33, blue: 0.62)]
        case .rare: return [Color(red: 0.31, green: 0.82, blue: 0.77), Color(red: 0.55, green: 0.48, blue: 1.0)]
        case .epic: return [Color(red: 1.0, green: 0.70, blue: 0.28), Color(red: 1.0, green: 0.36, blue: 0.60), Color(red: 0.62, green: 0.35, blue: 1.0)]
        }
    }

    var glow: Color { palette[0] }
    var burstSheet: String {
        switch self {
        case .common: return "burst_common"
        case .rare: return "burst_rare"
        case .epic: return "burst_epic"
        }
    }
}

extension GachaCardKind {
    var symbol: String {
        switch self {
        case .mood: return "face.smiling"
        case .genre: return "music.note"
        case .scene: return "photo"
        }
    }

    var tagKey: String { "gacha.kind.\(rawValue)" }
}

extension GachaCard {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    /// Per-card look (colours + symbol); rarity only drives the effects on top.
    private var theme: (colors: [Color], symbol: String)? {
        let c = Self.rgb
        switch id {
        case "mood.calm": return ([c(0.45, 0.75, 0.85), c(0.30, 0.45, 0.75)], "moon.stars")
        case "mood.cozy": return ([c(0.95, 0.62, 0.38), c(0.70, 0.35, 0.30)], "cup.and.saucer")
        case "mood.bright": return ([c(1.0, 0.85, 0.30), c(1.0, 0.55, 0.25)], "sun.max")
        case "mood.melancholy": return ([c(0.55, 0.60, 0.80), c(0.30, 0.30, 0.55)], "cloud.rain")
        case "mood.euphoric": return ([c(1.0, 0.45, 0.75), c(0.65, 0.40, 1.0), c(0.30, 0.80, 1.0)], "sparkles")
        case "mood.dramatic": return ([c(0.95, 0.30, 0.35), c(0.60, 0.30, 0.85), c(0.20, 0.15, 0.40)], "bolt.fill")
        case "genre.lofi": return ([c(0.80, 0.60, 0.85), c(0.40, 0.40, 0.70)], "headphones")
        case "genre.jazz": return ([c(0.85, 0.60, 0.30), c(0.30, 0.20, 0.40)], "music.mic")
        case "genre.pop": return ([c(1.0, 0.55, 0.70), c(1.0, 0.75, 0.40)], "heart.fill")
        case "genre.rock": return ([c(0.85, 0.25, 0.30), c(0.20, 0.20, 0.28)], "speaker.wave.3.fill")
        case "genre.classical": return ([c(0.92, 0.84, 0.66), c(0.55, 0.45, 0.38)], "music.quarternote.3")
        case "genre.electronic": return ([c(0.20, 0.90, 0.95), c(0.60, 0.30, 1.0), c(1.0, 0.30, 0.80)], "waveform")
        case "scene.rainyWindow": return ([c(0.45, 0.65, 0.80), c(0.25, 0.35, 0.50)], "cloud.drizzle")
        case "scene.morningWalk": return ([c(1.0, 0.78, 0.50), c(0.55, 0.80, 0.65)], "sunrise")
        case "scene.beachDrive": return ([c(0.30, 0.80, 0.85), c(1.0, 0.70, 0.40)], "car")
        case "scene.fireside": return ([c(1.0, 0.60, 0.25), c(0.55, 0.20, 0.20)], "flame")
        case "scene.snowfall": return ([c(0.80, 0.92, 1.0), c(0.50, 0.65, 0.90), c(0.75, 0.70, 1.0)], "snowflake")
        case "scene.windRider": return ([c(0.40, 0.85, 0.70), c(0.25, 0.45, 0.85), c(0.70, 0.55, 1.0)], "wind")
        default: return nil
        }
    }

    var palette: [Color] { theme?.colors ?? rarity.palette }
    var glow: Color { palette[0] }
    var symbol: String { theme?.symbol ?? kind.symbol }
}

struct GachaCardView: View {
    let card: GachaCard
    let language: AppLanguage
    var isHighlighted = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
    }

    var body: some View {
        shape
            .fill(LinearGradient(colors: card.palette, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.22)],
                                               startPoint: .top, endPoint: .bottom)))
            .overlay(sheen)
            .overlay(content)
            .overlay(shape.strokeBorder(
                AngularGradient(colors: [.white.opacity(0.9), card.glow.opacity(0.2), .white.opacity(0.7), card.glow.opacity(0.3), .white.opacity(0.9)],
                                center: .center),
                lineWidth: card.rarity == .common ? 1 : 1.5))
            .aspectRatio(0.72, contentMode: .fit)
            .background(glowBackdrop)
            .scaleEffect(isHighlighted ? 1.06 : 1)
            .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.microDuration)), value: isHighlighted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(language.localizedString(card.kind.tagKey)): \(language.localizedString("gacha.card.\(card.id)")), \(language.localizedString("gacha.rarity.\(card.rarity.rawValue)"))")
    }

    private var content: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text(language.localizedString(card.kind.tagKey))
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .opacity(0.8)
            Spacer(minLength: 0)
            Image(systemName: card.symbol)
                .font(.system(size: 26, weight: .semibold))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            Text(language.localizedString("gacha.card.\(card.id)"))
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(0...card.rarity.rawValue, id: \.self) { _ in
                    Image(systemName: "star.fill").font(.system(size: 8))
                }
            }
        }
        .foregroundColor(.white)
        .padding(DesignTokens.Spacing.sm)
    }

    /// Moving highlight for rare and epic cards; static under Reduce Motion.
    @ViewBuilder private var sheen: some View {
        if card.rarity != .common {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: MotionTokens.reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = MotionTokens.reduceMotion ? 0.3 : (t * (card.rarity == .epic ? 0.45 : 0.3)).truncatingRemainder(dividingBy: 1)
                LinearGradient(colors: [.clear, .white.opacity(card.rarity == .epic ? 0.55 : 0.35), .clear],
                               startPoint: UnitPoint(x: phase * 2 - 0.8, y: 0),
                               endPoint: UnitPoint(x: phase * 2 - 0.2, y: 1))
                    .blendMode(.plusLighter)
                    .clipShape(shape)
            }
        }
    }

    private var glowBackdrop: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: MotionTokens.reduceMotion || card.rarity != .epic)) { context in
            let pulse = card.rarity == .epic && !MotionTokens.reduceMotion
                ? 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 3) : 0.5
            shape
                .fill(card.glow)
                .blur(radius: 10 + CGFloat(card.rarity.rawValue) * 4 + CGFloat(pulse) * 4)
                .opacity(0.25 + 0.18 * Double(card.rarity.rawValue) + 0.2 * pulse)
        }
    }
}
