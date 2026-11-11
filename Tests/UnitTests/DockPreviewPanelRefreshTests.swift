import XCTest
import AppKit
import Combine
@testable import Switchly

private final class PanelRefreshMonitor: WindowMonitorServiceProtocol {
    var windows: [WindowInfo] = []
    var reads = 0
    func startMonitoring() {}
    func stopMonitoring() {}
    func getAllWindows() -> [WindowInfo] { reads += 1; return windows }
    func getOnScreenWindows() -> [WindowInfo] { windows }
    func getWindows(for bundleIdentifier: String) -> [WindowInfo] { windows }
    func getWindows(for bundleIdentifier: String, appName: String) -> [WindowInfo] { windows }
    func getWindows(for app: MonitoredApp) -> [WindowInfo] { windows }
    func windows(ownedBy bundleURL: URL) -> [WindowInfo] { reads += 1; return windows }
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
    func testMagnificationAnchorUpdateMovesWithoutReloadingWindows() async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipIf(session?["CGSSessionScreenIsLocked"] as? Bool == true, "锁屏无法验证窗口动画")
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let screen = try XCTUnwrap(NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main)
        let suite = "com.switchly.tests.dock-anchor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = PanelRefreshMonitor()
        let model = DockPreviewViewModel(windowMonitorService: monitor, windowSwitchService: PanelNoopSwitcher(),
            settingsService: SettingsService(defaults: defaults))
        let panel = FrameCountingDockPanel(viewModel: model)
        defer { panel.orderOut(nil); model.hidePanel() }
        let original = CGRect(x: screen.visibleFrame.midX - 32, y: screen.visibleFrame.minY, width: 64, height: 64)
        let shown = expectation(description: "panel shown")
        panel.show(forApp: finder.localizedName ?? "Finder", aboveIconFrame: original, completion: { shown.fulfill() })
        await fulfillment(of: [shown], timeout: 2)
        let reads = monitor.reads
        let magnified = original.offsetBy(dx: 80, dy: 0)
        panel.updateAnchorFrame(magnified)
        XCTAssertEqual(monitor.reads, reads, "同图标锚点变化不能重查窗口")
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(panel.frame.midX - magnified.midX) < 0.5
        }, object: nil)
        await fulfillment(of: [moved], timeout: 3)
    }
    @MainActor
    func testHideCancelsAQueuedPresentation() async throws {
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let suite = "com.switchly.tests.dock-hide-pending.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockPreviewViewModel(windowMonitorService: PanelRefreshMonitor(),
            windowSwitchService: PanelNoopSwitcher(), settingsService: SettingsService(defaults: defaults))
        let panel = FrameCountingDockPanel(viewModel: model)
        defer { panel.orderOut(nil) }
        panel.show(forApp: finder.localizedName ?? "Finder", aboveIconFrame: CGRect(x: 200, y: 40, width: 64, height: 64))
        panel.hide()
        let drained = expectation(description: "queued presentation drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertFalse(panel.isVisible, "离开 Dock 后，迟到的展示任务不能把面板重新显示")
        XCTAssertFalse(model.isPanelVisible)
    }

    @MainActor
    func testWindowListRefreshDoesNotReframeVisiblePanel() async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipIf(session?["CGSSessionScreenIsLocked"] as? Bool == true,
                      "锁屏环境无法验收真实窗口动画，解锁后需重新运行")
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
        let shown = expectation(description: "panel ordered front")
        panel.show(forApp: finder.localizedName ?? "Finder", aboveIconFrame: iconFrame, completion: { shown.fulfill() })
        await fulfillment(of: [shown], timeout: 3)
        try XCTSkipUnless(panel.isVisible, "当前会话无法显示面板（无可用显示会话），跳过")

        // 异步让出主线程，等待真实动画提交；嵌套 RunLoop 会阻止动画事务结束。
        var quietSince = Date()
        var lastCount = panel.frameSetCount
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if panel.frameSetCount != lastCount {
                lastCount = panel.frameSetCount
                quietSince = Date()
            }
            return Date().timeIntervalSince(quietSince) >= 0.3
        }, object: nil)
        await fulfillment(of: [settled], timeout: 4)
        XCTAssertEqual(model.windows.map(\.id), [9101])

        panel.frameSetCount = 0
        var sizeEmissions = 0
        var bag = Set<AnyCancellable>()
        model.$panelWidth.dropFirst().sink { _ in sizeEmissions += 1 }.store(in: &bag)
        model.$panelHeight.dropFirst().sink { _ in sizeEmissions += 1 }.store(in: &bag)
        for _ in 0..<3 {
            NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
            let refreshed = expectation(description: "unchanged refresh processed")
            DispatchQueue.main.async { refreshed.fulfill() }
            await fulfillment(of: [refreshed], timeout: 1)
        }
        XCTAssertEqual(sizeEmissions, 0, "内容未变的刷新不得重新发布尺寸")
        XCTAssertEqual(panel.frameSetCount, 0, "内容未变的刷新不得重设面板 frame")

        // 真实变化仍需重新布局：窗口消失后面板要收缩。
        monitor.windows = []
        NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            panel.frameSetCount > 0 && abs(panel.frame.width - model.panelWidth) <= 0.5
                && abs(panel.frame.height - model.panelHeight) <= 0.5
        }, object: nil)
        await fulfillment(of: [resized], timeout: 3)
        XCTAssertGreaterThan(panel.frameSetCount, 0, "窗口列表真实变化时面板仍应调整尺寸；实际=\(panel.frame) 目标=\(model.panelWidth)x\(model.panelHeight)")
        XCTAssertEqual(panel.frame.width, model.panelWidth, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, model.panelHeight, accuracy: 0.5)
    }
}
