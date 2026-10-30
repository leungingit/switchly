//
//  GachaNotes.swift
//  Switchly
//
//  Staff-style eighth notes that hop in place on the beat while a gacha song
//  plays. They sit still under Reduce Motion or while nothing is audible.
//

import SwiftUI

/// A filled eighth note (♪): tilted oval head, stem and flag.
struct MusicNoteShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        // Head: an oval tilted up to the right, as engraved on a staff.
        let head = CGRect(x: -0.30 * w, y: -0.19 * h, width: 0.60 * w, height: 0.38 * h)
        let transform = CGAffineTransform(translationX: rect.minX + 0.32 * w, y: rect.minY + 0.80 * h)
            .rotated(by: -.pi / 9)
        path.addPath(Path(ellipseIn: head), transform: transform)
        // Stem on the right edge of the head.
        let stemX = rect.minX + 0.56 * w
        path.addRect(CGRect(x: stemX - 0.045 * w, y: rect.minY + 0.06 * h, width: 0.09 * w, height: 0.74 * h))
        // Flag swinging out from the stem top.
        var flag = Path()
        flag.move(to: CGPoint(x: stemX, y: rect.minY + 0.06 * h))
        flag.addCurve(to: CGPoint(x: rect.minX + 0.94 * w, y: rect.minY + 0.52 * h),
                      control1: CGPoint(x: stemX + 0.10 * w, y: rect.minY + 0.34 * h),
                      control2: CGPoint(x: rect.minX + 0.98 * w, y: rect.minY + 0.30 * h))
        flag.addCurve(to: CGPoint(x: stemX, y: rect.minY + 0.30 * h),
                      control1: CGPoint(x: rect.minX + 0.86 * w, y: rect.minY + 0.38 * h),
                      control2: CGPoint(x: stemX + 0.12 * w, y: rect.minY + 0.28 * h))
        flag.closeSubpath()
        path.addPath(flag)
        return path
    }
}

/// Notes that dance on the beat. `bpm` ≤ 0 falls back to a steady pulse.
struct DancingNotes: View {
    let bpm: Double
    let isActive: Bool
    let accent: Color
    private static let defaultBPM = 100.0
    /// Per-note beat offset, hop height and size, so they never move in lockstep.
    private static let notes: [(phase: Double, hop: Double, size: CGFloat, dx: CGFloat)] = [
        (0.0, 7, 17, -7), (0.5, 9, 14, 8)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive || MotionTokens.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let beat = (bpm > 0 ? bpm : Self.defaultBPM) / 60
            ZStack {
                ForEach(0..<Self.notes.count, id: \.self) { i in
                    note(Self.notes[i], t: t, beat: beat)
                }
            }
        }
    }

    private func note(_ spec: (phase: Double, hop: Double, size: CGFloat, dx: CGFloat), t: TimeInterval, beat: Double) -> some View {
        let animated = isActive && !MotionTokens.reduceMotion
        // 0 on the downbeat, 1 at the top of the hop; |sin|^p gives a bouncy arc.
        let cycle = beat * t + spec.phase
        let arc = animated ? abs(sin(.pi * cycle)) : 0
        let lift = animated ? pow(arc, 0.8) : 0
        // Squash when it lands, stretch while in the air.
        let squash = animated ? 1 - 0.18 * pow(1 - arc, 6) : 1
        let sway = animated ? sin(.pi * cycle) * 10 : 0
        return MusicNoteShape()
            .fill(LinearGradient(colors: [.white, accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            .shadow(color: accent.opacity(0.9), radius: animated ? 3 + 4 * lift : 2)
            .frame(width: spec.size * 0.9, height: spec.size)
            .scaleEffect(x: 1 / squash, y: squash, anchor: .bottom)
            .rotationEffect(.degrees(sway), anchor: .bottom)
            .offset(x: spec.dx, y: 4 - spec.hop * lift)
    }
}
