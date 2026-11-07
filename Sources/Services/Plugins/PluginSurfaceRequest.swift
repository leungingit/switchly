//
//  PluginSurfaceRequest.swift
//  Switchly
//
//  T04 input contract for a restricted 2D dynamic surface. A `scene3d` screen
//  supplies a bounded `PluginUINode` tree plus the current media artwork; the
//  surface renderer turns that into a texture. The tree uses the same node
//  semantics as the 2D overlay, but §9.4 only allows the bounded layout,
//  text, image, progress, badge and marquee subset. Any forbidden node
//  invalidates the surface; see `PluginSurfaceContentValidator`.
//

import AppKit
import CoreGraphics

/// A pre-resolved sRGB color. Dynamic AppKit colors are resolved once when the
/// request is built so offscreen drawing does not depend on the current
/// appearance of the window that happens to trigger a redraw.
struct PluginSurfaceColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(white: CGFloat, alpha: CGFloat = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor { nsColor.cgColor }

    static let clear = PluginSurfaceColor(white: 0, alpha: 0)
    static let black = PluginSurfaceColor(white: 0)
    static let white = PluginSurfaceColor(white: 1)

    /// Resolves any AppKit color into sRGB components, including dynamic
    /// system colors. The fallback keeps drawing deterministic if a color
    /// cannot be converted.
    static func resolve(_ color: NSColor) -> PluginSurfaceColor {
        guard let converted = color.usingColorSpace(.sRGB) else { return .black }
        return PluginSurfaceColor(red: converted.redComponent,
                                  green: converted.greenComponent,
                                  blue: converted.blueComponent,
                                  alpha: converted.alphaComponent)
    }
}

/// Palette used by the surface drawing. The defaults mirror the 2D overlay
/// semantics; `system()` is the production entry point and resolves dynamic
/// colors under a specific appearance.
struct PluginSurfacePalette: Equatable {
    var background: PluginSurfaceColor = .clear
    var text: PluginSurfaceColor = .black
    var secondaryText: PluginSurfaceColor = .black
    var progressTrack: PluginSurfaceColor = .clear
    var progressFill: PluginSurfaceColor = .black
    var placeholderFill: PluginSurfaceColor = .clear
    var badgeNeutralFill: PluginSurfaceColor = .clear
    var badgeAccentFill: PluginSurfaceColor = .clear
    var badgeWarningFill: PluginSurfaceColor = .clear
    var badgeText: PluginSurfaceColor = .white

    /// Resolves the overlay's semantic colors for `appearance`. Pass the
    /// effective appearance of the panel hosting the 3D view; nil resolves
    /// against the process default (used by tests and background previews).
    static func system(appearance: NSAppearance? = nil) -> PluginSurfacePalette {
        let build: () -> PluginSurfacePalette = {
            let label = PluginSurfaceColor.resolve(.labelColor)
            let secondary = PluginSurfaceColor.resolve(.secondaryLabelColor)
            let quaternary = PluginSurfaceColor.resolve(.quaternaryLabelColor)
            func alpha(_ color: PluginSurfaceColor, _ value: CGFloat) -> PluginSurfaceColor {
                PluginSurfaceColor(red: color.red, green: color.green, blue: color.blue, alpha: value)
            }
            return PluginSurfacePalette(
                background: .clear,
                text: label,
                secondaryText: secondary,
                progressTrack: quaternary,
                progressFill: PluginSurfaceColor.resolve(.controlAccentColor),
                placeholderFill: alpha(label, 0.08),
                badgeNeutralFill: quaternary,
                badgeAccentFill: PluginSurfaceColor.resolve(.controlAccentColor),
                badgeWarningFill: PluginSurfaceColor.resolve(.systemOrange),
                badgeText: .white
            )
        }
        guard let appearance else { return build() }
        var palette: PluginSurfacePalette?
        appearance.performAsCurrentDrawingAppearance { palette = build() }
        return palette ?? build()
    }
}

/// Host-owned artwork handed to the surface. `token` is the content identity
/// (for example the cover cache key); `image` is an upright CGImage. The token
/// participates in the content signature, so a cover change triggers exactly
/// one redraw even if the image object itself is reused.
struct PluginSurfaceArtwork {
    var token: String
    var image: CGImage?

    init(token: String, image: CGImage?) {
        self.token = token
        self.image = image
    }
}

/// Everything needed to rasterize one surface. `pointSize` is the surface size
/// reported by the model in points; `pixelsPerPoint` is the desired density
/// (typically the backing scale factor). The renderer clamps the effective
/// density so neither pixel edge exceeds `maxPixelEdge`.
struct PluginSurfaceRequest {
    var content: PluginUINode
    var pointSize: CGSize
    var pixelsPerPoint: CGFloat = 2
    var artwork: PluginSurfaceArtwork?
    var assetDirectory: URL?
    var palette: PluginSurfacePalette = .system()
    var maxPixelEdge: Int = PluginSurfaceRequest.defaultMaxPixelEdge

    /// Implementation plan §2.3 freezes the per-surface edge limit at 1024 px.
    static let defaultMaxPixelEdge = 1024
}

/// §9.4 allowlist for `scene3d` surface content. The whole render output must
/// be rejected when this fails, so the scene3d decoder should call `validate`
/// while decoding. The surface renderer also checks this before rasterizing so
/// a forbidden subtree can never reach the drawing code.
///
/// `scene3d` itself has no `PluginUINode` case yet; once the decoder adds one,
/// it belongs in the forbidden branch below.
enum PluginSurfaceContentValidator {
    enum Violation: Error, Equatable {
        case forbiddenNode(String)
    }

    static func validate(_ node: PluginUINode) throws {
        switch node {
        case .hstack(let children, _, _), .vstack(let children, _, _), .zstack(let children):
            for child in children { try validate(child) }
        case .spacer, .text, .progress, .image, .badge, .marquee:
            return
        case .surface:
            throw Violation.forbiddenNode("surface")
        case .screen:
            throw Violation.forbiddenNode("screen")
        case .button:
            throw Violation.forbiddenNode("button")
        case .toggle:
            throw Violation.forbiddenNode("toggle")
        case .slider:
            throw Violation.forbiddenNode("slider")
        case .wheel:
            throw Violation.forbiddenNode("wheel")
        case .scene:
            throw Violation.forbiddenNode("scene")
        case .scene3d:
            throw Violation.forbiddenNode("scene3d")
        }
    }

    static func allows(_ node: PluginUINode) -> Bool {
        do {
            try validate(node)
            return true
        } catch {
            return false
        }
    }
}
