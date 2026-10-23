//
//  GridHUDPanel.swift
//  Switchly
//
//  Borderless, non-activating panel that hosts the gesture HUD.
//
//  It must never steal focus: a four-finger swipe happens while the user is
//  working in another app, so the panel is `.nonactivatingPanel`, ignores
//  mouse events and never becomes key (design spec §3.2, T16).
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class GridHUDPanel: NSPanel {
    static let shared = GridHUDPanel()

    private let viewModel: GridHUDViewModel
    private var dismissWorkItem: DispatchWorkItem?
    private var settingsCancellable: AnyCancellable?

    private init() {
        let settings = SettingsService.shared.loadSettings()
        viewModel = GridHUDViewModel(
            language: settings.language,
            material: settings.crystalMaterial,
            enableGlass: settings.enableBackgroundBlur,
            glassOpacity: settings.backgroundBlurOpacity
        )

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        contentView = NSHostingView(rootView: GridHUDView(viewModel: viewModel))
        applyAppearanceOverride(settings)
        observeSettings()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Presentation

    /// Shows the HUD for a recognised swipe. Returns the navigation the caller
    /// should run (or `.none` for the warning states).
    func present(swipe: TrackpadSwipeEvent, snapshot: DesktopSpaceSnapshot) -> GridHUDAction {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let action = viewModel.handle(swipe: swipe, snapshot: snapshot)
        show()

        if let delay = viewModel.autoDismissDelay {
            scheduleDismiss(after: delay)
        }
        return action
    }

    /// Updates the HUD after navigation finished, then hides it.
    func finish(navigation result: DesktopNavigationResult) {
        viewModel.finish(navigation: result)
        if viewModel.isVisible {
            if let delay = viewModel.autoDismissDelay {
                scheduleDismiss(after: delay)
            }
        } else {
            hide()
        }
    }

    private func show() {
        layout(on: targetScreen())
        // Already on screen (a second swipe during the same dwell): keep the
        // pill steady instead of re-fading it on every frame.
        guard !isVisible else { return }
        alphaValue = 0
        orderFrontRegardless()
        Motion.fadePanel(self, to: 1, duration: MotionTokens.panelDuration)
    }

    private func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard isVisible else { return }
        Motion.fadePanel(self, to: 0, duration: MotionTokens.panelDuration) { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
        }
        // T22: nothing keeps running once the pill is gone — no timer, no
        // animation, no settings work aimed at an invisible panel.
        viewModel.dismiss()
    }

    /// True only while the pill is on screen. The panel uses it to skip
    /// layout and settings work for a hidden HUD.
    var isShowing: Bool { isVisible }

    /// Hides immediately, without the fade. Used when the grid is switched
    /// off and the panel must not linger for another 0.22 s.
    func dismissNow() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        viewModel.dismiss()
        orderOut(nil)
        alphaValue = 1
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Layout

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let index = GridPanelLayout.screenIndex(
            containing: NSEvent.mouseLocation,
            frames: screens.map(\.frame),
            fallback: screens.firstIndex(of: NSScreen.main ?? screens[0]) ?? 0
        )
        return screens[min(index, screens.count - 1)]
    }

    /// Top-centre of the target screen's visible frame, sized to the HUD's
    /// ideal width but clamped so a narrow screen never pushes it off.
    private func layout(on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        // The copy changed before this call; lay the hosting view out first so
        // fittingSize reflects the new state rather than the previous one.
        contentView?.layoutSubtreeIfNeeded()
        let fitting = contentView?.fittingSize ?? CGSize(width: DesignTokens.Grid.HUD.maxWidth, height: 96)
        setFrame(
            GridPanelLayout.hudFrame(visibleFrame: visible, fittingSize: fitting),
            display: true
        )
    }

    // MARK: - Observers

    private func applyAppearanceOverride(_ settings: AppSettings) {
        let appearance: NSAppearance?
        switch settings.theme {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        self.appearance = appearance
        contentView?.appearance = appearance
        contentView?.needsDisplay = true
    }

    private func observeSettings() {
        settingsCancellable = NotificationCenter.default
            .publisher(for: .settingsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let settings = SettingsService.shared.loadSettings()
                self.viewModel.applySettings(settings)
                self.applyAppearanceOverride(settings)
                guard self.isVisible else { return }
                // Turning the grid off must take the pill away with the
                // listener it belongs to (T17, R10).
                guard settings.gridEnabled else {
                    self.hide()
                    return
                }
                self.layout(on: self.targetScreen())
            }
    }
}
