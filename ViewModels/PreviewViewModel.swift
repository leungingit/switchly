//
//  PreviewViewModel.swift
//  Switchly
//
//  ViewModel for preview panel
//

import Foundation
import Combine
import AppKit
import SwiftUI

class PreviewViewModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var filteredWindows: [WindowInfo] = []
    @Published var searchText: String = ""
    @Published var selectedWindow: WindowInfo?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isPanelVisible: Bool = false

    /// Unit point (in panel space) the content collapses toward when the
    /// panel dismisses — the center of the activated card, or `.center`.
    @Published var dismissAnchor: UnitPoint = .center

    /// Window the enlarged surface reproduces: the replica panel replays it at
    /// its own size and place. Follows the selection immediately (keyboard /
    /// click) and the pointer after `AppSettings.previewReplicaHoverDelay` —
    /// see `setHoveredWindow`.
    @Published var replicaWindow: WindowInfo?

    /// Content size of the panel, resolved from the target screen's
    /// `visibleFrame` by `PreviewPanel.layoutForDisplayMode()`. Lives here so
    /// the AppKit frame, the SwiftUI layout and the dismissal zoom anchor all
    /// read the same number instead of three hard-coded copies.
    @Published var panelSize: CGSize = PreviewPanelMetrics.fallbackSize

    /// Card frames in panel space, reported by each visible card. Used to
    /// compute the dismissal zoom anchor. Not published: only the panel reads
    /// it (synchronously, at dismissal time), and publishing would re-render
    /// the whole grid on every scroll frame.
    var cardFrames: [CGWindowID: CGRect] = [:]

    var gridColumnCount: Int = 1
    
    private let windowMonitorService: WindowMonitorServiceProtocol
    private let windowSwitchService: WindowSwitchServiceProtocol
    private let thumbnailService: ThumbnailServiceProtocol
    private let settingsService: SettingsServiceProtocol
    private var scope: PreviewScope = .all
    private var cancellables = Set<AnyCancellable>()

    /// Pending delayed replica swap for a hovered card. Cancelled whenever the
    /// selection moves, the pointer leaves the grid, or another card is
    /// hovered — a stale hover must never win over a newer one.
    private var replicaHoverTask: Task<Void, Never>?

    /// Card the pointer is currently over, if any. Owns the delayed swap, so a
    /// late exit event from a card the pointer already left cannot cancel it.
    private var hoveredWindowID: CGWindowID?
    
    init(
        windowMonitorService: WindowMonitorServiceProtocol = WindowMonitorService.shared,
        windowSwitchService: WindowSwitchServiceProtocol = WindowSwitchService.shared,
        thumbnailService: ThumbnailServiceProtocol = ThumbnailService.shared,
        settingsService: SettingsServiceProtocol = SettingsService.shared
    ) {
        self.windowMonitorService = windowMonitorService
        self.windowSwitchService = windowSwitchService
        self.thumbnailService = thumbnailService
        self.settingsService = settingsService
        
        setupObservers()
    }
    
    func refreshWindows() {
        isLoading = true
        defer { isLoading = false }

        switch scope {
        case .all:
            refreshAllWindows()
        case .apps(let apps):
            refreshWindows(for: apps)
        }
    }

    func refreshAllWindows() {
        scope = .all
        refreshAllWindowsPreservingScope()
    }

    private func refreshAllWindowsPreservingScope() {
        isLoading = true
        defer { isLoading = false }
        
        let settings = settingsService.loadSettings()
        var allWindows = windowMonitorService.getAllWindows()
        AppLogger.info("Refreshing preview windows. strategy=\(settings.previewStrategy.rawValue), rawCount=\(allWindows.count)")
        allWindows = windowMonitorService.filterWindows(allWindows, by: settings.previewStrategy)
        AppLogger.info("Preview windows filtered. count=\(allWindows.count)")
        
        windows = allWindows
        applyFilter()
    }

    private func refreshWindows(for apps: [MonitoredApp]) {
        isLoading = true
        defer { isLoading = false }

        let snapshot = apps.isEmpty ? [] : windowMonitorService.getAllWindows()
        let appWindows = apps.flatMap {
            windowMonitorService.filterWindows(snapshot, for: $0.bundleIdentifier, appName: $0.appName)
        }
        AppLogger.info("Refreshing app-scoped preview windows. apps=\(apps.map { $0.appName }.joined(separator: ",")), count=\(appWindows.count)")
        windows = appWindows
        applyFilter()
    }
    
    func selectWindow(_ window: WindowInfo) {
        selectedWindow = window
    }

    /// Pointer-driven replica update, throttled by `previewReplicaHoverDelay`.
    ///
    /// Sweeping the pointer across the grid crosses several cards; without the
    /// delay each crossing would capture a window-sized bitmap. Leaving the
    /// grid restores the selection, so a stale hover never sticks.
    ///
    /// Hover never touches `selectedWindow`: the panel's contract stays
    /// "activate on Enter/click, hover only previews".
    ///
    /// - Parameter hovering: `false` is only honoured for the card this
    ///   model still considers hovered. SwiftUI does not guarantee that a card's
    ///   exit event arrives before the next card's entry, and moving from card A
    ///   to card B must not let A's late exit overwrite B's hover.
    func setHoveredWindow(_ window: WindowInfo, hovering: Bool, settings: AppSettings) {
        guard settings.previewInteractionMode.showsWindowReplica else {
            return
        }

        guard hovering else {
            guard hoveredWindowID == window.id else {
                return
            }
            hoveredWindowID = nil
            replicaHoverTask?.cancel()
            replicaHoverTask = nil
            if replicaWindow?.id != selectedWindow?.id {
                replicaWindow = selectedWindow
            }
            return
        }

        hoveredWindowID = window.id
        replicaHoverTask?.cancel()
        replicaHoverTask = nil

        guard window.id != replicaWindow?.id else {
            return
        }

        let delay = max(0, settings.previewReplicaHoverDelay)
        replicaHoverTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                return
            }
            self?.replicaWindow = window
        }
    }

    /// Points the replica back at a window that is still in the filtered list —
    /// used when a refresh recycles windows out from under it.
    private func reconcileReplicaWindow() {
        if let replica = replicaWindow, filteredWindows.contains(replica) {
            return
        }
        replicaWindow = selectedWindow ?? filteredWindows.first
    }

    func selectNextWindow(reverse: Bool = false) {
        selectWindow(offset: reverse ? -1 : 1)
    }

    func selectWindow(offset: Int) {
        guard !filteredWindows.isEmpty else {
            selectedWindow = nil
            return
        }

        guard let selectedWindow,
              let currentIndex = filteredWindows.firstIndex(of: selectedWindow) else {
            self.selectedWindow = filteredWindows[0]
            return
        }

        let nextIndex = (currentIndex + offset + filteredWindows.count) % filteredWindows.count
        self.selectedWindow = filteredWindows[nextIndex]
    }

    func updateGridColumnCount(width: CGFloat, settings: AppSettings) {
        // The preview/highlight mode adds a window behind the panel, it does not
        // turn the panel into a list — so one arrow key always moves by one row
        // and the column count is a geometry question. It is still layout-aware:
        // the stage layout loses the ornament rail's width and runs narrower
        // cells, and arrow-key navigation must step by the count actually drawn.
        let spacing: CGFloat = 14
        let railWidth: CGFloat = settings.previewPanelStyle == .stage ? 58 : 0
        let contentWidth = width - 32 - railWidth
        let minWidth = settings.previewPanelStyle.minimumCardWidth(for: settings.thumbnailSize)
        gridColumnCount = max(1, Int((contentWidth + spacing) / (minWidth + spacing)))
    }

    @discardableResult
    func switchToSelectedOrFirstWindow() async -> Bool {
        if selectedWindow == nil {
            selectedWindow = filteredWindows.first
        }
        return await switchToSelectedWindow()
    }
    
    @discardableResult
    func switchToSelectedWindow() async -> Bool {
        guard let window = selectedWindow else {
            return false
        }

        return await switchToWindow(window)
    }

    @discardableResult
    func switchToWindow(_ window: WindowInfo) async -> Bool {
        selectedWindow = window

        do {
            try await windowSwitchService.switchToWindow(window)
            hidePanel()
            return true
        } catch {
            errorMessage = "Failed to switch window: \(error.localizedDescription)"
            AppLogger.error("Failed to switch preview window. windowID=\(window.id), owner=\(window.ownerName), title=\(window.windowTitle), error=\(error)")
            return false
        }
    }
    
    func showPanel() {
        isPanelVisible = true
        refreshAllWindows()
    }
    
    func hidePanel() {
        isPanelVisible = false
    }
    
    func togglePanel() {
        if isPanelVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showWindows(for app: MonitoredApp) {
        showWindows(for: [app])
    }

    func showWindows(for apps: [MonitoredApp]) {
        scope = .apps(apps)
        searchText = ""
        // The panel content is driven by `isPanelVisible` (opacity/scale in
        // `PreviewView`); `presentPanel` flips it via `showPanel()`, but this
        // app-scoped entry point never did — the panel appeared with a fully
        // transparent body ("blank panel" on every per-app shortcut).
        isPanelVisible = true
        refreshWindows(for: apps)

        if apps.count == 1,
           let app = apps.first,
           app.autoSwitchIfSingle,
           windows.count == 1,
           windowMonitorService.getVisibleWindowCount(for: app.bundleIdentifier) == 1 {
            let targetWindow = windows[0]
            AppLogger.info("Auto-switching single app window from preview scope. app=\(app.appName), windowID=\(targetWindow.id)")
            Task {
                do {
                    try await windowSwitchService.switchToWindow(targetWindow)
                    await MainActor.run {
                        self.hidePanel()
                        // No panel was shown for this switch; let the status
                        // bar item pulse so the user gets confirmation.
                        UsageStatisticsService.shared.record(
                            .quickSwitch,
                            source: QuickSwitchAttribution.source(for: .panelScopedAutoSwitch),
                            at: Date()
                        )
                        NotificationCenter.default.post(name: .switchDidComplete, object: nil)
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Failed to switch window: \(error.localizedDescription)"
                    }
                    AppLogger.error("Auto-switch single window failed. app=\(app.appName), error=\(error)")
                }
            }
        }
    }
    
    private func applyFilter() {
        var result = windows
        
        if !searchText.isEmpty {
            result = windowMonitorService.filterWindows(result, by: searchText)
        }
        
        filteredWindows = result
        if let selectedWindow, !filteredWindows.contains(selectedWindow) {
            self.selectedWindow = filteredWindows.first
        } else if selectedWindow == nil {
            self.selectedWindow = filteredWindows.first
        }
        reconcileReplicaWindow()
        AppLogger.debug("Applied preview search filter. searchText=\(searchText), outputCount=\(filteredWindows.count)")
    }
    
    private func setupObservers() {
        $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyFilter()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .windowListDidRefresh)
            .sink { [weak self] _ in
                // Hidden panels skip the refresh: the tick fires every
                // 1–5 s plus on every app activation, and each refresh walks
                // the full window list (CG + Accessibility) on the main
                // thread. Both show paths (showPanel / showWindows) refresh
                // synchronously before the panel appears, so nothing is lost.
                guard let self, self.isPanelVisible else {
                    return
                }
                self.refreshWindows()
            }
            .store(in: &cancellables)

        // Selection drives the replica synchronously: keyboard navigation must
        // swap the enlarged surface with no delay, unlike the pointer.
        // removeDuplicates keeps a re-selection of the same window (or a
        // list refresh) from pulling the replica back off a hovered card.
        $selectedWindow
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] window in
                guard let self, self.replicaWindow?.id != window?.id else {
                    return
                }
                self.replicaWindow = window
            }
            .store(in: &cancellables)
    }
}

private enum PreviewScope {
    case all
    case apps([MonitoredApp])
}
