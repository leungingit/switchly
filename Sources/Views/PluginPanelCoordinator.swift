import AppKit
import SwiftUI

@MainActor
final class PluginPanelCoordinator: NSObject, NSWindowDelegate {
    private let settings: () -> AppSettings
    private let host: PluginHosting
    private let activityImages: PluginActivityImageResolving?
    private var windows: [String: NSWindow] = [:]
    private var models: [String: PluginPanelModel] = [:]
    private var launcher: NSWindow?

    init(host: PluginHosting, activityImages: PluginActivityImageResolving?, settings: @escaping () -> AppSettings = { SettingsService.shared.loadSettings() }) {
        self.settings = settings
        self.host = host; self.activityImages = activityImages
    }
    func showLauncher() {
        if let launcher { launcher.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = makeWindow(title: settings().language.localizedString("Plugin Panels"))
        window.contentView = NSHostingView(rootView: PluginPanelLauncherView(host: host) { [weak self] id, title in self?.show(pluginID: id, title: title) })
        launcher = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func show(pluginID: String, title: String) {
        if let window = windows[pluginID] { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let model = PluginPanelModel(pluginID: pluginID, host: host)
        let window = makeWindow(title: title)
        window.contentView = NSHostingView(rootView: PluginPanelView(model: model, activityImages: activityImages, settings: settings()))
        models[pluginID] = model; windows[pluginID] = window
        model.start(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func makeWindow(title: String) -> NSWindow {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(DesignTokens.Plugin.panelWidth, max(1, visible.width - 2 * DesignTokens.Spacing.lg))
        let height = min(DesignTokens.Plugin.panelHeight, max(1, visible.height - 2 * DesignTokens.Spacing.lg))
        let rect = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        let panel = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.setFrame(rect, display: false)
        panel.title = title; panel.delegate = self; panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: min(400, width), height: min(360, height))
        panel.backgroundColor = .windowBackgroundColor; panel.isOpaque = false
        panel.titlebarAppearsTransparent = false
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        return panel
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === launcher { launcher = nil }
        for id in Array(windows.keys) where windows[id] === window { models.removeValue(forKey: id)?.stop(); windows.removeValue(forKey: id) }
    }
    func closeAll() {
        models.values.forEach { $0.stop() }
        for window in Array(windows.values) { window.close() }
        windows.removeAll(); models.removeAll(); launcher?.close(); launcher = nil
    }
}
