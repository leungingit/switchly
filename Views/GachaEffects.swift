//
//  GachaEffects.swift
//  Switchly
//
//  Effects for the weather gacha: the Remotion-rendered burst sprite sheets,
//  a shatter exit and the play button. All of them draw nothing or sit still
//  under Reduce Motion.
//

import AppKit
import SwiftUI

/// Plays a Remotion-rendered sprite sheet (6 × 4 frames of 256 pt, 24 fps)
/// once each time `trigger` changes. Shows nothing when the sheet is missing.
struct BurstSprite: View {
    let sheet: String
    let trigger: Int
    private static let columns = 6, rows = 4, fps = 24.0
    @State private var startedAt: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: startedAt == nil)) { context in
            if let startedAt, let frame = Self.frame(sheet: sheet, at: context.date.timeIntervalSince(startedAt)) {
                Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit()
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _ in
            guard !MotionTokens.reduceMotion else { return }
            startedAt = Date()
        }
    }

    private static var sheets: [String: CGImage] = [:]

    private static func frame(sheet: String, at elapsed: TimeInterval) -> CGImage? {
        let index = Int(elapsed * fps)
        guard index >= 0, index < columns * rows else { return nil }
        if sheets[sheet] == nil {
            guard let url = Bundle.main.url(forResource: sheet, withExtension: "png", subdirectory: "Gacha"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            sheets[sheet] = image
        }
        guard let image = sheets[sheet] else { return nil }
        let w = image.width / columns, h = image.height / rows
        return image.cropping(to: CGRect(x: (index % columns) * w, y: (index / columns) * h, width: w, height: h))
    }
}

/// Breaks `content` into tiles that fly apart and fade when `isShattered`.
struct ShatterView<Content: View>: View {
    let isShattered: Bool
    let content: Content
    private static var cols: Int { 4 }
    private static var rows: Int { 6 }
    /// Flips one frame after the tiles appear so they animate away from rest.
    @State private var isFlying = false

    init(isShattered: Bool, @ViewBuilder content: () -> Content) {
        self.isShattered = isShattered
        self.content = content()
    }

    var body: some View {
        if MotionTokens.reduceMotion {
            content.opacity(isShattered ? 0 : 1)
        } else if isShattered {
            // Tiles exist only while shattering; at rest the card is one view.
            ZStack {
                ForEach(0..<(Self.cols * Self.rows), id: \.self) { i in tile(i) }
            }
            .onAppear { isFlying = true }
            .onDisappear { isFlying = false }
        } else {
            content
        }
    }

    private func tile(_ i: Int) -> some View {
        let col = i % Self.cols, row = i / Self.cols
        // Deterministic pseudo-random flight per tile.
        let a = sin(Double(i) * 12.9898) * 43758.5453
        let r = a - a.rounded(.down)
        let b = sin(Double(i) * 78.233) * 12345.678
        let r2 = b - b.rounded(.down)
        return content
            .clipShape(TileShape(cols: Self.cols, rows: Self.rows, col: col, row: row))
            .rotationEffect(.degrees(isFlying ? (r - 0.5) * 140 : 0),
                            anchor: UnitPoint(x: (Double(col) + 0.5) / Double(Self.cols), y: (Double(row) + 0.5) / Double(Self.rows)))
            .offset(x: isFlying ? (Double(col) - 1.5) * 26 + (r - 0.5) * 30 : 0,
                    y: isFlying ? 40 + r2 * 70 : 0)
            .scaleEffect(isFlying ? 0.5 : 1)
            .opacity(isFlying ? 0 : 1)
            .animation(.easeIn(duration: 0.55 + r2 * 0.25).delay(Double(row) * 0.03), value: isFlying)
    }
}

private struct TileShape: Shape {
    let cols: Int, rows: Int, col: Int, row: Int

    func path(in rect: CGRect) -> Path {
        let w = rect.width / CGFloat(cols), h = rect.height / CGFloat(rows)
        return Path(CGRect(x: rect.minX + CGFloat(col) * w, y: rect.minY + CGFloat(row) * h, width: w + 0.5, height: h + 0.5))
    }
}

/// The glowing round button: play before the song starts, dancing notes while it plays.
struct MagicPlayButton: View {
    let isPlaying: Bool
    let isAudible: Bool
    let bpm: Double
    let accent: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: MotionTokens.reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let beat = (bpm > 0 ? bpm : 100) / 60
                    let pulse = isPlaying && isAudible ? pow(abs(sin(.pi * beat * t)), 3) : 0.5 + 0.5 * sin(t * 2.5)
                    Circle()
                        .fill(accent)
                        .blur(radius: 10)
                        .scaleEffect(MotionTokens.reduceMotion ? 1.1 : 1.15 + 0.25 * pulse)
                        .opacity(0.55)
                    Circle()
                        .strokeBorder(AngularGradient(colors: [.white, accent, .white.opacity(0.2), accent, .white],
                                                      center: .center, angle: .degrees(MotionTokens.reduceMotion ? 0 : t * 90)),
                                      lineWidth: 2)
                }
                Circle().fill(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    .padding(3)
                if isPlaying {
                    DancingNotes(bpm: bpm, isActive: isAudible, accent: accent)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .bold)).foregroundColor(.white).offset(x: 1)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(isPlaying)
        .accessibilityLabel(label)
    }
}
