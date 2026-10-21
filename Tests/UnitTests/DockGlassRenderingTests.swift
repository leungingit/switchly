import AppKit
import SwiftUI
import XCTest
@testable import Switchly

/// Opt-in desktop evidence for material switches on the production Dock panel.
final class DockGlassRenderingTests: XCTestCase {
    /// Same position and backdrop for fresh glass, a live style switch, and
    /// the production nonactivating Dock panel, including its clipping layer.
    @MainActor
    func testDockStyleSwitchOnDesktop() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires native glass") }
        guard ProcessInfo.processInfo.environment["SWITCHLY_CAPTURE_GLASS"] == "1" else {
            throw XCTSkip("Opt-in desktop visual review")
        }
        let suite = "com.switchly.tests.dock-style-rendering"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SettingsService(defaults: defaults)
        let frame = NSRect(x: 160, y: 170, width: 760, height: 592)
        let backdrop = NSWindow(contentRect: frame.insetBy(dx: -20, dy: -20),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            ForEach(0..<20) { row in
                HStack(spacing: 0) {
                    ForEach(0..<20) { column in
                        ZStack {
                            (column % 2 == 0 ? Color.blue : Color.orange).opacity(0.4)
                            Text("\(row)-\(column)").font(.system(size: 12)).foregroundColor(.black)
                        }
                    }
                }
            }
        })
        backdrop.orderFront(nil)
        defer { backdrop.orderOut(nil); backdrop.contentView = nil }
        let directory = "/tmp/switchly-dock-style"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for theme in [AppTheme.light, .dark] {
            for source in ["dock", "dock-compact", "preferences", "native"] {
                let compact = source == "dock-compact"
                let sampleFrame = compact ? NSRect(x: 160, y: 170, width: 386, height: 317) : frame
                var settings = AppSettings.default
                settings.theme = theme
                settings.language = .simplifiedChinese
                settings.dockPreviewCardWidth = 350
                settings.removeGlassOverlays()
                settings.crystalMaterial.cardOpacity = 0.3
                settings.crystalMaterial.tintColor = Color(red: 0.726, green: 0.916, blue: 1)
                settings.crystalMaterial.panelTintCap = 1
                settings.crystalMaterial.glassStyle = .frosted
                try service.saveSettings(settings)
                let dock = DockPreviewViewModel(windowMonitorService: RenderingMonitor(),
                                                windowSwitchService: RenderingSwitcher(), settingsService: service)
                dock.panelWidth = sampleFrame.width
                dock.panelHeight = sampleFrame.height
                if compact { dock.windows = Array(RenderingMonitor().windows.prefix(1)) }
                dock.appName = "" // Keep unrelated global window-list refreshes out of this fixture.
                dock.isPanelVisible = true
                let panel: NSWindow
                if source.hasPrefix("dock") {
                    panel = DockPreviewPanel(viewModel: dock)
                } else {
                    panel = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView],
                                     backing: .buffered, defer: false)
                    panel.titlebarAppearsTransparent = true
                    panel.titleVisibility = .hidden
                    panel.titlebarSeparatorStyle = .none
                }
                panel.level = .floating
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                func installContent() {
                    if source == "preferences" {
                        panel.contentView = NSHostingView(rootView: PreferencesView(initialTab: .appearance,
                            viewModel: PreferencesViewModel(settingsService: service)))
                    } else if source == "native" {
                        panel.contentView = NSHostingView(rootView: NativeCrystalContainer(
                            content: Color.clear.frame(width: 760, height: 560), density: 0,
                            material: settings.crystalMaterial, cornerRadius: 28))
                    }
                }
                installContent()
                for (index, style) in [GlassStyle.frosted, .transparent, .frosted, .transparent].enumerated() {
                    panel.orderOut(nil)
                    settings.crystalMaterial.glassStyle = style
                    try service.saveSettings(settings)
                    if source == "native" { installContent() }
                    // Keep geometry identical: the model also recomputes card
                    // dimensions when settings change, as it does in production.
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    dock.panelWidth = sampleFrame.width
                    dock.panelHeight = sampleFrame.height
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    panel.setFrame(sampleFrame, display: true)
                    panel.orderFront(nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    XCTAssertEqual(panel.frame, sampleFrame, "Do not compare a relocated Dock panel with another surface")
                    let screen = try XCTUnwrap(panel.screen)
                    let path = "\(directory)/\(source)-\(theme.rawValue)-\(index)-\(style.rawValue).png"
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-R", "160,\(Int(screen.frame.maxY - sampleFrame.maxY)),\(Int(sampleFrame.width)),\(Int(sampleFrame.height))", path]
                    try capture.run()
                    capture.waitUntilExit()
                    XCTAssertEqual(capture.terminationStatus, 0)
                    if capture.terminationStatus == 0 {
                        let attachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: path))
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }
    }

}
