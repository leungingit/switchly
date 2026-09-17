//
//  WindowTrafficLights.swift
//  Switchly
//
//  Reusable macOS-style window controls (close / minimize / zoom) for a window,
//  backed by the Accessibility API.
//

import SwiftUI

/// The three macOS window buttons, wired to WindowAction.
///
/// Extracted from the Dock preview card so every preview surface offers the same
/// window actions without a second copy of the Accessibility plumbing: the dock
/// cards, the preview panel's grid cards, the hero pane and its list rows all
/// use this one view. Size and glyph policy are parameters because the dock card
/// draws 10 pt dots that only reveal their glyphs on hover, while the hero pane
/// draws larger dots with the glyphs always visible.
struct WindowTrafficLightButtons: View {
    let window: WindowInfo
    /// Language used for the accessibility labels and tooltips. Passed in rather
    /// than resolved here: call sites already hold a decoded AppSettings, and
    /// resolving settings inside a body would decode them once per card.
    let language: AppLanguage
    /// Diameter of each dot, in points.
    var diameter: CGFloat = 10
    /// Draw the glyphs inside the dots at all times. macOS only reveals them
    /// while the pointer is over them; the hero pane keeps them visible because
    /// that row is the focused window and reads as the primary control.
    var alwaysShowsGlyphs: Bool = false
    /// Runs after a button's action was performed, so a host panel can close
    /// itself or refresh its window list.
    var onAction: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: diameter * 0.4) {
            dot(.close) { WindowAction.close(window) }
            dot(.minimize) { WindowAction.minimize(window) }
            dot(.zoom) { WindowAction.zoom(window) }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var showsGlyphs: Bool {
        alwaysShowsGlyphs || isHovered
    }

    private enum Kind {
        case close, minimize, zoom

        var color: Color {
            switch self {
            case .close:    return Color(red: 1.0, green: 0.36, blue: 0.32)
            case .minimize: return Color(red: 0.98, green: 0.76, blue: 0.22)
            case .zoom:     return Color(red: 0.28, green: 0.84, blue: 0.40)
            }
        }

        var icon: String {
            switch self {
            case .close:    return "xmark"
            case .minimize: return "minus"
            case .zoom:     return "plus"
            }
        }

        /// Localization key of the accessibility label.
        var labelKey: String {
            switch self {
            case .close:    return "Close"
            case .minimize: return "Minimize"
            case .zoom:     return "Zoom"
            }
        }
    }

    @ViewBuilder
    private func dot(_ kind: Kind, action: @escaping () -> Void) -> some View {
        let label = language.localizedString(kind.labelKey)

        ZStack {
            Circle()
                .fill(kind.color)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.16), lineWidth: 0.5)
                )
                .frame(width: diameter, height: diameter)

            if showsGlyphs {
                Image(systemName: kind.icon)
                    .font(.system(size: diameter * 0.58, weight: .bold))
                    .foregroundColor(Color.black.opacity(0.5))
            }
        }
        // macOS hit target: the dot is smaller than the button it sits in.
        .frame(width: diameter * 1.6, height: diameter * 1.6)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
        .help(label)
        .onTapGesture {
            action()
            onAction?()
        }
    }
}
