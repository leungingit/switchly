import SwiftUI

/// One observable overlay per card; old app-scoped plugins keep their original mount.
struct DockWindowPluginCard: View {
    let window: WindowInfo
    let isSelected: Bool
    let settings: AppSettings
    let context: PluginRenderContext?
    let isPanelVisible: Bool
    let appBottomBar: AnyView?
    private let thumbnail: NSImage?
    @StateObject private var overlay: DockPluginOverlayModel
    private struct Presentation: Equatable {
        let context: PluginRenderContext?
        let visible: Bool
    }
    private var presentation: Presentation { Presentation(context: context, visible: isPanelVisible) }

    init(window: WindowInfo, isSelected: Bool, settings: AppSettings, context: PluginRenderContext?,
         isPanelVisible: Bool, appBottomBar: AnyView?, host: PluginHosting = PluginHost.shared,
         thumbnail: NSImage? = nil) {
        self.window = window; self.isSelected = isSelected; self.settings = settings
        self.context = context; self.isPanelVisible = isPanelVisible; self.appBottomBar = appBottomBar
        self.thumbnail = thumbnail
        _overlay = StateObject(wrappedValue: DockPluginOverlayModel(host: host, scope: .window))
    }

    var body: some View {
        DockWindowCard(
            window: window, isSelected: isSelected, settings: settings,
            pluginOverlay: AnyView(VStack(spacing: DesignTokens.Spacing.xs) {
                appBottomBar
                slot(.bottomBar)
            }),
            pluginAccessory: overlay.slots[.titleAccessory]?.isEmpty == false ? AnyView(slot(.titleAccessory)) : nil,
            pluginTopTrailing: AnyView(slot(.topTrailing)),
            trafficLights: DockWindowCardHostDefaults.trafficLights(for: window, language: settings.language),
            initialThumbnail: { window in thumbnail.map(ThumbnailLoadState.loaded) ?? DockWindowCardHostDefaults.initialThumbnail(for: window) },
            loadThumbnail: { window, size in
                if let thumbnail { return thumbnail }
                return try await DockWindowCardHostDefaults.loadThumbnail(for: window, size: size)
            },
            thumbnailRefresh: DockWindowCardHostDefaults.thumbnailRefresh
        )
        .onAppear { update(presentation) }
        .onChange(of: presentation) { update($0) }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            overlay.reloadCurrentContext()
        }
        .onDisappear { overlay.stop() }
    }

    private func slot(_ slot: PluginSlot) -> some View {
        DockPluginSlotView(overlay: overlay, slots: [slot], settings: settings, fallback: nil)
    }

    private func update(_ presentation: Presentation) {
        if presentation.visible, let context = presentation.context { overlay.start(context: context) }
        else { overlay.stop() }
    }
}
