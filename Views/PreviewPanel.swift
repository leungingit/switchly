//
//  PreviewPanel.swift
//  Switchly
//
//  NSPanel for floating window preview
//

import SwiftUI
import AppKit
import Combine

/// Panel geometry, resolved from the target screen instead of hard-coded.
///
/// The panel used to be a fixed 800x500 pt, which could overflow the visible
/// frame on a small display. Every consumer — the AppKit frame, the SwiftUI
/// layout, the dismissal zoom anchor and the grid column count — now reads its
/// size from one place, so the copies of "800" the old code carried cannot drift
/// apart.
enum PreviewPanelMetrics {
    /// Content size used before a screen has been resolved (and by tests).
    /// Equal to the historical fixed size, so the panel looks unchanged on every
    /// screen that fits it.
    static let fallbackSize = CGSize(width: 800, height: 500)

    /// Smallest usable panel. Below this the header and the grid stop fitting;
    /// the visible-frame clamp still wins on a screen smaller than this.
    static let minimumSize = CGSize(width: 560, height: 360)

    /// Gap kept between the panel and the screen's visible frame on every edge.
    static let screenMargin: CGFloat = 24

    /// Content size for one screen's visible frame.
    ///
    /// One size for every mode: the merged enlarged mode does not grow the panel
    /// — it keeps the thumbnail grid exactly as the highlight-only mode draws it
    /// and adds the window replica *behind* the panel
    /// (docs/plan/2026-09-28-preview-panel-live-switch.md §15). The two panels
    /// the earlier design used (0.85 and 0.72 of the visible frame) are gone with
    /// the pane they existed for.
    ///
    /// The panel can never exceed the visible frame (minus `screenMargin`): the
    /// requested size is clamped up to `minimumSize` and then down to the
    /// available area, so a display smaller than the minimum gets the available
    /// area rather than a panel hanging off the edge.
    static func contentSize(visibleFrame: CGSize) -> CGSize {
        let available = CGSize(
            width: max(1, visibleFrame.width - screenMargin * 2),
            height: max(1, visibleFrame.height - screenMargin * 2)
        )

        return CGSize(
            width: min(max(fallbackSize.width, minimumSize.width), available.width),
            height: min(max(fallbackSize.height, minimumSize.height), available.height)
        )
    }

    /// Origin that centers `size` inside `visibleFrame`.
    static func centeredOrigin(size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
    }

    /// Unit point of a card's center in panel space, used as the dismissal zoom
    /// anchor. Clamped so a partially scrolled card still points inward.
    static func zoomAnchor(cardFrame: CGRect, panelSize: CGSize) -> UnitPoint {
        guard panelSize.width > 0, panelSize.height > 0 else {
            return .center
        }
        return UnitPoint(
            x: min(max(cardFrame.midX / panelSize.width, 0), 1),
            y: min(max(cardFrame.midY / panelSize.height, 0), 1)
        )
    }
}

class PreviewPanel: NSPanel {
    static let shared = PreviewPanel()

    private var keyDownMonitor: Any?
    private var visibilityCancellable: AnyCancellable?
    private var interestCancellable: AnyCancellable?
    private var replicaCancellable: AnyCancellable?
    private var thumbnailCancellable: AnyCancellable?
    private var isDismissing = false
    private var isSwitching = false

    /// Bumped on every show. A dismissal animation only closes the panel when
    /// the generation it started with is still current — otherwise the panel
    /// was re-shown mid-animation and must stay on screen.
    private var generation = 0

    private let viewModel = PreviewViewModel()
    
    private init() {
        let contentRect = NSRect(origin: .zero, size: PreviewPanelMetrics.fallbackSize)
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
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isOpaque = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isReleasedWhenClosed = false
        
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
        
        let hostingView = NSHostingView(rootView: PreviewView(viewModel: viewModel))
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView
        applyAppearanceOverride()
        applyRoundedCorners()

        layoutForDisplayMode()
        setupKeyHandling()
        observePanelVisibility()
        observeReplicaWindow()
        observeThumbnails()
    }

    /// Keeps the NSPanel in sync with view-model driven hides (e.g. the
    /// single-window auto-switch safety net) so the panel can never stay on
    /// screen while `isPanelVisible` is false, and points the thumbnail
    /// auto-refresh tick at the windows this panel actually shows.
    private func observePanelVisibility() {
        visibilityCancellable = viewModel.$isPanelVisible
            // dropFirst skips the current-value replay that @Published sends
            // to new subscribers; without it the replayed `false` (delivered
            // after the panel is already on screen) would dismiss it.
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                guard let self else {
                    return
                }
                if visible {
                    self.publishRefreshInterest(self.viewModel.filteredWindows)
                } else {
                    // Panel gone: the tick must do zero capture work.
                    self.clearRefreshInterest()
                }
                guard self.isVisible, !visible, !self.isDismissing else {
                    return
                }
                self.dismissPanel()
            }

        interestCancellable = viewModel.$filteredWindows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                self?.publishRefreshInterest(windows)
            }
    }

    /// Re-publishes interest for the replica's tier whenever the replayed window
    /// changes, so its bitmap is the one entry the auto-refresh tick keeps warm
    /// while the panel is open.
    private func observeReplicaWindow() {
        replicaCancellable = viewModel.replicaWindowSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else {
                    return
                }
                self.publishReplicaRefreshInterest()
                // The replica shows the same window the highlight is on, so it
                // moves with it.
                self.syncReplica()
            }
    }

    /// Re-syncs the replica when a native capture lands: the transitional grid
    /// thumbnail is replaced by the 1:1 window as soon as it exists, and a
    /// replica that had nothing to draw yet appears at all.
    private func observeThumbnails() {
        thumbnailCancellable = NotificationCenter.default.publisher(for: .thumbnailDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let windowID = notification.object as? CGWindowID,
                      windowID == self.viewModel.replicaWindow?.id,
                      (notification.userInfo?["tier"] as? String) == ThumbnailTier.native.rawValue else {
                    return
                }
                self.syncReplica()
            }
    }

    /// Publishes the window IDs each visible region shows: the grid tier for the
    /// whole grid, and the replica's tier for the single replayed window. No-op
    /// (empty interest) while the panel is off screen.
    private func publishRefreshInterest(_ windows: [WindowInfo]) {
        guard isVisible else {
            clearRefreshInterest()
            return
        }
        ThumbnailService.shared.setRefreshInterest(Set(windows.map(\.id)), owner: self)
        publishReplicaRefreshInterest()
    }

    /// The enlarged surface replays exactly one window, so it publishes that
    /// window's interest to the tier the current mode captures through — and
    /// clears it in the other mode, so a panel with no replica never keeps a
    /// window-sized bitmap warm.
    private func publishReplicaRefreshInterest() {
        let mode = SettingsService.shared.loadSettings().previewInteractionMode
        let replicaIDs = mode.showsWindowReplica
            ? viewModel.replicaWindow.map { Set([$0.id]) } ?? []
            : []
        ThumbnailService.shared.setRefreshInterest(replicaIDs, owner: self, tier: mode.replicaTier)
    }

    private func clearRefreshInterest() {
        // Owner-scoped: drops only this panel's registration. The old form
        // cleared every tier globally, which also erased the Dock preview
        // panel's interest — its windows then stopped auto-refreshing until
        // its next publish (~1 s later).
        ThumbnailService.shared.clearRefreshInterest(owner: self)
    }

    override var canBecomeKey: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if handlePreviewKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func resignKey() {
        super.resignKey()
        guard isVisible, !isSwitching else {
            return
        }
        dismissPanel()
    }
    
    func show(source: UsageEventSource = .unknown) {
        presentPanel(zoomAnchor: .center, source: source)
    }

    /// Shows the panel with a fade + rise entrance: the SwiftUI content
    /// scales from `zoomAnchor` while the panel's `alphaValue` animates in,
    /// so the panel feels like it grows out of the invocation point.
    private func presentPanel(zoomAnchor: UnitPoint, source: UsageEventSource) {
        generation += 1
        // Counted here, at the one place that actually puts the panel on
        // screen: the shortcut is a toggle, so counting the notification would
        // also count closing it.
        UsageStatisticsService.shared.record(.previewPresented, source: source, at: Date())
        viewModel.dismissAnchor = zoomAnchor
        viewModel.showPanel()
        layoutForDisplayMode()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncReplica()
        Motion.fadePanel(self, to: 1, duration: MotionTokens.panelDuration)
        NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
    }
    
    func hide() {
        dismissPanel()
    }

    func toggleVisibility(source: UsageEventSource = .unknown) {
        if isVisible {
            hide()
        } else {
            show(source: source)
        }
    }

    func showWindows(for app: MonitoredApp, source: UsageEventSource = .unknown) {
        showWindows(for: [app], source: source)
    }

    func showWindows(for apps: [MonitoredApp], source: UsageEventSource = .unknown) {
        generation += 1
        UsageStatisticsService.shared.record(.previewPresented, source: source, at: Date())
        viewModel.dismissAnchor = .center
        viewModel.showWindows(for: apps)
        layoutForDisplayMode()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncReplica()
        Motion.fadePanel(self, to: 1, duration: MotionTokens.panelDuration)
    }

    /// - Parameter source: how the user confirmed. Defaults to a click because
    ///   the pointer path is the only caller that reaches this without going
    ///   through the keyboard handler.
    func switchToWindowAndHide(_ window: WindowInfo, source: UsageEventSource = .panelClick) {
        isSwitching = true
        UsageStatisticsService.shared.record(.previewSwitchCommitted, source: source, at: Date())
        viewModel.selectWindow(window)
        dismissPanel(zoomAnchor: zoomAnchor(for: window))
        Task {
            let success = await viewModel.switchToWindow(window)
            await MainActor.run {
                self.isSwitching = false
                if !success {
                    WindowSwitchFeedback.presentFailure(language: SettingsService.shared.loadSettings().language)
                }
            }
        }
    }

    /// Dismisses the panel with a zoom-toward-target animation: the SwiftUI
    /// content scales down toward `zoomAnchor` (the activated card) while the
    /// panel fades out, so a switch reads as the panel collapsing into the
    /// window that is about to be focused.
    ///
    /// - Parameter zoomAnchor: Panel-space unit point to collapse toward.
    private func dismissPanel(zoomAnchor: UnitPoint = .center) {
        guard !isDismissing else {
            return
        }
        isDismissing = true
        let generationAtDismiss = generation
        viewModel.dismissAnchor = zoomAnchor
        viewModel.hidePanel()
        // The replica leaves with the panel rather than after it.
        PreviewReplicaPanel.shared.dismiss(fadeDuration: MotionTokens.panelDuration)
        AppLogger.info("Dismissing preview panel. isVisible=\(isVisible)")
        Motion.fadePanel(self, to: 0, duration: MotionTokens.panelDuration) { [weak self] in
            guard let self else {
                return
            }
            guard generationAtDismiss == self.generation else {
                // Re-shown while the dismissal animation was still running;
                // the panel must stay on screen.
                self.isDismissing = false
                return
            }
            self.orderOut(nil)
            self.close()
            self.alphaValue = 1
            self.isDismissing = false
        }
    }

    /// Panel-space unit point of a card's center, used as the dismissal zoom
    /// anchor. Falls back to the panel center when the frame is unknown
    /// (e.g. the card was recycled out of the lazy grid).
    private func zoomAnchor(for window: WindowInfo?) -> UnitPoint {
        guard let window,
              let frame = viewModel.cardFrames[window.id] else {
            return .center
        }
        // Normalized against the panel's *current* content size, not a
        // constant: the panel is clamped to the visible frame, so on a display
        // that cannot hold the requested size a stale denominator would throw
        // the collapse off its target.
        return PreviewPanelMetrics.zoomAnchor(cardFrame: frame, panelSize: viewModel.panelSize)
    }

    private func setupKeyHandling() {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else {
                return event
            }
            return self.handlePreviewKey(event) ? nil : event
        }
    }

    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            // ESC clears an active search first; only a second ESC (empty
            // query) dismisses the panel. Keyboard users otherwise lose
            // their query and the panel in one keystroke.
            if !viewModel.searchText.isEmpty {
                viewModel.searchText = ""
            } else {
                hide()
            }
            return true
        case 48:
            viewModel.selectNextWindow(reverse: event.modifierFlags.contains(.shift))
            return true
        case 123:
            viewModel.selectWindow(offset: -1)
            return true
        case 124:
            viewModel.selectWindow(offset: 1)
            return true
        case 125:
            viewModel.selectWindow(offset: viewModel.gridColumnCount)
            return true
        case 126:
            viewModel.selectWindow(offset: -viewModel.gridColumnCount)
            return true
        case 36, 76:
            if viewModel.selectedWindow == nil {
                viewModel.selectedWindow = viewModel.filteredWindows.first
            }
            guard viewModel.selectedWindow != nil else {
                return true
            }
            UsageStatisticsService.shared.record(.previewSwitchCommitted, source: .panelKeyboard, at: Date())
            dismissPanel(zoomAnchor: zoomAnchor(for: viewModel.selectedWindow))
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

    /// Applies the user's theme choice to this borderless panel.
    ///
    /// The crystal tokens resolve against the window appearance, and a
    /// borderless panel does not follow `NSApp.appearance` on its own. Without
    /// this, cutting the theme over to Light/Dark left the panel painting the
    /// previous polarity until the next launch.
    func applyAppearanceOverride() {
        let appearance: NSAppearance?

        switch SettingsService.shared.loadSettings().theme {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }

        self.appearance = appearance
        contentView?.appearance = appearance
        contentView?.needsDisplay = true
        invalidateShadow()
    }

    /// Resolves the screen the panel opens on for the current display mode.
    private func targetScreen(for settings: AppSettings) -> NSScreen? {
        switch settings.previewDisplayMode {
        case .primaryScreen:
            return NSScreen.main
        case .currentScreen:
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first { screen in
                screen.frame.contains(mouseLocation)
            } ?? NSScreen.main
        }
    }

    /// Sizes and centers the panel for the current display mode.
    ///
    /// The size is published to the view model *before* the frame is applied,
    /// because the SwiftUI content is laid out from `panelSize` — the panel and
    /// its content must agree on the panel's dimensions, or the grid would be
    /// laid out from a stale constant.
    @discardableResult
    private func layoutForDisplayMode() -> CGSize {
        let settings = SettingsService.shared.loadSettings()

        guard let visibleFrame = targetScreen(for: settings)?.visibleFrame else {
            let size = PreviewPanelMetrics.fallbackSize
            viewModel.panelSize = size
            setContentSize(size)
            center()
            return size
        }

        let size = PreviewPanelMetrics.contentSize(visibleFrame: visibleFrame.size)
        viewModel.panelSize = size
        setContentSize(size)
        let origin = PreviewPanelMetrics.centeredOrigin(size: size, in: visibleFrame)
        setFrameOrigin(origin)
        AppLogger.debug("Laid out preview panel. displayMode=\(settings.previewDisplayMode.rawValue), mode=\(settings.previewInteractionMode.rawValue), size=\(size), origin=\(origin), visibleFrame=\(visibleFrame)")
        return size
    }

    /// Re-applies the layout after a settings change that affects the panel's
    /// size or presentation (interaction mode). No-op while hidden — the next
    /// `presentPanel` lays out anyway.
    func refitToDisplayMode() {
        guard isVisible else {
            return
        }
        layoutForDisplayMode()
        syncReplica()
    }

    /// Keeps the window replica in step with the panel.
    ///
    /// Only the merged enlarged mode uses it, it follows the highlighted window,
    /// and it is never on screen without the panel. The rectangle comes from the
    /// window's own bounds, so the replica is the size and place of the window
    /// itself; the image comes from the native cache tier, which is captured at
    /// the window's size in display pixels and drawn 1:1.
    ///
    /// Until that capture lands, the grid thumbnail stands in so the replica is
    /// the window's shape rather than an empty frame — and while there is no
    /// image at all (and the capture is not in its failure cooldown) the replica
    /// stays off screen instead of parking an empty window-sized rectangle next
    /// to the panel. The capture notification re-enters here.
    private func syncReplica() {
        let settings = SettingsService.shared.loadSettings()
        let mode = settings.previewInteractionMode
        let screen = targetScreen(for: settings)

        guard mode.showsWindowReplica, isVisible, !isDismissing,
              let screen, let window = viewModel.replicaWindow else {
            PreviewReplicaPanel.shared.dismiss(fadeDuration: MotionTokens.panelDuration)
            return
        }

        let rect = replicaRect(for: window, on: screen)
        guard let image = replicaImage(for: window) else {
            PreviewReplicaPanel.shared.dismiss(fadeDuration: MotionTokens.panelDuration)
            requestReplicaCaptureIfNeeded(for: window)
            return
        }

        PreviewReplicaPanel.shared.show(
            image: image,
            rect: rect,
            fadeDuration: MotionTokens.panelDuration
        )
        AppLogger.debug(
            "Window replica synced. mode=" + mode.rawValue
                + ", windowID=" + String(window.id)
                + ", rect=" + NSStringFromRect(rect)
                + ", isNative=" + String(hasNativeImage(for: window))
        )
        requestReplicaCaptureIfNeeded(for: window)
    }

    /// Where the replica goes: the window's own rectangle, in the coordinates of
    /// the screen the panel opened on.
    ///
    /// `WindowInfo.bounds` comes from `kCGWindowBounds`, which counts y downward
    /// from the top of the primary display; the conversion back to Cocoa's
    /// upward axis happens in `PreviewReplicaPanel.replicaRect`.
    private func replicaRect(for window: WindowInfo, on screen: NSScreen) -> CGRect {
        PreviewReplicaPanel.replicaRect(
            forWindowBounds: window.bounds,
            primaryScreenHeight: NSScreen.screens.first?.frame.height ?? screen.frame.height,
            visibleFrame: screen.visibleFrame
        )
    }

    /// The image the replica should show right now: the 1:1 native capture when
    /// it exists, otherwise the grid thumbnail standing in.
    private func replicaImage(for window: WindowInfo) -> NSImage? {
        let service = ThumbnailService.shared
        if let native = service.getCachedThumbnail(for: window, tier: .native) {
            return native
        }
        return service.getCachedThumbnail(for: window, tier: .grid)
    }

    private func hasNativeImage(for window: WindowInfo) -> Bool {
        ThumbnailService.shared.getCachedThumbnail(for: window, tier: .native) != nil
    }

    /// Asks for a native capture of the replayed window — the window at its own
    /// size. Skipped while the key is in its failure cooldown, so a window that
    /// cannot be captured does not get retried on every sync.
    private func requestReplicaCaptureIfNeeded(for window: WindowInfo) {
        let service = ThumbnailService.shared
        guard service.getCachedThumbnail(for: window, tier: .native) == nil,
              !service.failedRecently(for: window, tier: .native) else {
            return
        }
        service.preheatThumbnails(
            for: [window],
            size: window.bounds.size,
            tier: .native,
            reason: "replica"
        )
    }
}

struct PreviewView: View {
    @StateObject private var viewModel: PreviewViewModel
    @State private var settings = SettingsService.shared.loadSettings()
    @FocusState private var searchFocused: Bool

    init(viewModel: PreviewViewModel = PreviewViewModel(), settings: AppSettings = SettingsService.shared.loadSettings()) {
        _settings = State(initialValue: settings)
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    var body: some View {
        // Each style draws its own structure. The stage adds the ornament rail
        // and the focus banner and runs tighter cells; the classic grid draws a
        // plain matrix. Sharing one body is fine — sharing one *layout* was not
        // (D20: layouts must follow each surface's function).
        HStack(spacing: 14) {
            if settings.previewPanelStyle == .stage {
                spatialOrnamentRail
            }

            VStack(spacing: 0) {
                header
                if settings.previewPanelStyle == .stage,
                   let focused = viewModel.selectedWindow ?? viewModel.filteredWindows.first {
                    spatialFocusStageBanner(for: focused)
                }
                windowGrid
            }
        }
        .frame(width: viewModel.panelSize.width, height: viewModel.panelSize.height)
        .scaleEffect(viewModel.isPanelVisible ? 1 : 0.94, anchor: viewModel.dismissAnchor)
        .opacity(viewModel.isPanelVisible ? 1 : 0)
        .animation(MotionTokens.panelSpring, value: viewModel.isPanelVisible)
        .coordinateSpace(name: PreviewPanelSpace.name)
        .onPreferenceChange(PreviewCardFrameKey.self) { frames in
            viewModel.cardFrames = frames
        }
        .panelGlass(
            isActive: (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque),
            opacity: backgroundOpacity,
            cornerRadius: GlassPanelCorner.radius,
            material: settings.crystalMaterial
        )
        .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 12)
        .onAppear {
            viewModel.updateGridColumnCount(width: viewModel.panelSize.width, settings: settings)
            viewModel.refreshWindows()
        }
        .onChange(of: viewModel.isPanelVisible) { visible in
            // Auto-focus search when the panel opens so typing filters
            // immediately (launcher convention); drop focus on close so the
            // caret never blinks behind a dismissed panel.
            guard visible else {
                searchFocused = false
                return
            }
            // Defer one run-loop turn: the panel becomes key right after the
            // view model flips visibility, and focus needs a key window.
            DispatchQueue.main.async { searchFocused = true }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            settings = SettingsService.shared.loadSettings()
            // The window appearance is the ground truth for the crystal tokens
            // (Color.crystalSheenTop & co. read it), so a theme switch has to
            // repaint the content: the NSPanel is chrome-less and never redraws
            // itself just because its appearance changed.
            PreviewPanel.shared.applyAppearanceOverride()
            // A mode or layout change resizes/refits the panel; refit first so
            // the column count below is computed from the new width.
            PreviewPanel.shared.refitToDisplayMode()
            viewModel.updateGridColumnCount(width: viewModel.panelSize.width, settings: settings)
        }
        .onExitCommand {
            viewModel.hidePanel()
            PreviewPanel.shared.hide()
        }
    }
    
    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Switchly")
                        .font(.title3.weight(.semibold))
                    // Same line as the count: a separate row would push the grid
                    // down while the other-desktop scan runs and back up after.
                    HStack(spacing: 6) {
                        windowCountText
                        if viewModel.isEnumeratingWindows {
                            Text(t("Finding windows on other desktops…"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if viewModel.isWindowDiscoveryLimited {
                        Text(t("Window list is limited without Accessibility permission"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                    if viewModel.usesDesktopScope, settings.previewSpaceScope == .currentSpace, viewModel.otherSpaceWindowCount > 0 {
                        Button(String(format: t("%d windows on other desktops"), viewModel.otherSpaceWindowCount)) {
                            viewModel.setPreviewSpaceScope(.allSpaces)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                }

                Spacer()

                if viewModel.usesDesktopScope {
                    Menu {
                        ForEach(PreviewSpaceScope.allCases) { scope in
                            Button(scope.displayName(language: settings.language)) {
                                viewModel.setPreviewSpaceScope(scope)
                            }
                        }
                    } label: {
                        Text(settings.previewSpaceScope.displayName(language: settings.language))
                    }
                    .fixedSize()
                    .accessibilityLabel(t("Desktop range"))
                }

                searchBar

                TrafficLightCloseButton {
                    viewModel.hidePanel()
                    PreviewPanel.shared.hide()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(sectionBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.crystalPanelHairline.opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.22 : 0.08),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: DesignTokens.hairline)
        }
    }

    /// Window count with a numeric roll animation on macOS 13+.
    /// Skipped entirely under Reduce Motion (the roll is pure decoration).
    @ViewBuilder
    private var windowCountText: some View {
        let text = Text(String(format: t("%d windows"), viewModel.filteredWindows.count))
            .font(.caption)
            .foregroundColor(.secondary)
        if #available(macOS 13.0, *), !MotionTokens.reduceMotion {
            text
                .contentTransition(.numericText())
                .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: viewModel.filteredWindows.count)
        } else {
            text
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField(t("Search windows"), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)

            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 260)
        .liquidGlass(
            isActive: (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque),
            opacity: controlOpacity,
            cornerRadius: DesignTokens.Radius.pill,
            tintColor: settings.crystalMaterial.tintColor,
            interactive: true,
            fallbackColor: Color(nsColor: .textBackgroundColor),
            material: settings.crystalMaterial
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.pill, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: searchFocused
                            ? [Color.crystalPanelHairline.opacity(0.92), Color.accentColor.opacity(0.85)]
                            : [Color.crystalPanelHairline.opacity(0.42), Color.crystalPanelHairline.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: searchFocused ? 1.25 : DesignTokens.hairline
                )
        )
        .shadow(color: Color.accentColor.opacity(searchFocused ? 0.28 : 0), radius: 8, x: 0, y: 2)
        .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.microDuration)), value: searchFocused)
    }
    
    private var windowGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.filteredWindows.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        ForEach(Array(viewModel.filteredWindows.enumerated()), id: \.element.id) { index, window in
                            WindowThumbnailView(
                                window: window,
                                isSelected: viewModel.selectedWindow?.id == window.id,
                                settings: settings,
                                onHoverChange: { hovering in
                                    viewModel.setHoveredWindow(window, hovering: hovering, settings: settings)
                                }
                            )
                            .id(window.id)
                            .staggeredEntrance(index: index)
                            .transition(MotionTokens.cardTransition)
                            .onTapGesture {
                                PreviewPanel.shared.switchToWindowAndHide(window, source: .panelClick)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: viewModel.filteredWindows)
            .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: settings.thumbnailSize)
            .onChange(of: viewModel.selectedWindow) { selectedWindow in
                guard let selectedWindow else {
                    return
                }
                // nil anchor = minimal scroll: a card that is already in view
                // must not drag the whole grid to the centre on every step.
                withAnimation(MotionTokens.animated(.easeOut(duration: MotionTokens.microDuration))) {
                    proxy.scrollTo(selectedWindow.id, anchor: nil)
                }
            }
            .background(sectionBackground)
        }
    }

    private var spatialOrnamentRail: some View {
        VStack(spacing: 12) {
            ForEach(PreviewPanelStyle.allCases, id: \.self) { style in
                let isCurrent = settings.previewPanelStyle == style
                Button {
                    var updated = settings
                    updated.previewPanelStyle = style
                    try? SettingsService.shared.saveSettings(updated)
                } label: {
                    Image(systemName: ornamentIcon(for: style))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isCurrent ? .white : .secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(isCurrent ? Color.accentColor.opacity(0.55) : Color.crystalPanelHairline.opacity(0.08))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.crystalPanelHairline.opacity(isCurrent ? 0.85 : 0.24),
                                              lineWidth: DesignTokens.hairline)
                        )
                }
                .buttonStyle(.plain)
                .help(style.displayName(language: settings.language))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .liquidGlass(
            isActive: (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque),
            opacity: 0.18,
            cornerRadius: DesignTokens.Radius.pill,
            material: settings.crystalMaterial
        )
        .padding(.leading, 12)
    }

    private func ornamentIcon(for style: PreviewPanelStyle) -> String {
        switch style {
        case .stage: return "sparkles.rectangle.stack"
        case .classicGrid: return "square.grid.2x2"
        }
    }

    private func spatialFocusStageBanner(for window: WindowInfo) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("#\(window.windowNumber)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.crystalPanelHairline.opacity(0.16)))
                    Text(window.ownerName)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                Text(window.displayName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            Text("↵ " + t("Switch"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.crystalPanelHairline.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Color.crystalPanelHairline.opacity(0.45),
                                                lineWidth: DesignTokens.hairline))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cardSurface(
            fill: Color.crystalSurfaceBase.opacity(0.10),
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            isSelected: true
        )
        .crystalSpecularRim(
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            isHighlighted: true
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var sectionBackground: some View {
        if settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque {
            Color.clear
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private var controlOpacity: Double {
        guard settings.backgroundBlurOpacity > 0 else {
            return 0
        }
        return min(max(settings.backgroundBlurOpacity + 0.16, 0), 1)
    }

    private var backgroundOpacity: Double {
        min(max(settings.panelGlassDensity, 0), 1)
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: settings.previewPanelStyle.minimumCardWidth(for: settings.thumbnailSize),
                    maximum: settings.thumbnailSize.previewCardMaxWidth
                ),
                spacing: 14
            )
        ]
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.on.square")
                .font(.system(size: 42))
                .foregroundColor(.secondary)

            Text(t("No windows found"))
                .font(.headline.weight(.semibold))

            Text(t("Switch General > Window source to Preview All Windows, or add running apps in the Apps tab."))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func t(_ key: String) -> String {
        settings.language.localizedString(key)
    }
}

enum ThumbnailLoadState: Equatable {
    case loading
    case placeholder(NSImage?)
    case loaded(NSImage)
    case failed(NSImage?)

    /// Identity-based comparison: images are compared by reference so the
    /// animation driver only fires when the state genuinely changes.
    static func == (lhs: ThumbnailLoadState, rhs: ThumbnailLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.placeholder(let lhsImage), .placeholder(let rhsImage)):
            return lhsImage === rhsImage
        case (.loaded(let lhsImage), .loaded(let rhsImage)):
            return lhsImage === rhsImage
        case (.failed(let lhsImage), .failed(let rhsImage)):
            return lhsImage === rhsImage
        default:
            return false
        }
    }
}

struct WindowThumbnailView: View {
    let window: WindowInfo
    let isSelected: Bool
    /// Resolved once by the panel and passed down. Cards must not each run
    /// their own `JSONDecoder` decode (that was one full settings decode per
    /// card per panel open) nor subscribe to `.settingsDidChange` themselves
    /// (one full reload per card per change).
    let settings: AppSettings
    /// Called with `true` when the pointer enters the card and `false` when it
    /// leaves. The panel owns the hover policy (delay + which tier follows), so
    /// the card only reports the event.
    let onHoverChange: (Bool) -> Void

    @State private var thumbnailState: ThumbnailLoadState
    /// Hover lives inside the card. When it lived in the parent, every
    /// pointer move re-ran the whole grid body — and every icon lookup and
    /// blur layer inside it.
    @State private var isHovered = false
    @Environment(\.colorScheme) private var inheritedColorScheme

    init(
        window: WindowInfo,
        isSelected: Bool,
        settings: AppSettings,
        onHoverChange: @escaping (Bool) -> Void
    ) {
        self.window = window
        self.isSelected = isSelected
        self.settings = settings
        self.onHoverChange = onHoverChange
        // 已有缓存立即显示；首次预览没有缓存时，由 `.task` 按需截图。
        let initial: ThumbnailLoadState
        if let cached = ThumbnailService.shared.getCachedThumbnail(for: window) {
            initial = .loaded(cached)
        } else {
            initial = .loading
        }
        _thumbnailState = State(initialValue: initial)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnailContainer
                .frame(height: settings.thumbnailSize.previewThumbnailHeight
                        * settings.previewPanelStyle.thumbnailHeightScale)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    titleAppIcon

                    Text(primaryTitle)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if settings.previewInfoShowsWindowNumber {
                        Text("#\(window.windowNumber)")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.crystalSecondary(on: cardFill))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .cardSurface(fill: chipFill, cornerRadius: DesignTokens.Radius.chip)
                    }
                }

                if settings.previewInfoShowsAppName {
                    detailText(window.ownerName)
                }

                if settings.previewInfoShowsProcessID {
                    detailText("PID \(window.ownerPID)")
                }

                if settings.previewInfoShowsSize {
                    detailText("\(Int(window.bounds.width))x\(Int(window.bounds.height))")
                }

                if settings.previewInfoShowsPosition {
                    detailText("x\(Int(window.bounds.origin.x)) y\(Int(window.bounds.origin.y))")
                }

                if let status = window.statusLocalizationKey {
                    Text(t(status))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if !window.isOnCurrentSpace, case .loaded = thumbnailState {
                    Text(t("Preview may be outdated"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        // Solid surface instead of a per-card material — see View.cardSurface.
        .cardSurface(
            fill: cardFill,
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            isSelected: isSelected || isHovered
        )
        .crystalSpecularRim(
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            isHighlighted: isSelected || isHovered
        )
        .overlay(alignment: .topTrailing) {
            // "Current window" badge. Keyboard navigation moves the selection
            // without a pointer, so the selected card needs a marker that
            // survives at a glance — a border and a 3% lift alone do not.
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 1)
                    .padding(6)
                    .accessibilityLabel(t("Current window"))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            // Window controls, as in the Dock preview. Shown on hover or
            // selection so a resting grid stays clean.
            if isHovered || isSelected {
                WindowTrafficLightButtons(
                    window: window,
                    language: settings.language,
                    diameter: 10
                )
                .padding(16)
                .transition(.opacity)
            }
        }
        .background(
            // Report this card's frame in panel space so the dismissal
            // animation can zoom toward the activated card. Only the card
            // that can be the anchor reports: the selected one (keyboard
            // switch) or the hovered one (a click sets the selection
            // synchronously, before the new frame preference is delivered).
            // Reporting every card meant a dictionary merge on every layout
            // and scroll frame for anchors that are never read.
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PreviewCardFrameKey.self,
                    value: isSelected || isHovered
                        ? [window.id: proxy.frame(in: .named(PreviewPanelSpace.name))]
                        : [:]
                )
            }
        )
        .scaleEffect(cardScale)
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0), radius: isSelected ? 10 : 0, x: 0, y: 4)
        .animation(MotionTokens.animated(MotionTokens.cardSpring), value: isSelected)
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
        .task(id: window.id) {
            await loadThumbnail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailDidUpdate)) { notification in
            guard let windowID = notification.object as? CGWindowID,
                  windowID == window.id,
                  // Cards only ever show the grid tier; a native capture of
                  // the same window must not reach them.
                  (notification.userInfo?["tier"] as? String) == ThumbnailTier.grid.rawValue,
                  let cached = ThumbnailService.shared.getCachedThumbnail(for: window) else {
                return
            }
            // Background refreshes (auto-refresh tick) swap without the
            // crossfade: the user did not ask for this frame, so it must not
            // animate under their cursor every few seconds.
            if notification.userInfo?["animated"] as? Bool == false {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    thumbnailState = .loaded(cached)
                }
            } else {
                thumbnailState = .loaded(cached)
            }
        }
        .environment(\.colorScheme, cardColorScheme)
    }

    /// A custom card backing sets the card's own text contrast; hover and
    /// selection replace the fill with an accent tint, so they keep the
    /// scheme inherited from the panel.
    private var cardColorScheme: ColorScheme {
        guard !isHovered, !isSelected else { return inheritedColorScheme }
        return settings.windowCardBackdrop.textColorScheme ?? inheritedColorScheme
    }

    private var primaryTitle: String {
        if settings.showWindowTitles && !window.windowTitle.isEmpty {
            return window.windowTitle
        }
        return window.ownerName
    }

    /// Cards lift toward the cursor on hover and a little higher when they
    /// hold the keyboard selection — the selection must stay findable at a
    /// glance while driving the panel with arrow keys.
    private var cardScale: CGFloat {
        if isSelected {
            return 1.03
        }
        if isHovered {
            return 1.02
        }
        return 1.0
    }

    private var titleAppIcon: some View {
        Group {
            if let icon = appIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .cardSurface(fill: chipFill, cornerRadius: DesignTokens.Radius.chip)
        // The app name is already spelled out in the text row below; the
        // icon is decoration for VoiceOver.
        .accessibilityHidden(true)
    }

    /// Solid card fill. Hover and selection tint with the accent color so
    /// pointer and keyboard feedback read the same way; the resting fill
    /// tracks the panel's glass opacity (with a floor) so cards stay legible
    /// even when the user turns the glass opacity all the way down.
    private var cardFill: Color {
        if isHovered {
            return Color.accentColor.opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.18 : 0.10)
        }
        if isSelected {
            return Color.accentColor.opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.12 : 0.06)
        }
        return settings.windowCardFill(opacity: cardFillOpacity)
    }

    /// Shared card separation; independent of backdrop density.
    private var cardFillOpacity: Double {
        guard (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) else {
            return 1
        }
        return settings.crystalMaterial.cardOpacity
    }

    private var cardBorder: Color {
        if isSelected || isHovered {
            return Color.accentColor.opacity(0.65)
        }
        return Color(nsColor: .separatorColor)
    }

    /// Fill for small chips (window-number badge, app-icon chip) and the
    /// loading skeleton — solid, like the card, never a material.
    private var chipFill: Color {
        if (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) {
            return Color.crystalChipBase.opacity(0.14)
        }
        return Color(nsColor: .textBackgroundColor)
    }

    private var skeletonFill: Color {
        let opacity: Double = (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.3 : 0.1
        return Color(nsColor: .textBackgroundColor).opacity(opacity)
    }
    
    private var thumbnailContainer: some View {
        GeometryReader { geometry in
            switch thumbnailState {
            case .loaded(let thumbnail):
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                    .background(settings.thumbnailBackdrop.resolvedColor())
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail))
                    .transition(MotionTokens.thumbnailTransition)
            case .failed(let fallbackIcon):
                fallbackThumbnail(icon: fallbackIcon, text: settings.language.localizedString("Preview unavailable"))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .transition(.opacity)
            case .placeholder(let fallbackIcon):
                fallbackThumbnail(icon: fallbackIcon, text: settings.language.localizedString("Loading preview"))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .transition(.opacity)
            case .loading:
                RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail)
                    .cardSurface(fill: skeletonFill, cornerRadius: DesignTokens.Radius.thumbnail)
                    .overlay(
                        ProgressView()
                            .progressViewStyle(.circular)
                    )
                    .skeletonPulse(isActive: true)
                    .transition(.opacity)
            }
        }
        .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: thumbnailState)
    }
    
    private func loadThumbnail() async {
        // `settings` is resolved once by the panel and passed into the card;
        // decoding it here again was one full settings decode per card per
        // panel open — the exact cost the card's own doc comment forbids.
        if let cached = ThumbnailService.shared.getCachedThumbnail(for: window) {
            // The initial `@State` already shows this cached image; avoid
            // re-assigning (which would trigger an unnecessary redraw) and
            // skip the capture entirely. A background auto-refresh tick will
            // post `.thumbnailDidUpdate` when a fresher image lands.
            if case .loaded(let current) = thumbnailState, current === cached {
                return
            }
            await MainActor.run {
                thumbnailState = .loaded(cached)
            }
            return
        }

        let fallbackIcon = appIcon()

        // 磁盘旧图可在截图失败冷却期间恢复；冷却由服务在尝试读盘后统一判断。
        await MainActor.run {
            thumbnailState = .placeholder(fallbackIcon)
        }

        do {
            let image = try await ThumbnailService.shared.captureThumbnail(
                for: window,
                size: self.settings.thumbnailSize.dimensions
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.thumbnailState = .loaded(image)
            }
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.warning("Using fallback thumbnail. windowID=\(window.id), error=\(error)")
            await MainActor.run {
                self.thumbnailState = .failed(appIcon())
            }
        }
    }

    /// Cached per pid — `NSRunningApplication.icon` is a LaunchServices
    /// round-trip and this used to run on every body evaluation.
    private func appIcon() -> NSImage? {
        AppIconCache.icon(forPID: window.ownerPID)
    }

    private func fallbackThumbnail(icon: NSImage?, text: String) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail)
            .cardSurface(fill: skeletonFill, cornerRadius: DesignTokens.Radius.thumbnail)
            .overlay {
                VStack(spacing: 8) {
                    if let icon = icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 42, height: 42)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                    }

                    Text(text)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            // Crystal-aware secondary: the semantic .secondary only knows the
            // window appearance, and the panel's wash can invert the surface
            // luminance under it (see Color.crystalSecondary).
            .foregroundColor(.crystalSecondary(on: cardFill))
            .lineLimit(1)
    }

    private func t(_ key: String) -> String {
        settings.language.localizedString(key)
    }
}

private struct TrafficLightCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 1.0, green: 0.36, blue: 0.32))
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.16), lineWidth: 0.5)
                )
                .frame(width: 13, height: 13)

            if isHovered {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Color.black.opacity(0.55))
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .focusable(false)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            action()
        }
        .help("Close")
    }
}

// MARK: - Card frame tracking

/// Named coordinate space covering the whole preview panel. Cards report
/// their frames inside it so the dismissal animation can zoom toward the
/// activated card.
private enum PreviewPanelSpace {
    static let name = "previewPanelSpace"
}

/// Maps window id to card frame (in panel space) for every visible card.
private struct PreviewCardFrameKey: PreferenceKey {
    static var defaultValue: [CGWindowID: CGRect] { [:] }

    static func reduce(
        value: inout [CGWindowID: CGRect],
        nextValue: () -> [CGWindowID: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}
