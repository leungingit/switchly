import AppKit
import ApplicationServices
import XCTest
@testable import Switchly

/// 受控实机枚举与可选的真实卡片点击验证；需先将两个窗口分置不同桌面。
final class AllSpacesIntegrationTests: XCTestCase {
    @MainActor
    func testDockPanelShowsAllSpacesAndAcceptsRealClick() async throws {
        guard ProcessInfo.processInfo.environment["SWITCHLY_TEST_DOCK_CLICK"] == "1" else {
            throw XCTSkip("需显式开启 Dock 面板实机点击验收")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("测试宿主没有辅助功能权限") }
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.switchly.spacesfixture").first)
        let monitor = WindowMonitorService.shared
        let discoveryDeadline = Date().addingTimeInterval(15)
        var windows = monitor.getAllWindows()
        while monitor.isEnumeratingWindows && Date() < discoveryDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            windows = monitor.getAllWindows()
        }
        let target = try XCTUnwrap(windows.first { $0.ownerPID == app.processIdentifier && $0.isOnOtherSpace })
        let model = DockPreviewViewModel()
        DockHoverMonitor.shared.stop()
        let panel = DockPreviewPanel.shared
        defer { panel.hide(); model.hidePanel(); DockHoverMonitor.shared.start() }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.show(forApp: app.localizedName ?? "SwitchlySpacesFixture",
                   aboveIconFrame: CGRect(x: screen.frame.midX, y: screen.visibleFrame.minY, width: 48, height: 48),
                   bundleURL: app.bundleURL)
        model.showPanel(forApp: app.localizedName ?? "SwitchlySpacesFixture", bundleURL: app.bundleURL)
        XCTAssertEqual(model.windows.filter { $0.ownerPID == app.processIdentifier }.count, 2)
        XCTAssertTrue(model.windows.contains { $0.id == target.id })
        // 由验收人员或桌面自动化点击真实卡片；不直接调用切窗服务替代交互。
        let clickDeadline = Date().addingTimeInterval(90)
        let presentationDeadline = Date().addingTimeInterval(5)
        while !panel.isVisible && Date() < presentationDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(panel.isVisible, "Dock 面板未显示")
        while panel.isVisible && Date() < clickDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(panel.isVisible, "等待真实卡片点击超时")
        let focusDeadline = Date().addingTimeInterval(8)
        while !AccessibilityService.shared.isFrontmostOnScreen(target) && Date() < focusDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(AccessibilityService.shared.isFrontmostOnScreen(target))
        XCTAssertEqual(AccessibilityService.shared.focusedWindowID(for: app.processIdentifier), target.id)
        let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        XCTAssertTrue(visible.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.id })
    }

    @MainActor
    func testFindsControlledWindowsAcrossSpaces() async throws {
        guard ProcessInfo.processInfo.environment["SWITCHLY_TEST_ALL_SPACES"] == "1" else {
            throw XCTSkip("需显式开启受控跨桌面实机验证")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("测试宿主没有辅助功能权限") }
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.switchly.spacesfixture").first)
        let service = WindowMonitorService.shared
        let deadline = Date().addingTimeInterval(15)
        var windows = service.getAllWindows()
        while service.isEnumeratingWindows && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            windows = service.getAllWindows()
        }
        XCTAssertFalse(service.isEnumeratingWindows, "枚举未在期限内完成")
        let fixtures = windows.filter { $0.ownerPID == app.processIdentifier }
        XCTAssertEqual(fixtures.count, 2, "两个受控窗口都必须被发现，不能混入辅助 surface")
        XCTAssertEqual(Set(fixtures.map(\.id)).count, 2)
        XCTAssertTrue(fixtures.contains { $0.isOnCurrentSpace })
        XCTAssertTrue(fixtures.contains { $0.isOnOtherSpace && !$0.isMinimized })
    }
}
