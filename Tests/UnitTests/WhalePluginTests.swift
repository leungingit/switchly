import AppKit
import SwiftUI
import XCTest
@testable import Switchly

/// Whale Girl: the pose follows the running / unread counts, and every picture it asks for must load within budget.
@MainActor
final class WhalePluginTests: XCTestCase {
    private var package: PluginPackage {
        get throws {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Plugins").standardizedFileURL
            let result = PluginRegistry(directory: dir, origin: .builtin).reload()
            XCTAssertEqual(result.failures, [])
            return try XCTUnwrap(result.plugins.first { $0.manifest.id == "com.switchly.whale" })
        }
    }

    /// Sessions the way Harness lays them out: <workspace>/session-<id>/{session.v4.jsonl.zstd, session.lock}.
    private var folders: [URL] = []
    private var heldLocks: [Int32] = []

    override func tearDown() {
        heldLocks.forEach { close($0) }
        heldLocks = []
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
    }

    /// A throwaway home with `running` sessions written a second ago, `unread` finished two minutes ago and still
    /// open (lock held), and `closed` finished two minutes ago with no lock holder.
    private func fixtureHome(running: Int, unread: Int, closed: Int = 0) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("whale-fs-\(UUID().uuidString)").resolvingSymlinksInPath()
        folders.append(home)
        let workspace = home.appendingPathComponent(".dsh/sessions/--Users-someone-project--")
        func session(age: TimeInterval, locked: Bool) throws {
            let dir = workspace.appendingPathComponent("session-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = dir.appendingPathComponent("session.v4.jsonl.zstd")
            try Data([1, 2, 3]).write(to: data)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: data.path)
            let lock = dir.appendingPathComponent("session.lock")
            FileManager.default.createFile(atPath: lock.path, contents: nil)
            if locked {
                let fd = open(lock.path, O_RDONLY)
                XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
                heldLocks.append(fd)
            }
        }
        for _ in 0..<running { try session(age: 1, locked: true) }
        for _ in 0..<unread { try session(age: 120, locked: true) }
        for _ in 0..<closed { try session(age: 120, locked: false) }
        return home
    }

    /// Renders the plugin against that home. `lastActive` is how long ago Harness was last in front (nil: unknown).
    private func scene(running: Double, unread: Double, closed: Int = 0, lastActive: TimeInterval? = 3600, allowed: Bool = true,
                       reduceMotion: Bool = false) async throws -> PluginScene {
        let pkg = try package
        let home = try fixtureHome(running: Int(running), unread: Int(unread), closed: closed)
        let runtime = PluginRuntime(package: pkg, timeout: 2, preferredLanguages: ["en"], permissions: allowed ? [.fsRead] : [],
                                    fileReader: PluginFileReader(roots: pkg.manifest.fsRoots ?? [], home: home),
                                    reduceMotion: { reduceMotion })
        func collect(_ n: PluginUINode) -> [PluginScene] { if case .scene(let s) = n { return [s] }; return n.children.flatMap(collect) }
        let ctx = PluginRenderContext(bundleID: "com.deepseek.dsh", pid: 1, appName: "DeepSeek Harness", windowID: 0, titleSummary: "",
                                      lastActiveAt: lastActive.map { Date().timeIntervalSince1970 - $0 })
        let slots = try await runtime.render(context: ctx).get()
        return try XCTUnwrap(slots.flatMap { collect($0.node) }.first)
    }

    /// The two numbers on the banner, running first.
    private func shownCounts(_ scene: PluginScene) -> [String] {
        func walk(_ layers: [SceneLayer]) -> [String] {
            layers.flatMap { ($0.kind == .text ? [$0.text ?? ""] : []) + walk($0.children) }.filter { Int($0) != nil }
        }
        return walk(scene.layers)
    }

    private func images(_ layers: [SceneLayer]) -> [String] {
        layers.flatMap { ($0.kind == .image ? [$0.image!] : []) + images($0.children) }
    }

    func testCountsSelectTheMode() async throws {
        let cases: [(Double, Double, String)] = [(0, 0, "idle"), (1, 0, "banner"), (0, 2, "banner"), (2, 5, "banner"), (3, 0, "busy"), (12, 9, "busy")]
        for (running, unread, mode) in cases {
            let s = try await scene(running: running, unread: unread)
            XCTAssertEqual(s.key, mode, "running=\(running) unread=\(unread)")
        }
    }

    func testCountsComeFromTheSessionFiles() async throws {
        let s = try await scene(running: 2, unread: 3)
        XCTAssertEqual(s.key, "banner")
        XCTAssertEqual(shownCounts(s), ["2", "3"])
    }

    func testNothingIsShownAsUnreadWhenHarnessIsInFrontOrWasNeverSeen() async throws {
        let inFront = try await scene(running: 0, unread: 3, lastActive: 0)
        XCTAssertEqual(inFront.key, "idle", "everything finished before 'now' has been seen")
        let unknown = try await scene(running: 0, unread: 3, lastActive: nil)
        XCTAssertEqual(unknown.key, "idle")
    }

    func testClosedSessionsAreNotUnread() async throws {
        let s = try await scene(running: 0, unread: 1, closed: 4)
        XCTAssertEqual(shownCounts(s), ["0", "1"])
    }

    func testWithoutFolderAccessTheWhaleJustDozes() async throws {
        let s = try await scene(running: 5, unread: 5, allowed: false)
        XCTAssertEqual(s.key, "idle")
    }

    func testEveryModeStaysInsideTheSceneBudget() async throws {
        for (running, unread) in [(0.0, 0.0), (1.0, 1.0), (6.0, 2.0)] {
            let s = try await scene(running: running, unread: unread)
            XCTAssertLessThanOrEqual(s.layers.reduce(0) { $0 + $1.layerCount }, PluginScene.maxLayers)
            XCTAssertLessThanOrEqual(s.layers.map(\.depth).max() ?? 0, PluginScene.maxDepth)
        }
    }

    func testAllPicturesLoadWithinTextureBudget() async throws {
        let pkg = try package
        let assets = SceneAssets(directory: pkg.directory)
        var seen = Set<String>()
        for (running, unread) in [(0.0, 0.0), (1.0, 1.0), (6.0, 2.0)] {
            for name in images(try await scene(running: running, unread: unread).layers) where seen.insert(name).inserted {
                XCTAssertNotNil(assets.image(name), "\(name) did not load")
            }
        }
        XCTAssertEqual(seen.count, 12)
        XCTAssertLessThan(assets.decodedBytes, SceneAssets.maxDecodedBytes)
    }

    func testBannerFollowsTheRaisedHands() async throws {
        // Left edge x and width are derived from the rotated grips; at rest they must match the straight-arm pose.
        let s = try await scene(running: 1, unread: 1)
        let body = try XCTUnwrap(s.layers.first)
        let banner = try XCTUnwrap(body.children.first { $0.image == "assets/banner.png" })
        let k = 180.0 / 950.0
        XCTAssertEqual(banner.value(.scaleX, at: 5), (1030.0 - 250.0) / 790.0, accuracy: 1e-9)
        XCTAssertEqual(banner.value(.x, at: 5) + body.x, (250.0 - 200.0) * k, accuracy: 1e-9)
        XCTAssertEqual(banner.value(.opacity, at: 0), 0, accuracy: 1e-9)
    }

    func testReduceMotionStillShowsTheFinishedPose() async throws {
        let s = try await scene(running: 1, unread: 1, reduceMotion: true)
        let banner = try XCTUnwrap(s.layers.first?.children.first { $0.image == "assets/banner.png" })
        XCTAssertEqual(banner.value(.opacity, at: s.restAt ?? 0, still: true), 1, accuracy: 1e-9)
        XCTAssertNil(s.settledAt, "ambient motion keeps the timeline alive; Reduce Motion is handled by still drawing")
    }

    /// Renders each mode to PNGs for eyeballing. Skipped unless /tmp/whale-snapshot-dir names an output directory.
    @available(macOS 13.0, *)
    func testRenderSnapshots() async throws {
        guard let dir = try? String(contentsOfFile: "/tmp/whale-snapshot-dir", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { throw XCTSkip("/tmp/whale-snapshot-dir not present") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let assets = SceneAssets(directory: try package.directory)
        let cases: [(String, Double, Double, [Double])] = [("idle", 0, 0, [0.2, 3.4, 4.1, 5]), ("banner", 2, 3, [0.3, 0.7, 1.0, 1.4, 4]),
                                                          ("busy", 5, 2, [0.1, 0.25, 0.5, 1.0, 1.3])]
        for (name, running, unread, times) in cases {
            let s = try await scene(running: running, unread: unread)
            for t in times {
                for dark in [true, false] {
                    let view = ZStack {
                        Rectangle().fill(dark ? Color(white: 0.16) : Color(white: 0.93))
                        Canvas { ctx, _ in SceneDrawing(scene: s, t: t, still: false, hover: [:], assets: assets).draw(into: ctx) }
                    }
                    .frame(width: CGFloat(s.width), height: CGFloat(s.height))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 3
                    let image = try XCTUnwrap(renderer.nsImage)
                    let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: out.appendingPathComponent("\(name)-\(String(format: "%.2f", t))-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    /// Mounts the real PluginSceneView in a window (so onAppear and asset loading run) and dumps what it draws.
    /// Skipped unless /tmp/whale-snapshot-dir names an output directory.
    func testRenderThroughSceneView() async throws {
        guard let dir = try? String(contentsOfFile: "/tmp/whale-snapshot-dir", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { throw XCTSkip("/tmp/whale-snapshot-dir not present") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, running, unread, wait) in [("idle", 0.0, 0.0, 0.8), ("banner", 2.0, 3.0, 2.2), ("busy", 5.0, 12.0, 1.4)] {
            let s = try await scene(running: running, unread: unread)
            let size = CGSize(width: 320, height: 220)
            let host = NSHostingView(rootView: PluginSceneView(scene: s, assetDirectory: try package.directory) { _, _ in }
                .frame(width: size.width, height: size.height).background(Color(white: 0.2)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("sceneview-\(name).png"))
        }
    }

    func testImageLayersCannotEscapeThePluginDirectory() throws {
        for path in ["../x.png", "/etc/passwd", "a/../../x.png", ""] {
            let json = #"{"kind":"image","image":"\#(path)","w":10,"h":10}"#
            XCTAssertThrowsError(try JSONDecoder().decode(SceneLayer.self, from: Data(json.utf8)), path)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SceneLayer.self, from: Data(#"{"kind":"image","w":10,"h":10}"#.utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(SceneLayer.self, from: Data(#"{"kind":"image","image":"assets/a.png","w":10,"h":10}"#.utf8)))
    }

    func testOversizedTextureIsRefusedOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whale-texture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = SceneAssets.maxEdge + 1
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("wide.png"))
        let assets = SceneAssets(directory: dir)
        XCTAssertNil(assets.image("wide.png"))
        XCTAssertEqual(assets.decodedBytes, 0)
    }
}
