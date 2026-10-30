//
//  SceneEvaluator.swift
//  Switchly
//
//  Pure evaluation of a PluginScene at a point in time: tracks, oscillators,
//  eases, deterministic randomness and how long a scene keeps changing. No
//  drawing here, so it is unit-testable and shared by the renderer and hit
//  testing.
//

import Foundation

enum SceneMath {
    static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    static func ease(_ e: SceneEase, _ u: Double) -> Double {
        let u = clamp01(u)
        switch e {
        case .linear: return u
        case .in: return u * u
        case .out: return 1 - (1 - u) * (1 - u)
        case .inOut: return u * u * (3 - 2 * u)
        case .hold: return u >= 1 ? 1 : 0
        }
    }

    /// Stable pseudo-random value in 0..<1.
    static func hash(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    static func lerp(_ range: [Double], _ u: Double) -> Double { range[0] + (range[1] - range[0]) * u }
}

extension SceneTrack {
    /// Track value at `t`; the arriving key's ease shapes each segment.
    func value(at time: Double, still: Bool) -> Double {
        var t = time
        if let loop, loop > 0 { t = still ? 0 : t - (t / loop).rounded(.down) * loop }
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.t { return first.v }
        if t >= last.t { return last.v }
        let next = keys.firstIndex { $0.t > t } ?? keys.count - 1
        let a = keys[next - 1], b = keys[next]
        let u = (t - a.t) / max(b.t - a.t, 1e-6)
        return a.v + (b.v - a.v) * SceneMath.ease(b.ease, u)
    }
}

extension SceneOsc {
    func value(at t: Double) -> Double {
        guard t >= start, end.map({ t <= $0 }) ?? true else { return 0 }
        let age = t - start
        let cycles = freq * age + phase
        let shape: Double
        switch wave {
        case .sin: shape = sin(2 * .pi * cycles)
        case .abs: shape = abs(sin(.pi * cycles))
        case .pulse: shape = pow(abs(sin(.pi * cycles)), power)
        }
        return amp * shape * (decay > 0 ? exp(-decay * age) : 1)
    }

    /// Time after which this term is negligible, nil if it never settles.
    var settledAt: Double? {
        if let end { return end }
        return decay > 0 ? start + 6 / decay : nil
    }
}

extension SceneLayer {
    func base(_ prop: SceneProp) -> Double {
        switch prop {
        case .x: return x
        case .y: return y
        case .w: return w
        case .h: return h
        case .rotation: return rotation
        case .scale: return scale
        case .scaleX: return scaleX
        case .scaleY: return scaleY
        case .opacity: return opacity
        case .blur: return blur
        case .angle: return angle
        }
    }

    /// Base value, replaced by a track when there is one, plus oscillators.
    /// `still` (Reduce Motion) drops oscillators and loops.
    func value(_ prop: SceneProp, at t: Double, still: Bool = false) -> Double {
        var v = tracks.first { $0.prop == prop }?.value(at: t, still: still) ?? base(prop)
        if !still {
            for o in osc where o.prop == prop { v += o.value(at: t) }
        }
        return v
    }

    func isVisible(at t: Double) -> Bool {
        (from.map { t >= $0 } ?? true) && (until.map { t <= $0 } ?? true)
    }

    /// Scene time after which this layer (and its children) stops changing; nil = never.
    var settledAt: Double? {
        var latest = 0.0
        for track in tracks {
            if track.loop != nil { return nil }
            latest = max(latest, track.keys.last?.t ?? 0)
        }
        for o in osc {
            guard let s = o.settledAt else { return nil }
            latest = max(latest, s)
        }
        if let e = emitter { latest = max(latest, e.t1 + e.life + e.topFirst) }
        if let s = shatter { latest = max(latest, s.at + s.duration + 0.5) }
        if let w = wave { latest = max(latest, (w.plucks.map(\.t).max() ?? 0) + SceneWave.pluckLife) }
        if let s = sprite { latest = max(latest, s.t0 + Double(s.cols * s.rows) / s.fps) }
        if let until { latest = max(latest, until) }
        if let from { latest = max(latest, from) }
        for child in children {
            guard let s = child.settledAt else { return nil }
            latest = max(latest, s)
        }
        return latest
    }
}

extension PluginScene {
    /// Scene time after which nothing moves anymore; nil when it animates forever.
    var settledAt: Double? {
        var latest = 0.0
        for layer in layers {
            guard let s = layer.settledAt else { return nil }
            latest = max(latest, s)
        }
        return latest
    }

    /// The time to draw at: live, or the rest pose under Reduce Motion.
    func time(now: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? (restAt ?? settledAt ?? 0) : now - epoch
    }
}
