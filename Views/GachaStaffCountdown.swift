//
//  GachaStaffCountdown.swift
//  Switchly
//
//  The gacha countdown drawn on a black music staff. A white note drops onto
//  the staff, crouches, hops from line to line and settles with a little
//  squash; every landing plucks the string it lands on, and gold dust drifts
//  off it mid-air. The count 3 / 2 / 1 sits on the line it stands on and
//  vanishes when it jumps. The lines ease together as it goes, the note ends on
//  the middle line, bows, and dissolves into gold dust from the top down while
//  the cards appear. `n == nil` means the countdown is over and only the dust
//  remains. Under Reduce Motion it shows a still staff with the current number.
//

import SwiftUI

struct GachaStaffCountdown: View {
    let n: Int?
    /// Seconds per number and for the closing bow, from GachaTiming.
    let step: TimeInterval
    let bow: TimeInterval
    @State private var start = Date()

    /// How long the dust lingers after the countdown ends.
    static let dustDuration: TimeInterval = 0.9

    private static let spacing: CGFloat = 9
    private static let margin: CGFloat = 10
    private static let gold = Color(red: 1.0, green: 0.82, blue: 0.35)
    /// Where 3 / 2 / 1 stand (x as a fraction of the width, staff line 0...4 from the top).
    private static let stations: [(x: CGFloat, line: CGFloat)] = [(0.10, 4), (0.25, 1), (0.40, 3)]
    private static let finish: (x: CGFloat, line: CGFloat) = (0.5, 2)
    /// Share of each step spent sitting before the hop, and the drop-in at the start.
    private static let sitShare = 0.58
    private static let intro = 0.15
    private static let crouch = 0.12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: MotionTokens.reduceMotion)) { context in
            let t = MotionTokens.reduceMotion ? 0 : context.date.timeIntervalSince(start)
            Canvas { ctx, size in draw(ctx, size: size, t: t) }
        }
        .frame(height: 84)
        .onAppear { start = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(n.map { "\($0)" } ?? "")
    }

    // MARK: - Timeline

    private struct Pose {
        var x: CGFloat
        var line: CGFloat
        var lift: CGFloat
        var lean: Double
        var sx: CGFloat
        var sy: CGFloat
    }

    private var countEnd: TimeInterval { step * 3 }
    private var hopTime: TimeInterval { step * (1 - Self.sitShare) }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
    private func smooth(_ v: Double) -> Double { let u = clamp(v); return u * u * (3 - 2 * u) }

    /// When and where the note touches the staff: the drop-in, then each hop's end.
    private var landings: [(t: TimeInterval, x: CGFloat, line: CGFloat)] {
        [(Self.intro, Self.stations[0].x, Self.stations[0].line),
         (step, Self.stations[1].x, Self.stations[1].line),
         (step * 2, Self.stations[2].x, Self.stations[2].line),
         (countEnd, Self.finish.x, Self.finish.line)]
    }

    private func pose(at t: TimeInterval) -> Pose {
        var sx: CGFloat = 1, sy: CGFloat = 1
        // Settling after a landing: a damped squash that rebounds once or twice.
        if let last = landings.last(where: { $0.t <= t }) {
            let age = t - last.t
            if age < 0.4 {
                let d = CGFloat(exp(-age * 9) * cos(age * 24))
                sy -= 0.2 * d
                sx += 0.1 * d
            }
        }
        guard t < countEnd else {
            return Pose(x: Self.finish.x, line: Self.finish.line, lift: 0, lean: 0, sx: sx, sy: sy)
        }
        if t < Self.intro {
            let u = t / Self.intro
            let s = Self.stations[0]
            return Pose(x: s.x, line: s.line, lift: 26 * CGFloat(1 - u * u), lean: 0, sx: 1, sy: 1 + 0.08 * CGFloat(u))
        }
        let k = min(2, Int(t / step))
        let from = Self.stations[k]
        let to = k < 2 ? Self.stations[k + 1] : Self.finish
        let local = t - Double(k) * step
        let hopStart = step * Self.sitShare
        let u = clamp((local - hopStart) / hopTime)
        // Crouch before launch.
        if local < hopStart, local > hopStart - Self.crouch {
            let c = CGFloat(smooth((local - (hopStart - Self.crouch)) / Self.crouch))
            sy -= 0.16 * c
            sx += 0.08 * c
        }
        let e = CGFloat(smooth(u))
        let air = CGFloat(sin(.pi * u))
        if u > 0, u < 1 {
            sy += 0.12 * air
            sx -= 0.06 * air
        }
        let sway = u == 0 ? 2.5 * sin(t * 3.4) : 0
        return Pose(x: from.x + (to.x - from.x) * e, line: from.line + (to.line - from.line) * e,
                    lift: 26 * CGFloat(4 * u * (1 - u)), lean: 16 * Double(air) + sway, sx: sx, sy: sy)
    }

    private func isHopping(at t: TimeInterval) -> Bool {
        guard t >= Self.intro, t < countEnd else { return false }
        let k = Int(t / step)
        return t - Double(k) * step >= step * Self.sitShare
    }

    /// One line's y. The outer lines lag a little behind the inner ones as the staff closes.
    private func lineY(_ i: Int, at t: TimeInterval, midY: CGFloat) -> CGFloat {
        let q = smooth(t / countEnd * 1.1 - 0.05 * Double(abs(i - 2)))
        return midY + CGFloat(i - 2) * Self.spacing * CGFloat(1 - q)
    }

    /// The staff line as a (fractional) line position, interpolated between two lines.
    private func yOnStaff(_ line: CGFloat, at t: TimeInterval, midY: CGFloat) -> CGFloat {
        let lo = Int(line.rounded(.down)), hi = min(4, lo + 1)
        let f = line - CGFloat(lo)
        return lineY(lo, at: t, midY: midY) * (1 - f) + lineY(hi, at: t, midY: midY) * f
    }

    /// Vibration of a line, rippling out from where the note last landed.
    private func pluck(line i: Int, x: CGFloat, at t: TimeInterval, width w: CGFloat) -> CGFloat {
        var sum: CGFloat = 0
        for l in landings where t >= l.t {
            let age = t - l.t
            guard age < 1.0 else { continue }
            let dist = abs(x - (Self.margin + l.x * (w - 2 * Self.margin)))
            let weight: CGFloat = abs(CGFloat(i) - l.line) < 0.5 ? 1 : 0.22
            let amp = 2.6 * CGFloat(exp(-age * 5)) * CGFloat(exp(-Double(dist) / 70)) * weight
            sum += amp * CGFloat(sin(age * 34 - Double(dist) / 9))
        }
        return sum
    }

    private func hash(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    // MARK: - Drawing

    private func draw(_ ctx: GraphicsContext, size: CGSize, t: TimeInterval) {
        let reduce = MotionTokens.reduceMotion
        let w = size.width, midY = size.height / 2 + 6
        let td = t - (countEnd + bow)
        guard reduce ? n != nil : td < Self.dustDuration else { return }
        let lineFade = reduce ? 1 : 1 - smooth(td / Self.dustDuration)
        drawStaff(ctx, width: w, midY: midY, t: reduce ? 0 : t, fade: lineFade, still: reduce)
        if reduce {
            drawStill(ctx, width: w, midY: midY)
        } else {
            drawNumbers(ctx, width: w, midY: midY, t: t)
            drawTrail(ctx, width: w, midY: midY, t: t)
            drawNoteOrDust(ctx, width: w, midY: midY, t: t, td: td)
        }
    }

    private func x(_ f: CGFloat, _ w: CGFloat) -> CGFloat { Self.margin + f * (w - 2 * Self.margin) }

    /// Black staff; a faint pale underlay keeps it readable on dark panels.
    private func drawStaff(_ ctx: GraphicsContext, width w: CGFloat, midY: CGFloat, t: TimeInterval, fade: Double, still: Bool) {
        for i in 0..<5 {
            var line = Path()
            var px = Self.margin
            while px <= w - Self.margin + 0.5 {
                let y = still ? midY + CGFloat(i - 2) * Self.spacing
                    : lineY(i, at: t, midY: midY) + pluck(line: i, x: px, at: t, width: w)
                    + 0.5 * CGFloat(sin(t * 1.7 + Double(i) * 0.9 + Double(px) * 0.03))
                if px == Self.margin { line.move(to: CGPoint(x: px, y: y)) } else { line.addLine(to: CGPoint(x: px, y: y)) }
                px += 6
            }
            ctx.stroke(line, with: .color(.white.opacity(0.22 * fade)), lineWidth: 3)
            ctx.stroke(line, with: .color(.black.opacity(0.85 * fade)), lineWidth: 1.2)
        }
    }

    private func drawStill(_ ctx: GraphicsContext, width w: CGFloat, midY: CGFloat) {
        guard let n, (1...3).contains(n) else { return }
        let s = Self.stations[3 - n]
        let y = midY + (s.line - 2) * Self.spacing
        drawNote(ctx, at: CGPoint(x: x(s.x, w), y: y), angle: 0, opacity: 1, sx: 1, sy: 1)
        drawNumber(ctx, n, at: CGPoint(x: x(s.x, w) + 16, y: y - 12), opacity: 1, scale: 1)
    }

    /// Numbers sit on their line while the note is there and drift off once it jumps.
    private func drawNumbers(_ ctx: GraphicsContext, width w: CGFloat, midY: CGFloat, t: TimeInterval) {
        for k in 0..<3 {
            let sat = t - Double(k) * step
            guard sat >= 0, sat < step else { continue }
            let appear = smooth((sat - (k == 0 ? Self.intro : 0)) / (step * 0.2))
            let hop = smooth((sat - step * Self.sitShare) / (hopTime * 0.7))
            let s = Self.stations[k]
            let y = yOnStaff(s.line, at: t, midY: midY) - 12 - 5 * CGFloat(1 - appear) - 8 * CGFloat(hop)
            drawNumber(ctx, 3 - k, at: CGPoint(x: x(s.x, w) + 16, y: y), opacity: appear * (1 - hop),
                       scale: CGFloat(0.8 + 0.2 * appear))
        }
    }

    /// Gold dust shed while hopping: it hangs back, drifts and twinkles out.
    private func drawTrail(_ ctx: GraphicsContext, width w: CGFloat, midY: CGFloat, t: TimeInterval) {
        let now = Int(t * 90)
        for idx in max(0, now - 50)...max(0, now) {
            let te = Double(idx) / 90
            guard isHopping(at: te), te <= t else { continue }
            let age = t - te
            let life = clamp(1 - age / 0.55)
            guard life > 0 else { continue }
            let p = pose(at: te)
            let ox = x(p.x, w), oy = yOnStaff(p.line, at: te, midY: midY) - p.lift
            let drift = CGFloat(sin(age * 6 + hash(idx, 7) * 6)) * 3
            let c = CGPoint(x: ox + CGFloat(hash(idx, 1) - 0.5) * 8 + drift,
                            y: oy + 2 + CGFloat(age * (10 + 22 * hash(idx, 2)) + age * age * 18))
            let twinkle = 0.7 + 0.3 * sin(age * 40 + hash(idx, 8) * 6)
            let r = CGFloat((0.8 + 1.6 * hash(idx, 3)) * twinkle * (0.5 + 0.5 * life))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 2.4, y: c.y - r * 2.4, width: r * 4.8, height: r * 4.8)),
                     with: .color(Self.gold.opacity(0.18 * life)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(Self.gold.opacity(life * life)))
        }
    }

    private func drawNoteOrDust(_ ctx: GraphicsContext, width w: CGFloat, midY: CGFloat, t: TimeInterval, td: TimeInterval) {
        let p = pose(at: t)
        let tb = clamp((t - countEnd) / max(bow, 0.001))
        // Lean forward, hold a beat, rise: eased so the bow reads as a gesture, not a tilt.
        let bowAngle = t >= countEnd ? 34 * sin(.pi * pow(tb, 0.75)) : 0
        let bowDip = t >= countEnd ? 3 * CGFloat(sin(.pi * tb)) : 0
        let dissolve = smooth(td / 0.45)
        let intro = t < Self.intro ? clamp(t / Self.intro) : 1
        let head = CGPoint(x: x(p.x, w), y: yOnStaff(p.line, at: t, midY: midY) - p.lift + bowDip - 10 * CGFloat(dissolve))
        if dissolve < 1 {
            drawNote(ctx, at: head, angle: p.lean + bowAngle, opacity: intro * (1 - dissolve),
                     sx: p.sx * CGFloat(1 + 0.08 * dissolve), sy: p.sy)
        }
        guard td >= 0 else { return }
        // Dust leaves from the top of the note first and rises before it falls.
        let origin = CGPoint(x: x(Self.finish.x, w), y: midY)
        for i in 0..<48 {
            let local = CGPoint(x: (hash(i, 4) - 0.5) * 12, y: -27 * hash(i, 5) + 2)
            let delay = (1 - (-local.y / 27)) * 0.3
            let age = td - delay
            guard age >= 0 else { continue }
            let life = clamp(1 - age / 0.55)
            guard life > 0 else { continue }
            let vx = (hash(i, 6) - 0.5) * 46, vy = -(10 + 34 * hash(i, 9))
            let c = CGPoint(x: origin.x + local.x + CGFloat(vx * age),
                            y: origin.y + local.y + CGFloat(vy * age + 90 * age * age))
            let twinkle = 0.7 + 0.3 * sin(age * 38 + hash(i, 10) * 6)
            let r = CGFloat((0.9 + 1.7 * hash(i, 11)) * twinkle * (0.5 + 0.5 * life))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 2.4, y: c.y - r * 2.4, width: r * 4.8, height: r * 4.8)),
                     with: .color(Self.gold.opacity(0.16 * life)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(Self.gold.opacity(life * life)))
        }
    }

    /// A white quarter note whose head is centred on `point` (so it sits on a line).
    private func drawNote(_ ctx: GraphicsContext, at point: CGPoint, angle: Double, opacity: Double, sx: CGFloat, sy: CGFloat) {
        var c = ctx
        c.opacity = opacity
        c.translateBy(x: point.x, y: point.y)
        c.rotate(by: .degrees(angle))
        c.scaleBy(x: sx, y: sy)
        var head = c
        head.rotate(by: .degrees(-20))
        let headPath = Path(ellipseIn: CGRect(x: -5.5, y: -4, width: 11, height: 8))
        let stem = Path(CGRect(x: 4.2, y: -27, width: 1.6, height: 26))
        c.fill(stem, with: .color(.white))
        c.stroke(stem, with: .color(.black.opacity(0.45)), lineWidth: 0.6)
        head.fill(headPath, with: .color(.white))
        head.stroke(headPath, with: .color(.black.opacity(0.45)), lineWidth: 0.6)
    }

    private func drawNumber(_ ctx: GraphicsContext, _ value: Int, at point: CGPoint, opacity: Double, scale: CGFloat) {
        guard opacity > 0 else { return }
        var c = ctx
        c.opacity = opacity
        c.translateBy(x: point.x, y: point.y)
        c.scaleBy(x: scale, y: scale)
        let text = Text("\(value)").font(.system(size: 24, weight: .bold, design: .serif).italic()).foregroundColor(Self.gold)
        c.draw(text, at: .zero)
    }
}
