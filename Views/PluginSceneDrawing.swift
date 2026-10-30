//
//  PluginSceneDrawing.swift
//  Switchly
//
//  Draws a PluginScene into a SwiftUI Canvas at one point in time. Each layer
//  is positioned by its anchor (default: centre), so children of a group sit in
//  a space whose origin is the group's anchor. Under Reduce Motion (`still`)
//  oscillators, loops, particles, plucks and shatters are not played.
//

import AppKit
import SwiftUI

extension SceneColor {
    var color: Color {
        switch token {
        case .label: return Color(nsColor: .labelColor)
        case .secondaryLabel: return Color(nsColor: .secondaryLabelColor)
        case nil: return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        }
    }
}

/// Sprite sheets of one plugin, decoded once and cropped per frame.
final class SceneAssets {
    private let directory: URL?
    private var sheets: [String: CGImage] = [:]
    private var frames: [String: CGImage] = [:]

    init(directory: URL?) { self.directory = directory }

    func frame(_ sprite: SceneSprite, index: Int) -> CGImage? {
        let name = "\(sprite.asset)#\(index)"
        if let cached = frames[name] { return cached }
        guard let directory else { return nil }
        if sheets[sprite.asset] == nil {
            let url = directory.appendingPathComponent(sprite.asset)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            sheets[sprite.asset] = image
        }
        guard let sheet = sheets[sprite.asset] else { return nil }
        let w = sheet.width / sprite.cols, h = sheet.height / sprite.rows
        let crop = CGRect(x: (index % sprite.cols) * w, y: (index / sprite.cols) * h, width: w, height: h)
        guard let frame = sheet.cropping(to: crop) else { return nil }
        frames[name] = frame
        return frame
    }
}

struct SceneDrawing {
    let scene: PluginScene
    let t: Double
    let still: Bool
    /// Hover factor 0...1 per hit id.
    let hover: [String: Double]
    let assets: SceneAssets

    func draw(into ctx: GraphicsContext) {
        for layer in scene.layers { draw(layer, in: ctx, opacity: 1, siblings: scene.layers) }
    }

    // MARK: - Layer

    private func draw(_ layer: SceneLayer, in parent: GraphicsContext, opacity inherited: Double, siblings: [SceneLayer]) {
        guard layer.isVisible(at: t) else { return }
        let factor = layer.hit.map { hover[$0.id] ?? 0 } ?? 0
        let show = layer.showOnHover.map { hover[$0] ?? 0 } ?? 1
        let opacity = inherited * SceneMath.clamp01(layer.value(.opacity, at: t, still: still)) * show
        guard opacity > 0.004 else { return }
        var c = parent
        let lift = 1 + ((layer.hit?.hoverScale ?? 1) - 1) * factor
        let s = layer.value(.scale, at: t, still: still) * lift
        c.translateBy(x: layer.value(.x, at: t, still: still), y: layer.value(.y, at: t, still: still))
        c.rotate(by: .degrees(layer.value(.rotation, at: t, still: still)))
        c.scaleBy(x: s * layer.value(.scaleX, at: t, still: still), y: s * layer.value(.scaleY, at: t, still: still))
        if layer.add { c.blendMode = .plusLighter }
        let blur = layer.value(.blur, at: t, still: still)
        if blur > 0.1 {
            // The blurred layer is flattened first, then composited once.
            c.opacity = 1
            c.drawLayer { l in
                l.addFilter(.blur(radius: blur))
                l.opacity = opacity
                drawBody(layer, in: l, opacity: opacity, siblings: siblings)
            }
        } else {
            c.opacity = opacity
            drawBody(layer, in: c, opacity: opacity, siblings: siblings)
        }
    }

    private func box(_ layer: SceneLayer) -> CGRect {
        let w = layer.value(.w, at: t, still: still), h = layer.value(.h, at: t, still: still)
        return CGRect(x: -layer.anchor.x * w, y: -layer.anchor.y * h, width: w, height: h)
    }

    private func drawBody(_ layer: SceneLayer, in ctx: GraphicsContext, opacity: Double, siblings: [SceneLayer]) {
        let rect = box(layer)
        let angle = layer.value(.angle, at: t, still: still)
        switch layer.kind {
        case .group:
            var c = ctx
            if layer.clip { c.clip(to: RoundedRectangle(cornerRadius: layer.radius, style: .continuous).path(in: rect)) }
            if let shatter = layer.shatter, t >= shatter.at {
                if !still { drawShattered(layer, shatter, rect: rect, in: c, opacity: opacity) }
            } else {
                drawChildren(layer, in: c, opacity: opacity)
            }
        case .rect:
            let path = RoundedRectangle(cornerRadius: layer.radius, style: .continuous).path(in: rect)
            paint(path, layer: layer, rect: rect, angle: angle, in: ctx) { w in
                RoundedRectangle(cornerRadius: max(layer.radius - w / 2, 0), style: .continuous).path(in: rect.insetBy(dx: w / 2, dy: w / 2))
            }
        case .ellipse:
            paint(Path(ellipseIn: rect), layer: layer, rect: rect, angle: angle, in: ctx) { w in
                Path(ellipseIn: rect.insetBy(dx: w / 2, dy: w / 2))
            }
        case .text:
            drawText(layer, in: ctx)
        case .symbol:
            guard let name = layer.symbol else { return }
            let color = (layer.fill ?? .solid(SceneColor(hex: "#FFFFFF")!)).firstColor.color
            let text = Text(Image(systemName: name)).font(.system(size: layer.size, weight: weight(layer.weight))).foregroundColor(color)
            ctx.draw(ctx.resolve(text), at: .zero, anchor: UnitPoint(x: layer.anchor.x, y: layer.anchor.y))
        case .wave:
            drawWave(layer, in: ctx)
        case .emitter:
            if !still { drawParticles(layer, in: ctx, siblings: siblings) }
        case .sprite:
            guard let sprite = layer.sprite, !still else { return }
            let index = Int((t - sprite.t0) * sprite.fps)
            guard index >= 0, index < sprite.cols * sprite.rows, let frame = assets.frame(sprite, index: index) else { return }
            ctx.draw(Image(decorative: frame, scale: 1).resizable().interpolation(.high), in: rect)
        }
    }

    private func drawChildren(_ layer: SceneLayer, in ctx: GraphicsContext, opacity: Double) {
        for child in layer.children { draw(child, in: ctx, opacity: opacity, siblings: layer.children) }
    }

    /// Fills, then strokes just inside the outline (so strokes never exceed the box).
    private func paint(_ path: Path, layer: SceneLayer, rect: CGRect, angle: Double, in ctx: GraphicsContext,
                       inset: (CGFloat) -> Path) {
        if let fill = layer.fill { ctx.fill(path, with: shading(fill, rect: rect, angle: angle)) }
        for stroke in layer.strokes {
            ctx.stroke(inset(stroke.width), with: shading(stroke.fill, rect: rect, angle: angle), lineWidth: stroke.width)
        }
    }

    private func shading(_ fill: SceneFill, rect: CGRect, angle: Double) -> GraphicsContext.Shading {
        func point(_ v: SceneVec) -> CGPoint { CGPoint(x: rect.minX + v.x * rect.width, y: rect.minY + v.y * rect.height) }
        switch fill {
        case .solid(let c): return .color(c.color)
        case .linear(let colors, let from, let to):
            return .linearGradient(Gradient(colors: colors.map(\.color)), startPoint: point(from), endPoint: point(to))
        case .angular(let colors, let center):
            return .conicGradient(Gradient(colors: colors.map(\.color)), center: point(center), angle: .degrees(angle))
        }
    }

    // MARK: - Text

    private func weight(_ w: SceneWeight) -> Font.Weight {
        switch w {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    private func drawText(_ layer: SceneLayer, in ctx: GraphicsContext) {
        guard let string = layer.text else { return }
        let design: Font.Design
        switch layer.design {
        case .default: design = .default
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .mono: design = .monospaced
        }
        var font = Font.system(size: layer.size, weight: weight(layer.weight), design: design)
        if layer.italic { font = font.italic() }
        let color = (layer.fill ?? .solid(SceneColor(hex: "#FFFFFF")!)).firstColor.color
        let resolved = ctx.resolve(Text(string).font(font).foregroundColor(color))
        var c = ctx
        // `w` is a maximum width: wider text is shrunk (not below 70 %) to fit.
        if layer.w > 0 {
            let natural = resolved.measure(in: CGSize(width: 10_000, height: 10_000)).width
            if natural > layer.w {
                let k = max(layer.w / natural, 0.7)
                c.scaleBy(x: k, y: k)
            }
        }
        c.draw(resolved, at: .zero, anchor: UnitPoint(x: layer.anchor.x, y: layer.anchor.y))
    }

    // MARK: - Wave

    private func drawWave(_ layer: SceneLayer, in ctx: GraphicsContext) {
        guard let wave = layer.wave else { return }
        let x0 = -layer.anchor.x * wave.length
        let breathePhase = SceneMath.hash(Int(layer.y.rounded()), 3) * 6
        var path = Path()
        var px = 0.0
        while px <= wave.length + 0.5 {
            var dy = 0.0
            if !still {
                for p in wave.plucks {
                    let age = t - p.t
                    guard age >= 0, age < SceneWave.pluckLife else { continue }
                    let dist = abs(px - p.x)
                    dy += p.amp * exp(-age * wave.decayT) * exp(-dist / wave.decayX) * sin(age * wave.speed - dist / wave.wavelength)
                }
                if wave.breathe != 0 { dy += wave.breathe * sin(t * 1.7 + breathePhase + px * 0.03) }
            }
            let point = CGPoint(x: x0 + px, y: dy)
            if px == 0 { path.move(to: point) } else { path.addLine(to: point) }
            px += wave.step
        }
        let bounds = CGRect(x: x0, y: -2, width: wave.length, height: 4)
        for stroke in layer.strokes { ctx.stroke(path, with: shading(stroke.fill, rect: bounds, angle: 0), lineWidth: stroke.width) }
    }

    // MARK: - Particles

    private func drawParticles(_ layer: SceneLayer, in ctx: GraphicsContext, siblings: [SceneLayer]) {
        guard let e = layer.emitter else { return }
        let follow = e.follow.flatMap { id in siblings.first { $0.id == id } }
        let base = e.color
        for i in 0..<e.count {
            let u = (Double(i) + SceneMath.hash(i + e.seed, 1) * 0.999) / Double(e.count)
            let rY = SceneMath.hash(i + e.seed, 5)
            let born = e.t0 + (e.t1 - e.t0) * u + (e.topFirst > 0 ? rY * e.topFirst : 0)
            let age = t - born
            guard age >= 0, age < e.life else { continue }
            let life = 1 - age / e.life
            var origin = CGPoint(x: e.region[0] + SceneMath.hash(i + e.seed, 4) * e.region[2],
                                 y: e.region[1] + rY * e.region[3])
            if let follow {
                origin = CGPoint(x: follow.value(.x, at: born) + (SceneMath.hash(i + e.seed, 4) - 0.5) * e.region[2] + e.region[0],
                                 y: follow.value(.y, at: born) + e.region[1] + rY * e.region[3])
            }
            let vx = SceneMath.lerp(e.vx, SceneMath.hash(i + e.seed, 6)), vy = SceneMath.lerp(e.vy, SceneMath.hash(i + e.seed, 9))
            let swirl = e.drift * sin(age * 6 + SceneMath.hash(i + e.seed, 7) * 6)
            let p = CGPoint(x: origin.x + vx * age + 0.5 * e.ax * age * age + swirl,
                            y: origin.y + vy * age + 0.5 * e.ay * age * age)
            let flicker = 1 - e.twinkle * 0.3 + e.twinkle * 0.3 * sin(age * 40 + SceneMath.hash(i + e.seed, 8) * 6)
            let r = SceneMath.lerp(e.size, SceneMath.hash(i + e.seed, 3)) * flicker * (0.5 + 0.5 * life)
            if e.glow > 0 {
                let g = r * 2.4
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - g, y: p.y - g, width: g * 2, height: g * 2)),
                         with: .color(base.color.opacity(e.glow * life)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(base.color.opacity(life * life)))
        }
    }

    // MARK: - Shatter

    private func drawShattered(_ layer: SceneLayer, _ s: SceneShatter, rect: CGRect, in ctx: GraphicsContext, opacity: Double) {
        let tw = rect.width / CGFloat(s.cols), th = rect.height / CGFloat(s.rows)
        for i in 0..<(s.cols * s.rows) {
            let col = i % s.cols, row = i / s.cols
            let r = SceneMath.hash(i, 0)
            let b = sin(Double(i) * 78.233) * 12345.678
            let r2 = b - b.rounded(.down)
            let span = s.duration * (0.55 + r2 * 0.25) / 0.8
            let p = SceneMath.ease(.in, (t - s.at - Double(row) * 0.03) / span)
            guard p < 1 else { continue }
            let tile = CGRect(x: rect.minX + CGFloat(col) * tw, y: rect.minY + CGFloat(row) * th, width: tw + 0.5, height: th + 0.5)
            var c = ctx
            c.opacity = opacity * (1 - p)
            c.translateBy(x: tile.midX + CGFloat(p * ((Double(col) - Double(s.cols - 1) / 2) * 26 + (r - 0.5) * 30)),
                          y: tile.midY + CGFloat(p * (40 + r2 * 70)))
            c.rotate(by: .degrees(p * (r - 0.5) * 140))
            c.scaleBy(x: 1 - 0.5 * p, y: 1 - 0.5 * p)
            c.translateBy(x: -tile.midX, y: -tile.midY)
            c.clip(to: Path(tile))
            drawChildren(layer, in: c, opacity: opacity * (1 - p))
        }
    }

    // MARK: - Hit testing

    struct HitRegion: Equatable {
        let hit: SceneHit
        /// In scene coordinates.
        let rect: CGRect
    }

    /// Frames of the interactive layers at time `t`, ignoring rotation.
    static func hitRegions(in scene: PluginScene, at t: Double, still: Bool) -> [HitRegion] {
        func walk(_ layers: [SceneLayer], origin: CGPoint, scale: CGFloat) -> [HitRegion] {
            layers.filter { $0.isVisible(at: t) }.flatMap { layer -> [HitRegion] in
                let s = scale * CGFloat(layer.value(.scale, at: t, still: still))
                let center = CGPoint(x: origin.x + CGFloat(layer.value(.x, at: t, still: still)) * scale,
                                     y: origin.y + CGFloat(layer.value(.y, at: t, still: still)) * scale)
                var found: [HitRegion] = []
                if let hit = layer.hit {
                    let w = CGFloat(layer.value(.w, at: t, still: still)) * s, h = CGFloat(layer.value(.h, at: t, still: still)) * s
                    found.append(HitRegion(hit: hit, rect: CGRect(x: center.x - CGFloat(layer.anchor.x) * w,
                                                                  y: center.y - CGFloat(layer.anchor.y) * h, width: w, height: h)))
                }
                return found + walk(layer.children, origin: center, scale: s)
            }
        }
        return walk(scene.layers, origin: .zero, scale: 1)
    }
}
