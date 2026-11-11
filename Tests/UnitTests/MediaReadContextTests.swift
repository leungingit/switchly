import XCTest
@testable import Switchly

final class MediaReadContextTests: XCTestCase {
    func testEnginePrewarmDoesNotExecutePluginEntryOrReadMedia() async throws {
        let bridge = ReadTestBridge()
        let (runtime, root) = try makeRuntime(bridge: bridge, permissions: [.mediaNowPlaying], source: """
        console.log("entry-executed");
        let calls = 0;
        globalThis.__switchlyPlugin = { render() {
          calls += 1;
          return [{slot:"center",node:{type:"text",value:String(calls)}}];
        }};
        """)
        defer { runtime.unmount(); try? FileManager.default.removeItem(at: root) }
        await runtime.prewarmEngine()
        XCTAssertTrue(runtime.drainConsole().isEmpty, "不可在隐藏预热阶段执行插件入口")
        XCTAssertEqual(bridge.reads, 0)
        let rendered = try await runtime.render(context: context).get()
        XCTAssertEqual(rendered.first?.node, .text(value: "1", style: .body, lines: nil))
        XCTAssertEqual(runtime.drainConsole().map(\.message), ["entry-executed"])
        runtime.unmount()
        await runtime.prewarmEngine()
        let restarted = try await runtime.render(context: context).get()
        XCTAssertEqual(restarted.first?.node, .text(value: "1", style: .body, lines: nil))
    }
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

    func testRealRuntimePrepareContextHasNoSensitiveHostInterfaces() async throws {
        let bridge = ReadTestBridge()
        let source = """
        globalThis.__switchlyPlugin = { async prepare(ctx) {
          const names = ["media", "weather", "fs", "storage", "invalidate", "capabilities"];
          const values = names.map(name => ctx[name] === undefined ? "undefined" : "present").join(",");
          return [{slot:"center",node:{type:"text",value:values}}];
        }};
        """
        let permissions: Set<PluginCapability> = [
            .mediaNowPlaying, .mediaControl, .weatherCurrent, .fsRead
        ]
        let fileReader = PluginFileReader(roots: [PluginFSRoot(
            id: "safe",
            path: "~/media-prepare-fixture",
            summary: ["en": "Fixture"]
        )])
        let (runtime, root) = try makeRuntime(
            bridge: bridge,
            permissions: permissions,
            manifestPermissions: Array(permissions),
            source: source,
            fileReader: fileReader,
            weather: { ["temperature": 20] },
            storage: ReadTestStorage()
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try await runtime.prepare(context: context).get()
        XCTAssertEqual(output.first?.node, .text(
            value: "undefined,undefined,undefined,undefined,undefined,undefined",
            style: .body,
            lines: nil
        ))
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

    private func makeRuntime(
        bridge: ReadTestBridge,
        permissions: Set<PluginCapability>,
        manifestPermissions: [PluginCapability] = [.mediaNowPlaying, .mediaControl],
        source: String? = nil,
        fileReader: PluginFileReading? = nil,
        weather: (() -> [String: Any]?)? = nil,
        storage: PluginStorageProviding? = nil
    ) throws -> (PluginRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-pin-\(UUID().uuidString)")
        let plugin = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "id": "com.example.pin",
            "name": ["en": "Pin"],
            "version": "1",
            "apiVersion": 1,
            "matches": ["com.apple.Music"],
            "permissions": manifestPermissions.map(\.rawValue),
            "entry": "main.js"
        ]
        if manifestPermissions.contains(.fsRead) {
            manifest["fsRoots"] = [[
                "id": "safe",
                "path": "~/media-prepare-fixture",
                "summary": ["en": "Fixture"]
            ]]
        }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: plugin.appendingPathComponent("manifest.json"), options: .atomic)
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
        return (PluginRuntime(
            package: package,
            mediaBridge: bridge,
            permissions: permissions,
            fileReader: fileReader,
            weather: weather,
            storage: storage
        ), root)
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

private final class ReadTestStorage: PluginStorageProviding {
    private var values: [String: Any] = [:]

    func get(_ key: String) throws -> Any? { values[key] }
    func set(_ key: String, value: Any) throws { values[key] = value }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
    func clear() throws { values.removeAll() }
}
