import AppKit
import SwiftUI
import XCTest
@testable import Switchly

/// Renders the weather gacha scenes to PNGs for eyeballing. Skipped unless
/// GACHA_SNAPSHOT_DIR is set (pass it as TEST_RUNNER_GACHA_SNAPSHOT_DIR).
@available(macOS 13.0, *)
@MainActor
final class WeatherGachaSnapshotTests: XCTestCase {
    private let context = PluginRenderContext(bundleID: "com.apple.Music", pid: 1, appName: "Music", windowID: 0, titleSummary: "")

    private final class Bridge: MediaBridging, MusicLibraryPlaying, @unchecked Sendable {
        let queue = DispatchQueue(label: "snapshot.bridge")
        var audible = false
        func supports(bundleID: String) -> Bool { true }
        func nowPlaying(bundleID: String) throws -> NowPlaying? {
            NowPlaying(isPlaying: audible, title: "Midnight City", artist: "M83", album: "", position: 5, duration: 240, liked: false, canLike: true)
        }
        func perform(_ command: MediaCommand, bundleID: String) throws {}
        func artwork(bundleID: String) throws -> Data? { nil }
        func pickRandomTrack(genreKeywords: [String]) throws -> PickedTrack? {
            PickedTrack(persistentID: "X1", title: "Midnight City", artist: "M83", bpm: 105, matchedGenre: true)
        }
        func play(persistentID: String) throws { audible = true }
        func pausePlayback() throws {}
        func currentTrack() throws -> NowPlaying? { try nowPlaying(bundleID: "") }
    }

    private func scenes(_ slots: [PluginSlotContent]) -> (back: PluginScene, front: PluginScene) {
        func collect(_ n: PluginUINode) -> [PluginScene] { if case .scene(let s) = n { return [s] }; return n.children.flatMap(collect) }
        let all = slots.flatMap { collect($0.node) }
        return (all.first { $0.fit == .cover }!, all.first { $0.fit == .width }!)
    }

    private func png(_ pair: (back: PluginScene, front: PluginScene), t: Double, hover: [String: Double] = [:], dark: Bool,
                     assets: SceneAssets, to url: URL) throws {
        let w = CGFloat(pair.front.width), h = CGFloat(pair.front.height)
        let view = ZStack {
            Rectangle().fill(dark ? Color(white: 0.16) : Color(white: 0.93))
            Canvas { ctx, _ in
                SceneDrawing(scene: pair.back, t: t, still: false, hover: [:], assets: assets).draw(into: ctx)
                SceneDrawing(scene: pair.front, t: t, still: false, hover: hover, assets: assets).draw(into: ctx)
            }
        }
        .frame(width: w, height: h)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testRenderSnapshots() async throws {
        guard let dir = try? String(contentsOfFile: "/tmp/gacha-snapshot-dir", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { throw XCTSkip("/tmp/gacha-snapshot-dir not present") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pluginDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Plugins").standardizedFileURL
        let package = try XCTUnwrap(PluginRegistry(directory: pluginDir, origin: .builtin).reload().plugins.first { $0.manifest.id == "com.switchly.weather-gacha" })
        let assets = SceneAssets(directory: package.directory)
        let bridge = Bridge()
        let runtime = PluginRuntime(package: package, timeout: 2, preferredLanguages: ["en"], mediaBridge: bridge,
                                    permissions: Set(package.manifest.permissions), libraryBridge: bridge,
                                    values: { ["condition": .string("rain"), "temperature": .number(14)] }, reduceMotion: { false })

        var pair = scenes(try await runtime.render(context: context).get())
        for (name, t) in [("a-0.10-drop", 0.10), ("a-0.45-sit", 0.45), ("a-0.95-hop", 0.95), ("a-1.35", 1.35), ("a-2.20", 2.20),
                          ("a-2.85-final", 2.85), ("a-3.05-bow", 3.05), ("a-3.45-dust", 3.45), ("a-3.70-deal", 3.70), ("a-4.60-cards", 4.60)] {
            try png(pair, t: t, dark: true, assets: assets, to: out.appendingPathComponent("\(name).png"))
        }
        try png(pair, t: 4.6, dark: false, assets: assets, to: out.appendingPathComponent("a-4.60-cards-light.png"))
        try png(pair, t: 4.6, hover: ["info:condition": 1], dark: true, assets: assets, to: out.appendingPathComponent("a-4.60-hover-glyph.png"))

        // The whole card as the Dock preview lays it out, at a typical panel width.
        let slots0 = try await runtime.render(context: context).get()
        // (Hosted in a real window: ImageRenderer cannot draw the AppKit input view.)
        for (name, width) in [("overlay-300", 300.0), ("overlay-narrow-220", 220.0)] {
            let overlay = PluginOverlayView(node: slots0[0].node, material: .legacyDefault, isGlassActive: false, assetDirectory: package.directory) { _, _ in }
                .padding(8).frame(width: width + 16).fixedSize(horizontal: false, vertical: true).background(Color(white: 0.16))
            let host = NSHostingView(rootView: overlay)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
            print("GACHA_LAYOUT", name, size)
        }
        // Drawing cost of the busiest frame (cards in, sheens and glows running).
        let start = Date()
        for i in 0..<20 { try png(pair, t: 4.0 + Double(i) * 0.03, dark: true, assets: assets, to: out.appendingPathComponent("perf.png")) }
        print("GACHA_PERF render+encode ms per frame:", Date().timeIntervalSince(start) / 20 * 1000)

        // Wait for the real countdown, then pick, reveal, play.
        try await Task.sleep(nanoseconds: 3_600_000_000)
        pair = scenes(try await runtime.render(context: context).get())
        let slots = try await runtime.render(context: context).get()
        let ids: [String] = slots.flatMap { $0.node.actionIDs }
        let pick = try XCTUnwrap(ids.first { $0.hasPrefix("pick:") })
        _ = await runtime.performAction(id: pick, value: nil, context: context)
        try await Task.sleep(nanoseconds: 300_000_000)
        pair = scenes(try await runtime.render(context: context).get())
        try png(pair, t: 0.35, dark: true, assets: assets, to: out.appendingPathComponent("b-0.35-shatter.png"))
        try png(pair, t: 0.70, dark: true, assets: assets, to: out.appendingPathComponent("b-0.70-shatter.png"))
        try await Task.sleep(nanoseconds: 1_300_000_000)
        pair = scenes(try await runtime.render(context: context).get())
        try png(pair, t: 2.0, dark: true, assets: assets, to: out.appendingPathComponent("c-reveal.png"))
        _ = await runtime.performAction(id: "play", value: nil, context: context)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        pair = scenes(try await runtime.render(context: context).get())
        try png(pair, t: 4.1, dark: true, assets: assets, to: out.appendingPathComponent("d-playing.png"))
        try png(pair, t: 4.1, dark: false, assets: assets, to: out.appendingPathComponent("d-playing-light.png"))
    }
}
