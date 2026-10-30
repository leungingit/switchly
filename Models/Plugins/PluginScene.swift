//
//  PluginScene.swift
//  Switchly
//
//  Declarative animated scene a plugin returns as a `scene` UI node (design
//  doc §8). The plugin describes layers, keyframe tracks, oscillators, particle
//  emitters, plucked lines and shatter exits once; the host plays them locally
//  against a wall-clock `epoch`, so nothing crosses into JS per frame.
//  Decoding is the schema check: bad shapes fail to decode and budgets are
//  enforced in `validate()`.
//

import Foundation

struct SceneVec: Equatable, Decodable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }
}

struct SceneColor: Equatable, Decodable {
    /// Theme colours the host resolves, so plugin text follows light / dark.
    enum Token: String { case label = "$label", secondaryLabel = "$secondaryLabel" }

    var r: Double, g: Double, b: Double, a: Double
    var token: Token?

    init(token: Token) { r = 0; g = 0; b = 0; a = 1; self.token = token }

    /// `#RRGGBB` or `#RRGGBBAA`.
    init?(hex: String) {
        if let token = Token(rawValue: hex) {
            r = 0; g = 0; b = 0; a = 1
            self.token = token
            return
        }
        guard hex.hasPrefix("#"), hex.count == 7 || hex.count == 9, let v = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        let hasAlpha = hex.count == 9
        let value = hasAlpha ? v : (v << 8 | 0xFF)
        r = Double((value >> 24) & 0xFF) / 255
        g = Double((value >> 16) & 0xFF) / 255
        b = Double((value >> 8) & 0xFF) / 255
        a = Double(value & 0xFF) / 255
    }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let color = SceneColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad colour \(s)"))
        }
        self = color
    }
}

enum SceneFill: Equatable, Decodable {
    case solid(SceneColor)
    /// Points are fractions of the layer box.
    case linear(colors: [SceneColor], from: SceneVec, to: SceneVec)
    case angular(colors: [SceneColor], center: SceneVec)

    private enum Keys: String, CodingKey { case linear, angular }
    private struct Linear: Decodable { let colors: [SceneColor]; let from: SceneVec?; let to: SceneVec? }
    private struct Angular: Decodable { let colors: [SceneColor]; let center: SceneVec? }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(SceneColor.self) {
            self = .solid(single)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        if let l = try c.decodeIfPresent(Linear.self, forKey: .linear), !l.colors.isEmpty, l.colors.count <= 6 {
            self = .linear(colors: l.colors, from: l.from ?? SceneVec(x: 0.5, y: 0), to: l.to ?? SceneVec(x: 0.5, y: 1))
        } else if let a = try c.decodeIfPresent(Angular.self, forKey: .angular), !a.colors.isEmpty, a.colors.count <= 8 {
            self = .angular(colors: a.colors, center: a.center ?? SceneVec(x: 0.5, y: 0.5))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown fill"))
        }
    }

    /// First colour, for text and symbols which cannot take a gradient.
    var firstColor: SceneColor {
        switch self {
        case .solid(let c): return c
        case .linear(let colors, _, _), .angular(let colors, _): return colors[0]
        }
    }
}

struct SceneStroke: Equatable, Decodable {
    var fill: SceneFill
    var width: Double

    private enum Keys: String, CodingKey { case color, width }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        fill = try c.decode(SceneFill.self, forKey: .color)
        width = min(max(try c.decodeIfPresent(Double.self, forKey: .width) ?? 1, 0.1), 16)
    }
}

enum SceneProp: String, Decodable {
    case x, y, w, h, rotation, scale, scaleX, scaleY, opacity, blur
    /// Rotation in degrees of angular gradients on this layer.
    case angle
}

enum SceneEase: String, Decodable {
    case linear, `in`, out, inOut, hold
}

struct SceneKey: Equatable, Decodable {
    var t: Double
    var v: Double
    var ease: SceneEase

    private enum Keys: String, CodingKey { case t, v, e }

    init(t: Double, v: Double, ease: SceneEase = .linear) { self.t = t; self.v = v; self.ease = ease }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        t = try c.decode(Double.self, forKey: .t)
        v = try c.decode(Double.self, forKey: .v)
        ease = try c.decodeIfPresent(SceneEase.self, forKey: .e) ?? .linear
    }
}

struct SceneTrack: Equatable, Decodable {
    var prop: SceneProp
    var keys: [SceneKey]
    /// Repeats every `loop` seconds when set.
    var loop: Double?

    private enum Keys: String, CodingKey { case prop, keys, loop }

    init(prop: SceneProp, keys: [SceneKey], loop: Double? = nil) { self.prop = prop; self.keys = keys; self.loop = loop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        prop = try c.decode(SceneProp.self, forKey: .prop)
        let raw = try c.decode([SceneKey].self, forKey: .keys)
        guard !raw.isEmpty, raw.count <= PluginScene.maxKeysPerTrack else {
            throw DecodingError.dataCorruptedError(forKey: .keys, in: c, debugDescription: "Key count out of range")
        }
        keys = raw.sorted { $0.t < $1.t }
        let loop = try c.decodeIfPresent(Double.self, forKey: .loop)
        guard loop == nil || loop! > 0.05 else {
            throw DecodingError.dataCorruptedError(forKey: .loop, in: c, debugDescription: "Loop too short")
        }
        self.loop = loop
    }
}

/// Added on top of the base / track value: `amp * wave(freq * (t - start) + phase) * e^(-decay (t - start))`.
struct SceneOsc: Equatable, Decodable {
    enum Wave: String, Decodable { case sin, pulse, abs }

    var prop: SceneProp
    var amp: Double
    /// Cycles per second.
    var freq: Double
    /// In cycles.
    var phase: Double
    var start: Double
    var end: Double?
    var decay: Double
    var wave: Wave
    /// Exponent of `pulse`.
    var power: Double

    private enum Keys: String, CodingKey { case prop, amp, freq, phase, start, end, decay, wave, power }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        prop = try c.decode(SceneProp.self, forKey: .prop)
        amp = try c.decode(Double.self, forKey: .amp)
        freq = try c.decode(Double.self, forKey: .freq)
        phase = try c.decodeIfPresent(Double.self, forKey: .phase) ?? 0
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        decay = max(try c.decodeIfPresent(Double.self, forKey: .decay) ?? 0, 0)
        wave = try c.decodeIfPresent(Wave.self, forKey: .wave) ?? .sin
        power = min(max(try c.decodeIfPresent(Double.self, forKey: .power) ?? 3, 0.5), 8)
    }
}

struct SceneEmitter: Equatable, Decodable {
    var seed: Int
    var count: Int
    /// Particles are born evenly between `t0` and `t1`.
    var t0: Double
    var t1: Double
    var life: Double
    /// Birth area in layer coordinates; ignored when `follow` names a sibling layer.
    var region: [Double]
    var follow: String?
    var vx: [Double]
    var vy: [Double]
    var ax: Double
    var ay: Double
    var size: [Double]
    var color: SceneColor
    var glow: Double
    var twinkle: Double
    var drift: Double
    /// Seconds by which particles born lower in the region are delayed (top leaves first).
    var topFirst: Double

    private enum Keys: String, CodingKey {
        case seed, count, t0, t1, life, region, follow, vx, vy, ax, ay, size, color, glow, twinkle, drift, topFirst
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func pair(_ key: Keys, _ fallback: [Double]) throws -> [Double] {
            let v = try c.decodeIfPresent([Double].self, forKey: key) ?? fallback
            guard v.count == 2 else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Needs 2 numbers") }
            return v
        }
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? 1
        count = min(max(try c.decode(Int.self, forKey: .count), 1), PluginScene.maxParticlesPerEmitter)
        t0 = try c.decode(Double.self, forKey: .t0)
        t1 = max(try c.decodeIfPresent(Double.self, forKey: .t1) ?? t0, t0)
        life = min(max(try c.decode(Double.self, forKey: .life), 0.1), 4)
        region = try c.decodeIfPresent([Double].self, forKey: .region) ?? [0, 0, 0, 0]
        guard region.count == 4 else { throw DecodingError.dataCorruptedError(forKey: .region, in: c, debugDescription: "Needs x y w h") }
        follow = try c.decodeIfPresent(String.self, forKey: .follow)
        vx = try pair(.vx, [0, 0])
        vy = try pair(.vy, [0, 0])
        ax = try c.decodeIfPresent(Double.self, forKey: .ax) ?? 0
        ay = try c.decodeIfPresent(Double.self, forKey: .ay) ?? 0
        size = try pair(.size, [1, 2])
        color = try c.decode(SceneColor.self, forKey: .color)
        glow = min(max(try c.decodeIfPresent(Double.self, forKey: .glow) ?? 0, 0), 1)
        twinkle = min(max(try c.decodeIfPresent(Double.self, forKey: .twinkle) ?? 0, 0), 1)
        drift = try c.decodeIfPresent(Double.self, forKey: .drift) ?? 0
        topFirst = max(try c.decodeIfPresent(Double.self, forKey: .topFirst) ?? 0, 0)
    }
}

/// A horizontal line that ripples where it was plucked.
struct SceneWave: Equatable, Decodable {
    struct Pluck: Equatable, Decodable { var t: Double; var x: Double; var amp: Double }

    var length: Double
    var plucks: [Pluck]
    var breathe: Double
    var step: Double
    /// Pluck decay over time (1/s) and distance (pt), ripple speed (rad/s) and wavelength (pt).
    var decayT: Double
    var decayX: Double
    var speed: Double
    var wavelength: Double
    /// Seconds a pluck keeps moving the line.
    static let pluckLife = 1.2

    private enum Keys: String, CodingKey { case length, plucks, breathe, step, decayT, decayX, speed, wavelength }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        length = max(try c.decode(Double.self, forKey: .length), 1)
        plucks = Array((try c.decodeIfPresent([Pluck].self, forKey: .plucks) ?? []).prefix(PluginScene.maxPlucks))
        breathe = try c.decodeIfPresent(Double.self, forKey: .breathe) ?? 0
        step = min(max(try c.decodeIfPresent(Double.self, forKey: .step) ?? 6, 2), 24)
        decayT = try c.decodeIfPresent(Double.self, forKey: .decayT) ?? 5
        decayX = max(try c.decodeIfPresent(Double.self, forKey: .decayX) ?? 70, 1)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 34
        wavelength = max(try c.decodeIfPresent(Double.self, forKey: .wavelength) ?? 9, 1)
    }
}

struct SceneShatter: Equatable, Decodable {
    var at: Double
    var cols: Int
    var rows: Int
    var duration: Double

    private enum Keys: String, CodingKey { case at, cols, rows, duration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        at = try c.decode(Double.self, forKey: .at)
        cols = min(max(try c.decodeIfPresent(Int.self, forKey: .cols) ?? 4, 1), 8)
        rows = min(max(try c.decodeIfPresent(Int.self, forKey: .rows) ?? 6, 1), 8)
        duration = min(max(try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0.8, 0.1), 3)
    }
}

struct SceneHit: Equatable, Decodable {
    var id: String
    var label: String
    /// Scale factor while hovered (1 = none).
    var hoverScale: Double

    private enum Keys: String, CodingKey { case id, label, hoverScale }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        guard !id.isEmpty, !label.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Hit needs id and label")
        }
        hoverScale = min(max(try c.decodeIfPresent(Double.self, forKey: .hoverScale) ?? 1, 0.8), 1.3)
    }
}

struct SceneSprite: Equatable, Decodable {
    var asset: String
    var cols: Int
    var rows: Int
    var fps: Double
    var t0: Double

    private enum Keys: String, CodingKey { case asset, cols, rows, fps, t0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        asset = try c.decode(String.self, forKey: .asset)
        guard !asset.hasPrefix("/"), !asset.split(separator: "/").contains("..") else {
            throw DecodingError.dataCorruptedError(forKey: .asset, in: c, debugDescription: "Asset escapes plugin")
        }
        cols = min(max(try c.decode(Int.self, forKey: .cols), 1), 16)
        rows = min(max(try c.decode(Int.self, forKey: .rows), 1), 16)
        fps = min(max(try c.decodeIfPresent(Double.self, forKey: .fps) ?? 24, 1), 60)
        t0 = try c.decode(Double.self, forKey: .t0)
    }
}

enum SceneKind: String, Decodable { case group, rect, ellipse, text, symbol, wave, emitter, sprite }
enum SceneDesign: String, Decodable { case `default`, serif, rounded, mono }
enum SceneWeight: String, Decodable { case regular, medium, semibold, bold, heavy }

struct SceneLayer: Equatable, Decodable {
    var id: String?
    var kind: SceneKind
    var x = 0.0, y = 0.0, w = 0.0, h = 0.0
    var anchor = SceneVec(x: 0.5, y: 0.5)
    var rotation = 0.0, scale = 1.0, scaleX = 1.0, scaleY = 1.0, opacity = 1.0, blur = 0.0, angle = 0.0
    var radius = 0.0
    var fill: SceneFill?
    var strokes: [SceneStroke] = []
    /// Drawn with additive blending.
    var add = false
    var text: String?
    var symbol: String?
    var size = 12.0
    var weight = SceneWeight.regular
    var design = SceneDesign.default
    var italic = false
    /// Clip children to the layer's rounded box.
    var clip = false
    /// Visible only between these scene times.
    var from: Double?
    var until: Double?
    /// Opacity follows the hover factor of this hit id.
    var showOnHover: String?
    var tracks: [SceneTrack] = []
    var osc: [SceneOsc] = []
    var children: [SceneLayer] = []
    var shatter: SceneShatter?
    var hit: SceneHit?
    var emitter: SceneEmitter?
    var wave: SceneWave?
    var sprite: SceneSprite?

    private enum Keys: String, CodingKey {
        case id, kind, x, y, w, h, anchor, rotation, scale, scaleX, scaleY, opacity, blur, angle, radius, fill, stroke, strokes
        case add, text, symbol, size, weight, design, italic, clip, from, until, showOnHover, tracks, osc, children
        case shatter, hit, emitter, wave, sprite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func num(_ key: Keys, _ fallback: Double) throws -> Double {
            let v = try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
            guard v.isFinite else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not finite") }
            return v
        }
        id = try c.decodeIfPresent(String.self, forKey: .id)
        kind = try c.decode(SceneKind.self, forKey: .kind)
        x = try num(.x, 0); y = try num(.y, 0); w = try num(.w, 0); h = try num(.h, 0)
        anchor = try c.decodeIfPresent(SceneVec.self, forKey: .anchor) ?? SceneVec(x: 0.5, y: 0.5)
        rotation = try num(.rotation, 0); scale = try num(.scale, 1); scaleX = try num(.scaleX, 1); scaleY = try num(.scaleY, 1)
        opacity = try num(.opacity, 1); blur = min(max(try num(.blur, 0), 0), 40); angle = try num(.angle, 0)
        radius = max(try num(.radius, 0), 0)
        fill = try c.decodeIfPresent(SceneFill.self, forKey: .fill)
        if let many = try c.decodeIfPresent([SceneStroke].self, forKey: .strokes) {
            strokes = many
        } else if let one = try c.decodeIfPresent(SceneStroke.self, forKey: .stroke) {
            strokes = [one]
        }
        add = try c.decodeIfPresent(Bool.self, forKey: .add) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        size = min(max(try num(.size, 12), 4), 160)
        weight = try c.decodeIfPresent(SceneWeight.self, forKey: .weight) ?? .regular
        design = try c.decodeIfPresent(SceneDesign.self, forKey: .design) ?? .default
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        clip = try c.decodeIfPresent(Bool.self, forKey: .clip) ?? false
        from = try c.decodeIfPresent(Double.self, forKey: .from)
        until = try c.decodeIfPresent(Double.self, forKey: .until)
        showOnHover = try c.decodeIfPresent(String.self, forKey: .showOnHover)
        tracks = try c.decodeIfPresent([SceneTrack].self, forKey: .tracks) ?? []
        osc = try c.decodeIfPresent([SceneOsc].self, forKey: .osc) ?? []
        children = try c.decodeIfPresent([SceneLayer].self, forKey: .children) ?? []
        shatter = try c.decodeIfPresent(SceneShatter.self, forKey: .shatter)
        hit = try c.decodeIfPresent(SceneHit.self, forKey: .hit)
        emitter = try c.decodeIfPresent(SceneEmitter.self, forKey: .emitter)
        wave = try c.decodeIfPresent(SceneWave.self, forKey: .wave)
        sprite = try c.decodeIfPresent(SceneSprite.self, forKey: .sprite)
        // Each kind needs its payload.
        let missing: Bool
        switch kind {
        case .text: missing = text == nil
        case .symbol: missing = symbol == nil
        case .wave: missing = wave == nil
        case .emitter: missing = emitter == nil
        case .sprite: missing = sprite == nil
        case .group, .rect, .ellipse: missing = false
        }
        if missing { throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "\(kind) layer is missing its payload") }
        if kind != .group, !children.isEmpty { throw DecodingError.dataCorruptedError(forKey: .children, in: c, debugDescription: "Only groups nest") }
    }

    var layerCount: Int { 1 + children.reduce(0) { $0 + $1.layerCount } }
    var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }
    var particleCount: Int { (emitter?.count ?? 0) + children.reduce(0) { $0 + $1.particleCount } }
    var hits: [SceneHit] { (hit.map { [$0] } ?? []) + children.flatMap(\.hits) }
}

struct PluginScene: Equatable, Decodable {
    static let maxLayers = 160
    static let maxDepth = 6
    static let maxParticles = 400
    static let maxParticlesPerEmitter = 120
    static let maxKeysPerTrack = 160
    static let maxPlucks = 8
    static let maxHits = 12

    enum Fit: String, Decodable { case width, cover }

    /// Same key = same animation: re-renders do not restart it.
    var key: String
    /// Unix seconds at scene time 0.
    var epoch: Double
    var width: Double
    var height: Double
    var fps: Double
    var fit: Fit
    /// Scene time shown under Reduce Motion (and when nothing is left to animate).
    var restAt: Double?
    var layers: [SceneLayer]

    private enum Keys: String, CodingKey { case key, epoch, width, height, fps, fit, restAt, layers }

    enum ValidationError: Error, Equatable {
        case tooManyLayers, tooDeep, tooManyParticles, tooManyHits, duplicateHit(String), badSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        key = try c.decode(String.self, forKey: .key)
        epoch = try c.decode(Double.self, forKey: .epoch)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        fps = min(max(try c.decodeIfPresent(Double.self, forKey: .fps) ?? 30, 10), 60)
        fit = try c.decodeIfPresent(Fit.self, forKey: .fit) ?? .width
        restAt = try c.decodeIfPresent(Double.self, forKey: .restAt)
        layers = try c.decode([SceneLayer].self, forKey: .layers)
        do { try validate() } catch {
            throw DecodingError.dataCorruptedError(forKey: .layers, in: c, debugDescription: "Scene rejected: \(error)")
        }
    }

    func validate() throws {
        guard width.isFinite, height.isFinite, epoch.isFinite, (16...1200).contains(width), (16...1200).contains(height) else {
            throw ValidationError.badSize
        }
        guard layers.reduce(0, { $0 + $1.layerCount }) <= Self.maxLayers else { throw ValidationError.tooManyLayers }
        guard (layers.map(\.depth).max() ?? 0) <= Self.maxDepth else { throw ValidationError.tooDeep }
        guard layers.reduce(0, { $0 + $1.particleCount }) <= Self.maxParticles else { throw ValidationError.tooManyParticles }
        let hits = layers.flatMap(\.hits)
        guard hits.count <= Self.maxHits else { throw ValidationError.tooManyHits }
        var seen = Set<String>()
        for hit in hits where !seen.insert(hit.id).inserted { throw ValidationError.duplicateHit(hit.id) }
    }

    var hits: [SceneHit] { layers.flatMap(\.hits) }
}
