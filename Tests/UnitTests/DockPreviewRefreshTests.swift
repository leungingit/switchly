import XCTest
import Combine
import AppKit
@testable import Switchly

private final class StaticWindowMonitor: WindowMonitorServiceProtocol {
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
}

private final class NoopSwitchService: WindowSwitchServiceProtocol {
    func switchToWindow(_ window: WindowInfo) async throws {}
    func switchToApplication(pid: pid_t) async throws {}
}

/// 窗口监控每约 2s 触发一次刷新；内容未变时不得重复发布，
/// 否则面板会重绘并以相同 frame 重复 setFrame（周期性闪白）。
final class DockPreviewRefreshTests: XCTestCase {
    @MainActor
    func testRepeatedRefreshWithSameContentDoesNotRepublish() throws {
        let finder = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
            "需要 Finder 进程作为被悬停的应用"
        )
        let suite = "com.switchly.tests.dock-refresh"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let monitor = StaticWindowMonitor()
        monitor.windows = [WindowInfo(id: 9001, ownerPID: finder.processIdentifier, ownerName: "Finder",
                                      windowTitle: "Docs", bounds: .zero, isOnCurrentSpace: true, windowNumber: 9001)]
        let model = DockPreviewViewModel(windowMonitorService: monitor, windowSwitchService: NoopSwitchService(),
                                         settingsService: SettingsService(defaults: defaults))
        let name = finder.localizedName ?? "Finder"
        model.refreshWindows(forApp: name)
        XCTAssertEqual(model.windows.map(\.id), [9001])
        let context = try XCTUnwrap(model.pluginContext(for: monitor.windows[0]))
        XCTAssertEqual(context.captureTarget?.pid, finder.processIdentifier)
        XCTAssertEqual(context.captureTarget?.processStartedAt, WindowCaptureProcessIdentity.startedAt(pid: finder.processIdentifier))

        let ownWindow = WindowInfo(id: 9002, ownerPID: getpid(), ownerName: "Fixture", windowTitle: "Fixture",
                                   bounds: .zero, isOnCurrentSpace: true, windowNumber: 9002)
        XCTAssertEqual(model.pluginContext(for: ownWindow)?.captureTarget?.pid, getpid(),
                       "窗口插件绑定真实 owner，不得改用 Dock 所属主进程")

        var emissions = 0
        var bag = Set<AnyCancellable>()
        model.$windows.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        model.$selectedWindow.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        model.$panelWidth.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        model.$panelHeight.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        model.$isEnumeratingWindows.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)

        model.refreshWindows(forApp: name)
        XCTAssertEqual(emissions, 0, "内容未变的刷新不应触发任何发布")

        monitor.windows = [WindowInfo(id: 9001, ownerPID: finder.processIdentifier, ownerName: "Finder",
                                      windowTitle: "Renamed", bounds: .zero, isOnCurrentSpace: true, windowNumber: 9001)]
        model.refreshWindows(forApp: name)
        XCTAssertEqual(model.windows.first?.windowTitle, "Renamed", "标题变化必须仍然更新")
    }
}
