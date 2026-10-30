//
//  DockPreviewViewModel.swift
//  Switchly
//
//  ViewModel for the per-app dock preview bar.
//  Shows windows belonging to a single application whose Dock icon is hovered.
//

import Foundation
import Combine
import AppKit

class DockPreviewViewModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published private(set) var isEnumeratingWindows = false
    @Published private(set) var isWindowDiscoveryLimited = false
    @Published var selectedWindow: WindowInfo?
    @Published var isPanelVisible: Bool = false
    @Published var appName: String = ""
    @Published var panelWidth: CGFloat = 200
    @Published var panelHeight: CGFloat = 180
    @Published private(set) var settings: AppSettings
    /// The plugin card replaces the window strip (plugin option).
    @Published private(set) var hidesWindowStrip = false
    /// A plugin card (`center` slot) sits below the window strip.
    private var hasPluginCard = false
    /// Natural height of the plugin card as laid out (0 until measured).
    private var measuredPluginCardHeight: CGFloat = 0
    /// Plugin overlays for the hovered app (docs/dock-preview-plugins-design.md).
    let pluginOverlay: DockPluginOverlayModel

    private let windowMonitorService: WindowMonitorServiceProtocol
    private let windowSwitchService: WindowSwitchServiceProtocol
    private let settingsService: SettingsServiceProtocol
    private var cancellables = Set<AnyCancellable>()
    private var currentBundleID: String?
    private var currentBundleURL: URL?

    init(
        windowMonitorService: WindowMonitorServiceProtocol = WindowMonitorService.shared,
        windowSwitchService: WindowSwitchServiceProtocol = WindowSwitchService.shared,
        settingsService: SettingsServiceProtocol = SettingsService.shared,
        pluginOverlay: DockPluginOverlayModel = DockPluginOverlayModel()
    ) {
        self.pluginOverlay = pluginOverlay
        self.windowMonitorService = windowMonitorService
        self.windowSwitchService = windowSwitchService
        self.settingsService = settingsService
        self.settings = settingsService.loadSettings()
        setupObservers()
    }

    func showPanel(forApp appName: String, bundleURL: URL? = nil) {
        // A Dock panel can stay ordered out while Preferences changes. Read
        // before presenting, even if SwiftUI has not mounted its view yet.
        settings = settingsService.loadSettings()
        self.appName = appName
        self.currentBundleURL = bundleURL
        isPanelVisible = true
        refreshOnlineWeatherIfNeeded()
        refreshWindows(forApp: appName, bundleURL: bundleURL)
    }

    func hidePanel() {
        isPanelVisible = false
        pluginOverlay.stop()
    }

    /// Refresh the opt-in online weather at most once per interval; manual
    /// weather never touches the network.
    func refreshOnlineWeatherIfNeeded() {
        guard settings.onlineWeather.enabled else { return }
        OnlineWeatherService.shared.refreshIfNeeded()
    }

    func refreshWindows(forApp appName: String, bundleURL: URL? = nil) {
        // Resolve the running application. The Dock AX item's bundle URL is
        // authoritative when present: it uniquely identifies one product even
        // when several share a display name (e.g. ChatGPT and ChatGPT Atlas),
        // so name-based matching alone must not select the wrong process.
        guard let runningApp = findRunningApp(named: appName, bundleURL: bundleURL),
              let bundleID = runningApp.bundleIdentifier else {
            AppLogger.warning("Dock preview: could not find running app. appName=\(appName), bundleURL=\(bundleURL?.path ?? "nil")")
            self.windows = []
            pluginOverlay.stop()
            updatePanelWidth()
            return
        }

        currentBundleID = bundleID

        // When the Dock icon exposes a bundle URL, attribute windows to the
        // whole *product* rather than to one process: apps span many processes
        // (main app, nested bundles such as WeChat's WeChatAppEx.app, renderer
        // / mini-program helpers) and the windows they open can be owned by
        // any of them. Matching by an exact URL or PID then shows "No windows"
        // or the wrong window set (e.g. NoMachine). The product root collapses
        // the whole bundle tree into one identity.
        let matched: [WindowInfo]
        if let productRoot = WindowAttribution.productRootURL(for: bundleURL) {
            matched = windowMonitorService.windows(ownedBy: productRoot)
        } else {
            // No bundle URL (name-based resolution): match by PID. Filtering
            // by bundle identifier or name could pull in another product that
            // shares the same bundle ID or display name.
            let allWindows = windowMonitorService.getAllWindows()
            matched = allWindows.filter { window in
                window.ownerPID == runningApp.processIdentifier
            }
        }
        AppLogger.info("Refreshing dock preview windows. appName=\(appName), bundleURL=\(bundleURL?.path ?? "nil"), resolvedPID=\(runningApp.processIdentifier), matchedCount=\(matched.count)")

        self.windows = matched
        // 监控器每约 2s 会后台重扫 AX 窗口；已有窗口时的刷新不应让标题栏闪出“正在查找”。
        isEnumeratingWindows = windowMonitorService.isEnumeratingWindows && matched.isEmpty
        isWindowDiscoveryLimited = windowMonitorService.isWindowDiscoveryLimited
        selectedWindow = matched.first { $0.id == selectedWindow?.id } ?? matched.first
        updatePanelWidth()
        updatePluginOverlay(app: runningApp, bundleID: bundleID)
    }

    /// Plugins render per app; the first window (if any) supplies ctx.window.
    /// Apps such as Music are often used with their window closed, so an
    /// empty window list still mounts the overlay.
    private func updatePluginOverlay(app: NSRunningApplication, bundleID: String) {
        guard isPanelVisible else { return }
        let window = windows.first
        pluginOverlay.start(context: PluginRenderContext(
            bundleID: bundleID,
            pid: app.processIdentifier,
            appName: app.localizedName ?? appName,
            windowID: window.map { UInt32($0.id) } ?? 0,
            titleSummary: PluginRenderContext.summarize(title: window?.windowTitle ?? "")
        ))
    }

    /// Finds the running application for a hovered Dock icon.
    ///
    /// 1. When the Dock AX item's bundle URL is available, match it against
    ///    the running apps' bundle URLs. This is authoritative and resolves
    ///    duplicate display names (e.g. ChatGPT Desktop vs ChatGPT Atlas)
    ///    that name matching cannot tell apart. Returns nil when no running
    ///    app matches — the hovered app is simply not running, and its
    ///    preview must show no windows rather than another app's windows.
    /// 2. Falls back to the display name, with fuzzy matching to handle
    ///    discrepancies between the Dock AX title and the system's localized
    ///    name (e.g. "Visual Studio Code" vs "Code").
    private func findRunningApp(named axTitle: String, bundleURL: URL?) -> NSRunningApplication? {
        if let bundleURL {
            // Match any .regular process belonging to the product root (see
            // WindowAttribution). A nested bundle inside the app (e.g.
            // WeChatAppEx.app within WeChat.app) can run on its own, so an
            // exact URL match would miss the product.
            guard let productRoot = WindowAttribution.productRootURL(for: bundleURL) else {
                AppLogger.warning("Dock preview: could not resolve product root. axTitle=\(axTitle), bundleURL=\(bundleURL.path)")
                return nil
            }
            let byURL = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && WindowAttribution.process($0, belongsTo: productRoot)
            }
            if let app = byURL.first {
                AppLogger.verbose("Dock preview: matched by product root. axTitle=\(axTitle), root=\(productRoot.path), pid=\(app.processIdentifier)")
                return app
            }
            // The hovered product is not running: return nil so the preview
            // shows no windows instead of leaking another app's windows.
            AppLogger.debug("Dock preview: no running app for product root. axTitle=\(axTitle), root=\(productRoot.path)")
            return nil
        }

        // 1. Exact match on localizedName. Several products can share a
        // display name (e.g. ChatGPT and ChatGPT Atlas), so when the name is
        // ambiguous prefer the process that actually has visible windows on
        // the current space — otherwise the wrong app's windows would be
        // shown and switching would jump to that app.
        let exactMatches = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.localizedName == axTitle
        }
        if let best = disambiguate(exactMatches) {
            AppLogger.debug("Dock preview: exact match. axTitle=\(axTitle), localizedName=\(best.localizedName ?? "nil"), pid=\(best.processIdentifier)")
            return best
        }

        // 2. Fuzzy match: the AX title contains the localized name, or vice versa.
        let axLower = axTitle.lowercased()
        var fuzzyMatches: [NSRunningApplication] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName?.lowercased() else { continue }
            if axLower.contains(name) || name.contains(axLower) {
                fuzzyMatches.append(app)
            }
        }
        if let best = disambiguate(fuzzyMatches) {
            AppLogger.debug("Dock preview: fuzzy match. axTitle=\(axTitle), localizedName=\(best.localizedName ?? "nil"), bundleID=\(best.bundleIdentifier ?? "nil"), pid=\(best.processIdentifier)")
            return best
        }

        AppLogger.warning("Dock preview: no match found. axTitle=\(axTitle)")
        return nil
    }

    /// Picks the most likely process among several apps sharing the same
    /// display name. Prefers the one with windows on the current space (the
    /// one the user can actually see in the Dock preview); falls back to the
    /// first match when the name is still ambiguous.
    private func disambiguate(_ candidates: [NSRunningApplication]) -> NSRunningApplication? {
        guard let first = candidates.first else {
            return nil
        }
        guard candidates.count > 1 else {
            return first
        }

        // On-screen windows are all this decision needs (which of two
        // same-named apps has anything visible), and the fast path skips the
        // Accessibility-heavy full enumeration this refresh runs again right
        // afterwards anyway.
        let pidsWithWindows = Set(windowMonitorService.getOnScreenWindows().map(\.ownerPID))
        if let withWindows = candidates.first(where: { pidsWithWindows.contains($0.processIdentifier) }) {
            AppLogger.debug("Dock preview: disambiguated duplicate app name by visible windows. pid=\(withWindows.processIdentifier), candidates=\(candidates.map { $0.processIdentifier })")
            return withWindows
        }

        AppLogger.warning("Dock preview: duplicate app name without window disambiguation. name=\(first.localizedName ?? "?"), pids=\(candidates.map { $0.processIdentifier })")
        return first
    }

    /// Called by the view with the card's laid-out height so the panel grows
    /// to fit whichever layout the plugin renders.
    func pluginCardHeightMeasured(_ height: CGFloat) {
        // Not gated on hasPluginCard: the card can lay out (and report) a
        // frame before the slot publisher flips that flag.
        guard abs(height - measuredPluginCardHeight) > 0.5 else { return }
        measuredPluginCardHeight = height
        updatePanelWidth()
    }

    /// Recalculates the panel width and height based on the current card size
    /// setting and window count. The panel exactly fits the content without
    /// clipping or extra padding.
    private func updatePanelWidth() {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 800, height: 600)
        let size = DockPanelMetrics.panelSize(
            spec: settings.dockPreviewLayout.spec,
            count: windows.count,
            cardWidth: settings.dockPreviewCardWidth,
            visibleSize: visible
        )
        let hideStrip = hasPluginCard && pluginOverlay.hidesWindowPreviews(in: settings)
        if hidesWindowStrip != hideStrip { hidesWindowStrip = hideStrip }
        guard hasPluginCard else {
            panelHeight = size.height
            panelWidth = size.width
            return
        }

        let cardExtra = measuredPluginCardHeight > 0
            ? measuredPluginCardHeight + DesignTokens.Spacing.sm
            : DesignTokens.Plugin.belowCardHeight
        let minWidth = DesignTokens.Plugin.belowCardMinWidth
        let maxHeight = visible.height - DockPanelMetrics.screenMargin
        // With no windows (or the option on) the card replaces the strip area.
        if windows.isEmpty || hideStrip {
            panelHeight = min(maxHeight, DockPanelMetrics.headerHeight + cardExtra)
            panelWidth = minWidth
        } else {
            panelHeight = min(maxHeight, size.height + cardExtra)
            panelWidth = max(size.width, minWidth)
        }
    }

    /// Refreshes the current app's windows (called on windowListDidRefresh).
    private func refreshCurrentApp() {
        guard isPanelVisible, !appName.isEmpty else { return }
        refreshWindows(forApp: appName, bundleURL: currentBundleURL)
    }

    func selectWindow(offset: Int) {
        guard !windows.isEmpty else {
            selectedWindow = nil
            return
        }

        guard let selectedWindow,
              let currentIndex = windows.firstIndex(of: selectedWindow) else {
            self.selectedWindow = windows[0]
            return
        }

        let nextIndex = (currentIndex + offset + windows.count) % windows.count
        self.selectedWindow = windows[nextIndex]
    }

    @discardableResult
    func switchToWindowAndHide(_ window: WindowInfo) async -> Bool {
        do {
            try await windowSwitchService.switchToWindow(window)
            await MainActor.run {
                self.hidePanel()
            }
            return true
        } catch {
            AppLogger.error("Dock preview switch failed. windowID=\(window.id), owner=\(window.ownerName), error=\(error)")
            return false
        }
    }

    @discardableResult
    func switchToSelectedWindow() async -> Bool {
        guard let window = selectedWindow else {
            return false
        }
        return await switchToWindowAndHide(window)
    }

    private func setupObservers() {
        pluginOverlay.$slots
            .map { $0[.center] != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] has in
                self?.hasPluginCard = has
                self?.updatePanelWidth()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .settingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settings = self.settingsService.loadSettings()
                self.updatePanelWidth()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .windowListDidRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCurrentApp()
            }
            .store(in: &cancellables)
    }
}
