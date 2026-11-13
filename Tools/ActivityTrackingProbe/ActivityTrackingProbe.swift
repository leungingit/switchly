import AppKit
import SwiftUI

private final class ProbeMedia: MediaBridging {
    let queue = DispatchQueue(label: "activity.probe.media")
    func supports(bundleID: String) -> Bool { false }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { nil }
    func artwork(bundleID: String) throws -> Data? { nil }
    func perform(_ command: MediaCommand, bundleID: String) throws {}
}

@MainActor
private final class ProbeActivity: PluginActivityProviding, PluginActivityImageResolving {
    let references = ["A83A0194-847C-401B-BA39-66E2A623B821", "83FD3C7B-111A-41B0-87A6-C689C173A339"]
    let rows: [ActivitySession] = {
        let day = Calendar.current.startOfDay(for: Date())
        var rows = [ActivitySession(id: UUID(), bundleID: "com.example.editor", appName: "样例编辑器 · Sample Editor", start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(10 * 3600), seconds: 3600, endReason: .switched),
                ActivitySession(id: UUID(), bundleID: "com.example.reader", appName: "文档阅读器 · Research Library — Literature Review and Project Notes", start: day.addingTimeInterval(10 * 3600), end: day.addingTimeInterval(10.5 * 3600), seconds: 1800, endReason: .switched),
                ActivitySession(id: UUID(), bundleID: "com.example.editor", appName: "样例编辑器 · Sample Editor", start: day.addingTimeInterval(10.5 * 3600), end: day.addingTimeInterval(11 * 3600), seconds: 1800, endReason: .idle)]
        if ProcessInfo.processInfo.arguments.contains("--many-apps") {
            for index in 0..<5 {
                let start = day.addingTimeInterval(11 * 3600 + Double(index) * 300)
                rows.append(ActivitySession(id: UUID(), bundleID: "com.example.extra\(index)",
                    appName: "样例应用 \(index + 3) · Additional App", start: start,
                    end: start.addingTimeInterval(120), seconds: 120, endReason: .switched))
            }
        }
        return rows
    }()
    func query(method: String, options: [String: Any], pluginID: String, snapshotsAllowed: Bool) async throws -> [String: Any] {
        let from = Date(timeIntervalSince1970: options["from"] as? Double ?? 0), to = Date(timeIntervalSince1970: options["to"] as? Double ?? 0)
        switch method {
        case "summary": return ["items": ActivityQuery.summary(sessions: rows, from: from, to: to, groupBy: options["groupBy"] as? String ?? "app", timeZone: .current), "revision": 1, "recording": false, "screenshotsEnabled": true, "availableFrom": Date().addingTimeInterval(-400 * 86400).timeIntervalSince1970]
        case "sessions": return ["items": rows.filter { $0.start < to && $0.end > from }.map { ["id": $0.id.uuidString, "bundleID": $0.bundleID, "appName": $0.appName, "start": $0.start.timeIntervalSince1970, "end": $0.end.timeIntervalSince1970, "seconds": $0.seconds, "endReason": $0.endReason.rawValue] as [String: Any] }, "nextCursor": NSNull(), "revision": 1]
        case "snapshots":
            let items = references.enumerated().compactMap { offset, reference -> [String: Any]? in
                let session = rows[offset == 0 ? 0 : 2]
                let captured = session.start.addingTimeInterval(120)
                guard captured >= from, captured < to else { return nil }
                return ["ref": reference, "bundleID": session.bundleID, "sessionID": session.id.uuidString,
                        "capturedAt": captured.timeIntervalSince1970]
            }
            return ["items": items, "nextCursor": NSNull(), "revision": 1]
        default: return ["items": [], "nextCursor": NSNull(), "revision": 1]
        }
    }
    func image(reference: String, pluginID: String) async -> NSImage? {
        guard let index = references.firstIndex(of: reference) else { return nil }
        let image = NSImage(size: NSSize(width: 320, height: 180))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        ("样例截图 \(index + 1)\nSample snapshot" as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.labelColor])
        image.unlockFocus(); return image
    }
}

@MainActor
private final class ProbeApp: NSObject, NSApplicationDelegate {
    var host: PluginHost!
    var coordinator: PluginPanelCoordinator!
    let activity = ProbeActivity()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--plugins"), args.count > index + 1 else { NSApp.terminate(nil); return }
        let source = URL(fileURLWithPath: args[index + 1])
        let language = args.contains("--english") ? "en" : "zh-Hans"
        ThemeApplier.apply(args.contains("--system") ? .system : (args.contains("--dark") ? .dark : .light))
        let menu = NSMenu()
        let application = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出验证", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu; menu.addItem(application); NSApp.mainMenu = menu
        host = PluginHost(registry: PluginRegistry(directory: source, origin: .builtin), grants: {
            if args.contains("--ungranted") { return [:] }
            return ["com.switchly.activity-timeline": PluginGrant(isEnabled: true, permissions: ["activity.read", "activity.snapshots"])]
        }, mediaBridge: ProbeMedia(), makeRuntime: { [activity] package, _ in
            PluginRuntime(package: package, timeout: 2, preferredLanguages: [language], permissions: [.activityRead, .activitySnapshots], activityProvider: activity)
        })
        var settings = AppSettings.default
        settings.language = args.contains("--english") ? .english : .simplifiedChinese
        settings.enableBackgroundBlur = !args.contains("--opaque")
        if args.contains("--opaque") { settings.crystalMaterial.glassStyle = .opaque }
        settings.theme = args.contains("--system") ? .system : (args.contains("--dark") ? .dark : .light)
        coordinator = PluginPanelCoordinator(host: host, activityImages: activity, settings: { settings })
        if let index = args.firstIndex(of: "--render-panel") ?? args.firstIndex(of: "--render-timeline"), args.count > index + 1 {
            let model = PluginPanelModel(pluginID: "com.switchly.activity-timeline", host: host)
            model.start()
            Task {
                for _ in 0..<100 where model.isLoading { try? await Task.sleep(nanoseconds: 50_000_000) }
                guard !model.entries.isEmpty || !model.pendingPermissions.isEmpty else { print("render failed"); NSApp.terminate(nil); return }
                let width: CGFloat = args.contains("--compact") ? 400 : 760
                if args[index] == "--render-timeline" {
                    guard let node = model.entries.compactMap({ self.timeline(in: $0.node) }).first else {
                        print("timeline unavailable"); NSApp.terminate(nil); return
                    }
                    self.render(PluginOverlayView(node: node, material: settings.crystalMaterial,
                                                  isGlassActive: settings.enableBackgroundBlur,
                                                  activityImages: self.activity, onAction: { _, _ in })
                        .padding(DesignTokens.Spacing.xl)
                        .environment(\.locale, Locale(identifier: language))
                        .preferredColorScheme(settings.theme.colorScheme), to: args[index + 1], width: width)
                } else {
                    self.render(PluginPanelView(model: model, activityImages: self.activity, settings: settings),
                                to: args[index + 1], width: width)
                }
            }
            return
        }
        if let index = args.firstIndex(of: "--render-consent"), args.count > index + 1 {
            let intent: ActivityConsentState.Intent = args.contains("--recording-consent") ? .recording
                : (args.contains("--screenshots-consent") ? .screenshots : .clear)
            render(ActivityConsentView(intent: intent, language: settings.language,
                                       clearText: .constant(""), canClear: false,
                                       onCancel: {}, onConfirm: {})
                .preferredColorScheme(settings.theme.colorScheme),
                   to: args[index + 1], width: DesignTokens.Plugin.confirmationWidth, height: 300)
            return
        }
        if let index = args.firstIndex(of: "--render-settings"), args.count > index + 1 {
            render(ProbeSettings(language: settings.language, enabled: args.contains("--screenshots-settings")), to: args[index + 1])
            return
        }
        if args.contains("--settings") {
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 820), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "活动设置 · 合成验证"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProbeSettings(language: settings.language))
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return
        }
        coordinator.show(pluginID: "com.switchly.activity-timeline", title: "活动时间线 · 合成夹具验证")
    }
    private func timeline(in node: PluginUINode) -> PluginUINode? {
        if case .timeline = node { return node }
        return node.children.compactMap { timeline(in: $0) }.first
    }

    private func render<Content: View>(_ content: Content, to path: String, width: CGFloat = 760, height: CGFloat = 820) {
        let host = NSHostingView(rootView: content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("bitmap unavailable"); NSApp.terminate(nil); return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { print("PNG unavailable"); NSApp.terminate(nil); return }
            do { try data.write(to: URL(fileURLWithPath: path)); print("原生隐藏视图渲染成功：\(Int(width))×\(Int(height))pt，PNG字节=\(data.count)，active=\(NSApp.isActive)") }
            catch { print("PNG write failed") }
            panel.close(); NSApp.terminate(nil)
        }
    }

}

private struct ProbeSettings: View {
    let language: AppLanguage
    @State private var settings: ActivityTrackingSettings
    init(language: AppLanguage, enabled: Bool = false) {
        self.language = language
        var settings = ActivityTrackingSettings(); settings.enabled = enabled; settings.screenshotsEnabled = enabled
        _settings = State(initialValue: settings)
    }
    var body: some View {
        ScrollView {
            ActivityTrackingPreferencesSection(settings: $settings, language: language, tracking: nil)
                .padding(DesignTokens.Spacing.xl)
        }
    }
}

@main
struct ActivityTrackingProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ProbeApp(); app.delegate = delegate; app.run(); withExtendedLifetime(delegate) {}
    }
}
