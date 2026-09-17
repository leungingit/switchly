//
//  DockPreviewPanel.swift
//  Switchly
//
//  NSPanel for per-app dock preview - positioned directly above the
//  hovered Dock icon, showing that app's window thumbnails.
//

import SwiftUI
import AppKit
import Combine

class DockPreviewPanel: NSPanel {
    static let shared = DockPreviewPanel()

    private var keyDownMonitor: Any?
    private var isDismissing = false
    private var isSwitching = false

    /// Bumped on every show; a dismissal animation only closes the panel
    /// when its generation is still current (see `hide()`).
    private var generation = 0

    private let viewModel = DockPreviewViewModel()
    private var panelWidthCancellable: AnyCancellable?
    private var interestCancellable: AnyCancellable?
    private var currentIconFrame: CGRect = .zero

    private init() {
        let contentRect = NSRect(x: 0, y: 0, width: 300, height: 180)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isOpaque = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false

        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        let hostingView = NSHostingView(rootView: DockPreviewView(viewModel: viewModel))
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView
        applyRoundedCorners()

        setupKeyHandling()
        observePanelWidth()
        observeRefreshInterest()
    }

    /// Points the thumbnail auto-refresh tick at the windows this panel shows
    /// while it is on screen, and clears the interest when it dismisses —
    /// otherwise the tick kept re-capturing (and re-animating) every cached
    /// window in the app while the user was doing something else entirely.
    private func observeRefreshInterest() {
        interestCancellable = viewModel.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                guard let self, self.isVisible else { return }
                ThumbnailService.shared.setRefreshInterest(Set(windows.map(\.id)))
            }
    }

    private func publishRefreshInterest() {
        guard isVisible else { return }
        ThumbnailService.shared.setRefreshInterest(Set(viewModel.windows.map(\.id)))
    }

    private func observePanelWidth() {
        panelWidthCancellable = viewModel.$panelWidth
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                // Content width changed while visible (icon switch, or the
                // window list refreshed): spring to the new frame.
                Motion.movePanel(
                    self,
                    to: self.frameForCurrentContent(),
                    duration: MotionTokens.morphDuration
                )
            }
    }

    override var canBecomeKey: Bool {
        false
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    /// Show the per-app preview positioned above the hovered Dock icon.
    ///
    /// `bundleURL` is the app bundle URL read from the Dock AX item (AXURL).
    /// When present it uniquely identifies the hovered product even when
    /// several products share a display name (e.g. ChatGPT and ChatGPT Atlas).
    ///
    /// `completion` runs on the main thread once the panel has been ordered on
    /// screen. The caller uses it to tell an in-flight presentation from a
    /// desync: the window list is refreshed (with Accessibility work that can
    /// pump the run loop) before the panel is ordered front, so until this
    /// fires the panel is legitimately not visible yet.
    func show(forApp appName: String,
              aboveIconFrame iconFrame: CGRect,
              bundleURL: URL? = nil,
              completion: (() -> Void)? = nil) {
        currentIconFrame = iconFrame
        viewModel.showPanel(forApp: appName, bundleURL: bundleURL)
        // Resize and position after the view model has loaded windows.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            let finalFrame = self.frameForCurrentContent()
            if self.isVisible {
                // Hovering a different Dock icon: slide the panel to the new
                // icon (position + width) with the morph timing. Bumping the
                // generation also cancels a dismissal animation that may
                // still be fading the panel out.
                self.generation += 1
                self.isDismissing = false
                Motion.movePanel(self, to: finalFrame, duration: MotionTokens.morphDuration)
                Motion.fadePanel(self, to: 1, duration: MotionTokens.morphDuration)
            } else {
                // First show: grow out of the Dock icon — start one lift-step
                // lower and fully transparent, then spring up into place.
                // Counted only here: sliding between already-hovered icons
                // re-shows a visible panel and must not re-count.
                UsageStatisticsService.shared.record(.previewPresented, source: .dockHover, at: Date())
                self.generation += 1
                self.isDismissing = false
                var startFrame = finalFrame
                startFrame.origin.y -= MotionTokens.dockLift
                self.setFrame(startFrame, display: true)
                self.alphaValue = 0
                self.orderFront(nil)
                Motion.fadePanel(self, to: 1, duration: MotionTokens.morphDuration)
                Motion.movePanel(self, to: finalFrame, duration: MotionTokens.morphDuration)
            }
            // Publish here rather than relying on the $windows sink: the
            // panel only becomes visible in this block, and the sink fires
            // before that (the view model assigns windows synchronously in
            // showPanel, ahead of orderFront).
            self.publishRefreshInterest()
            AppLogger.info("Showing dock preview panel. appName=\(appName), bundleURL=\(bundleURL?.path ?? "nil"), isVisible=\(self.isVisible)")
            completion?()
        }
    }

    /// The frame the panel needs for its current content, positioned above
    /// the hovered Dock icon. Single source of truth for both the instant
    /// resize path and the animated slide between icons.
    ///
    /// AX icon positions may use a different coordinate origin than NSEvent
    /// (it varies across macOS versions and Dock magnification states), so we
    /// only trust the x coordinate for horizontal alignment. The vertical
    /// position is derived from the screen geometry (Dock edge + gap).
    private func frameForCurrentContent() -> NSRect {
        let panelWidth = viewModel.panelWidth
        let gap: CGFloat = 8 // Space between the Dock and the panel.

        // Use the icon's x center for horizontal alignment.
        let iconCenterX = currentIconFrame.midX
        let originX = iconCenterX - panelWidth / 2

        // Find the screen containing the mouse cursor.
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let screen else {
            return NSRect(
                x: max(0, (NSScreen.main?.frame.midX ?? 400) - panelWidth / 2),
                y: max(0, (NSScreen.main?.frame.midY ?? 300) - viewModel.panelHeight / 2),
                width: panelWidth,
                height: viewModel.panelHeight
            )
        }

        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        // Clamp x so the panel stays on-screen.
        let clampedX = max(visibleFrame.minX, min(originX, visibleFrame.maxX - panelWidth))

        // Determine vertical position based on Dock orientation / autohide.
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let autohide = dockDefaults?.bool(forKey: "autohide") ?? false
        let orientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"

        let originY: CGFloat
        switch orientation {
        case "left":
            originY = visibleFrame.midY - 90
        case "right":
            originY = visibleFrame.midY - 90
        default: // "bottom"
            let dockTopY = autohide ? fullFrame.minY + 80 : visibleFrame.minY
            originY = dockTopY + gap
        }

        return NSRect(x: clampedX, y: originY, width: panelWidth, height: viewModel.panelHeight)
    }

    func hide() {
        guard !isDismissing else {
            return
        }
        isDismissing = true
        let generationAtDismiss = generation
        viewModel.hidePanel()
        AppLogger.info("Hiding dock preview panel. isVisible=\(isVisible)")
        Motion.fadePanel(self, to: 0, duration: MotionTokens.panelDuration) { [weak self] in
            guard let self else {
                return
            }
            guard generationAtDismiss == self.generation else {
                // Another Dock icon was hovered mid-animation; the panel was
                // re-shown and must stay on screen.
                self.isDismissing = false
                return
            }
            ThumbnailService.shared.setRefreshInterest([])
            self.orderOut(nil)
            self.alphaValue = 1
            self.isDismissing = false
        }
    }

    /// Pointer-only commit path: the click on a window card. Recorded as a
    /// confirmed switch so it reaches the flows and the counts.
    func switchToWindowAndHide(_ window: WindowInfo) {
        isSwitching = true
        UsageStatisticsService.shared.record(.previewSwitchCommitted, source: .dockHover, at: Date())
        viewModel.selectedWindow = window
        hide()
        Task { [weak self] in
            await self?.viewModel.switchToWindowAndHide(window)
            await MainActor.run {
                self?.isSwitching = false
            }
        }
    }

    private func setupKeyHandling() {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else {
                return event
            }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            hide()
            return true
        case 48: // Tab
            viewModel.selectWindow(offset: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 123: // Left
            viewModel.selectWindow(offset: -1)
            return true
        case 124: // Right
            viewModel.selectWindow(offset: 1)
            return true
        case 36, 76: // Enter
            Task {
                await viewModel.switchToSelectedWindow()
            }
            return true
        default:
            return false
        }
    }

    private func applyRoundedCorners() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = GlassPanelCorner.radius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
    }

}

extension Notification.Name {
    static let toggleDockPreview = Notification.Name("com.switchly.toggleDockPreview")
}
