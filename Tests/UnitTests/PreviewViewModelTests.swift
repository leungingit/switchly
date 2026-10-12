//
//  PreviewViewModelTests.swift
//  SwitchlyTests
//
//  Unit tests for the preview panel's view model state machine — specifically
//  the two regressions that shipped because nothing observed the model
//  directly: the app-scoped entry point leaving the panel body transparent,
//  and the window-list observer refreshing a hidden panel every second.
//

import XCTest
import AppKit
@testable import Switchly

private final class MockWindowMonitorService: WindowMonitorServiceProtocol {
    var windows: [WindowInfo] = []
    var visibleWindowCount = 0
    private(set) var allWindowsCallCount = 0

    func startMonitoring() {}
    func stopMonitoring() {}

    func getAllWindows() -> [WindowInfo] {
        allWindowsCallCount += 1
        return windows
    }

    func getOnScreenWindows() -> [WindowInfo] {
        windows
    }

    func getWindows(for bundleIdentifier: String) -> [WindowInfo] {
        windows
    }

    func getWindows(for bundleIdentifier: String, appName: String) -> [WindowInfo] {
        windows
    }

    func getWindows(for app: MonitoredApp) -> [WindowInfo] {
        windows
    }

    func windows(ownedBy bundleURL: URL) -> [WindowInfo] {
        windows
    }

    func getVisibleWindowCount(for bundleIdentifier: String) -> Int {
        visibleWindowCount
    }

    func filterWindows(_ windows: [WindowInfo], by strategy: PreviewStrategy) -> [WindowInfo] {
        windows
    }

    func filterWindows(_ windows: [WindowInfo], by searchText: String) -> [WindowInfo] {
        windows
    }
}

private final class MockWindowSwitchService: WindowSwitchServiceProtocol {
    func switchToWindow(_ window: WindowInfo) async throws {}
    func switchToApplication(pid: pid_t) async throws {}
}

private final class MockThumbnailService: ThumbnailServiceProtocol {
    func captureThumbnail(for window: WindowInfo, size: CGSize, tier: ThumbnailTier) async throws -> NSImage {
        NSImage()
    }

    func getCachedThumbnail(for window: WindowInfo, tier: ThumbnailTier) -> NSImage? {
        nil
    }

    func preheatThumbnails(for windows: [WindowInfo], size: CGSize, tier: ThumbnailTier, reason: String) {}

    func setRefreshInterest(_ windowIDs: Set<CGWindowID>, owner: AnyObject, tier: ThumbnailTier) {}

    func clearRefreshInterest(owner: AnyObject) {}

    func startAutoRefresh() {}

    func stopAutoRefresh() {}
}

private final class MockSettingsService: SettingsServiceProtocol {
    private let settings: AppSettings

    init(settings: AppSettings = .default) {
        self.settings = settings
    }

    func loadSettings() -> AppSettings {
        settings
    }

    func saveSettings(_ settings: AppSettings) throws {}

    func observeChanges(_ handler: @escaping (AppSettings) -> Void) {}
}

final class PreviewViewModelTests: XCTestCase {

    private func makeViewModel(monitor: MockWindowMonitorService) -> PreviewViewModel {
        PreviewViewModel(
            windowMonitorService: monitor,
            windowSwitchService: MockWindowSwitchService(),
            thumbnailService: MockThumbnailService(),
            settingsService: MockSettingsService()
        )
    }

    private func makeWindow(id: CGWindowID) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: 1000,
            ownerName: "App",
            windowTitle: "Window \(id)",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnCurrentSpace: true,
            windowNumber: Int(id)
        )
    }

    /// Regression: the app-scoped entry point (per-app shortcuts) used to
    /// refresh the window list without ever flipping `isPanelVisible`, so the
    /// NSPanel appeared with its SwiftUI body at opacity 0 — an invisible
    /// "blank panel" that still swallowed keyboard focus.
    func testAppScopedShowWindowsMarksThePanelVisible() {
        let monitor = MockWindowMonitorService()
        monitor.windows = [makeWindow(id: 1), makeWindow(id: 2)]
        monitor.visibleWindowCount = 2
        let viewModel = makeViewModel(monitor: monitor)

        XCTAssertFalse(viewModel.isPanelVisible, "a freshly created model must start hidden")

        viewModel.showWindows(for: [MonitoredApp(bundleIdentifier: "com.example.app", appName: "Example")])

        XCTAssertTrue(
            viewModel.isPanelVisible,
            "the app-scoped entry point must flip isPanelVisible — the panel body renders at opacity 0 otherwise"
        )
    }

    /// The panel-global entry point keeps working as before.
    func testShowPanelMarksThePanelVisible() {
        let monitor = MockWindowMonitorService()
        monitor.windows = [makeWindow(id: 1)]
        let viewModel = makeViewModel(monitor: monitor)

        viewModel.showPanel()

        XCTAssertTrue(viewModel.isPanelVisible)
    }

    /// Regression: the window-list observer used to refresh unconditionally,
    /// so a hidden panel still walked the full window list (CG +
    /// Accessibility) on every monitor tick — forever, once the panel
    /// singleton exists. Both show paths refresh synchronously, so a hidden
    /// panel loses nothing by skipping.
    func testHiddenPanelSkipsWindowListRefreshes() {
        let monitor = MockWindowMonitorService()
        monitor.windows = [makeWindow(id: 1)]
        let viewModel = makeViewModel(monitor: monitor)

        NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
        XCTAssertEqual(
            monitor.allWindowsCallCount, 0,
            "a hidden panel must not enumerate windows on window-list changes"
        )

        viewModel.showPanel()
        XCTAssertEqual(monitor.allWindowsCallCount, 1, "showing the panel refreshes once synchronously")

        NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
        XCTAssertEqual(
            monitor.allWindowsCallCount, 2,
            "a visible panel keeps refreshing on window-list changes"
        )
    }
}
