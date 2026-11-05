//
//  WindowAction.swift
//  Switchly
//
//  Accessibility-backed window operations (close, minimize, zoom) shared by
//  every preview surface that draws traffic light buttons.
//

import ApplicationServices
import Foundation

/// Helper to perform common window operations (close, minimize, zoom)
/// via the Accessibility API.
enum WindowAction {
    static func close(_ window: WindowInfo) {
        guard let axWindow = AccessibilityService.shared.findAXWindow(for: window) else {
            AppLogger.warning("WindowAction.close: could not find AX window. windowID=\(window.id)")
            return
        }
        guard let button = findTrafficLightButton(in: axWindow, subrole: "AXCloseButton") else {
            AppLogger.warning("WindowAction.close: could not find close button. windowID=\(window.id)")
            return
        }
        if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            AppLogger.info("Window closed via dock preview. windowID=\(window.id)")
            notifyWindowListChanged()
        } else {
            AppLogger.warning("WindowAction.close: press action failed. windowID=\(window.id)")
        }
    }

    static func minimize(_ window: WindowInfo) {
        guard let axWindow = AccessibilityService.shared.findAXWindow(for: window) else {
            AppLogger.warning("WindowAction.minimize: could not find AX window. windowID=\(window.id)")
            return
        }
        if AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
            AppLogger.info("Window minimized via dock preview. windowID=\(window.id)")
            notifyWindowListChanged()
        } else {
            AppLogger.warning("WindowAction.minimize: failed to set minimized attribute. windowID=\(window.id)")
        }
    }

    static func zoom(_ window: WindowInfo) {
        guard let axWindow = AccessibilityService.shared.findAXWindow(for: window) else {
            AppLogger.warning("WindowAction.zoom: could not find AX window. windowID=\(window.id)")
            return
        }
        guard let button = findTrafficLightButton(in: axWindow, subrole: "AXZoomButton") else {
            AppLogger.warning("WindowAction.zoom: could not find zoom button. windowID=\(window.id)")
            return
        }
        if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            AppLogger.info("Window zoomed via dock preview. windowID=\(window.id)")
            notifyWindowListChanged()
        } else {
            AppLogger.warning("WindowAction.zoom: press action failed. windowID=\(window.id)")
        }
    }

    /// Posts a notification so the preview panels refresh their window list
    /// immediately after an AX window operation.
    private static func notifyWindowListChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
        }
    }

    /// Finds a traffic light button (close/minimize/zoom) by its AX subrole
    /// from the direct children of the given window element.
    /// Sets a short messaging timeout to avoid hanging on slow apps.
    private static func findTrafficLightButton(in axWindow: AXUIElement, subrole: String) -> AXUIElement? {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXChildrenAttribute as CFString, &children) == .success,
              let buttons = children as? [AXUIElement] else {
            return nil
        }
        for button in buttons {
            AXUIElementSetMessagingTimeout(button, 0.5)
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(button, kAXSubroleAttribute as CFString, &role)
            if (role as? String) == subrole {
                return button
            }
        }
        return nil
    }
}
