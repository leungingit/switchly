//
//  GridOverviewPanel.swift
//  Switchly
//
//  Borderless floating NSPanel that hosts the desktop grid overview.
//  Lifecycle follows PreviewPanel: one shared panel, fade in/out, layout from
//  the target screen's visibleFrame, and a clean teardown of refresh interest.
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class GridOverviewPanel: NSPanel {
    static let shared = GridOverviewPanel()

    private let viewModel: GridOverviewViewModel
    private var settingsCancellable: AnyCancellable?
    private var thumbnailInterestCancellable: AnyCancellable?
    private var isDismissing = false

    private init() {
        let settings = SettingsService.shared.loadSettings()
        viewModel = GridOverviewViewModel(
            style: settings.gridStyle,
            background: settings.gridBackground,
            language: settings.language,
            material: settings.crystalMaterial,
            glassOpacity: settings.backgroundBlurOpacity,
            enableGlass: settings.enableBackgroundBlur
        )

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        contentView = NSHostingView(
            rootView: GridOverviewView(
                viewModel: viewModel,
                thumbnailLoader: Self.loadThumbnail,
                openSystemSettings: Self.openSystemSettings,
                openMissionControl: Self.openMissionControl
            )
        )

        // T15: the overview no longer logs a placeholder; selecting a desktop
        // goes through the same navigation service the gestures use.
        viewModel.onSwitchRequested = { desktop in
            Task { @MainActor in
                let result = await DesktopGridCoordinator.shared.switchToDesktop(number: desktop.number)
                AppLogger.info("Desktop grid switch requested. target=\(desktop.number), result=\(result)")
            }
        }

        applyAppearanceOverride(settings)
        applyRoundedCorners(style: settings.gridStyle)
        observeSettings()
        observeThumbnailInterest()
    }

    // MARK: - Presentation

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let settings = SettingsService.shared.loadSettings()
        // R10: the master switch is the only gate. A stale menu item (or a
        // shortcut registered a moment ago) must not open the overview while
        // the grid is off; the menu entry is disabled in that state too.
        guard settings.gridEnabled else {
            AppLogger.info("Desktop grid open ignored. reason=grid_disabled")
            return
        }
        viewModel.applySettings(settings)
        applyAppearanceOverride(settings)
        applyRoundedCorners(style: settings.gridStyle)
        layout(on: targetScreen(), style: settings.gridStyle)

        isDismissing = false
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Motion.fadePanel(self, to: 1, duration: MotionTokens.panelDuration)

        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.activate()
            self.updateThumbnailInterest()
        }

        AppLogger.info("Desktop grid shown. style=\(settings.gridStyle.rawValue), background=\(settings.gridBackground.rawValue), visibleFrame=\(frame)")
    }

    func hide() {
        viewModel.deactivate()
        ThumbnailService.shared.clearRefreshInterest(owner: self)

        guard isVisible, !isDismissing else {
            orderOut(nil)
            return
        }

        isDismissing = true
        Motion.fadePanel(self, to: 0, duration: MotionTokens.panelDuration) { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            self.isDismissing = false
        }
        AppLogger.info("Desktop grid hidden. windows=\(viewModel.windowsShownByOverview.count)")
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

    private func layout(on screen: NSScreen?, style: GridStyle) {
        guard let visible = screen?.visibleFrame else { return }
        setFrame(
            GridPanelLayout.overviewFrame(style: style, visibleFrame: visible, margin: 48),
            display: true
        )
    }

    private func applyRoundedCorners(style: GridStyle) {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = style == .b ? DesignTokens.Radius.panel : 0
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
    }

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

    // MARK: - Observers

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
                if !settings.gridEnabled {
                    self.hide()
                    return
                }
                self.applyRoundedCorners(style: settings.gridStyle)
                self.layout(on: self.targetScreen(), style: settings.gridStyle)
            }
    }

    private func observeThumbnailInterest() {
        thumbnailInterestCancellable = viewModel.$thumbnailRevision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateThumbnailInterest()
                }
            }
    }

    private func updateThumbnailInterest() {
        guard isVisible else { return }
        ThumbnailService.shared.setRefreshInterest(
            viewModel.windowsShownByOverview,
            owner: self,
            tier: .grid
        )
    }

    // MARK: - Keyboard

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            hide()
            return true
        case 123: // Left
            viewModel.moveSelection(.left)
            return true
        case 124: // Right
            viewModel.moveSelection(.right)
            return true
        case 125: // Down
            viewModel.moveSelection(.down)
            return true
        case 126: // Up
            viewModel.moveSelection(.up)
            return true
        case 36, 76: // Return / keypad Enter
            viewModel.activateSelection()
            return true
        default:
            break
        }

        // ⌃1…⌃9: select + callback only. The actual Space switch is T15.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.control),
           let characters = event.charactersIgnoringModifiers,
           let number = Int(characters),
           (1...9).contains(number) {
            viewModel.selectAndActivate(number)
            return true
        }

        // Tab / Shift-Tab walk the nine cells in visual order (T21).
        if event.keyCode == 48 {
            let forward = !modifiers.contains(.shift)
            viewModel.focusAdjacent(forward: forward)
            return true
        }

        return false
    }

    override func resignKey() {
        super.resignKey()
        guard isVisible, !isDismissing else { return }
        hide()
    }

    // MARK: - Production adapters

    private static func loadThumbnail(for window: WindowInfo, size: CGSize) async -> NSImage? {
        if let cached = ThumbnailService.shared.getCachedThumbnail(for: window, tier: .grid) {
            return cached
        }
        return try? await ThumbnailService.shared.captureThumbnail(
            for: window,
            size: size,
            tier: .grid
        )
    }

    private static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func openMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                AppLogger.warning("Could not open Mission Control. error=\(error.localizedDescription)")
            }
        }
    }
}
