import AppKit
import ApplicationServices
import SceneKit
import SwiftUI

enum PluginPreviewSurfaceError: Error {
    case unavailable, isolationLost, invalidImage, processFailed
}

/// 截图与坐标输入共用的活视图；不复制 Entry，以免动作后仍显示旧树。
private struct PluginPreviewCaptureView: View {
    @ObservedObject var state: PluginPreviewState

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(state.capturedSlots, id: \.self) { slot in
                PluginSlotSurface(entries: state.slots[slot] ?? [],
                                  material: state.environment.material,
                                  isGlassActive: state.environment.glassEnabled, artwork: state.artwork,
                                  fallback: nil, onAction: state.perform)
            }
        }
            .environment(\.pluginSceneNow, state.virtualNowSeconds.map { now in { now } })
            .frame(width: state.environment.contentWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(state.environment.theme.colorScheme)
            .environment(\.locale, Locale(identifier: state.environment.language.rawValue))
    }
}

/// PV-D13：必须保留原生呈现表面，但从不 order；alpha=0／完全离屏均可能返回空图。
private final class PluginPreviewHiddenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class PluginPreviewCaptureSurface {
    let window: NSWindow
    let screen: NSScreen
    private let background: Bool
    private let host: NSHostingView<PluginPreviewCaptureView>
    private var child: Process?
    private var closed = false

    init(state: PluginPreviewState, screen: NSScreen, background: Bool) throws {
        self.screen = screen
        self.background = background
        host = NSHostingView(rootView: PluginPreviewCaptureView(state: state))
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, size.width <= screen.visibleFrame.width,
              size.height <= screen.visibleFrame.height else { throw PluginPreviewSurfaceError.unavailable }
        let frame = NSRect(origin: NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY), size: size)
        if background {
            let panel = PluginPreviewHiddenPanel(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.animationBehavior = .none
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window = panel
        } else {
            window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        }
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.alphaValue = 1
        window.appearance = NSAppearance(named: state.environment.theme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        if !background { window.makeKeyAndOrderFront(nil) }
        try requireIsolation()
    }

    func requireIsolation() throws {
        guard !closed else { throw PluginPreviewSurfaceError.unavailable }
        guard background else { return }
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            throw PluginPreviewSurfaceError.unavailable
        }
        let onScreen = windows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }
        guard !window.isVisible, !window.isKeyWindow, !window.isMainWindow, !NSApp.isActive, !onScreen else {
            throw PluginPreviewSurfaceError.isolationLost
        }
    }

    /// 让 SwiftUI 的更新跨过一次 RunLoop，布局仍在主线程，不冻结相机或替换 SCNView。
    func layout() async throws {
        try requireIsolation()
        try await Task.sleep(nanoseconds: 50_000_000)
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, size.width <= screen.visibleFrame.width,
              size.height <= screen.visibleFrame.height else { throw PluginPreviewSurfaceError.unavailable }
        // setContentSize 保留顶边，内容变高时可能把底边推到屏幕外；固定屏幕内原点。
        window.setFrame(NSRect(origin: screen.visibleFrame.origin, size: size), display: false)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        SCNTransaction.flush()
        try requireIsolation()
    }

    func prepareAccessibility() async throws {
        try requireIsolation()
        guard let executable = Bundle.main.executableURL else { throw PluginPreviewSurfaceError.unavailable }
        try await run(executable: executable, arguments: ["--prepare-preview-accessibility", String(getpid())])
        try requireIsolation()
    }

    func capture(to url: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw PluginPreviewSurfaceError.unavailable }
        try await layout()
        try await run(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                      arguments: ["-x", "-o", "-l", String(window.windowNumber), url.path])
        try requireIsolation()
        try await Task.detached { try Self.validateImage(at: url) }.value
    }

    /// 命令成功但全透明的反例已实测；同时拒绝空背景，不能把不可用环境误报为通过。
    nonisolated static func validateImage(at url: URL) throws {
        guard let data = try? Data(contentsOf: url), let image = NSBitmapImageRep(data: data),
              image.pixelsWide > 0, image.pixelsHigh > 0 else {
            throw PluginPreviewSurfaceError.invalidImage
        }
        var first: [Int]?
        var varied = false
        var visible = false
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    throw PluginPreviewSurfaceError.invalidImage
                }
                if color.alphaComponent > 0 {
                    visible = true
                    let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
                    if let first { varied = varied || rgb != first } else { first = rgb }
                }
                if visible && varied { return }
            }
        }
        throw PluginPreviewSurfaceError.invalidImage
    }

    /// 有界子进程，等待不阻塞主 RunLoop；取消、超时和关闭均回收，绝不启动全局输入进程。
    private func run(executable: URL, arguments: [String]) async throws {
        guard child == nil else { throw PluginPreviewSurfaceError.processFailed }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw PluginPreviewSurfaceError.processFailed }
        child = process
        defer { child = nil }
        do {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw PluginPreviewSurfaceError.processFailed }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard process.terminationStatus == 0 else { throw PluginPreviewSurfaceError.processFailed }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            await Task.detached { process.waitUntilExit() }.value
            throw error
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// 仅为直接父进程启用 SwiftUI AX 树；不读标签、不写焦点、不对其他应用执行任何操作。
enum PluginPreviewAccessibilityPreparation {
    static func run(arguments: [String]) -> Int32? {
        guard arguments.first == "--prepare-preview-accessibility" else { return nil }
        guard arguments.count == 2, let pid = Int32(arguments[1]), pid == getppid() else { return 2 }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return 4 }
        for window in value as? [AXUIElement] ?? [] {
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
        }
        return 0
    }
}
