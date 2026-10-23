import AppKit
import SwiftUI
import XCTest
@testable import Switchly

/// 固定样本源码渲染，仅检查布局，不能替代真实桌面合成和交互验收。
final class AllSpacesRenderingTests: XCTestCase {
    @MainActor
    func testRenderDesktopScopeAndWindowStates() throws {
        guard let output = ProcessInfo.processInfo.environment["SWITCHLY_RENDER_OUTPUT"] else {
            throw XCTSkip("需显式提供源码渲染输出目录")
        }
        let suite = "com.switchly.tests.all-spaces-rendering"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SettingsService(defaults: defaults)
        let monitor = RenderingMonitor()
        monitor.windows = [
            WindowInfo(id: 4_100_001, ownerPID: -1, ownerName: "测试应用", windowTitle: "当前桌面的窗口",
                       bounds: CGRect(x: 0, y: 0, width: 640, height: 400), isOnCurrentSpace: true, windowNumber: 1),
            WindowInfo(id: 4_100_002, ownerPID: -1, ownerName: "测试应用", windowTitle: "其他桌面的长标题窗口 · 需求说明与设计文档",
                       bounds: CGRect(x: 0, y: 0, width: 640, height: 400), isOnCurrentSpace: false, windowNumber: 2, isOnOtherSpace: true),
            WindowInfo(id: 4_100_003, ownerPID: -1, ownerName: "测试应用", windowTitle: "最小化窗口",
                       bounds: CGRect(x: 0, y: 0, width: 640, height: 400), isOnCurrentSpace: true, windowNumber: 3, isMinimized: true)
        ]
        for theme in [AppTheme.light, .dark, .system] {
            for scope in PreviewSpaceScope.allCases {
                var settings = AppSettings.default
                settings.theme = theme
                settings.language = .simplifiedChinese
                settings.previewSpaceScope = scope
                settings.enableBackgroundBlur = false
                try service.saveSettings(settings)
                let model = PreviewViewModel(windowMonitorService: monitor, windowSwitchService: RenderingSwitcher(), settingsService: service)
                model.panelSize = CGSize(width: 800, height: 480)
                model.isPanelVisible = true
                model.refreshAllWindows()
                let host = NSHostingView(rootView: PreviewView(viewModel: model, settings: settings))
                host.frame = CGRect(origin: .zero, size: model.panelSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("source-\(theme.rawValue)-\(scope.rawValue).png"))
                window.contentView = nil
                window.close()
            }
        }
    }
}
