//
//  DesktopGridPalette.swift
//  Switchly
//
//  Colour tokens for the desktop grid (3×3 Spaces overview).
//  See docs/desktop-grid-design-spec.md §5 and §7.2.
//
//  Kept apart from GlassEffect.swift: these are content colours drawn inside
//  the grid, not glass material. Glass, sheen and rim still come from the
//  shared material helpers. Window colours resolve per view appearance via
//  `Color.appearanceAware`.
//

import SwiftUI

extension DesignTokens.Grid {

    /// Overview wallpaper gradient stops, top-leading to bottom-trailing.
    /// Dark appearance always uses graphite regardless of the background axis.
    enum Wall {
        static let cream: [Color] = [rgb(0xFBF9F3), rgb(0xF5F2EA), rgb(0xEEE9DC)]
        static let white: [Color] = [rgb(0xFFFFFF)]
        static let graphite: [Color] = [rgb(0x34363D), rgb(0x2A2C31), rgb(0x1B1C20)]

        /// Nine low-saturation wallpaper bases for desktop thumbnails
        /// (design spec §9.1). Warm, green and grey families repeat across the
        /// grid so neighbouring cells never read as one flat surface.
        static let thumbnailBases: [[Color]] = [
            [rgb(0xE9EDF3), rgb(0xD8DFE9)],
            [rgb(0xE7EEE6), rgb(0xD3E2D8)],
            [rgb(0xF3EAD7), rgb(0xE7D9BE)],
            [rgb(0xF1E4E6), rgb(0xE3D0D5)],
            [rgb(0xE4EAF3), rgb(0xD1DDEB)],
            [rgb(0xE6EEE7), rgb(0xD2E2D6)],
            [rgb(0xF0EBDD), rgb(0xE3DAC6)],
            [rgb(0xF2E4DF), rgb(0xE5D1C9)],
            [rgb(0xE8E9ED), rgb(0xD5D8DF)],
        ]

        static func thumbnailBase(for number: Int) -> [Color] {
            let index = (max(1, number) - 1) % thumbnailBases.count
            return thumbnailBases[index]
        }
    }

    /// Stable letter-block colour for an application name.
    ///
    /// `String.hashValue` is seeded per process, so it would repaint every
    /// launch; the scalar sum is deterministic across runs instead.
    static func appColor(for name: String) -> Color {
        let seed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return appPalette[seed % appPalette.count]
    }

    /// Letter-block fallback colours for app icons; white text stays ≥ 4.5:1.
    static let appPalette: [Color] = [
        0x1D5FD1, 0x6D3FD1, 0x0A6FA8, 0x8F5400,
        0xB8286B, 0x0B7A70, 0x374151, 0xC0243F,
    ].map(rgb)

    /// Semantic status colours. Always paired with a text label.
    enum Status {
        static let ok = rgb(0x1A7F45)
        static let warn = rgb(0x9A5A00)
        static let bad = rgb(0xB3261E)
    }

    /// Miniature window chrome drawn inside a desktop thumbnail.
    enum Window {
        static var background: Color {
            .appearanceAware(dark: rgb(0x2B2D33), light: rgb(0xFBFAF7))
        }
        static var edge: Color { ink(0.20, dark: 0.22) }
        static var dot: Color { ink(0.22, dark: 0.26) }
        static var line: Color { ink(0.14, dark: 0.16) }
        static var text: Color {
            .appearanceAware(dark: .white, light: .crystalGraphite)
        }

        private static func ink(_ light: Double, dark: Double) -> Color {
            .appearanceAware(dark: .white.opacity(dark), light: .crystalGraphite.opacity(light))
        }
    }
}

private func rgb(_ hex: Int) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255
    )
}
