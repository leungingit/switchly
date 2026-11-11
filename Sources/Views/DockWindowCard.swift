//
//  DockWindowCard.swift
//  Switchly
//
//  One window card in the Dock preview strip. Thumbnail capture and the AX
//  traffic light controls are injected so hosts without ScreenCaptureKit /
//  Accessibility (the standalone plugin preview app) can reuse the card.
//

import AppKit
import Combine
import SwiftUI

struct DockWindowCard: View {
    let window: WindowInfo
    let isSelected: Bool
    /// Resolved once by the panel — see WindowThumbnailView.settings.
    let settings: AppSettings

    /// Pre-rendered plugin content for the card's bottom bar. The host builds
    /// it so this file stays free of the plugin overlay model.
    private let pluginOverlay: AnyView?
    private let pluginAccessory: AnyView?
    private let pluginTopTrailing: AnyView?
    /// Pre-rendered traffic light controls. The host injects the AX-backed
    /// buttons; a host without Accessibility can pass nil or its own view.
    private let trafficLights: AnyView?

    /// State shown before the first load resolves (host passes the cached
    /// thumbnail when one exists, `.loading` otherwise).
    private let initialThumbnail: (WindowInfo) -> ThumbnailLoadState
    /// Captures a thumbnail for the given window and point size.
    private let loadThumbnailImage: (WindowInfo, CGSize) async throws -> NSImage
    /// Maps a `.thumbnailDidUpdate` notification to a fresh image. Returning
    /// nil ignores the notification (wrong window or tier).
    private let thumbnailRefresh: (Notification, WindowInfo) -> NSImage?

    @State private var thumbnailState: ThumbnailLoadState
    /// Hover lives inside the card so moving the pointer across the strip
    /// does not re-run the whole strip body.
    @State private var isHovered = false
    @Environment(\.colorScheme) private var inheritedColorScheme

    private var cardThumbnailWidth: CGFloat { settings.dockPreviewCardWidth }
    private var cardThumbnailHeight: CGFloat { cardThumbnailWidth * 0.625 } // 75/120 ratio

    init(
        window: WindowInfo,
        isSelected: Bool,
        settings: AppSettings,
        pluginOverlay: AnyView? = nil,
        pluginAccessory: AnyView? = nil,
        pluginTopTrailing: AnyView? = nil,
        trafficLights: AnyView? = nil,
        initialThumbnail: @escaping (WindowInfo) -> ThumbnailLoadState = { _ in .loading },
        loadThumbnail: @escaping (WindowInfo, CGSize) async throws -> NSImage = { _, _ in
            throw CocoaError(.featureUnsupported)
        },
        thumbnailRefresh: @escaping (Notification, WindowInfo) -> NSImage? = { _, _ in nil }
    ) {
        self.window = window
        self.isSelected = isSelected
        self.settings = settings
        self.pluginOverlay = pluginOverlay
        self.pluginAccessory = pluginAccessory
        self.pluginTopTrailing = pluginTopTrailing
        self.trafficLights = trafficLights
        self.initialThumbnail = initialThumbnail
        self.loadThumbnailImage = loadThumbnail
        self.thumbnailRefresh = thumbnailRefresh
        _thumbnailState = State(initialValue: initialThumbnail(window))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DockPanelMetrics.labelSpacing) {
            ZStack(alignment: .topLeading) {
                thumbnailContainer
                    .frame(width: cardThumbnailWidth, height: cardThumbnailHeight)
                    .overlay(alignment: .bottom) {
                        if let pluginOverlay {
                            // Buttons inside take the click, so the card's tap
                            // (switch window) only fires outside them.
                            pluginOverlay
                                .frame(maxHeight: cardThumbnailHeight * DesignTokens.Plugin.bottomBarMaxHeightFraction)
                                .padding(DesignTokens.Spacing.xs)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let pluginTopTrailing {
                            pluginTopTrailing.padding(DesignTokens.Spacing.xs)
                        }
                    }

                if let status = window.statusLocalizationKey {
                    VStack {
                        Spacer()
                        Text(settings.language.localizedString(status))
                            .font(.caption2)
                            .padding(4)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.chip))
                    }
                    .frame(width: cardThumbnailWidth, height: cardThumbnailHeight)
                    .allowsHitTesting(false)
                }

                // macOS standard traffic light buttons (close / minimize / zoom)
                // visible on hover or when selected.
                if isHovered || isSelected, let trafficLights {
                    trafficLights
                        .padding(4)
                        .transition(.opacity)
                }
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(primaryTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pluginAccessory
            }
            .frame(width: cardThumbnailWidth, height: pluginAccessory == nil ? nil : DesignTokens.Plugin.controlSmall, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
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
        .environment(\.colorScheme, cardColorScheme)
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: window.id) {
            await loadThumbnail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailDidUpdate)) { notification in
            guard let cached = thumbnailRefresh(notification, window) else {
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

    // Window controls are injected by the host; the shared implementation
    // lives in WindowTrafficLights.swift and calls WindowAction.

    @ViewBuilder
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
                    .overlay(ProgressView().progressViewStyle(.circular))
                    .skeletonPulse(isActive: true)
                    .transition(.opacity)
            }
        }
        .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: thumbnailState)
    }

    private func loadThumbnail() async {
        if case .loaded(let cached) = initialThumbnail(window) {
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
            let image = try await loadThumbnailImage(window, settings.thumbnailSize.dimensions)
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

    /// A custom card backing sets the card's own text contrast; hover and
    /// selection replace the fill with an accent tint, so they keep the
    /// scheme inherited from the panel.
    private var cardColorScheme: ColorScheme {
        guard !isHovered, !isSelected else { return inheritedColorScheme }
        return settings.windowCardBackdrop.textColorScheme ?? inheritedColorScheme
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
            return Color.accentColor.opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.18 : 0.10)
        }
        if isSelected {
            return Color.accentColor.opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.12 : 0.06)
        }
        return settings.windowCardFill(opacity: cardFillOpacity)
    }

    private var cardFillOpacity: Double {
        guard (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) else { return 1 }
        return settings.crystalMaterial.cardOpacity
    }

    private var cardBorder: Color {
        if isSelected || isHovered {
            return Color.accentColor.opacity(0.7)
        }
        return Color(nsColor: .separatorColor)
    }

    private var skeletonFill: Color {
        let opacity: Double = (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.3 : 0.1
        return Color(nsColor: .textBackgroundColor).opacity(opacity)
    }
}
