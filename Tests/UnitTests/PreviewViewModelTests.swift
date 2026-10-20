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
    private(set) var appWindowsCallCount = 0
    var windowsByBundle: [String: [WindowInfo]] = [:]

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
        appWindowsCallCount += 1
        return windowsByBundle[app.bundleIdentifier] ?? windows
    }

    func filterWindows(_ windows: [WindowInfo], for bundleIdentifier: String, appName: String?) -> [WindowInfo] {
        windowsByBundle[bundleIdentifier] ?? windows
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

    func testSnapshotFilteringPreservesAppIdentityAndOwnerNameFallback() throws {
        let app = NSRunningApplication.current
        let bundleID = try XCTUnwrap(app.bundleIdentifier)
        let name = try XCTUnwrap(app.localizedName)
        let window = WindowInfo(
            id: 42, ownerPID: app.processIdentifier, ownerName: "窗口所属应用",
            windowTitle: "测试窗口", bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnCurrentSpace: true, windowNumber: 42
        )
        let monitor = WindowMonitorService.shared
        XCTAssertEqual(monitor.filterWindows([window], for: bundleID, appName: name.uppercased()).map(\.id), [42])
        XCTAssertEqual(monitor.filterWindows([window], for: bundleID, appName: window.ownerName).map(\.id), [42])
        XCTAssertEqual(monitor.filterWindows([window], for: bundleID, appName: nil).map(\.id), [42])
        XCTAssertEqual(monitor.filterWindows([window], for: bundleID, appName: "").map(\.id), [42])
        XCTAssertTrue(monitor.filterWindows([window], for: bundleID, appName: "其他产品").isEmpty)
        XCTAssertTrue(monitor.filterWindows([window], for: "com.example.other", appName: name).isEmpty)
    }

    func testMultipleAppsShareOneWindowSnapshotPerRefresh() {
        let monitor = MockWindowMonitorService()
        let first = makeWindow(id: 1)
        let second = makeWindow(id: 2)
        monitor.windows = [first, second]
        monitor.windowsByBundle = ["com.example.a": [first], "com.example.b": [second]]
        let viewModel = makeViewModel(monitor: monitor)
        viewModel.showWindows(for: [
            MonitoredApp(bundleIdentifier: "com.example.a", appName: "甲"),
            MonitoredApp(bundleIdentifier: "com.example.b", appName: "乙")
        ])

        XCTAssertEqual(viewModel.windows.map(\.id), [1, 2])
        XCTAssertEqual(monitor.allWindowsCallCount, 1, "多应用首次展示只应枚举一次")
        XCTAssertEqual(monitor.appWindowsCallCount, 0, "不应逐应用重新枚举窗口")
        viewModel.refreshWindows()
        XCTAssertEqual(monitor.allWindowsCallCount, 2, "每轮刷新各取一次新快照")
        XCTAssertEqual(viewModel.windows.map(\.id), [1, 2])
    }

    @MainActor
    func testWorkspaceAppsShareOneWindowSnapshotAndKeepPlaceholders() {
        let monitor = MockWindowMonitorService()
        let first = makeWindow(id: 1)
        monitor.windows = [first]
        monitor.windowsByBundle = ["com.example.a": [first], "com.example.b": []]
        let viewModel = WorkspaceBarViewModel(
            settingsService: MockSettingsService(),
            windowMonitorService: monitor,
            windowSwitchService: MockWindowSwitchService()
        )
        viewModel.workspace = Workspace(name: "工作区", appItems: [
            WorkspaceAppItem(bundleIdentifier: "com.example.a", appName: "甲"),
            WorkspaceAppItem(bundleIdentifier: "com.example.b", appName: "乙")
        ], missingAppDisplayMode: .placeholder)
        viewModel.refreshItems()

        XCTAssertEqual(monitor.allWindowsCallCount, 1)
        XCTAssertEqual(viewModel.items.count, 2)
        guard case .window(let window, _) = viewModel.items[0],
              case .placeholder(let missing, _) = viewModel.items[1] else {
            return XCTFail("应保留应用顺序、窗口及缺失应用占位")
        }
        XCTAssertEqual(window.id, first.id)
        XCTAssertEqual(missing.bundleIdentifier, "com.example.b")
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
