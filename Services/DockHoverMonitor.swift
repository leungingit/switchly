//
//  DockHoverMonitor.swift
//  Switchly
//
//  Monitors global mouse movement to detect when the cursor hovers over a
//  specific app icon in the Dock, then triggers a per-app window preview
//  positioned directly above that icon.
//

import Foundation
import AppKit
import ApplicationServices

/// Represents a Dock icon detected via the Accessibility API.
struct DockIconInfo {
    let appName: String
    let frame: CGRect
    /// The app bundle URL exposed by the Dock AX item (`AXURL`), e.g.
    /// `file:///Applications/ChatGPT Atlas.app/`. Unlike the display name this
    /// uniquely identifies one installed product, so it is the reliable key
    /// for resolving which running process the hovered icon belongs to.
    let bundleURL: URL?
}

/// Pure decisions for the dock-hover pointer loop.
///
/// Kept free of AppKit, timers and the panel so the two states that decide
/// whether the preview is stranded — "the panel is on screen" and "a
/// presentation is still in flight" — can be exercised headless.
enum DockHoverState {
    /// Whether the monitor's bookkeeping must be reset because the panel it
    /// believes it is showing is gone (dismissed by Escape, a card click, or
    /// any other path that bypasses the monitor).
    ///
    /// A presentation that is still in flight is deliberately *not* a desync.
    /// `DockPreviewPanel.show` refreshes the window list before it orders the
    /// panel on screen, and that Accessibility work can pump the run loop and
    /// land a poll tick here in between. Reading that in-between state as a
    /// desync reset `isShowing`/`currentIcon` *after* `showPreview()` had
    /// claimed them, so the panel then appeared while the monitor no longer
    /// tracked it and never auto-hid.
    static func isDesynced(isShowing: Bool,
                           isPresentationPending: Bool,
                           panelVisible: Bool) -> Bool {
        isShowing && !isPresentationPending && !panelVisible
    }

    /// Whether an on-screen panel must be dismissed for this pointer sample.
    ///
    /// The caller's own `isShowing` flag is intentionally not consulted: the
    /// panel is dismissed whenever it is actually visible and the pointer is
    /// outside both the Dock and the panel, so stale bookkeeping can never
    /// leave a panel stranded on screen.
    static func shouldDismiss(panelVisible: Bool,
                              pointerInDockArea: Bool,
                              pointerInPanel: Bool) -> Bool {
        panelVisible && !pointerInDockArea && !pointerInPanel
    }
}

class DockHoverMonitor {
    static let shared = DockHoverMonitor()

    private var globalMonitor: Any?
    private var pollTimer: Timer?
    private var showDelayTimer: Timer?
    private var hideTimer: Timer?
    private var isShowing = false
    /// True from the moment `showPreview()` claims the panel until
    /// `DockPreviewPanel.show` has actually ordered it on screen.
    ///
    /// The presentation refreshes the window list first, and that Accessibility
    /// work can pump the run loop and land a poll tick in between. Without this
    /// flag that tick looks exactly like a desync (see `processMouseLocation`),
    /// resets the monitor's state, and strands the panel once it appears.
    private var isPresentationPending = false
    private var currentIcon: DockIconInfo?
    private var lastProcessedLocation: NSPoint?
    private let pollInterval: TimeInterval = 0.05

    // Tracks whether the autohide Dock has actually slid out.
    // macOS only reveals the Dock when the cursor enters the screen edge
    // (~2px). Without this flag, isInDockArea() would return true for the
    // entire 80px strip, causing the preview to appear when the Dock is
    // still hidden.
    private var isDockRevealed = false

    // Cached configuration to avoid reading UserDefaults on every poll tick.
    private var cachedHoverDelay: Double = 0.4
    private var cachedDockAutohide = false
    private var cachedDockOrientation = "bottom"

    private init() {}

    func start() {
        guard globalMonitor == nil else { return }
        refreshCache()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                self?.processMouseLocation(location)
            }
        }
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                let location = NSEvent.mouseLocation
                DispatchQueue.main.async { [weak self] in
                    self?.processMouseLocation(location)
                }
            }
        }
        AppLogger.info("DockHoverMonitor started")
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        showDelayTimer?.invalidate()
        showDelayTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        isShowing = false
        isPresentationPending = false
        currentIcon = nil
        lastProcessedLocation = nil
        isDockRevealed = false
        AppLogger.info("DockHoverMonitor stopped")
    }

    func updateSettings() {
        let settings = SettingsService.shared.loadSettings()
        if settings.dockPreviewEnabled && settings.dockPreviewHoverEnabled {
            refreshCache()
            start()
        } else {
            stop()
        }
    }

    private func refreshCache() {
        let settings = SettingsService.shared.loadSettings()
        cachedHoverDelay = settings.dockPreviewHoverDelay

        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        cachedDockAutohide = dockDefaults?.bool(forKey: "autohide") ?? false
        cachedDockOrientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"
    }

    private func processMouseLocation(_ location: NSPoint) {
        // State recovery: if the monitor thinks the panel is showing but it's
        // actually hidden (e.g. dismissed via Escape key, thumbnail click, or
        // any other external path), reset the internal state so the next hover
        // can re-trigger the preview. Without this check, isShowing stays true
        // and currentIcon stays set, preventing any future show/hide cycle.
        // A presentation that is still in flight is not a desync: the panel is
        // not on screen yet by design, and resetting here would drop the state
        // `showPreview()` just claimed (see `DockHoverState.isDesynced`).
        if DockHoverState.isDesynced(isShowing: isShowing,
                                     isPresentationPending: isPresentationPending,
                                     panelVisible: DockPreviewPanel.shared.isVisible) {
            AppLogger.info("DockHoverMonitor state desync detected: isShowing=true but panel not visible. Resetting state.")
            isShowing = false
            currentIcon = nil
            lastProcessedLocation = nil
            showDelayTimer?.invalidate()
            showDelayTimer = nil
            hideTimer?.invalidate()
            hideTimer = nil
        }

        // Skip duplicate processing for the same location (reduces timer noise).
        // BUT: if the cursor is in the Dock area and we haven't identified an
        // icon yet, keep retrying - the Dock may still be sliding out (autohide)
        // and the AX tree may not be available yet.
        if let last = lastProcessedLocation,
           abs(last.x - location.x) < 1, abs(last.y - location.y) < 1,
           currentIcon != nil {
            return
        }
        lastProcessedLocation = location

        // Don't trigger the preview if the Dock area is obscured by the
        // frontmost application's window (e.g. full-screen IDE, maximized
        // browser). The Dock is not accessible to the user in this state.
        let inDockArea = isInDockArea(location) && !isDockAreaObscured()
        // Membership is derived from the panel itself: a panel that is on
        // screen keeps the preview alive even if the monitor's own bookkeeping
        // was reset, so the pointer can still travel up to it and click a card.
        let inPanel = DockPreviewPanel.shared.isVisible && isInPanelArea(location)

        // Keep the panel visible while the cursor is in the Dock area OR in
        // the preview panel itself. This allows the user to move the mouse
        // from the Dock icon up to the panel and click on a thumbnail.
        if inDockArea || inPanel {
            // Cancel any pending hide timer.
            hideTimer?.invalidate()
            hideTimer = nil
        }

        if inDockArea {
            // Cursor is in the Dock area. Try to identify which icon it's over.
            let hoveredIcon = dockIconAtLocation(location)

            if let icon = hoveredIcon {
                showDelayTimer?.invalidate()
                showDelayTimer = nil
                hideTimer?.invalidate()
                hideTimer = nil

                // If hovering a different icon than what's currently shown, update.
                // Compare by bundle URL when available (several products can
                // share a display name, e.g. ChatGPT and ChatGPT Atlas), and
                // fall back to the name otherwise.
                if !iconsIdentical(currentIcon, icon) {
                    currentIcon = icon
                    if isShowing {
                        // Switch to the new app immediately without re-delay.
                        AppLogger.info("Dock hover switched app. appName=\(icon.appName), bundleURL=\(icon.bundleURL?.path ?? "nil")")
                        DockPreviewPanel.shared.show(forApp: icon.appName, aboveIconFrame: icon.frame, bundleURL: icon.bundleURL)
                    }
                }

                if !isShowing && showDelayTimer == nil {
                    showDelayTimer = Timer.scheduledTimer(withTimeInterval: cachedHoverDelay, repeats: false) { [weak self] _ in
                        DispatchQueue.main.async {
                            self?.showPreview()
                        }
                    }
                }
            } else if isShowing {
                // Cursor is in the Dock area but AX didn't return an icon yet
                // (e.g. Dock is still sliding out with autohide). Keep the current
                // state unchanged - don't cancel the show timer or schedule a hide.
                // The next poll tick will retry the AX query.
            }
        } else if !inPanel {
            // Cursor left both the Dock area and the panel - schedule a hide.
            showDelayTimer?.invalidate()
            showDelayTimer = nil

            // Dismiss whenever the panel is actually on screen, even when the
            // monitor's isShowing flag is stale (a desync must never strand a
            // visible panel until something else dismisses it).
            if DockHoverState.shouldDismiss(panelVisible: DockPreviewPanel.shared.isVisible,
                                            pointerInDockArea: inDockArea,
                                            pointerInPanel: inPanel),
               hideTimer == nil {
                hideTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.hidePreview()
                    }
                }
            }
        }
        // If inPanel but not inDockArea, nothing to do - the panel stays visible.
    }

    /// Checks whether the cursor is within the preview panel's frame.
    /// This allows the user to interact with the panel (click thumbnails)
    /// without the panel being dismissed when the cursor leaves the Dock.
    private func isInPanelArea(_ point: NSPoint) -> Bool {
        let panel = DockPreviewPanel.shared
        guard panel.isVisible else { return false }
        let panelFrame = panel.frame
        return panelFrame.contains(point)
    }

    /// Quick geometric check: is the cursor in the Dock area?
    /// Used as a cheap pre-filter before the expensive AX query.
    private func isInDockArea(_ point: NSPoint) -> Bool {
        // Auto-hidden Dock height: covers the full Dock strip when slid out.
        let autohideDockSize: CGFloat = 80

        for screen in NSScreen.screens {
            let fullFrame = screen.frame
            guard fullFrame.contains(point) else { continue }

            if cachedDockAutohide {
                // With autohide, the Dock only slides out when the cursor
                // enters the screen edge (~2px). We track that state so the
                // preview only triggers when the Dock is actually visible.
                let edgeThreshold: CGFloat = 2
                switch cachedDockOrientation {
                case "left":
                    let atEdge = point.x >= fullFrame.minX && point.x <= fullFrame.minX + edgeThreshold
                    let inDock = point.x >= fullFrame.minX && point.x <= fullFrame.minX + autohideDockSize
                    if atEdge { isDockRevealed = true }
                    else if !inDock { isDockRevealed = false }
                    return inDock && isDockRevealed
                case "right":
                    let atEdge = point.x >= fullFrame.maxX - edgeThreshold && point.x <= fullFrame.maxX
                    let inDock = point.x >= fullFrame.maxX - autohideDockSize && point.x <= fullFrame.maxX
                    if atEdge { isDockRevealed = true }
                    else if !inDock { isDockRevealed = false }
                    return inDock && isDockRevealed
                default: // "bottom"
                    let atEdge = point.y >= fullFrame.minY && point.y <= fullFrame.minY + edgeThreshold
                    let inDock = point.y >= fullFrame.minY && point.y <= fullFrame.minY + autohideDockSize
                    if atEdge { isDockRevealed = true }
                    else if !inDock { isDockRevealed = false }
                    return inDock && isDockRevealed
                }
            }

            // Visible (non-autohidden) Dock: use the visibleFrame gap.
            let visibleFrame = screen.visibleFrame
            let dockHeight = visibleFrame.minY - fullFrame.minY
            let dockWidthLeft = visibleFrame.minX - fullFrame.minX
            let dockWidthRight = fullFrame.maxX - visibleFrame.maxX
            let tolerance: CGFloat = 12

            if dockHeight > 4 {
                return point.y >= fullFrame.minY && point.y <= visibleFrame.minY + tolerance
            } else if dockWidthLeft > 4 {
                return point.x >= fullFrame.minX && point.x <= visibleFrame.minX + tolerance
            } else if dockWidthRight > 4 {
                return point.x >= visibleFrame.maxX - tolerance && point.x <= fullFrame.maxX
            }
        }
        return false
    }

    /// Checks whether the frontmost application is in full-screen mode.
    /// When the frontmost app is full-screen, the Dock is hidden by macOS
    /// and the preview should not trigger, regardless of the cursor position.
    private func isDockAreaObscured() -> Bool {
        // Skip check if Switchly itself is frontmost (our panel is showing).
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier,
              frontmostApp.activationPolicy == .regular else {
            return false
        }

        // Check if the frontmost app has any windows on the current space.
        // A full-screen app lives on its own space and has no windows on the
        // current space, even though the app is the frontmost application.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let frontmostPID = frontmostApp.processIdentifier
        var hasWindowOnCurrentSpace = false

        for dict in windowList {
            guard let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmostPID,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] else { continue }

            let bounds = extractCGRect(from: boundsDict)
            // A valid window on the current space has non-zero size.
            if bounds.width > 0 && bounds.height > 0 {
                hasWindowOnCurrentSpace = true
                break
            }
        }

        // If the frontmost app has no windows on the current space, it is
        // likely in full-screen mode (or has no visible windows). In either
        // case, the Dock preview should not trigger.
        return !hasWindowOnCurrentSpace
    }

    private func extractCGRect(from dict: [String: Any]) -> CGRect {
        let x = cgFloatValue(dict["X"])
        let y = cgFloatValue(dict["Y"])
        let width = cgFloatValue(dict["Width"])
        let height = cgFloatValue(dict["Height"])
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func cgFloatValue(_ value: Any?) -> CGFloat {
        switch value {
        case let v as CGFloat: return v
        case let v as Double: return CGFloat(v)
        case let v as Int: return CGFloat(v)
        case let v as NSNumber: return CGFloat(truncating: v)
        default: return 0
        }
    }

    /// Two icons are the same product when both expose a bundle URL and they
    /// match, or when only the display name is available and it matches.
    private func iconsIdentical(_ lhs: DockIconInfo?, _ rhs: DockIconInfo) -> Bool {
        guard let lhs else { return false }
        if let lhsURL = lhs.bundleURL, let rhsURL = rhs.bundleURL {
            return lhsURL.standardizedFileURL == rhsURL.standardizedFileURL
        }
        return lhs.appName == rhs.appName
    }

    /// Finds the Dock icon at the given screen location by querying the Dock's
    /// Accessibility tree. Returns nil if the cursor is not over a Dock icon.
    ///
    /// The AX position coordinate system does not always match NSEvent's
    /// bottom-left origin (it varies across macOS versions and Dock states),
    /// so we match by horizontal proximity rather than strict `contains`.
    private func dockIconAtLocation(_ location: NSPoint) -> DockIconInfo? {
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Dock" }) else {
            return nil
        }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.5)

        // Dock -> AXList -> [AXDockItem] (each icon)
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement],
              let listElement = children.first else {
            return nil
        }

        var iconsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(listElement, kAXChildrenAttribute as CFString, &iconsValue) == .success,
              let icons = iconsValue as? [AXUIElement] else {
            return nil
        }

        // Find the icon whose horizontal center is closest to the cursor.
        // For a bottom Dock, icons are laid out horizontally, so x proximity
        // is the primary discriminator.
        var bestIcon: DockIconInfo?
        var bestDistance: CGFloat = .greatestFiniteMagnitude

        for icon in icons {
            var subroleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(icon, kAXSubroleAttribute as CFString, &subroleValue)
            let subrole = subroleValue as? String ?? ""

            // Only consider app icons (not Trash, Downloads, minimized windows).
            guard subrole == "AXApplicationDockItem" else { continue }

            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(icon, kAXTitleAttribute as CFString, &titleValue)
            guard let appName = titleValue as? String, !appName.isEmpty else { continue }

            // The Dock AX item exposes AXURL (the app bundle URL), which is
            // the only reliable identity here — several installed products can
            // share the same display title (e.g. ChatGPT and ChatGPT Atlas).
            var urlValue: CFTypeRef?
            AXUIElementCopyAttributeValue(icon, kAXURLAttribute as CFString, &urlValue)
            let bundleURL = urlValue as? URL

            // Read position and size to build the icon's frame.
            var posValue: CFTypeRef?
            AXUIElementCopyAttributeValue(icon, kAXPositionAttribute as CFString, &posValue)
            var sizeValue: CFTypeRef?
            AXUIElementCopyAttributeValue(icon, kAXSizeAttribute as CFString, &sizeValue)

            guard let posValue, let sizeValue,
                  CFGetTypeID(posValue) == AXValueGetTypeID(),
                  CFGetTypeID(sizeValue) == AXValueGetTypeID() else { continue }

            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { continue }

            let frame = CGRect(origin: position, size: size)

            // Normalize to the product root: apps that ship nested app bundles
            // (e.g. WeChat's WeChatAppEx.app inside WeChat.app) get their own
            // Dock icon, but their windows are owned by processes across the
            // whole containing bundle. Resolving to the nearest enclosing .app
            // makes both icons resolve to the same product so the preview
            // shows the product's windows instead of "No windows".
            let productURL = WindowAttribution.productRootURL(for: bundleURL)

            // Match by horizontal proximity (within the icon's width).
            // The cursor's x should be within the icon's x span.
            if location.x >= frame.minX && location.x <= frame.maxX {
                let distance = abs(location.x - frame.midX)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIcon = DockIconInfo(appName: appName, frame: frame, bundleURL: productURL)
                }
            }
        }

        return bestIcon
    }

    private func showPreview() {
        guard !isShowing, !isPresentationPending, let icon = currentIcon else { return }
        isShowing = true
        isPresentationPending = true
        AppLogger.info("Dock hover triggered show. appName=\(icon.appName), bundleURL=\(icon.bundleURL?.path ?? "nil"), iconFrame=\(icon.frame)")
        DockPreviewPanel.shared.show(forApp: icon.appName, aboveIconFrame: icon.frame, bundleURL: icon.bundleURL) { [weak self] in
            // The panel is on screen now: the state claimed above is real, so
            // the desync check may police it again.
            self?.isPresentationPending = false
        }
    }

    private func hidePreview() {
        // Hide whenever the panel is actually on screen, not only when the
        // monitor's flag agrees: that is what keeps a stranded panel from
        // staying up forever.
        guard isShowing || DockPreviewPanel.shared.isVisible else { return }
        isShowing = false
        isPresentationPending = false
        currentIcon = nil
        AppLogger.info("Dock hover leave triggered hide")
        DockPreviewPanel.shared.hide()
    }
}
