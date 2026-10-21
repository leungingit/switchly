import AppKit
import SwiftUI
import XCTest
@testable import Switchly

/// Opt-in desktop compositing evidence; unit tests do not normally show windows.
/// Run xcodebuild with TEST_RUNNER_SWITCHLY_CAPTURE_GLASS=1 to save synthetic-background captures in /tmp.
final class GlassRenderingTests: XCTestCase {
    /// Capture actual native compositing at both control limits, with every
    /// other layer held constant. The matte intentionally leaves image margins.
    @MainActor
    func testControlEndpointsOnDesktop() throws {
        guard ProcessInfo.processInfo.environment["SWITCHLY_CAPTURE_GLASS"] == "1" else {
            throw XCTSkip("Opt-in desktop visual review")
        }
        try FileManager.default.createDirectory(atPath: "/tmp/switchly-control-limits", withIntermediateDirectories: true)
        let frame = NSRect(x: 100, y: 100, width: 940, height: 640)
        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.contentView = NSHostingView(rootView: Color.blue.opacity(0.35).background(Color.white))
        backdrop.orderFront(nil)
        defer { backdrop.orderOut(nil); backdrop.contentView = nil }
        for theme in [AppTheme.light, .dark] {
            for style in [GlassStyle.frosted, .transparent] {
                let board = VStack(spacing: 8) {
                    Text("\(theme.rawValue) / \(style.rawValue) — lower limit / upper limit")
                        .font(.headline)
                    ForEach(EndpointControl.allCases, id: \.self) { control in
                        HStack(spacing: 16) {
                            Text(control.rawValue).frame(width: 140, alignment: .leading)
                            if style == .transparent && (control == .sheen || control == .rim) {
                                Text("Frosted glass only — controls hidden in Preferences")
                                    .frame(maxWidth: .infinity)
                            } else {
                                self.endpointSample(control, maximum: false, style: style)
                                self.endpointSample(control, maximum: true, style: style)
                            }
                        }.frame(height: 82)
                    }
                }
                .padding(16)
                .preferredColorScheme(theme.colorScheme)
                let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.level = .floating
                window.isOpaque = false
                window.backgroundColor = .clear
                window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                window.contentView = NSHostingView(rootView: board)
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let screen = try XCTUnwrap(NSScreen.screens.first)
                let path = "/tmp/switchly-control-limits/endpoints-\(theme.rawValue)-\(style.rawValue).png"
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-R", "100,\(Int(screen.frame.maxY - frame.maxY)),940,640", path]
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0)
                let attachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: path))
                attachment.lifetime = .keepAlways
                add(attachment)
                window.orderOut(nil)
                window.contentView = nil
            }
        }
    }

    /// Include the actual AppKit titlebar (not just the requested content rect).
    /// Check both unmodified system glass and strongly customized glass.
    @MainActor
    func testPreferencesTitlebarOnDesktop() throws {
        guard ProcessInfo.processInfo.environment["SWITCHLY_CAPTURE_GLASS"] == "1" else {
            throw XCTSkip("Opt-in desktop visual review")
        }
        let suite = "com.switchly.tests.titlebar-rendering"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SettingsService(defaults: defaults)
        let backdrop = NSWindow(contentRect: NSRect(x: 100, y: 80, width: 1000, height: 800),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.contentView = NSHostingView(rootView: HStack(spacing: 0) {
            ForEach(0..<12) { index in
                [Color.blue, .cyan, .orange, .pink][index % 4].opacity(0.4)
            }
        })
        backdrop.orderFront(nil)
        defer { backdrop.orderOut(nil); backdrop.contentView = nil }
        for theme in [AppTheme.light, .dark] {
            for style in [GlassStyle.transparent, .frosted] {
                for customized in [false, true] {
                    var settings = AppSettings.default
                    settings.theme = theme
                    settings.language = .simplifiedChinese
                    settings.crystalMaterial.glassStyle = style
                    if customized {
                        settings.crystalMaterial.sharedDensity = 0.8
                        settings.crystalMaterial.panelTintCap = 0.8
                        settings.crystalMaterial.topSheenOpacity = 0.4
                        settings.crystalMaterial.rimTopOpacity = 0.8
                    } else {
                        settings.removeGlassOverlays()
                    }
                    try service.saveSettings(settings)
                    let model = PreferencesViewModel(settingsService: service)
                    let window = NSWindow(contentRect: NSRect(x: 180, y: 170, width: 760, height: 560),
                                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
                    window.titlebarAppearsTransparent = true
                    window.titlebarSeparatorStyle = .none
                    window.titleVisibility = .hidden
                    window.level = .floating
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                    window.contentView = NSHostingView(rootView: PreferencesView(initialTab: .appearance, viewModel: model))
                    window.makeKeyAndOrderFront(nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    let frame = window.frame
                    let screen = try XCTUnwrap(window.screen)
                    let mode = customized ? "custom" : "system"
                    let path = "/tmp/switchly-titlebar/\(theme.rawValue)-\(style.rawValue)-\(mode).png"
                    try FileManager.default.createDirectory(atPath: "/tmp/switchly-titlebar", withIntermediateDirectories: true)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-R", "\(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))", path]
                    try process.run()
                    process.waitUntilExit()
                    XCTAssertEqual(process.terminationStatus, 0)
                    let attachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: path))
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    window.orderOut(nil)
                    window.contentView = nil
                }
            }
        }
    }

    private enum EndpointControl: String, CaseIterable {
        case density = "Density 0–100%"
        case tint = "Tint 0–100%"
        case card = "Card fill 0–80%"
        case sheen = "Sheen 0–60%"
        case rim = "Rim 0–100%"
        case matte = "Matte 0–60%"
    }

    private func endpointSample(_ control: EndpointControl, maximum: Bool, style: GlassStyle) -> some View {
        var material = CrystalMaterial.legacyDefault
        material.glassStyle = style
        material.cardOpacity = control == .card && maximum ? CrystalMaterial.Range.card.upperBound : 0
        material.topSheenOpacity = control == .sheen && maximum ? CrystalMaterial.Range.sheen.upperBound : 0
        material.rimTopOpacity = control == .rim && maximum ? CrystalMaterial.Range.rim.upperBound : 0
        material.panelTintCap = control == .tint && maximum ? CrystalMaterial.Range.panelTint.upperBound : 0
        let density = control == .density ? (maximum ? 1.0 : 0) : 0.0
        let matte = ThumbnailBackdrop(tintColor: .black, opacity: control == .matte && maximum ? ThumbnailBackdrop.Range.opacity.upperBound : 0)
        return HStack {
            Image(systemName: "photo")
                .frame(width: 48, height: 28)
                .background(Color(nsColor: .windowBackgroundColor))
                .padding(8)
                .background(matte.resolvedColor())
            Text(maximum ? "Upper limit" : "Lower limit")
            Spacer()
        }
        .padding(10)
        .cardSurface(fill: Color.crystalSurfaceBase.opacity(material.cardOpacity), material: material)
        .crystalSpecularRim(material: material)
        .padding(8)
        .panelGlass(isActive: true, opacity: density, cornerRadius: DesignTokens.Radius.card, material: material)
    }

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
