import AppKit
import SwiftUI
import ScreenCaptureKit
import SceneKit
import Combine
import XCTest
@testable import Switchly

/// 显式开启的本机验收入口。普通测试不读取真实媒体、不启动 Adapter、不展示窗口。
@MainActor
final class MediaRemoteLiveIntegrationTests: XCTestCase {
    func testInjectedBridgeInRealDockPanel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SWITCHLY_MEDIAREMOTE_LIVE_DIRECTORY"],
              let plugins = environment["SWITCHLY_MEDIAREMOTE_LIVE_PLUGINS"] else {
            throw XCTSkip("需显式指定真实媒体验收目录与本地插件制品")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: MediaRemoteState.bundleID).first)
        let adapter = environment["SWITCHLY_MEDIAREMOTE_LIVE_ADAPTER"].map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("adapter")
        let configuration = MediaRemoteLaunchConfiguration(directory: adapter)
        let script = MusicAppleScriptBridge()
        let identity: () -> MediaRemoteProcessIdentity? = {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: MediaRemoteState.bundleID).first,
                  let launched = app.launchDate else { return nil }
            return MediaRemoteProcessIdentity(pid: app.processIdentifier, launchDate: launched)
        }
        let session = MediaRemoteSession(stream: MediaRemoteStream {
            FoundationMediaRemoteChildProcess(configuration: configuration)
        }, identity: identity)
        let bridge = CompositeMediaBridge(script: script, session: session, identity: identity)
        let pluginID = "com.switchly.music-controls"
        let mode = LiveMediaMode()
        mode.setThreeD(environment["SWITCHLY_MEDIAREMOTE_LIVE_3D"] == "1")
        let host = PluginHost(registry: LiveMusicRegistry(directory: URL(fileURLWithPath: plugins)),
                              grants: { [pluginID: PluginGrant(isEnabled: true, permissions: ["media.nowPlaying", "media.control"])] },
                              mediaBridge: bridge, weather: { nil }, makeRuntime: { package, permissions in
            PluginRuntime(package: package, timeout: 2, mediaBridge: bridge, permissions: permissions,
                          libraryBridge: bridge, settings: { mode.settings }, weather: { nil })
        })
        let suite = "com.switchly.tests.mediaremote-live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settingsService = SettingsService(defaults: defaults)
        var settings = AppSettings.default
        settings.onlineWeather.enabled = false
        settings.pluginSettings[pluginID] = ["hidePreviews": true]
        settings.theme = .light
        try settingsService.saveSettings(settings)
        let overlay = DockPluginOverlayModel(host: host)
        let model = DockPreviewViewModel(settingsService: settingsService, pluginOverlay: overlay)
        let panel = DockPreviewPanel(viewModel: model)
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)
        let performance = environment["SWITCHLY_MEDIAREMOTE_LIVE_PERFORMANCE"] == "1"
        let probe = LivePanelPerformance(directory: directory)
        if performance { try await probe.start(screen: screen, panel: panel, overlay: overlay) }
        defer {
            probe.stop()
            panel.hide()
            model.hidePanel()
            host.unmountAll()
            defaults.removePersistentDomain(forName: suite)
        }
        if environment["SWITCHLY_MEDIAREMOTE_LIVE_WAIT"] == "1" {
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier])
                .write(to: directory.appendingPathComponent("ready.json"))
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if let data = try? Data(contentsOf: directory.appendingPathComponent("live-command.json")),
                   let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any], command["begin"] as? Bool == true { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        if performance { probe.begin(panel: panel) }
        panel.show(forApp: app.localizedName ?? "Music", aboveIconFrame: CGRect(x: screen.visibleFrame.midX,
                   y: screen.visibleFrame.minY + 30, width: 48, height: 48), bundleURL: app.bundleURL)
        let events = directory.appendingPathComponent("live-samples.jsonl")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        let output = try FileHandle(forWritingTo: events)
        defer { try? output.close() }
        var commandID = -1
        var sampled = 0
        var covered = 0
        var finishes = false
        let deadline = Date().addingTimeInterval(360)
        while Date() < deadline && !finishes {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("live-command.json")),
               let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = command["id"] as? Int, id != commandID {
                commandID = id
                if let threeD = command["threeD"] as? Bool { mode.setThreeD(threeD); overlay.reloadCurrentContext() }
                if let theme = command["theme"] as? String {
                    settings.theme = theme == "dark" ? .dark : .light
                    try settingsService.saveSettings(settings)
                    panel.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                }
                if let action = command["action"] as? String { overlay.perform(pluginID: pluginID, actionID: action) }
                if command["sample"] as? Bool == true {
                    probe.begin(panel: panel)
                    let target = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? screen
                    panel.show(forApp: app.localizedName ?? "Music", aboveIconFrame: CGRect(x: target.visibleFrame.midX,
                               y: target.visibleFrame.minY + 30, width: 48, height: 48), bundleURL: app.bundleURL)
                }
                if let marker = command["marker"] as? String { probe.marker(marker) }
                if let capture = command["capture"] as? String,
                   capture.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), let view = panel.contentView {
                    view.layoutSubtreeIfNeeded()
                    if #available(macOS 14.0, *) {
                        let content = try await SCShareableContent.current
                        let window = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) })
                        let config = SCStreamConfiguration()
                        config.width = Int(panel.frame.width * 2)
                        config.height = Int(panel.frame.height * 2)
                        config.showsCursor = false
                        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                            .write(to: directory.appendingPathComponent(capture + ".png"))
                    } else { throw XCTSkip("合成窗口截图需 macOS 14 或以上，不能使用空白 SceneKit 离屏图替代") }
                }
                if command["hidden"] as? Bool == true { model.hidePanel(); panel.orderOut(nil) }
                if command["hidden"] as? Bool == false {
                    panel.show(forApp: app.localizedName ?? "Music", aboveIconFrame: CGRect(x: screen.visibleFrame.midX,
                               y: screen.visibleFrame.minY + 30, width: 48, height: 48), bundleURL: app.bundleURL)
                }
                if let sleep = command["simulatedSleep"] as? Bool { session.setSleeping(sleep) }
                finishes = command["finish"] as? Bool == true
            }
            let remote = session.snapshot().0
            let read = overlay.mediaRead
            let sample: [String: Any] = [
                "time": Date().timeIntervalSince1970, "visible": panel.isVisible,
                "source": read?.source.rawValue ?? "none", "title": read?.nowPlaying?.title ?? "",
                "playing": read?.nowPlaying?.isPlaying as Any? ?? NSNull(),
                "position": read?.nowPlaying?.position as Any? ?? NSNull(),
                "liked": read?.nowPlaying?.liked as Any? ?? NSNull(),
                "canLike": read?.nowPlaying?.canLike as Any? ?? NSNull(),
                "artwork": overlay.artworkToken as Any? ?? NSNull(),
                "remoteTitle": remote?.nowPlaying.title ?? "",
                "remoteConnection": remote?.token.connection.uuidString as Any? ?? NSNull(),
                "remoteTrack": remote?.token.track as Any? ?? NSNull(),
                "remoteArtwork": remote?.artworkToken as Any? ?? NSNull(),
                "panelFrame": NSStringFromRect(panel.frame),
                "screen": panel.screen?.localizedName ?? "none",
                "windows": model.windows.map { ["id": $0.id, "currentSpace": $0.isOnCurrentSpace] },
            ]
            try output.write(contentsOf: JSONSerialization.data(withJSONObject: sample) + Data([10]))
            sampled += 1
            if read?.source == .mediaRemote && overlay.artwork != nil { covered += 1 }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(finishes, "验收窗口超时；需通过命令文件显式结束")
        XCTAssertGreaterThan(sampled, 5)
        XCTAssertGreaterThan(covered, 0, "没有取得真实配对后的系统封面，不能把回退占位当作通过")
        if performance { try await probe.finish() }
        print("MediaRemote live evidence: samples=\(sampled) covered=\(covered)")
    }
}

/// 显式验收才启用。合成帧在后台复制面板区域，先缓存在内存，停止后写盘；
/// 时间为采集回调到达上界，包含 ScreenCaptureKit 传递成本。
@available(macOS 14.0, *)
private final class LivePanelFrames: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext()
    private var crop: CGRect = .zero
    private var until: Double = 0
    private var frames: [(Double, CGImage)] = []
    func update(crop: CGRect, until: Double) {
        lock.lock(); self.crop = crop; self.until = until; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); let region = crop; let capture = now <= until && frames.count < 180; lock.unlock()
        guard type == .screen, capture, !region.isEmpty,
              sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
        let source = CIImage(cvPixelBuffer: buffer)
        let flipped = CGRect(x: region.minX, y: source.extent.height - region.maxY,
                             width: region.width, height: region.height).intersection(source.extent)
        guard !flipped.isEmpty, let image = context.createCGImage(source.cropped(to: flipped), from: flipped) else { return }
        lock.lock(); frames.append((now, image)); lock.unlock()
    }
    func drain() -> [(Double, CGImage)] {
        lock.lock(); defer { lock.unlock() }
        let result = frames; frames.removeAll(); return result
    }
}

private final class LiveRenderObserver: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rendered: Double?
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock(); if rendered == nil { rendered = ProcessInfo.processInfo.systemUptime }; lock.unlock()
    }
    func reset() { lock.lock(); rendered = nil; lock.unlock() }
    var first: Double? { lock.lock(); defer { lock.unlock() }; return rendered }
}

@MainActor
private final class LivePanelPerformance {
    let directory: URL
    private var timer: Timer?
    private var stream: AnyObject?
    private var frames: AnyObject?
    private var displayBounds: CGRect = .zero
    private var observations: [[String: Any]] = []
    private var subscription: AnyCancellable?
    private var started = ProcessInfo.processInfo.systemUptime
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var observer = LiveRenderObserver()
    private weak var panel: DockPreviewPanel?
    private var cycle = 0
    private var sceneSeen = false
    private var renderedSeen = false
    private var deadline: Double = 0
    init(directory: URL) { self.directory = directory }
    func start(screen: NSScreen, panel: DockPreviewPanel, overlay: DockPluginOverlayModel) async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("合成首帧采样需要 macOS 14+") }
        let content = try await SCShareableContent.current
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let display = try XCTUnwrap(content.displays.first { $0.displayID == id })
        displayBounds = screen.frame
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width); config.height = Int(screen.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3; config.showsCursor = false
        let output = LivePanelFrames()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.switchly.tests.live-frames"))
        try await stream.startCapture()
        self.stream = stream; frames = output
        subscription = overlay.slotsPublisher.dropFirst().sink { [weak self] slots in
            self?.observations.append(["event": "slots", "time": ProcessInfo.processInfo.systemUptime, "count": slots.count])
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func begin(panel: DockPreviewPanel) {
        self.panel = panel; cycle += 1; sceneSeen = false; renderedSeen = false
        started = ProcessInfo.processInfo.systemUptime; lastTick = started; deadline = started + 3
        observer.reset(); marker("show-\(cycle)")
    }
    func marker(_ name: String) {
        observations.append(["event": name, "time": ProcessInfo.processInfo.systemUptime, "cycle": cycle])
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = (now - lastTick) * 1000; lastTick = now
        if gap > 20 { observations.append(["event": "mainGap", "ms": gap, "time": now, "cycle": cycle]) }
        guard let panel else { return }
        if #available(macOS 14.0, *), let frames = frames as? LivePanelFrames {
            let rect = panel.frame
            frames.update(crop: CGRect(x: rect.minX - displayBounds.minX,
                y: displayBounds.maxY - rect.maxY, width: rect.width, height: rect.height), until: panel.isVisible ? deadline : 0)
        }
        guard let root = panel.contentView else { return }
        var queue = [root]
        while let view = queue.popLast() {
            if let host = view as? PluginScene3DPointerView, host.scene != nil {
                if !sceneSeen {
                    sceneSeen = true; host.delegate = observer
                    observations.append(["event": "sceneMounted", "ms": (now - started) * 1000, "time": now, "cycle": cycle])
                }
                if !renderedSeen, let rendered = observer.first {
                    renderedSeen = true
                    observations.append(["event": "didRender", "ms": (rendered - started) * 1000, "time": rendered, "cycle": cycle])
                }
                break
            }
            queue.append(contentsOf: view.subviews)
        }
    }
    func stop() { timer?.invalidate(); timer = nil; subscription = nil }
    func finish() async throws {
        stop()
        if #available(macOS 14.0, *), let stream = stream as? SCStream, let frames = frames as? LivePanelFrames {
            try await stream.stopCapture()
            var rows: [[String: Any]] = []
            for (i, frame) in frames.drain().enumerated() {
                let name = String(format: "frame-%03d.png", i)
                try XCTUnwrap(NSBitmapImageRep(cgImage: frame.1).representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(name))
                rows.append(["file": name, "time": frame.0])
            }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("frames.json"))
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("performance.json"))
    }
}

private final class LiveMediaMode: @unchecked Sendable {
    private let lock = NSLock()
    private var threeD = false
    var settings: [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        return ["ipod3d": threeD, "wheelLayout": false, "showCover": true, "showLove": true, "hidePreviews": true]
    }
    func setThreeD(_ value: Bool) { lock.lock(); threeD = value; lock.unlock() }
}

private final class LiveMusicRegistry: PluginRegistryProtocol {
    private let registry: PluginRegistry
    init(directory: URL) { registry = PluginRegistry(searchPaths: [PluginSearchPath(directory: directory, origin: .builtin)]) }
    func reload() -> (plugins: [PluginPackage], failures: [PluginLoadFailure]) {
        let all = registry.reload()
        return (all.plugins.filter { $0.manifest.id == "com.switchly.music-controls" }, all.failures)
    }
}
