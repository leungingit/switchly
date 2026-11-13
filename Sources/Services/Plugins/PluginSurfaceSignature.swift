//
//  PluginSurfaceSignature.swift
//  Switchly
//
//  Deterministic content hash for dynamic surfaces. The hash covers only the
//  inputs that can change the pixels: the supported node subtree, the logical
//  size, the effective pixel density and size, the resolved palette, the
//  artwork identity and the asset directory. Badge value and tone participate
//  because both change the pixels. Forbidden §9.4 nodes are rejected before
//  hashing and only retain a type marker as a defensive fallback.
//

import CryptoKit
import Foundation

enum PluginSurfaceSignature {
    static func make(for request: PluginSurfaceRequest,
                     pixelSize: CGSize,
                     pixelsPerPoint: CGFloat) -> String {
        var parts: [String] = [
            "plugin-surface-v1",
            "points=\(number(request.pointSize.width))x\(number(request.pointSize.height))",
            "pixels=\(number(pixelSize.width))x\(number(pixelSize.height))",
            "density=\(hex(pixelsPerPoint))",
            "maxEdge=\(request.maxPixelEdge)",
            "palette=\(palette(request.palette))",
            "artwork=\(request.artwork?.token ?? "-")",
            "assets=\(request.assetDirectory?.standardizedFileURL.path ?? "-")"
        ]
        parts.append(serialize(request.content))
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func serialize(_ node: PluginUINode) -> String {
        switch node {
        case .hstack(let children, let spacing, let align):
            return "h(\(spacing?.rawValue ?? "-"),\(align?.rawValue ?? "-"))[\(children.map(serialize).joined(separator: ","))]"
        case .vstack(let children, let spacing, let align):
            return "v(\(spacing?.rawValue ?? "-"),\(align?.rawValue ?? "-"))[\(children.map(serialize).joined(separator: ","))]"
        case .zstack(let children):
            return "z[\(children.map(serialize).joined(separator: ","))]"
        case .spacer:
            return "spacer"
        case .text(let value, let style, let lines):
            return "text(\(style.rawValue),\(lines.map(String.init) ?? "-"),\(string(value)))"
        case .progress(let value, let style, _):
            // `rate` is not interpolated by the surface renderer; the host
            // writes the current value when the media snapshot changes.
            return "progress(\(style.rawValue),\(hex(value)))"
        case .image(let source, let size, let corner):
            return "image(\(imageSource(source)),\(size.rawValue),\(corner?.rawValue ?? "-"))"
        case .marquee(let value):
            return "marquee(\(string(value)))"
        case .badge(let value, let tone):
            return "badge(\(tone.rawValue),\(string(value)))"
        case .surface, .button, .toggle, .slider, .wheel, .screen, .scene, .scene3d, .segmented, .dateRange, .barChart, .lineChart, .timeline, .grid:
            // Forbidden by §9.4; the renderer rejects the request before it
            // gets here. The marker keeps the hash deterministic defensively.
            return forbiddenName(node)
        }
    }

    private static func forbiddenName(_ node: PluginUINode) -> String {
        switch node {
        case .surface: return "forbidden:surface"
        case .button: return "forbidden:button"
        case .toggle: return "forbidden:toggle"
        case .slider: return "forbidden:slider"
        case .wheel: return "forbidden:wheel"
        case .screen: return "forbidden:screen"
        case .scene: return "forbidden:scene"
        case .scene3d: return "forbidden:scene3d"
        default: return "forbidden:?"
        }
    }

    private static func imageSource(_ source: PluginImageSource) -> String {
        switch source {
        case .symbol(let name): return "symbol:\(string(name))"
        case .pluginAsset(let name): return "asset:\(string(name))"
        case .activitySnapshot: return "forbidden:activitySnapshot"
        case .artwork: return "artwork"
        }
    }

    private static func palette(_ palette: PluginSurfacePalette) -> String {
        [palette.background, palette.text, palette.secondaryText,
         palette.progressTrack, palette.progressFill, palette.placeholderFill,
         palette.badgeNeutralFill, palette.badgeAccentFill,
         palette.badgeWarningFill, palette.badgeText]
            .map(color)
            .joined(separator: ";")
    }

    private static func color(_ color: PluginSurfaceColor) -> String {
        "\(hex(color.red)),\(hex(color.green)),\(hex(color.blue)),\(hex(color.alpha))"
    }

    /// Length-prefixed UTF-8 keeps user text unambiguous inside the joined
    /// signature even when it contains punctuation or separators.
    private static func string(_ value: String) -> String {
        let data = Data(value.utf8)
        return "\(data.count):\(value)"
    }

    private static func hex(_ value: CGFloat) -> String {
        String(Double(value).bitPattern, radix: 16)
    }

    private static func number(_ value: CGFloat) -> String {
        String(Double(value).bitPattern, radix: 16)
    }
}
