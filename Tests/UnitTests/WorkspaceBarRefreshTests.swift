import XCTest
import Combine
@testable import Switchly

private final class WorkspaceRefreshMonitor: WindowMonitorServiceProtocol {
    var windows: [WindowInfo] = []
    func startMonitoring() {}
    func stopMonitoring() {}
    func getAllWindows() -> [WindowInfo] { windows }
    func getOnScreenWindows() -> [WindowInfo] { windows }
    func getWindows(for bundleIdentifier: String) -> [WindowInfo] { windows }
    func getWindows(for bundleIdentifier: String, appName: String) -> [WindowInfo] { windows }
    func getWindows(for app: MonitoredApp) -> [WindowInfo] { windows }
    func windows(ownedBy bundleURL: URL) -> [WindowInfo] { windows }
    func getVisibleWindowCount(for bundleIdentifier: String) -> Int { windows.count }
    func filterWindows(_ windows: [WindowInfo], by strategy: PreviewStrategy) -> [WindowInfo] { windows }
    func filterWindows(_ windows: [WindowInfo], by searchText: String) -> [WindowInfo] { windows }
    func filterWindows(_ windows: [WindowInfo], for bundleIdentifier: String, appName: String?) -> [WindowInfo] { windows }
}

private final class WorkspaceNoopSwitcher: WindowSwitchServiceProtocol {
    func switchToWindow(_ window: WindowInfo) async throws {}
    func switchToApplication(pid: pid_t) async throws {}
}

/// 窗口列表每约 2s 刷新一次；内容未变时不得重新发布 items，
/// 否则 Workspace 栏会对同一 frame 重复做 morph 动画（与 Dock 预览同类问题）。
final class WorkspaceBarRefreshTests: XCTestCase {
    @MainActor
    func testRepeatedRefreshWithSameWindowsDoesNotRepublishItems() throws {
        let suite = "com.switchly.tests.workspace-bar-refresh"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let app = WorkspaceAppItem(bundleIdentifier: "com.example.app", appName: "Example")
        let workspace = Workspace(name: "Test", appItems: [app])
        var settings = AppSettings.default
        settings.workspaces = [workspace]
        let settingsService = SettingsService(defaults: defaults)
        try settingsService.saveSettings(settings)

        let monitor = WorkspaceRefreshMonitor()
        monitor.windows = [WindowInfo(id: 9201, ownerPID: 1, ownerName: "Example", windowTitle: "Docs",
                                      bounds: .zero, isOnCurrentSpace: true, windowNumber: 9201)]
        let model = WorkspaceBarViewModel(settingsService: settingsService,
                                          windowMonitorService: monitor,
                                          windowSwitchService: WorkspaceNoopSwitcher())
        model.show(workspaceID: workspace.id)
        XCTAssertEqual(model.items.count, 1)

        var emissions = 0
        var bag = Set<AnyCancellable>()
        model.$items.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        model.$panelWidth.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)

        model.refreshItems()
        XCTAssertEqual(emissions, 0, "内容未变的刷新不应触发任何发布")

        monitor.windows = [WindowInfo(id: 9201, ownerPID: 1, ownerName: "Example", windowTitle: "Renamed",
                                      bounds: .zero, isOnCurrentSpace: true, windowNumber: 9201)]
        model.refreshItems()
        XCTAssertEqual(model.items.first?.title, "Renamed", "标题变化必须仍然更新")
        XCTAssertEqual(emissions, 1)
    }

    @MainActor
    func testEmptyWorkspaceStopsRepublishingEmptyItems() throws {
        let suite = "com.switchly.tests.workspace-bar-empty"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settingsService = SettingsService(defaults: defaults)
        let monitor = WorkspaceRefreshMonitor()
        let model = WorkspaceBarViewModel(settingsService: settingsService,
                                          windowMonitorService: monitor,
                                          windowSwitchService: WorkspaceNoopSwitcher())
        model.refreshItems() // 没有工作区：items 已经是空数组

        var emissions = 0
        var bag = Set<AnyCancellable>()
        model.$items.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        model.refreshItems()
        XCTAssertEqual(emissions, 0)
    }
}
