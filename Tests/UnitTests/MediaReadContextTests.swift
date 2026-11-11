import XCTest
@testable import Switchly

final class MediaReadContextTests: XCTestCase {
    func testRenderPinsRepeatedReadsButActionReadsCurrentState() async throws {
        let bridge = ReadTestBridge()
        let (runtime, root) = try makeRuntime(bridge: bridge, permissions: [.mediaNowPlaying, .mediaControl])
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = MediaReadContext(nowPlaying: ReadTestBridge.track("Pinned"), artwork: nil,
                                      artworkToken: nil, validate: { true })
        let output = try await runtime.render(context: context, mediaRead: pinned).get()
        XCTAssertEqual(output.first?.node, .text(value: "Pinned/Pinned", style: .body, lines: nil))
        XCTAssertEqual(bridge.reads, 0)
        _ = try await runtime.performAction(id: "check", value: nil, context: context).get()
        XCTAssertEqual(bridge.commands, [.like])
        XCTAssertGreaterThan(bridge.reads, 0)
    }

    func testControlOnlyRuntimeCannotReceivePinnedMetadataEvenThroughFactoryOverride() async throws {
        let bridge = ReadTestBridge()
        let source = """
        let seen = "none";
        globalThis.__switchlyPlugin = {
          render(ctx) {
            const original = globalThis.__switchlyMakeMedia;
            globalThis.__switchlyMakeMedia = function(b, p, s) { seen = s ? s.title : "none"; return original(b,p,s); };
            return [{slot:"center",node:{type:"text",value:seen}}];
          }
        };
        """
        let (runtime, root) = try makeRuntime(bridge: bridge, permissions: [.mediaControl], source: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = MediaReadContext(nowPlaying: ReadTestBridge.track("Secret"), artwork: nil,
                                      artworkToken: nil, validate: { true })
        _ = await runtime.render(context: context, mediaRead: pinned)
        let output = try await runtime.render(context: context, mediaRead: pinned).get()
        XCTAssertEqual(output.first?.node, .text(value: "none", style: .body, lines: nil))
        XCTAssertEqual(bridge.reads, 0)
    }

    func testPinnedReadFailureStillRejectsPromiseForPluginErrorHandling() async throws {
        let bridge = ReadTestBridge()
        let (runtime, root) = try makeRuntime(bridge: bridge, permissions: [.mediaNowPlaying], source: """
        globalThis.__switchlyPlugin = { async render(ctx) {
          let value = "unexpected";
          try { await ctx.media.nowPlaying(); } catch (error) { value = error.message; }
          return [{slot:"center",node:{type:"text",value:value}}];
        }};
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let read = MediaReadContext(nowPlaying: nil, readError: "notAuthorized", artwork: nil,
                                   artworkToken: nil, validate: { true })
        let result = try await runtime.render(context: context, mediaRead: read).get()
        XCTAssertEqual(result.first?.node, .text(value: "notAuthorized", style: .body, lines: nil))
        XCTAssertEqual(bridge.reads, 0)
    }

    func testInterestCancellationAndDeinitAreIdempotent() {
        var count = 0
        var lease: MediaReadInterest? = MediaReadInterest { count += 1 }
        lease?.cancel()
        lease?.cancel()
        lease = nil
        XCTAssertEqual(count, 1)
        do { let other = MediaReadInterest { count += 1 }; _ = other }
        XCTAssertEqual(count, 2)
    }

    private var context: PluginRenderContext {
        PluginRenderContext(bundleID: "com.apple.Music", pid: 42, appName: "Music", windowID: 1, titleSummary: "")
    }

    private func makeRuntime(bridge: ReadTestBridge, permissions: Set<PluginCapability>, source: String? = nil) throws -> (PluginRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-pin-\(UUID().uuidString)")
        let plugin = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try """
        {"id":"com.example.pin","name":{"en":"Pin"},"version":"1","apiVersion":1,
         "matches":["com.apple.Music"],"permissions":["media.nowPlaying","media.control"],"entry":"main.js"}
        """.write(to: plugin.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try (source ?? """
        globalThis.__switchlyPlugin = {
          async render(ctx) {
            const a = await ctx.media.nowPlaying();
            const b = await ctx.media.nowPlaying();
            return [{slot:"center",node:{type:"text",value:a.title+"/"+b.title}}];
          },
          async onAction(ctx) { const a = await ctx.media.nowPlaying(); if (a.title === "Live") await ctx.media.setLiked(true); }
        };
        """).write(to: plugin.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        let package = try XCTUnwrap(PluginRegistry(directory: root).reload().plugins.first)
        return (PluginRuntime(package: package, mediaBridge: bridge, permissions: permissions), root)
    }
}

private final class ReadTestBridge: MediaBridging, @unchecked Sendable {
    let queue = DispatchQueue(label: "test.pin.bridge")
    var reads = 0
    var commands: [MediaCommand] = []
    static func track(_ title: String) -> NowPlaying {
        NowPlaying(isPlaying: true, title: title, artist: "Artist", album: "Album", position: 1,
                   duration: 100, liked: true, canLike: true)
    }
    func supports(bundleID: String) -> Bool { true }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { reads += 1; return Self.track("Live") }
    func artwork(bundleID: String) throws -> Data? { nil }
    func perform(_ command: MediaCommand, bundleID: String) throws { commands.append(command) }
}
