import AppKit
import SwiftUI
import XCTest
@testable import Switchly

/// Opt-in desktop compositing evidence; unit tests do not normally show windows.
/// Run xcodebuild with TEST_RUNNER_SWITCHLY_CAPTURE_GLASS=1 to save synthetic-background captures in /tmp.
final class GlassRenderingTests: XCTestCase {
    @MainActor
    func testDesktopCompositing() throws {
        guard ProcessInfo.processInfo.environment["SWITCHLY_CAPTURE_GLASS"] == "1" else {
            throw XCTSkip("Opt-in desktop visual review")
        }
        let suite = "com.switchly.tests.glass-rendering"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SettingsService(defaults: defaults)
        let backdrop = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.contentView = NSHostingView(rootView:
            HStack(spacing: 0) {
                ForEach(0..<12) { index in
                    [Color.blue, .cyan, .orange, .pink][index % 4].opacity(0.4)
                }
            })
        backdrop.level = .floating
        backdrop.orderFront(nil)
        defer { backdrop.orderOut(nil); backdrop.contentView = nil }

        for theme in [AppTheme.light, .dark] {
            for style in [GlassStyle.transparent, .frosted, .opaque] {
                var settings = AppSettings.default
                settings.theme = theme
                settings.previewInfoShowsProcessID = true
                settings.language = .simplifiedChinese
                settings.crystalMaterial.glassStyle = style
                settings.crystalMaterial.sharedDensity = 0.2
                settings.crystalMaterial.panelTintCap = 0
                try service.saveSettings(settings)
                let model = PreferencesViewModel(settingsService: service)
                let host = NSHostingView(rootView: PreferencesView(initialTab: .appearance, viewModel: model))
                let window = NSWindow(contentRect: NSRect(x: 180, y: 170, width: 760, height: 560),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.level = .floating
                window.isOpaque = false
                window.backgroundColor = .clear
                window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let screen = try XCTUnwrap(NSScreen.screens.first)
                let region = "180,\(Int(screen.frame.maxY - 730)),760,560"
                let output = "/tmp/switchly-glass-\(theme.rawValue)-\(style.rawValue).png"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-R", region, output]
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                let attachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: output))
                attachment.lifetime = .keepAlways
                add(attachment)
                window.orderOut(nil)
                window.contentView = nil

                let monitor = RenderingMonitor()
                let switcher = RenderingSwitcher()
                let preview = PreviewViewModel(windowMonitorService: monitor, windowSwitchService: switcher,
                                               thumbnailService: RenderingThumbnails(), settingsService: service)
                preview.panelSize = CGSize(width: 640, height: 400)
                preview.isPanelVisible = true
                preview.refreshWindows()
                let dock = DockPreviewViewModel(windowMonitorService: monitor, windowSwitchService: switcher,
                                                settingsService: service)
                dock.showPanel(forApp: "Finder", bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
                dock.windows = monitor.windows
                dock.appName = "Sample app"
                dock.isPanelVisible = true
                let samples: [(String, AnyView, CGSize)] = [
                    ("preview", AnyView(PreviewView(viewModel: preview, settings: settings)), CGSize(width: 640, height: 400)),
                    ("dock", AnyView(DockPreviewView(viewModel: dock, settings: settings)), CGSize(width: dock.panelWidth, height: dock.panelHeight))
                ]
                for (name, sample, size) in samples {
                    let height = size.height
                    let panel = NSPanel(contentRect: NSRect(x: 180, y: 170, width: size.width, height: height),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.level = .floating
                    panel.hidesOnDeactivate = false
                    panel.isOpaque = false
                    panel.backgroundColor = .clear
                    panel.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                    panel.contentView = NSHostingView(rootView: sample)
                    panel.makeKeyAndOrderFront(nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    if name == "dock" { XCTAssertEqual(dock.windows.count, 2) }
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    let filename = "/tmp/switchly-glass-\(name)-\(theme.rawValue)-\(style.rawValue).png"
                    capture.arguments = ["-x", "-R", "180,\(Int(screen.frame.maxY - 170 - height)),\(Int(size.width)),\(Int(height))", filename]
                    try capture.run()
                    capture.waitUntilExit()
                    XCTAssertEqual(capture.terminationStatus, 0)
                    panel.orderOut(nil)
                    panel.contentView = nil
                }
            }
        }
    }
}

private final class RenderingMonitor: WindowMonitorServiceProtocol {
    var windows: [WindowInfo] = [
        WindowInfo(id: 4_000_001, ownerPID: -1, ownerName: "Sample app", windowTitle: "Window A", bounds: CGRect(x: 0, y: 0, width: 400, height: 240), isOnCurrentSpace: true, windowNumber: 1),
        WindowInfo(id: 4_000_002, ownerPID: -1, ownerName: "Sample app", windowTitle: "Window B", bounds: CGRect(x: 0, y: 0, width: 400, height: 240), isOnCurrentSpace: true, windowNumber: 2)
    ]
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

private final class RenderingSwitcher: WindowSwitchServiceProtocol {
    func switchToWindow(_ window: WindowInfo) async throws {}
    func switchToApplication(pid: pid_t) async throws {}
}

private final class RenderingThumbnails: ThumbnailServiceProtocol {
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
