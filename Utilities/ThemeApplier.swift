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
            window.appearance = appearance
            window.contentView?.appearance = appearance
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
        }
    }
}
