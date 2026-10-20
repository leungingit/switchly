//
//  DockPreviewView.swift
//  Switchly
//
//  SwiftUI view for the per-app dock preview bar.
//  Shows a header with the app name and icon, followed by a horizontal
//  strip of that app's window thumbnails.
//

import SwiftUI
import AppKit
import ApplicationServices

struct DockPreviewView: View {
    @StateObject private var viewModel: DockPreviewViewModel
    @State private var settings = SettingsService.shared.loadSettings()
    /// Content width of the window strip, measured so the edge fade only
    /// appears when the strip actually overflows.
    @State private var stripContentWidth: CGFloat = 0

    init(viewModel: DockPreviewViewModel = DockPreviewViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if viewModel.windows.isEmpty {
                emptyState
            } else {
                windowStrip
            }
        }
        .frame(width: viewModel.panelWidth, height: viewModel.panelHeight)
        .scaleEffect(viewModel.isPanelVisible ? 1 : 0.88, anchor: .bottom)
        .opacity(viewModel.isPanelVisible ? 1 : 0)
        .animation(MotionTokens.animated(MotionTokens.panelSpring), value: viewModel.isPanelVisible)
        .panelGlass(
            isActive: settings.enableBackgroundBlur,
            opacity: backgroundOpacity,
            cornerRadius: GlassPanelCorner.radius,
            material: settings.crystalMaterial
        )
        .crystalSpecularRim(
            cornerRadius: GlassPanelCorner.radius,
            material: settings.crystalMaterial,
            lineWidth: settings.enableBackgroundBlur ? 0.75 : 0
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            settings = SettingsService.shared.loadSettings()
        }
        .onExitCommand {
            viewModel.hidePanel()
            DockPreviewPanel.shared.hide()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            appIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.appName)
                    .font(.headline)
                    .lineLimit(1)
                Text(String(format: t("%d windows"), viewModel.windows.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(sectionBackground)
    }

    private var appIcon: some View {
        Group {
            if let icon = resolvedAppIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    // MARK: - Window strip

    private var windowStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.windows) { window in
                    DockWindowCard(
                        window: window,
                        isSelected: viewModel.selectedWindow?.id == window.id,
                        settings: settings
                    )
                    .transition(.opacity)
                    .onTapGesture {
                        DockPreviewPanel.shared.switchToWindowAndHide(window)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                // Measure the strip content so the edge fade below only
                // appears when there is actually something to scroll to.
                GeometryReader { proxy in
                    Color.clear.preference(key: StripWidthKey.self, value: proxy.size.width)
                }
            )
            .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: viewModel.windows)
        }
        .onPreferenceChange(StripWidthKey.self) { width in
            stripContentWidth = width
        }
        .mask(stripMask)
    }

    /// Fades both edges when the strip overflows its panel — the strip hides
    /// its scroll indicators, so without this there is no affordance that
    /// more windows exist off-screen.
    @ViewBuilder
    private var stripMask: some View {
        if stripContentWidth > viewModel.panelWidth {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Rectangle()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(t("No windows"))
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Styling

    @ViewBuilder
    private var sectionBackground: some View {
        if settings.enableBackgroundBlur {
            if #available(macOS 26, *) {
                Color(nsColor: .controlBackgroundColor).opacity(0.03)
            } else {
                Color(nsColor: .controlBackgroundColor).opacity(max(backgroundOpacity * 0.5, 0.04))
            }
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private var backgroundOpacity: Double {
        min(max(settings.backgroundBlurOpacity, 0), 1)
    }

    // MARK: - Helpers

    private func resolvedAppIcon() -> NSImage? {
        // Cached per app name — resolving walks runningApplications and the
        // header re-renders on every hover / window refresh.
        AppIconCache.icon(forAppName: viewModel.appName)
    }

    private func t(_ key: String) -> String {
        settings.language.localizedString(key)
    }
}

// MARK: - DockWindowCard

struct DockWindowCard: View {
    let window: WindowInfo
    let isSelected: Bool
    /// Resolved once by the panel — see WindowThumbnailView.settings.
    let settings: AppSettings

    @State private var thumbnailState: ThumbnailLoadState
    /// Hover lives inside the card so moving the pointer across the strip
    /// does not re-run the whole strip body.
    @State private var isHovered = false

    private var cardThumbnailWidth: CGFloat { settings.dockPreviewCardWidth }
    private var cardThumbnailHeight: CGFloat { cardThumbnailWidth * 0.625 } // 75/120 ratio

    init(window: WindowInfo, isSelected: Bool, settings: AppSettings) {
        self.window = window
        self.isSelected = isSelected
        self.settings = settings
        // Render the cached thumbnail immediately so the dock card never shows
        // a loading spinner for a window that was already captured (the common
        // case, since the monitor preheats high-value windows on every window-
        // list change).
        let initial: ThumbnailLoadState
        if let cached = ThumbnailService.shared.getCachedThumbnail(for: window) {
            initial = .loaded(cached)
        } else {
            initial = .loading
        }
        _thumbnailState = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                thumbnailContainer
                    .frame(width: cardThumbnailWidth, height: cardThumbnailHeight)

                // macOS standard traffic light buttons (close / minimize / zoom)
                // visible on hover or when selected.
                if isHovered || isSelected {
                    WindowTrafficLightButtons(
                        window: window,
                        language: settings.language,
                        diameter: 10
                    )
                    .padding(4)
                    .transition(.opacity)
                }
            }

            Text(primaryTitle)
                .font(.caption2.weight(.medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: cardThumbnailWidth, alignment: .leading)
        }
        .padding(6)
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
        .scaleEffect(cardScale)
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0), radius: isSelected ? 10 : 0, x: 0, y: 4)
        .animation(MotionTokens.animated(MotionTokens.cardSpring), value: isSelected)
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: window.id) {
            await loadThumbnail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailDidUpdate)) { notification in
            guard let windowID = notification.object as? CGWindowID,
                  windowID == window.id,
                  // Cards only ever show the grid tier; a native capture of
                  // the same window must not reach them (mirrors
                  // WindowThumbnailView).
                  (notification.userInfo?["tier"] as? String) == ThumbnailTier.grid.rawValue,
                  let cached = ThumbnailService.shared.getCachedThumbnail(for: window) else {
                return
            }
            // Background refreshes swap without the crossfade — see
            // WindowThumbnailView.
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
    }

    // Window controls live in WindowTrafficLights.swift so every preview
    // surface (dock cards, grid cards, hero pane, list rows) draws the same
    // buttons and calls the same Accessibility actions.

    @ViewBuilder
    private var thumbnailContainer: some View {
        GeometryReader { geometry in
            switch thumbnailState {
            case .loaded(let thumbnail):
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                    .background(settings.thumbnailBackdrop.resolvedColor(isBlurred: settings.enableBackgroundBlur))
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
                    .overlay(ProgressView().progressViewStyle(.circular))
                    .skeletonPulse(isActive: true)
                    .transition(.opacity)
            }
        }
        .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: thumbnailState)
    }

    private func loadThumbnail() async {
        if let cached = ThumbnailService.shared.getCachedThumbnail(for: window) {
            // Initial `@State` already renders the cached image; avoid an
            // unnecessary redraw. The auto-refresh tick will refresh it via
            // `.thumbnailDidUpdate` when a fresher capture lands.
            if case .loaded(let current) = thumbnailState, current === cached {
                return
            }
            await MainActor.run { thumbnailState = .loaded(cached) }
            return
        }

        let fallbackIcon = appIcon()

        // 磁盘旧图可在截图失败冷却期间恢复；冷却由服务在尝试读盘后统一判断。
        await MainActor.run { thumbnailState = .placeholder(fallbackIcon) }

        do {
            let image = try await ThumbnailService.shared.captureThumbnail(for: window, size: settings.thumbnailSize.dimensions)
            guard !Task.isCancelled else { return }
            await MainActor.run { thumbnailState = .loaded(image) }
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.warning("Dock card thumbnail failed. windowID=\(window.id), error=\(error)")
            await MainActor.run { thumbnailState = .failed(appIcon()) }
        }
    }

    /// Cached per pid — see WindowThumbnailView.appIcon().
    private func appIcon() -> NSImage? {
        AppIconCache.icon(forPID: window.ownerPID)
    }

    private func fallbackThumbnail(icon: NSImage?, text: String) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail)
            .cardSurface(fill: skeletonFill, cornerRadius: DesignTokens.Radius.thumbnail)
            .overlay {
                VStack(spacing: 4) {
                    if let icon = icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                    Text(text)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
    }

    private func t(_ key: String) -> String {
        settings.language.localizedString(key)
    }

    private var primaryTitle: String {
        if settings.showWindowTitles && !window.windowTitle.isEmpty {
            return window.windowTitle
        }
        return t("Window")
    }

    /// Hover lifts the card slightly; the keyboard selection lifts it a
    /// touch higher so it stays findable while tabbing through windows.
    private var cardScale: CGFloat {
        if isSelected {
            return 1.03
        }
        if isHovered {
            return 1.02
        }
        return 1.0
    }

    /// Solid card fill — see WindowThumbnailView.cardFill.
    private var cardFill: Color {
        if isHovered {
            return Color.accentColor.opacity(settings.enableBackgroundBlur ? 0.18 : 0.10)
        }
        if isSelected {
            return Color.accentColor.opacity(settings.enableBackgroundBlur ? 0.12 : 0.06)
        }
        return Color.crystalSurfaceBase.opacity(cardFillOpacity)
    }

    private var cardFillOpacity: Double {
        guard settings.enableBackgroundBlur else { return 1 }
        return min(max(settings.backgroundBlurOpacity * 0.35 + 0.04, 0.06), 0.28)
    }

    private var cardBorder: Color {
        if isSelected || isHovered {
            return Color.accentColor.opacity(0.7)
        }
        return Color(nsColor: .separatorColor)
    }

    private var skeletonFill: Color {
        let opacity: Double = settings.enableBackgroundBlur ? 0.3 : 0.1
        return Color(nsColor: .textBackgroundColor).opacity(opacity)
    }
}

/// Content width of the dock preview's horizontal strip. Compared
/// against the panel width to decide whether the scroll-affordance edge fade
/// should be shown.
private struct StripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - AX Window Actions

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

