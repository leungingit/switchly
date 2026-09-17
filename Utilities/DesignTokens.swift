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
        /// Floating panel outer curve — matches standard macOS windows.
        /// Single source of truth shared with GlassPanelCorner.
        static let panel: CGFloat = GlassPanelCorner.radius

        /// Cards inside a panel (window cards, workspace cards).
        static let card: CGFloat = 10

        /// Window thumbnails inside a card.
        static let thumbnail: CGFloat = 6

        /// Interactive controls (search field, buttons).
        static let control: CGFloat = 8

        /// Tiny chips (window-number badge, app-icon chip).
        static let chip: CGFloat = 5
    }

    /// Hairline border weight. 0.5pt reads as a crisp line on Retina; 1pt
    /// looks heavy next to the system's own separators.
    static let hairline: CGFloat = 0.5
}
