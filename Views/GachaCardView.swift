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

struct GachaCardView: View {
    let card: GachaCard
    let language: AppLanguage
    var isHighlighted = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
    }

    var body: some View {
        shape
            .fill(LinearGradient(colors: card.rarity.palette, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.22)],
                                               startPoint: .top, endPoint: .bottom)))
            .overlay(sheen)
            .overlay(content)
            .overlay(shape.strokeBorder(
                AngularGradient(colors: [.white.opacity(0.9), card.rarity.glow.opacity(0.2), .white.opacity(0.7), card.rarity.glow.opacity(0.3), .white.opacity(0.9)],
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
            Image(systemName: card.kind.symbol)
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
                .fill(card.rarity.glow)
                .blur(radius: 10 + CGFloat(card.rarity.rawValue) * 4 + CGFloat(pulse) * 4)
                .opacity(0.25 + 0.18 * Double(card.rarity.rawValue) + 0.2 * pulse)
        }
    }
}
