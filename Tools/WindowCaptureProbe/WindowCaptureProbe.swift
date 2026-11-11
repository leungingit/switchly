import AppKit
import SwiftUI

private final class ProbeLocale: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "zh-Hans"
    var language: String { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ language: String) { lock.lock(); value = language; lock.unlock() }
}

private final class ProbeMedia: MediaBridging {
    let queue = DispatchQueue(label: "capture-probe.media")
    func supports(bundleID: String) -> Bool { false }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { nil }
    func artwork(bundleID: String) throws -> Data? { nil }
    func perform(_ command: MediaCommand, bundleID: String) throws {}
}

private struct ProbeWindow: Identifiable {
    let window: WindowInfo
    let image: CGImage
    var id: CGWindowID { window.id }
}

private final class ProbeSourceView: NSView {
    let label: String
    let color: NSColor
    init(label: String, color: NSColor, frame: NSRect) {
        self.label = label; self.color = color; super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); bounds.fill()
        (label as NSString).draw(at: NSPoint(x: 24, y: bounds.midY), withAttributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.white
        ])
    }
}

@MainActor
private final class ProbeModel: ObservableObject {
    @Published var items: [ProbeWindow] = []
    @Published var visible = true
    @Published var settings = AppSettings.default
    @Published var error = ""
    var host: PluginHost!
    var coordinator: WindowCaptureCoordinator!
    var sources: [NSWindow] = []
    var output: URL!
    let processStartedAt = NSRunningApplication.current.launchDate ?? Date()
    let locale = ProbeLocale()

    func context(_ item: ProbeWindow) -> PluginRenderContext {
        PluginRenderContext(bundleID: "com.switchly.capture-probe", pid: getpid(), appName: "截图验证",
                            windowID: item.id, titleSummary: item.window.windowTitle,
                            captureTarget: WindowCaptureTarget(windowID: item.id, pid: getpid(),
                                                               processStartedAt: processStartedAt))
    }

    func showCards() { visible = true }
    func theme(_ theme: AppTheme) { settings.theme = theme; ThemeApplier.apply(theme) }
    func toggleLanguage() {
        settings.language = settings.language == .english ? .simplifiedChinese : .english
        locale.set(settings.language.rawValue)
        host.reload()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }
    func toggleGlass() {
        let enable = settings.crystalMaterial.glassStyle == .opaque
        settings.enableBackgroundBlur = enable
        settings.crystalMaterial.glassStyle = enable ? .frosted : .opaque
    }
}

private struct ProbeCards: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("窗口截图验证").font(.title2.bold())
            Text("只使用本工具创建的 A / B / C 样例窗口。每张卡片的按钮应操作对应窗口。")
            HStack(spacing: DesignTokens.Spacing.md) {
                ForEach(model.items) { item in
                    DockWindowPluginCard(window: item.window, isSelected: false, settings: model.settings,
                                         context: model.context(item), isPanelVisible: model.visible,
                                         appBottomBar: nil, host: model.host,
                                         thumbnail: NSImage(cgImage: item.image, size: NSSize(width: item.image.width, height: item.image.height)))
                }
            }
            .opacity(model.visible ? 1 : 0.35)
            .disabled(!model.visible)
            HStack {
                Button("恢复卡片入口") { model.showCards() }
                Button("浅色") { model.theme(.light) }
                Button("深色") { model.theme(.dark) }
                Button("跟随系统") { model.theme(.system) }
                Button(model.settings.language == .english ? "简体中文" : "English") { model.toggleLanguage() }
                Button(model.settings.crystalMaterial.glassStyle == .opaque ? "开启玻璃" : "关闭玻璃") { model.toggleGlass() }
            }
            if !model.error.isEmpty { Text(model.error).foregroundColor(.red) }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 940, height: 400)
    }
}

/// Native acceptance harness: uses production card/runtime/capture/editor code, own windows only.
@main
@MainActor
private final class CaptureProbe: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = CaptureProbe(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    private var model: ProbeModel!
    private var window: NSWindow!
    private var snapshotIndex = 0
    private var screenshotWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.delegate is WindowCapturePresenter }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), application = NSMenuItem(), commands = NSMenu()
        commands.addItem(withTitle: "保存当前窗口验证图", action: #selector(snapshot), keyEquivalent: "").target = self
        commands.addItem(withTitle: "缩到最小窗口", action: #selector(compactWindow), keyEquivalent: "").target = self
        commands.addItem(withTitle: "验证 SCK 原图", action: #selector(captureSCKFixture), keyEquivalent: "").target = self
        commands.addItem(withTitle: "退出验证工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = commands; menu.addItem(application); NSApp.mainMenu = menu
        model = ProbeModel(); model.settings.language = .simplifiedChinese
        model.settings.dockPreviewCardWidth = 280
        model.output = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.dropFirst().first ?? NSTemporaryDirectory())
        let package = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.dropFirst(2).first ?? "")
        guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json"))) else {
            fputs("用法：SwitchlyCaptureProbe <系统临时输出目录> <待验证插件包目录>\n", stderr); NSApp.terminate(nil); return
        }
        var requester: WindowCaptureRequesting?
        let locale = model.locale
        let host = PluginHost(registry: PluginRegistry(directory: package.deletingLastPathComponent()),
                              grants: { [manifest.id: PluginGrant(isEnabled: true, permissions: ["window.capture"])] },
                              mediaBridge: ProbeMedia(), makeRuntime: { package, permissions in
            PluginRuntime(package: package, timeout: 1, preferredLanguages: [locale.language],
                          permissions: permissions, captureRequester: requester)
        })
        model.host = host
        let documents = WindowCaptureDocumentService(root: model.output.appendingPathComponent("editing"))
        let presenter = WindowCapturePresenter(documents: documents, settings: { [weak model] in model?.settings ?? .default })
        let started = model.processStartedAt
        let raw = RawWindowCaptureService(screenAccess: { true }, processStart: { $0 == getpid() ? started : nil })
        let coordinator = WindowCaptureCoordinator(capturer: OwnWindowCapture(raw), presenter: presenter,
                                                   screenAccess: { true },
                                                   authorized: { [weak host] in host?.isCaptureAuthorized(pluginID: $0) == true },
                                                   dismissDock: { [weak model] in model?.visible = false })
        requester = coordinator; model.coordinator = coordinator
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen]
        for index in 0..<3 {
            let label = ["A", "B", "C"][index]
            let source = NSWindow(contentRect: NSRect(x: 80 + index * 360, y: 180, width: 320, height: 220),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            source.title = "截图样例 \(label)"
            source.contentView = ProbeSourceView(label: "窗口 \(label)", color: colors[index], frame: NSRect(x: 0, y: 0, width: 320, height: 220))
            source.isReleasedWhenClosed = false; source.orderFront(nil); model.sources.append(source)
        }
        window = NSWindow(contentRect: NSRect(x: 100, y: 520, width: 940, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Switchly 窗口截图验收"
        window.contentView = NSHostingView(rootView: ProbeCards(model: model))
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            for source in model.sources {
                do {
                    let image = try await raw.capture(target: .init(windowID: CGWindowID(source.windowNumber), pid: getpid(), processStartedAt: started))
                    let info = WindowInfo(id: CGWindowID(source.windowNumber), ownerPID: getpid(), ownerName: "CaptureProbe", windowTitle: source.title,
                                          bounds: source.frame, isOnCurrentSpace: true, windowNumber: source.windowNumber)
                    model.items.append(ProbeWindow(window: info, image: image))
                    try await documents.save(image: image, to: model.output.appendingPathComponent("source-\(model.items.count).png"))
                } catch { model.error = String(describing: error) }
            }
        }
    }

    @objc private func snapshot() {
        let current = screenshotWindow ?? window!
        guard current.isVisible, !current.isMiniaturized else { return }
        let number = CGWindowID(current.windowNumber)
        snapshotIndex += 1
        let url = model.output.appendingPathComponent("snapshot-\(getpid())-\(snapshotIndex).png")
        Task {
            do {
                let image = try await WindowImageCaptureBackend.shared.captureCG(windowID: number, timeout: 2)
                guard current.isVisible, !current.isMiniaturized, current.windowNumber == Int(number) else { return }
                try await WindowCaptureDocumentService().save(image: image, to: url)
                AppLogger.info("Capture probe snapshot saved. file=\(url.lastPathComponent) pixels=\(image.width)x\(image.height)")
            } catch { model.error = String(describing: error) }
        }
    }

    @objc private func compactWindow() {
        guard let current = screenshotWindow else { return }
        var frame = current.frame
        frame.size = current.minSize
        current.setFrame(frame, display: true)
    }

    @objc private func captureSCKFixture() {
        guard let source = model.sources.first else { return }
        let id = CGWindowID(source.windowNumber)
        Task {
            do {
                let image = try await WindowImageCaptureBackend.shared.captureSCK(windowID: id, pid: getpid(), pixelSize: nil, timeout: 3)
                try await WindowCaptureDocumentService().save(image: image, to: model.output.appendingPathComponent("source-sck.png"))
                AppLogger.info("Capture probe SCK succeeded. pixels=\(image.width)x\(image.height)")
            } catch { model.error = "SCK: \(error)" }
        }
    }
}

private struct OwnWindowCapture: RawWindowCapturing {
    let raw: RawWindowCapturing
    init(_ raw: RawWindowCapturing) { self.raw = raw }
    func capture(target: WindowCaptureTarget) async throws -> CGImage {
        guard target.pid == getpid() else { throw WindowCaptureFailure.permissionDenied }
        return try await raw.capture(target: target)
    }
}
