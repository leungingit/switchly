//
//  DesignTokens.swift
//  Switchly
//
//  Shared layout constants — spacing, corner radii, border weights.
//
//  Mirrors MotionTokens so the app has one source of truth per design axis:
//  motion lives in MotionTokens, layout lives here. Panels, cards and
//  controls resolve their metrics through this file instead of hard-coding
//  numbers, which keeps the visual rhythm consistent when a value changes.
//

import SwiftUI

enum DesignTokens {

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        /// Floating panel outer curve — matches visionOS-inspired spatial crystal curvature.
        /// Single source of truth shared with GlassPanelCorner.
        static let panel: CGFloat = GlassPanelCorner.radius

        /// Cards inside a panel (window cards, workspace cards).
        static let card: CGFloat = 16

        /// Window thumbnails inside a card.
        static let thumbnail: CGFloat = 10

        /// Interactive controls (search field, buttons).
        static let control: CGFloat = 12

        /// Floating spatial pills (search pill, ornament rail).
        static let pill: CGFloat = 999

        /// Tiny chips (window-number badge, app-icon chip).
        static let chip: CGFloat = 6
    }

    enum Glass {
        static let maximumTintOpacity: Double = 0.35
        static let maximumNativeReadingOpacity: Double = 0.85
        /// A structural card outline, independent of optional optical highlights.
        static let groupBorderOpacity: Double = 0.25
    }

    /// Hairline border weight. 0.5pt reads as a crisp specular line on Retina.
    static let hairline: CGFloat = 0.5

    /// Desktop grid (3×3 Spaces overview). See docs/desktop-grid-design-spec.md §7.2.
    enum Grid {
        /// Perspective tilt of the style C overview, in degrees.
        static let tilt: Double = 9

        /// Style C column / row weights; the centre cell is the current desktop.
        static let columnFractions: [CGFloat] = [1, 2.1, 1]
        static let rowFractions: [CGFloat] = [0.85, 1.6, 0.85]

        /// Overall scale that keeps the third row inside the visible frame.
        static let overviewScale: CGFloat = 0.88

        /// Target cell lift and scale, paired with the dashed target ring.
        static let targetLift: CGFloat = 24
        static let targetScale: CGFloat = 1.02

        /// Single-cell hover lift.
        static let hoverLift: CGFloat = 3

        /// Style B (flat grid) geometry.
        static let styleBCellHeight: CGFloat = 176
        static let styleBMaxWidth: CGFloat = 900
        /// Cap on the style B panel height; on a short screen the visible
        /// frame wins instead (see `GridPanelLayout.overviewFrame`).
        static let styleBMaxHeight: CGFloat = 720

        /// Style C grid width cap. The prototype wraps the grid in a 1260px
        /// container (`--gridwrap max-width`) so the perspective grid never
        /// stretches edge to edge; the leftover space becomes symmetric margin.
        static let styleCMaxWidth: CGFloat = 1260

        /// Relative vanishing point for `rotation3DEffect`. The web prototype
        /// uses `perspective: 1800px` over a 1260px-wide grid (~0.7 of the
        /// grid width); SwiftUI's parameter is relative to the view size, so
        /// 0.12 read as almost flat and the third row did not foreshorten.
        static let perspective: CGFloat = 0.9

        /// Gesture HUD geometry (design spec §3.2; prototype `.hudp`/`.ring`/`.mini`).
        enum HUD {
            /// Direction ring diameter.
            static let ringSize: CGFloat = 64
            /// Ring dot offsets: idle / highlighted.
            static let ringDot: CGFloat = 6
            static let ringDotActive: CGFloat = 9
            /// Radius the dots sit at, measured from the ring centre.
            static let ringDotRadius: CGFloat = 25
            /// Mini 3×3 map cell and gap.
            static let miniCell: CGFloat = 18
            static let miniGap: CGFloat = 3
            /// The pill never grows past this; beyond it the mini map hides.
            static let maxWidth: CGFloat = 520
        }
    }

    /// Type ramp for the desktop grid surfaces.
    enum Typography {
        static let gridTitle = Font.system(size: 22, weight: .semibold)
        static let gridCard = Font.system(size: 14, weight: .medium)
        static let gridMeta = Font.system(size: 12)
        static let gridNumber = Font.system(size: 44, weight: .semibold).monospacedDigit()
    }
}
