import AppKit
import SwiftUI
import ScreenCaptureKit
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
        let screen = try XCTUnwrap(NSScreen.main)
        defer {
            panel.hide()
            model.hidePanel()
            host.unmountAll()
            defaults.removePersistentDomain(forName: suite)
        }
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
            ]
            try output.write(contentsOf: JSONSerialization.data(withJSONObject: sample) + Data([10]))
            sampled += 1
            if read?.source == .mediaRemote && overlay.artwork != nil { covered += 1 }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(finishes, "验收窗口超时；需通过命令文件显式结束")
        XCTAssertGreaterThan(sampled, 5)
        XCTAssertGreaterThan(covered, 0, "没有取得真实配对后的系统封面，不能把回退占位当作通过")
        print("MediaRemote live evidence: samples=\(sampled) covered=\(covered)")
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
