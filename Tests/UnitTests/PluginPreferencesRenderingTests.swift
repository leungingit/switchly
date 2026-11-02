import AppKit
import SwiftUI
import XCTest
@testable import Switchly

/// 使用真实管理视图和合成插件状态，避免截取任何用户工作窗口。
@MainActor
final class PluginPreferencesRenderingTests: XCTestCase {
    func testManagementWindowWithEmptyInstalledAndThousandPluginFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["SWITCHLY_PLUGIN_QA_DIR"] else {
            throw XCTSkip("仅在显式指定独立证据目录时运行原生界面验收")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = try XCTUnwrap(PluginRegistry.builtinDirectory)
        let packages = PluginRegistry(directory: directory, origin: .builtin).reload().plugins
        XCTAssertFalse(packages.isEmpty)
        for count in [0, 3, 1000] {
            for dark in [false, true] {
                var settings = AppSettings.default
                settings.language = .simplifiedChinese
                let host = FixturePluginHost(packages: packages, count: count)
                let view = ScrollView {
                    PluginPreferencesSection(settings: settings, onSettingsChange: { _ in },
                                             onOnlineWeatherChange: { _ in }, host: host)
                        .padding(24)
                }
                .frame(width: 760, height: 560)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                let content = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 560),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "插件管理验收（合成数据）"
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = content
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                content.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: rep)
                let name = "plugins-\(count)-\(dark ? "dark" : "light").png"
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
                XCTAssertEqual(host.runtimeRequests, 0, "管理列表不能激活插件")
                window.orderOut(nil)
                window.contentView = nil
            }
        }
        print("PLUGIN_QA_DIR=\(output.path)")
    }
}

private final class FixturePluginHost: PluginHosting {
    let plugins: [InstalledPlugin]
    private(set) var runtimeRequests = 0

    init(packages: [PluginPackage], count: Int) {
        plugins = (0..<count).map { index in
            var original = packages[index % packages.count]
            if count > packages.count {
                let manifest = PluginManifest(id: "com.example.fixture-\(index)",
                    name: ["en": "Fixture \(index)", "zh-Hans": "合成插件 \(index)：长名称与应用状态"],
                    version: "1.0.0", apiVersion: 2, matches: ["com.example.target"], permissions: [],
                    entry: "main.js", refreshInterval: nil)
                original = PluginPackage(manifest: manifest, directory: original.directory, source: "", origin: .user)
            }
            return InstalledPlugin(package: original, authorization: .init(isEnabled: false, permissions: [], pendingPermissions: []))
        }
    }

    func installedPlugins() -> [InstalledPlugin] { plugins }
    func runtimes(for bundleID: String) -> [PluginRuntimeProtocol] { runtimeRequests += 1; return [] }
    func artwork(for bundleID: String) async -> Data? { nil }
    func unmountAll() {}
    func reload() {}
}
