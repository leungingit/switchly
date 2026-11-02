//
//  SettingsHelpButton.swift
//  Switchly
//
//  Hover "?" for the preferences window. The hint is drawn by the window's
//  root view (see `settingsHelpBubbleOverlay`) instead of NSToolTip / NSPopover:
//  Switchly is an accessory app, so its windows are often not key / the app is
//  not active, and both system mechanisms silently refuse to show then.
//

import SwiftUI

struct SettingsHelpBubbleInfo {
    let text: String
    let anchor: Anchor<CGRect>
}

struct SettingsHelpBubbleKey: PreferenceKey {
    static var defaultValue: SettingsHelpBubbleInfo? = nil
    static func reduce(value: inout SettingsHelpBubbleInfo?, nextValue: () -> SettingsHelpBubbleInfo?) {
        value = nextValue() ?? value
    }
}

struct SettingsHelpButton: View {
    let help: String
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isHovering ? .primary : .secondary)
            .padding(4)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .accessibilityElement()
            .accessibilityLabel(Text(help))
            .anchorPreference(key: SettingsHelpBubbleKey.self, value: .bounds) { anchor in
                isHovering ? SettingsHelpBubbleInfo(text: help, anchor: anchor) : nil
            }
    }
}

private struct SettingsHelpBubbleOverlay: View {
    let info: SettingsHelpBubbleInfo?
    private let width: CGFloat = 280
    private let margin: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            if let info {
                let rect = proxy[info.anchor]
                let x = min(max(rect.minX, margin), max(margin, proxy.size.width - width - margin))
                Text(info.text)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                            .fill(Color(NSColor.windowBackgroundColor))
                            .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
                    )
                    .offset(x: x, y: rect.maxY + 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Apply once at the root of a settings window to render `SettingsHelpButton` hints.
    func settingsHelpBubbleOverlay() -> some View {
        overlayPreferenceValue(SettingsHelpBubbleKey.self) { SettingsHelpBubbleOverlay(info: $0) }
    }
}
