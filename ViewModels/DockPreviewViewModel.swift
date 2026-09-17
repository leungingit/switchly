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
    @Published var selectedWindow: WindowInfo?
    @Published var isPanelVisible: Bool = false
    @Published var appName: String = ""
    @Published var panelWidth: CGFloat = 200
    @Published var panelHeight: CGFloat = 180

    private let windowMonitorService: WindowMonitorServiceProtocol
    private let windowSwitchService: WindowSwitchServiceProtocol
    private let settingsService: SettingsServiceProtocol
    private var cancellables = Set<AnyCancellable>()
    private var currentBundleID: String?
    private var currentBundleURL: URL?

    init(
        windowMonitorService: WindowMonitorServiceProtocol = WindowMonitorService.shared,
        windowSwitchService: WindowSwitchServiceProtocol = WindowSwitchService.shared,
        settingsService: SettingsServiceProtocol = SettingsService.shared
    ) {
        self.windowMonitorService = windowMonitorService
        self.windowSwitchService = windowSwitchService
        self.settingsService = settingsService
        setupObservers()
    }

    func showPanel(forApp appName: String, bundleURL: URL? = nil) {
        self.appName = appName
        self.currentBundleURL = bundleURL
        isPanelVisible = true
        refreshWindows(forApp: appName, bundleURL: bundleURL)
    }

    func hidePanel() {
        isPanelVisible = false
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
        if selectedWindow == nil || !self.windows.contains(selectedWindow!) {
            selectedWindow = self.windows.first
        }
        updatePanelWidth()
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

        let pidsWithWindows = Set(windowMonitorService.getAllWindows().map(\.ownerPID))
        if let withWindows = candidates.first(where: { pidsWithWindows.contains($0.processIdentifier) }) {
            AppLogger.debug("Dock preview: disambiguated duplicate app name by visible windows. pid=\(withWindows.processIdentifier), candidates=\(candidates.map { $0.processIdentifier })")
            return withWindows
        }

        AppLogger.warning("Dock preview: duplicate app name without window disambiguation. name=\(first.localizedName ?? "?"), pids=\(candidates.map { $0.processIdentifier })")
        return first
    }

    /// Recalculates the panel width and height based on the current card size
    /// setting and window count. The panel exactly fits the content without
    /// clipping or extra padding.
    private func updatePanelWidth() {
        let settings = settingsService.loadSettings()
        let cardThumbnailWidth = settings.dockPreviewCardWidth
        let cardTotalWidth = cardThumbnailWidth + 12  // 6+6 padding
        let spacing: CGFloat = 10
        let horizontalPadding: CGFloat = 24  // 12+12 edge insets
        let count = windows.count

        // Height calculation
        let thumbnailHeight = cardThumbnailWidth * 0.625  // keep 75/120 ratio
        let cardTotalHeight = thumbnailHeight + 12 + 6 + 20  // padding + spacing + text
        let stripVerticalPadding: CGFloat = 20  // 10+10
        let headerHeight: CGFloat = 40
        panelHeight = headerHeight + stripVerticalPadding + cardTotalHeight

        // Width calculation
        guard count > 0 else {
            panelWidth = 200
            return
        }

        let totalWidth = CGFloat(count) * cardTotalWidth + CGFloat(count - 1) * spacing + horizontalPadding
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 800
        let maxWidth = screenWidth - 96  // 48px margin on each side
        panelWidth = min(maxWidth, totalWidth)
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

    func switchToWindowAndHide(_ window: WindowInfo) async {
        do {
            try await windowSwitchService.switchToWindow(window)
            await MainActor.run {
                self.hidePanel()
            }
        } catch {
            AppLogger.error("Dock preview switch failed. windowID=\(window.id), owner=\(window.ownerName), error=\(error)")
        }
    }

    @discardableResult
    func switchToSelectedWindow() async -> Bool {
        guard let window = selectedWindow else {
            return false
        }
        await switchToWindowAndHide(window)
        return true
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: .windowListDidRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCurrentApp()
            }
            .store(in: &cancellables)
    }
}