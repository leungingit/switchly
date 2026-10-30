import XCTest
@testable import Switchly

final class PluginSystemTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginSystemTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let context = PluginRenderContext(bundleID: "com.apple.Music", pid: 42, appName: "Music",
                                              windowID: 7, titleSummary: "Song")

    private func manifestJSON(id: String = "com.example.test", apiVersion: Int = 1,
                              permissions: [String] = ["media.nowPlaying"], entry: String = "main.js") -> String {
        let perms = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(id)","name":{"en":"Test","zh-Hans":"测试"},"version":"0.1.0","apiVersion":\(apiVersion),
         "matches":["com.apple.Music"],"permissions":[\(perms)],"entry":"\(entry)"}
        """
    }

    @discardableResult
    private func install(_ dirName: String, manifest: String, source: String,
                         locales: [String: String] = [:]) throws -> URL {
        let dir = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("locales"), withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try source.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        for (lang, json) in locales {
            try json.write(to: dir.appendingPathComponent("locales/\(lang).json"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func runtime(source: String, timeout: TimeInterval = 0.2, locales: [String: String] = [:],
                         languages: [String] = ["en"]) throws -> PluginRuntime {
        try install("p", manifest: manifestJSON(), source: source, locales: locales)
        let package = try XCTUnwrap(PluginRegistry(directory: root).reload().plugins.first)
        return PluginRuntime(package: package, timeout: timeout, preferredLanguages: languages)
    }

    // MARK: Manifest

    func testManifestDecodesAndRejectsUnknownPermission() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(
            permissions: ["media.control", "appleScript:com.apple.Music"]).utf8))
        XCTAssertEqual(manifest.permissions, [.mediaControl, .appleScript(bundleID: "com.apple.Music")])
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(manifest.displayName(preferredLanguages: ["zh-Hans-CN"]), "测试")

        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self,
                                                      from: Data(manifestJSON(permissions: ["network"]).utf8)))
    }

    func testManifestValidationRejectsUnsupportedVersionAndEscapingEntry() throws {
        let future = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(apiVersion: 3).utf8))
        XCTAssertThrowsError(try future.validate()) {
            XCTAssertEqual($0 as? PluginManifest.ValidationError, .unsupportedAPIVersion(3))
        }
        let escaping = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(entry: "../x.js").utf8))
        XCTAssertThrowsError(try escaping.validate())
    }

    // MARK: Registry

    func testRegistryReportsFailuresAndDuplicateIDs() throws {
        try install("a", manifest: manifestJSON(), source: "")
        try install("b", manifest: manifestJSON(), source: "")
        try install("c", manifest: "{", source: "")
        let result = PluginRegistry(directory: root).reload()
        XCTAssertEqual(result.plugins.map(\.directory.lastPathComponent), ["a"])
        XCTAssertEqual(result.failures.count, 2)
    }

    func testRegistryMissingDirectoryIsEmpty() {
        let result = PluginRegistry(directory: root.appendingPathComponent("missing")).reload()
        XCTAssertTrue(result.plugins.isEmpty && result.failures.isEmpty)
    }

    // MARK: UI schema

    func testRenderOutputDecodesTreeAndClampsValues() throws {
        let json = """
        [{"slot":"bottomBar","node":{"type":"surface","children":[
          {"type":"hstack","spacing":"s","children":[
            {"type":"image","source":{"artwork":true},"size":"s"},
            {"type":"button","id":"toggle","symbol":"play.fill","label":"Play"}]},
          {"type":"slider","id":"seek","value":1.7,"label":"Position"}]}}]
        """
        let output = try PluginRenderOutput.decode(json: Data(json.utf8))
        XCTAssertEqual(output.first?.slot, .bottomBar)
        XCTAssertEqual(output.first?.node.actionIDs, ["toggle", "seek"])
        guard case .slider(_, let value, _, _) = output.first?.node.children.last else { return XCTFail() }
        XCTAssertEqual(value, 1)
        XCTAssertEqual(try PluginRenderOutput.decode(json: Data("null".utf8)), [])
    }

    func testRenderOutputRejectsInvalidTrees() {
        let cases = [
            #"[{"slot":"bottomBar","node":{"type":"canvas"}}]"#,
            #"[{"slot":"bottomBar","node":{"type":"button","id":"a","symbol":"x"}}]"#,
            ##"[{"slot":"bottomBar","node":{"type":"badge","value":"1","tone":"#ff0000"}}]"##,
            #"[{"slot":"center","node":{"type":"spacer"}},{"slot":"center","node":{"type":"spacer"}}]"#,
            #"[{"slot":"center","node":{"type":"hstack","children":[{"type":"button","id":"a","symbol":"x","label":"A"},{"type":"button","id":"a","symbol":"x","label":"B"}]}}]"#,
            #"[{"slot":"center","node":{"type":"image","source":{"pluginAsset":"../../secret.png"}}}]"#,
        ]
        for json in cases {
            XCTAssertThrowsError(try PluginRenderOutput.decode(json: Data(json.utf8)), json)
        }
        var deep = #"{"type":"spacer"}"#
        for _ in 0..<PluginRenderOutput.maxDepth { deep = #"{"type":"zstack","children":[\#(deep)]}"# }
        XCTAssertThrowsError(try PluginRenderOutput.decode(json: Data(#"[{"slot":"center","node":\#(deep)}]"#.utf8)))
    }

    // MARK: Runtime

    func testRuntimeRendersAsyncPluginWithContextAndLocale() async throws {
        let source = """
        globalThis.__switchlyPlugin = {
          async render(ctx) {
            await new Promise(r => setTimeout(r, 5));
            return [{ slot: "center", node: { type: "button", id: "toggle", symbol: "play.fill",
                      label: ctx.t("Play") + ":" + ctx.app.bundleID } }];
          }
        };
        """
        let rt = try runtime(source: source, locales: ["zh-Hans": #"{"Play":"播放"}"#], languages: ["zh-Hans-CN"])
        let result = try await rt.render(context: context).get()
        XCTAssertEqual(result, [PluginSlotContent(slot: .center, node: .button(
            id: "toggle", symbol: "play.fill", label: "播放:com.apple.Music", size: .m,
            variant: .plain, enabled: true, selected: false))])
    }

    func testRuntimeHasNoNetworkOrFileGlobals() async throws {
        let source = """
        globalThis.__switchlyPlugin = { render() {
          const g = ["fetch", "XMLHttpRequest", "require", "process", "WebSocket"].filter(n => typeof globalThis[n] !== "undefined");
          return [{ slot: "center", node: { type: "text", value: g.join(",") } }];
        } };
        """
        let result = try await runtime(source: source).render(context: context).get()
        XCTAssertEqual(result.first?.node, .text(value: "", style: .body, lines: nil))
    }

    func testRuntimeReportsScriptErrorsAndInvalidOutput() async throws {
        let throwing = try runtime(source: #"globalThis.__switchlyPlugin = { render() { throw new Error("boom"); } };"#)
        guard case .failure(.script(let message)) = await throwing.render(context: context) else { return XCTFail() }
        XCTAssertTrue(message.contains("boom"))

        try FileManager.default.removeItem(at: root.appendingPathComponent("p"))
        let invalid = try runtime(source: #"globalThis.__switchlyPlugin = { render() { return [{ slot: "nowhere" }]; } };"#)
        guard case .failure(.invalidOutput) = await invalid.render(context: context) else { return XCTFail() }
    }

    func testRuntimeWithoutRegistrationIsNotLoaded() async throws {
        let rt = try runtime(source: "var x = 1;")
        let result = await rt.render(context: context)
        XCTAssertEqual(result.map { _ in 0 }, .failure(.notLoaded))
    }

    func testRuntimeTimeoutsDisablePlugin() async throws {
        let rt = try runtime(source: "globalThis.__switchlyPlugin = { render() { return new Promise(() => {}); } };",
                             timeout: 0.02)
        for _ in 0..<3 {
            let result = await rt.render(context: context)
            XCTAssertEqual(result.map { _ in 0 }, .failure(.timedOut))
        }
        XCTAssertTrue(rt.isDisabled)
        let after = await rt.render(context: context)
        XCTAssertEqual(after.map { _ in 0 }, .failure(.disabled))
    }

    func testActionInvalidateAndUnmountCancelsTimers() async throws {
        let source = """
        let fired = 0;
        globalThis.__switchlyPlugin = {
          render() { return [{ slot: "titleAccessory", node: { type: "badge", value: String(fired) } }]; },
          onAction(ctx, id, value) {
            if (id !== "seek" || value !== 0.5) throw new Error("bad args");
            setTimeout(() => { fired += 1; }, 30);
            ctx.invalidate();
          }
        };
        """
        let rt = try runtime(source: source)
        let invalidated = expectation(description: "invalidate")
        rt.onInvalidate = { invalidated.fulfill() }
        _ = try await rt.performAction(id: "seek", value: 0.5, context: context).get()
        await fulfillment(of: [invalidated], timeout: 1)

        // Unmount before the timer fires; a fresh VM starts from zero and the
        // old timer must never run.
        rt.unmount()
        rt.unmount()
        try await Task.sleep(nanoseconds: 80_000_000)
        let result = try await rt.render(context: context).get()
        XCTAssertEqual(result.first?.node, .badge(value: "0", tone: .neutral))
    }
}

// MARK: - Media bridge, registry origins, built-in plugin

private final class FakeMediaBridge: MediaBridging, @unchecked Sendable {
    let queue = DispatchQueue(label: "test.media")
    var current: NowPlaying? = NowPlaying(isPlaying: true, title: "Song", artist: "Artist", album: "Album",
                                          position: 30, duration: 120, liked: false, canLike: true)
    private(set) var commands: [MediaCommand] = []

    var artworkData: Data?
    func supports(bundleID: String) -> Bool { bundleID == "com.apple.Music" }
    func artwork(bundleID: String) throws -> Data? { artworkData }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { current }
    func perform(_ command: MediaCommand, bundleID: String) throws {
        commands.append(command)
        if command == .togglePlayPause, let c = current {
            current = NowPlaying(isPlaying: !c.isPlaying, title: c.title, artist: c.artist, album: c.album,
                                 position: c.position, duration: c.duration, liked: c.liked, canLike: c.canLike)
        }
    }
}

final class PluginMediaTests: XCTestCase {
    private let windowContext = PluginRenderContext(bundleID: "com.apple.Music", pid: 1, appName: "Music",
                                                    windowID: 9, titleSummary: "Music")
    private let windowlessContext = PluginRenderContext(bundleID: "com.apple.Music", pid: 1, appName: "Music",
                                                        windowID: 0, titleSummary: "")

    private var builtinMusic: PluginPackage {
        get throws {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Resources/Plugins").standardizedFileURL
            let result = PluginRegistry(directory: dir, origin: .builtin).reload()
            XCTAssertEqual(result.failures, [])
            return try XCTUnwrap(result.plugins.first { $0.manifest.id == "com.switchly.music-controls" })
        }
    }

    func testBuiltinMusicPluginRendersCardBelowStrip() async throws {
        let bridge = FakeMediaBridge()
        let rt = PluginRuntime(package: try builtinMusic, preferredLanguages: ["zh-Hans"], mediaBridge: bridge)
        let slots = try await rt.render(context: windowContext).get()
        XCTAssertEqual(slots.map(\.slot), [.center])
        XCTAssertEqual(slots.first?.node.actionIDs, ["love", "previous", "toggle", "next"])
        XCTAssertTrue(slots.first?.node.usesArtwork ?? false)
    }

    func testBuiltinMusicPluginShowsTrackWithoutWindowAndKeepsCardWhenIdle() async throws {
        let bridge = FakeMediaBridge()
        let rt = PluginRuntime(package: try builtinMusic, preferredLanguages: ["en"], mediaBridge: bridge)
        let slots = try await rt.render(context: windowlessContext).get()
        guard case .surface(let children, _) = slots.first?.node,
              case .hstack(let row, _, _) = children.first,
              case .vstack(let lines, _, _) = row.last else { return XCTFail() }
        XCTAssertEqual(row.first, .image(source: .artwork, size: .l, corner: .m))
        XCTAssertEqual(lines[1], .marquee(value: "Song"))

        // Stopped: the card stays so Play can start playback.
        bridge.current = nil
        let idle = try await rt.render(context: windowlessContext).get()
        XCTAssertEqual(idle.map(\.slot), [.center])
        XCTAssertEqual(idle.first?.node.actionIDs, ["love", "previous", "toggle", "next"])
    }

    func testBuiltinMusicPluginHonoursOwnSettings() async throws {
        let bridge = FakeMediaBridge()
        let rt = PluginRuntime(package: try builtinMusic, preferredLanguages: ["en"], mediaBridge: bridge,
                               settings: { ["showCover": false, "showLove": false, "unknown": true] })
        let slots = try await rt.render(context: windowlessContext).get()
        XCTAssertEqual(slots.first?.node.actionIDs, ["previous", "toggle", "next"])
        XCTAssertFalse(slots.first?.node.usesArtwork ?? true)
    }

    func testBuiltinMusicPluginWheelLayout() async throws {
        let rt = PluginRuntime(package: try builtinMusic, preferredLanguages: ["en"], mediaBridge: FakeMediaBridge(),
                               settings: { ["wheelLayout": true] })
        let slots = try await rt.render(context: windowlessContext).get()
        XCTAssertEqual(slots.map(\.slot), [.center])
        XCTAssertEqual(Set(slots.first?.node.actionIDs ?? []), ["love", "previous", "toggle", "next"])
    }

    func testBuiltinMusicPluginDeclaresHidePreviewsOption() throws {
        let keys = try builtinMusic.manifest.hidePreviewsKeys
        XCTAssertEqual(keys.map(\.key), ["hidePreviews"])
        XCTAssertFalse(keys[0].default)
    }

    func testWheelLayoutWrapsInfoInScreen() async throws {
        let rt = PluginRuntime(package: try builtinMusic, preferredLanguages: ["en"], mediaBridge: FakeMediaBridge(),
                               settings: { ["wheelLayout": true] })
        let slots = try await rt.render(context: windowlessContext).get()
        guard case .surface(let outer, _) = slots.first?.node,
              case .vstack(let parts, _, _) = outer.first,
              case .screen = parts.first else { return XCTFail("screen frame missing") }
    }

    func testBuiltinMusicPluginActionsReachBridge() async throws {
        let bridge = FakeMediaBridge()
        let rt = PluginRuntime(package: try builtinMusic, mediaBridge: bridge)
        for (id, value) in [("toggle", nil), ("next", nil), ("previous", nil), ("love", 1.0), ("love", 0.0)] as [(String, Double?)] {
            _ = try await rt.performAction(id: id, value: value, context: windowContext).get()
        }
        XCTAssertEqual(bridge.queue.sync { bridge.commands }, [.togglePlayPause, .next, .previous, .like, .unlike])
    }

    func testMediaIsAbsentWithoutPermission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginMediaTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"id":"com.example.ro","name":{"en":"RO"},"version":"1","apiVersion":1,"matches":["com.apple.Music"],"permissions":["media.nowPlaying"],"entry":"main.js"}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try #"globalThis.__switchlyPlugin = { render(ctx) { return [{ slot: "center", node: { type: "text", value: Object.keys(ctx.media).join(",") } }]; } };"#
            .write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        let package = try XCTUnwrap(PluginRegistry(directory: root).reload().plugins.first)
        let slots = try await PluginRuntime(package: package, mediaBridge: FakeMediaBridge()).render(context: windowContext).get()
        XCTAssertEqual(slots.first?.node, .text(value: "nowPlaying", style: .body, lines: nil))
    }

    func testBuiltinPathWinsOverUserCopy() throws {
        let builtin = try builtinMusic
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginOrigin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: builtin.directory, to: root.appendingPathComponent("copy"))
        let result = PluginRegistry(searchPaths: [
            PluginSearchPath(directory: builtin.directory.deletingLastPathComponent(), origin: .builtin),
            PluginSearchPath(directory: root, origin: .user),
        ]).reload()
        // Every built-in plugin loads once; the user copy of Music Controls is rejected as a duplicate.
        XCTAssertEqual(result.plugins.filter { $0.manifest.id == "com.switchly.music-controls" }.map(\.origin), [.builtin])
        XCTAssertEqual(result.plugins.map(\.origin), Array(repeating: .builtin, count: result.plugins.count))
        XCTAssertEqual(result.failures.count, 1)
    }
}

// MARK: - Authorization and host

private final class StubRegistry: PluginRegistryProtocol {
    var plugins: [PluginPackage]
    init(_ plugins: [PluginPackage]) { self.plugins = plugins }
    func reload() -> (plugins: [PluginPackage], failures: [PluginLoadFailure]) { (plugins, []) }
}

final class PluginAuthorizationTests: XCTestCase {
    private func package(_ origin: PluginOrigin, permissions: [PluginCapability] = [.mediaNowPlaying, .mediaControl]) -> PluginPackage {
        let manifest = PluginManifest(id: "com.example.p", name: ["en": "P"], version: "1", apiVersion: 1,
                                      matches: ["com.apple.Music"], permissions: permissions, entry: "main.js",
                                      refreshInterval: nil)
        return PluginPackage(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/p"),
                             source: "globalThis.__switchlyPlugin = {};", origin: origin)
    }

    func testBuiltinRunsByDefaultAndCanBeTurnedOff() {
        let p = package(.builtin)
        let auth = PluginAuthorization.resolve(manifest: p.manifest, origin: .builtin, grant: nil)
        XCTAssertTrue(auth.isEnabled)
        XCTAssertEqual(auth.permissions, [.mediaNowPlaying, .mediaControl])
        XCTAssertFalse(PluginAuthorization.resolve(manifest: p.manifest, origin: .builtin,
                                                   grant: PluginGrant(isEnabled: false, permissions: [])).isEnabled)
    }

    func testUserPluginNeedsConfirmationAndNewPermissionsStayPending() {
        let p = package(.user)
        let fresh = PluginAuthorization.resolve(manifest: p.manifest, origin: .user, grant: nil)
        XCTAssertFalse(fresh.isEnabled)
        XCTAssertEqual(fresh.permissions, [])
        XCTAssertEqual(fresh.pendingPermissions, [.mediaNowPlaying, .mediaControl])

        // Confirmed an older version that only read state; the update adds control.
        let old = PluginGrant(isEnabled: true, permissions: ["media.nowPlaying"])
        let updated = PluginAuthorization.resolve(manifest: p.manifest, origin: .user, grant: old)
        XCTAssertEqual(updated.permissions, [.mediaNowPlaying])
        XCTAssertEqual(updated.pendingPermissions, [.mediaControl])
    }

    func testHostSkipsDisabledAndRebuildsOnGrantChange() {
        var grants: [String: PluginGrant] = [:]
        var created: [Set<PluginCapability>] = []
        let host = PluginHost(registry: StubRegistry([package(.user)]), grants: { grants },
                              mediaBridge: FakeMediaBridge(),
                              makeRuntime: { pkg, perms in
                                  created.append(perms)
                                  return PluginRuntime(package: pkg, permissions: perms)
                              })
        XCTAssertTrue(host.runtimes(for: "com.apple.Music").isEmpty)
        grants["com.example.p"] = PluginGrant(isEnabled: true, permissions: ["media.nowPlaying"])
        let first = host.runtimes(for: "com.apple.Music")
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0] === host.runtimes(for: "com.apple.Music")[0])
        grants["com.example.p"]?.permissions.append("media.control")
        XCTAssertFalse(first[0] === host.runtimes(for: "com.apple.Music")[0])
        XCTAssertEqual(created, [[.mediaNowPlaying], [.mediaNowPlaying, .mediaControl]])
        XCTAssertTrue(host.runtimes(for: "com.other").isEmpty)
    }

    func testRuntimeInjectsOnlyGrantedMedia() async throws {
        let source = #"globalThis.__switchlyPlugin = { render(ctx) { return [{ slot: "center", node: { type: "text", value: Object.keys(ctx.media || {}).join(",") } }]; } };"#
        let p = PluginPackage(manifest: package(.user).manifest, directory: URL(fileURLWithPath: "/tmp/p"),
                              source: source, origin: .user)
        let ctx = PluginRenderContext(bundleID: "com.apple.Music", pid: 1, appName: "Music", windowID: 1, titleSummary: "")
        let none = try await PluginRuntime(package: p, mediaBridge: FakeMediaBridge(), permissions: []).render(context: ctx).get()
        XCTAssertEqual(none.first?.node, .text(value: "", style: .body, lines: nil))
        let read = try await PluginRuntime(package: p, mediaBridge: FakeMediaBridge(), permissions: [.mediaNowPlaying]).render(context: ctx).get()
        XCTAssertEqual(read.first?.node, .text(value: "nowPlaying", style: .body, lines: nil))
    }

    func testHostArtworkRequiresAuthorizedPlugin() async {
        let bridge = FakeMediaBridge()
        bridge.artworkData = Data([1, 2, 3])
        var grants: [String: PluginGrant] = [:]
        let host = PluginHost(registry: StubRegistry([package(.user)]), grants: { grants }, mediaBridge: bridge)
        let denied = await host.artwork(for: "com.apple.Music")
        XCTAssertNil(denied)
        grants["com.example.p"] = PluginGrant(isEnabled: true, permissions: ["media.nowPlaying"])
        let allowed = await host.artwork(for: "com.apple.Music")
        XCTAssertEqual(allowed, Data([1, 2, 3]))
    }

    func testSettingsWithoutPluginGrantsDecode() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any])
        object.removeValue(forKey: "pluginGrants")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.pluginGrants, [:])
    }
}
