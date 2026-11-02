import XCTest
import AppKit
import Combine
@testable import Switchly

private final class PanelRefreshMonitor: WindowMonitorServiceProtocol {
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

private final class PanelNoopSwitcher: WindowSwitchServiceProtocol {
    func switchToWindow(_ window: WindowInfo) async throws {}
    func switchToApplication(pid: pid_t) async throws {}
}

/// 计数面板被强制重设 frame 的次数：面板可见期间，窗口列表刷新若内容不变，
/// 不得再 setFrame——那会让透明玻璃面板周期性重绘（表现为闪白）。
private final class FrameCountingDockPanel: DockPreviewPanel {
    var frameSetCount = 0

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameSetCount += 1
        super.setFrame(frameRect, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        frameSetCount += 1
        super.setFrame(frameRect, display: flag, animate: animateFlag)
    }
}

final class DockPreviewPanelRefreshTests: XCTestCase {
    @MainActor
    func testWindowListRefreshDoesNotReframeVisiblePanel() throws {
        let finder = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
            "需要 Finder 进程作为被悬停的应用"
        )
        let suite = "com.switchly.tests.dock-panel-refresh"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let monitor = PanelRefreshMonitor()
        monitor.windows = [WindowInfo(id: 9101, ownerPID: finder.processIdentifier, ownerName: "Finder",
                                      windowTitle: "Docs", bounds: .zero, isOnCurrentSpace: true, windowNumber: 9101)]
        let model = DockPreviewViewModel(windowMonitorService: monitor, windowSwitchService: PanelNoopSwitcher(),
                                         settingsService: SettingsService(defaults: defaults))
        let panel = FrameCountingDockPanel(viewModel: model)
        defer { panel.orderOut(nil) }

        let iconFrame = NSRect(x: 200, y: 40, width: 64, height: 64)
        panel.show(forApp: finder.localizedName ?? "Finder", aboveIconFrame: iconFrame)
        // 入场动画逐帧 setFrame；等计数连续 0.3s 不再增长后再开始计数。
        var quietSince = Date()
        var lastCount = panel.frameSetCount
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if panel.frameSetCount != lastCount {
                lastCount = panel.frameSetCount
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= 0.3 {
                break
            }
        }
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(model.windows.map(\.id), [9101])

        panel.frameSetCount = 0
        var sizeEmissions = 0
        var bag = Set<AnyCancellable>()
        model.$panelWidth.dropFirst().sink { _ in sizeEmissions += 1 }.store(in: &bag)
        model.$panelHeight.dropFirst().sink { _ in sizeEmissions += 1 }.store(in: &bag)
        for _ in 0..<3 {
            NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(sizeEmissions, 0, "内容未变的刷新不得重新发布尺寸")
        XCTAssertEqual(panel.frameSetCount, 0, "内容未变的刷新不得重设面板 frame")

        // 真实变化仍需重新布局：窗口消失后面板要收缩。
        monitor.windows = []
        NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(panel.frameSetCount, 0, "窗口列表真实变化时面板仍应调整尺寸")
    }
}
