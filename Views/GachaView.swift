//
//  GachaView.swift
//  Switchly
//
//  The weather gacha card in the Music Dock preview. The stage runs the
//  phases of GachaViewModel: countdown, cards dealt, the other two shatter,
//  the chosen card moves to the middle and reveals the song, then the play
//  button turns into beat bars while it plays. Animations are skipped or
//  reduced under Reduce Motion.
//

import SwiftUI

struct GachaView: View {
    @ObservedObject var model: GachaViewModel
    let language: AppLanguage
    @State private var burstSheet = GachaRarity.common.burstSheet
    @State private var burstTrigger = 0
    @State private var hoveredID: String?

    private static let stageHeight: CGFloat = 244
    private static let cardSpacing: CGFloat = 10

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            header
            stage
        }
        .padding(DesignTokens.Spacing.md)
        .cardSurface(fill: Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onAppear { model.startIfIdle() }
        .onChange(of: model.phase) { phase in burst(for: phase) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: model.weather.condition.symbol)
            Text(summary).font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            if case .playing = model.phase {
                Button { model.startRound() } label: {
                    Label(t("Again"), systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .transition(.opacity)
            }
        }
        .frame(height: 22)
        .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.stateDuration)), value: model.phase.chosenID)
    }

    private var summary: String {
        let w = model.weather
        return "\(t(w.condition.titleKey)) · \(Int(w.temperatureCelsius)) °C · \(Int(w.windSpeedKmh)) km/h · \(t(w.season.titleKey))"
    }

    // MARK: - Stage

    private var stage: some View {
        GeometryReader { geo in
            let cardW = min((geo.size.width - 2 * Self.cardSpacing) / 3, 92)
            let cardH = cardW / 0.72
            let midX = geo.size.width / 2
            let cardY = cardH / 2 + 8
            ZStack {
                if case .countdown(let n) = model.phase {
                    countdown(n).position(x: midX, y: cardY)
                }
                BurstSprite(sheet: burstSheet, trigger: burstTrigger)
                    .frame(width: 220, height: 220)
                    .position(x: midX, y: cardY)
                ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                    cardSlot(card, index: index, size: CGSize(width: cardW, height: cardH),
                             slotX: midX + CGFloat(index - 1) * (cardW + Self.cardSpacing), midX: midX, y: cardY)
                }
                caption(width: geo.size.width).position(x: midX, y: cardY + cardH / 2 + 34)
                action.position(x: midX, y: Self.stageHeight - 26)
            }
        }
        .frame(height: Self.stageHeight)
    }

    private func cardSlot(_ card: GachaCard, index: Int, size: CGSize, slotX: CGFloat, midX: CGFloat, y: CGFloat) -> some View {
        let chosenID = model.phase.chosenID
        let isChosen = chosenID == card.id
        let isDealt: Bool = {
            switch model.phase {
            case .idle, .countdown, .failed: return false
            default: return true
            }
        }()
        let isChoosing = model.phase == .choosing
        return ShatterView(isShattered: chosenID != nil && !isChosen) {
            GachaCardView(card: card, language: language, isHighlighted: isChoosing && hoveredID == card.id)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(isDealt ? (isChosen ? 1.1 : 1) : 0.2)
        .rotationEffect(.degrees(isDealt ? 0 : Double(index - 1) * 28))
        .opacity(isDealt ? 1 : 0)
        .position(x: isDealt && !isChosen ? slotX : midX, y: y)
        .animation(MotionTokens.animated(.spring(response: 0.55, dampingFraction: 0.7).delay(isChoosing ? Double(index) * 0.12 : 0)), value: isDealt)
        .animation(MotionTokens.animated(.easeInOut(duration: 1.0)), value: isChosen)
        .onHover { hoveredID = $0 ? card.id : (hoveredID == card.id ? nil : hoveredID) }
        .onTapGesture { if isChoosing { model.choose(card) } }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isChoosing { model.choose(card) } }
    }

    private func countdown(_ n: Int) -> some View {
        ZStack {
            Circle()
                .strokeBorder(LinearGradient(colors: GachaRarity.epic.palette, startPoint: .top, endPoint: .bottom), lineWidth: 3)
                .frame(width: 96, height: 96)
                .blur(radius: 1)
            Text("\(n)")
                .font(.system(size: 60, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: GachaRarity.epic.palette, startPoint: .top, endPoint: .bottom))
                .shadow(color: GachaRarity.epic.glow.opacity(0.8), radius: 12)
        }
        .id(n)
        .transition(.asymmetric(insertion: .scale(scale: 1.9).combined(with: .opacity), removal: .scale(scale: 0.5).combined(with: .opacity)))
        .animation(MotionTokens.animated(.spring(response: 0.4, dampingFraction: 0.6)), value: n)
    }

    @ViewBuilder private func caption(width: CGFloat) -> some View {
        switch model.phase {
        case .choosing:
            Text(t("Pick one card to reveal your song.")).font(.caption).foregroundColor(.secondary)
        case .revealed, .playing, .finished:
            if let track = model.track {
                VStack(spacing: 2) {
                    Text(track.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if !track.artist.isEmpty { Text(track.artist).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                }
                .frame(maxWidth: width - 16)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        case .failed(let failure):
            Text(message(for: failure)).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var action: some View {
        switch model.phase {
        case .revealed(let id), .playing(let id):
            let isPlaying = { if case .playing = model.phase { return true } else { return false } }()
            MagicPlayButton(isPlaying: isPlaying, isAudible: model.isAudible, bpm: model.track?.bpm ?? 0,
                            accent: rarity(of: id).glow, label: t("Play"), action: { model.play() })
                .transition(.scale.combined(with: .opacity))
        case .finished, .failed:
            againPill
        default:
            EmptyView()
        }
    }

    private var againPill: some View {
        Button { model.startRound() } label: {
            Label(t("Again"), systemImage: "arrow.counterclockwise")
                .font(.callout.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(Capsule().fill(LinearGradient(colors: GachaRarity.epic.palette, startPoint: .leading, endPoint: .trailing)))
                .shadow(color: GachaRarity.epic.glow.opacity(0.6), radius: 8)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Helpers

    private func burst(for phase: GachaPhase) {
        switch phase {
        case .countdown(let n):
            burstSheet = [GachaRarity.epic, .rare, .common][max(0, min(2, n - 1))].burstSheet
        case .choosing:
            burstSheet = (model.cards.map(\.rarity).max() ?? .common).burstSheet
        case .revealed(let id):
            burstSheet = rarity(of: id).burstSheet
        default:
            return
        }
        burstTrigger += 1
    }

    private func rarity(of id: String) -> GachaRarity {
        model.cards.first { $0.id == id }?.rarity ?? .common
    }

    private func message(for failure: GachaFailure) -> String {
        switch failure {
        case .libraryEmpty: return t("Your Music library has no songs.")
        case .needsAuthorization: return t("Allow Switchly to control Music, then draw again.")
        case .musicNotRunning: return t("Open Music first, then draw again.")
        case .failed: return t("Couldn't play a song.")
        }
    }

    private func t(_ key: String) -> String { language.localizedString(key) }
}
