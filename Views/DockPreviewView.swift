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

struct DockPreviewView: View {
    @StateObject private var viewModel: DockPreviewViewModel
    // The model observes settings even while this transient view is unmounted.
    private var settings: AppSettings { viewModel.settings }
    /// Content size of the window strip, measured so the edge fade only
    /// appears when the strip actually overflows.
    @State private var stripContentSize: CGSize = .zero

    init(viewModel: DockPreviewViewModel = DockPreviewViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if viewModel.hidesWindowStrip {
                // Plugin option: widget only, no window previews.
            } else if viewModel.windows.isEmpty {
                // Apps like Music are often used with no window open; their
                // plugin card (below) replaces the empty state.
                if !viewModel.pluginOverlay.hasCenter { emptyState }
            } else {
                windowStrip
            }
            // Plugin card sits below the previews, never over them.
            DockPluginSlotView(overlay: viewModel.pluginOverlay, slots: [.center],
                               settings: settings, fallback: nil)
                // Ideal height, so a too-small panel can't squeeze the card
                // and have that squeezed height measured back.
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PluginCardHeightKey.self, value: proxy.size.height)
                })
                .onPreferenceChange(PluginCardHeightKey.self) { viewModel.pluginCardHeightMeasured($0) }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.sm)
        }
        .frame(width: viewModel.panelWidth, height: viewModel.panelHeight)
        .scaleEffect(viewModel.isPanelVisible ? 1 : 0.88, anchor: .bottom)
        .opacity(viewModel.isPanelVisible ? 1 : 0)
        .animation(MotionTokens.animated(MotionTokens.panelSpring), value: viewModel.isPanelVisible)
        .panelGlass(
            isActive: (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque),
            opacity: backgroundOpacity,
            cornerRadius: GlassPanelCorner.radius,
            material: settings.crystalMaterial
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .preferredColorScheme(settings.theme.colorScheme)
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
                Text(viewModel.isWindowDiscoveryLimited ? t("Window list is limited") :
                     viewModel.isEnumeratingWindows ? t("Finding windows…") : String(format: t("%d windows"), viewModel.windows.count))
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

    private var layoutSpec: DockLayoutSpec { settings.dockPreviewLayout.spec }

    private var windowStrip: some View {
        let spec = layoutSpec
        return ScrollView(spec.axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
            stripContent(spec: spec)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    // Measure the strip content so the edge fade below only
                    // appears when there is actually something to scroll to.
                    GeometryReader { proxy in
                        Color.clear.preference(key: StripSizeKey.self, value: proxy.size)
                    }
                )
                .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: viewModel.windows)
        }
        .onPreferenceChange(StripSizeKey.self) { size in
            stripContentSize = size
        }
        .mask(stripMask(spec: spec))
    }

    @ViewBuilder
    private func stripContent(spec: DockLayoutSpec) -> some View {
        switch spec.axis {
        case .horizontal:
            HStack(spacing: spec.spacing) { windowCards }
        case .vertical:
            let cardWidth = DockPanelMetrics.cardSize(cardWidth: settings.dockPreviewCardWidth).width
            let columns = Array(
                repeating: GridItem(.fixed(cardWidth), spacing: spec.spacing, alignment: .top),
                count: spec.columns(for: viewModel.windows.count)
            )
            LazyVGrid(columns: columns, alignment: .center, spacing: spec.spacing) { windowCards }
        }
    }

    @ViewBuilder
    private var windowCards: some View {
        ForEach(viewModel.windows) { window in
            DockWindowCard(
                window: window,
                isSelected: viewModel.selectedWindow?.id == window.id,
                settings: settings,
                // Plugins render against the first window (ctx.window).
                pluginOverlay: window.id == viewModel.windows.first?.id
                    ? AnyView(DockPluginSlotView(overlay: viewModel.pluginOverlay, slots: [.bottomBar], settings: settings, fallback: nil))
                    : nil,
                trafficLights: DockWindowCardHostDefaults.trafficLights(for: window, language: settings.language),
                initialThumbnail: DockWindowCardHostDefaults.initialThumbnail,
                loadThumbnail: DockWindowCardHostDefaults.loadThumbnail,
                thumbnailRefresh: DockWindowCardHostDefaults.thumbnailRefresh
            )
            .transition(.opacity)
            .onTapGesture {
                DockPreviewPanel.shared.switchToWindowAndHide(window)
            }
        }
    }

    /// Fades both edges when the strip overflows its panel — the strip hides
    /// its scroll indicators, so without this there is no affordance that
    /// more windows exist off-screen.
    @ViewBuilder
    private func stripMask(spec: DockLayoutSpec) -> some View {
        let horizontal = spec.axis == .horizontal
        let overflows = horizontal
            ? stripContentSize.width > viewModel.panelWidth
            : stripContentSize.height > viewModel.panelHeight - DockPanelMetrics.headerHeight
        if overflows {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1)
                ],
                startPoint: horizontal ? .leading : .top,
                endPoint: horizontal ? .trailing : .bottom
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
        if settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque {
            Color.clear
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private var backgroundOpacity: Double {
        min(max(settings.panelGlassDensity, 0), 1)
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

// MARK: - DockWindowCard host injection

/// Host defaults for `DockWindowCard`'s injection points. They live here —
/// not in the card file — so the card itself compiles in hosts without
/// ScreenCaptureKit or Accessibility (the standalone plugin preview app).
private enum DockWindowCardHostDefaults {
    static func trafficLights(for window: WindowInfo, language: AppLanguage) -> AnyView {
        AnyView(WindowTrafficLightButtons(window: window, language: language, diameter: 10))
    }

    static func initialThumbnail(for window: WindowInfo) -> ThumbnailLoadState {
        // 复用先前按需截图的缓存，避免重复显示加载状态。
        if let cached = ThumbnailService.shared.getCachedThumbnail(for: window) {
            return .loaded(cached)
        }
        return .loading
    }

    static func loadThumbnail(for window: WindowInfo, size: CGSize) async throws -> NSImage {
        try await ThumbnailService.shared.captureThumbnail(for: window, size: size)
    }

    static func thumbnailRefresh(_ notification: Notification, window: WindowInfo) -> NSImage? {
        guard let windowID = notification.object as? CGWindowID,
              windowID == window.id,
              // Cards only ever show the grid tier; a native capture of
              // the same window must not reach them (mirrors
              // WindowThumbnailView).
              (notification.userInfo?["tier"] as? String) == ThumbnailTier.grid.rawValue else {
            return nil
        }
        return ThumbnailService.shared.getCachedThumbnail(for: window)
    }
}

// MARK: - Plugin slots

/// Observes the overlay model so plugin re-renders only redraw this view, not
/// the whole strip.
struct DockPluginSlotView: View {
    @ObservedObject var overlay: DockPluginOverlayModel
    let slots: [PluginSlot]
    let settings: AppSettings
    let fallback: AnyView?

    var body: some View {
        let entries = slots.flatMap { overlay.slots[$0] ?? [] }
        PluginSlotSurface(
            entries: entries.map {
                PluginSlotSurface.Entry(id: $0.id, node: $0.node, assetDirectory: $0.directory)
            },
            material: settings.crystalMaterial,
            isGlassActive: settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque,
            artwork: overlay.artwork,
            fallback: fallback
        ) { pluginID, actionID, value in
            overlay.perform(pluginID: pluginID, actionID: actionID, value: value)
        }
    }
}

private struct PluginCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Content size of the dock preview's card strip. Compared against the panel
/// size to decide whether the scroll-affordance edge fade should be shown.
private struct StripSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}
