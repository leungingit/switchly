//
//  GachaBackdrop.swift
//  Switchly
//
//  Slow colour blobs plus ripples behind the gacha stage. The ripples pulse on
//  the beat while a song is audible. Kept faint so cards and text stay in front;
//  static under Reduce Motion.
//

import SwiftUI

struct GachaBackdrop: View {
    let colors: [Color]
    let bpm: Double
    let isBeating: Bool
    private static let defaultBPM = 100.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: MotionTokens.reduceMotion)) { context in
            let t = MotionTokens.reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let beat = (bpm > 0 ? bpm : Self.defaultBPM) / 60
            let pulse = isBeating && !MotionTokens.reduceMotion ? pow(abs(sin(.pi * beat * t)), 3) : 0
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let a = t * (0.35 + 0.12 * Double(i)) + Double(i) * 2.1
                        Circle()
                            .fill(colors[i % colors.count])
                            .frame(width: w * 0.7, height: w * 0.7)
                            .blur(radius: 34)
                            .opacity(0.20 + 0.10 * pulse)
                            .position(x: w * (0.5 + 0.32 * cos(a)), y: h * (0.5 + 0.30 * sin(a * 1.3)))
                    }
                    // Ripples spreading from the centre once per two beats.
                    ForEach(0..<3, id: \.self) { i in
                        let phase = (t * beat * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .strokeBorder(colors[i % colors.count], lineWidth: 1.5)
                            .frame(width: w * (0.3 + 0.9 * phase), height: w * (0.3 + 0.9 * phase))
                            .opacity((1 - phase) * (isBeating ? 0.22 : 0.10))
                            .position(x: w / 2, y: h * 0.45)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
