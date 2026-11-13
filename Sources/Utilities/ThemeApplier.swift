//
//  ThemeApplier.swift
//  Switchly
//
//  Applies appearance changes across existing AppKit windows.
//

import AppKit

enum ThemeApplier {
    static func apply(_ theme: AppTheme) {
        let appearance: NSAppearance?

        switch theme {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }

        NSApp.appearance = appearance

        NSApp.windows.forEach { window in
            // AppKit gives status windows the menu bar's own appearance,
            // independently of NSApp.appearance. Preserve that inheritance.
            let windowAppearance = containsStatusBarButton(window.contentView) ? nil : appearance
            window.appearance = windowAppearance
            window.contentView?.appearance = windowAppearance
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
        }
    }

    private static func containsStatusBarButton(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view is NSStatusBarButton || view.subviews.contains { containsStatusBarButton($0) }
    }
}
