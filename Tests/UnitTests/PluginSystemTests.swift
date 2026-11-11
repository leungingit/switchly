import Foundation
import AppKit
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

    func testCapabilitySnapshotDoesNotMistakeDeclarationForImplementation() async throws {
        let source = """
        globalThis.__switchlyPlugin = { render(ctx) {
          return [{slot:"center",node:{type:"text",value:JSON.stringify([
            ctx.capabilities["media.control"].supported,
            ctx.capabilities["media.control"].available,
            ctx.capabilities["window.focus"].supported
          ])}}];
        }};
        """
        let result = try await runtime(source: source).render(context: context).get()
        XCTAssertEqual(result.first?.node, .text(value: "[true,false,false]", style: .body, lines: nil))
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
    /// Simulates Music answering Apple Events slowly (queued skips).
    var nowPlayingDelay: TimeInterval = 0
    func supports(bundleID: String) -> Bool { bundleID == "com.apple.Music" }
    func artwork(bundleID: String) throws -> Data? { artworkData }
    func nowPlaying(bundleID: String) throws -> NowPlaying? {
        if nowPlayingDelay > 0 { Thread.sleep(forTimeInterval: nowPlayingDelay) }
        return current
    }
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


}

// MARK: - Music toggle state reconciliation

/// Music's `player state` can lag `playpause`. The bridge must publish the
/// requested state on the very next render, without waiting inside a script,
/// and must stop doing so as soon as Music agrees or the deadline expires.
final class MediaPlayStateReconciliationTests: XCTestCase {
    private func snapshot(_ playing: Bool) -> NowPlaying {
        NowPlaying(isPlaying: playing, title: "Song", artist: "Artist", album: "Album",
                   position: 30, duration: 120, liked: false, canLike: true)
    }

    func testStalePlayerStateIsOverriddenImmediately() {
        let now = DispatchTime.now()
        let pending = MediaPlayStateExpectation(isPlaying: false, deadline: now + .milliseconds(600))
        let resolved = MediaPlayStateReconciler.resolve(snapshot: snapshot(true), last: nil,
                                                        expectation: pending, now: now)
        XCTAssertEqual(resolved.snapshot?.isPlaying, false)
        XCTAssertEqual(resolved.snapshot?.title, "Song", "track metadata must survive the override")
        XCTAssertNotNil(resolved.expectation)
    }

    func testExpectationClearsOnceMusicCatchesUp() {
        let now = DispatchTime.now()
        let pending = MediaPlayStateExpectation(isPlaying: false, deadline: now + .milliseconds(600))
        let resolved = MediaPlayStateReconciler.resolve(snapshot: snapshot(false), last: nil,
                                                        expectation: pending, now: now)
        XCTAssertEqual(resolved.snapshot?.isPlaying, false)
        XCTAssertNil(resolved.expectation)
    }

    func testExpiredExpectationCannotFakePlaybackState() {
        let now = DispatchTime.now()
        let expired = MediaPlayStateExpectation(isPlaying: false, deadline: now + .milliseconds(-1))
        let resolved = MediaPlayStateReconciler.resolve(snapshot: snapshot(true), last: nil,
                                                        expectation: expired, now: now)
        XCTAssertEqual(resolved.snapshot?.isPlaying, true)
        XCTAssertNil(resolved.expectation)
    }

    func testStoppedSnapshotKeepsLastTrackWhileTransportSettles() {
        let now = DispatchTime.now()
        let pending = MediaPlayStateExpectation(isPlaying: true, deadline: now + .milliseconds(600))
        let resolved = MediaPlayStateReconciler.resolve(snapshot: nil, last: snapshot(false),
                                                        expectation: pending, now: now)
        XCTAssertEqual(resolved.snapshot?.isPlaying, true)
        XCTAssertEqual(resolved.snapshot?.title, "Song")
        XCTAssertNotNil(resolved.expectation)
    }

    func testWithoutPendingToggleTheRealSnapshotIsUntouched() {
        let resolved = MediaPlayStateReconciler.resolve(snapshot: snapshot(true), last: snapshot(false),
                                                        expectation: nil, now: .now())
        XCTAssertEqual(resolved.snapshot, snapshot(true))
        XCTAssertNil(resolved.expectation)
    }

    /// Music reports a streaming track's cover one queue position late, so
    /// those covers must fall back to the placeholder; library tracks keep theirs.
    func testStreamingTrackArtworkIsNotTrusted() {
        XCTAssertFalse(MusicAppleScriptBridge.trustsArtwork(trackClass: "URL track"))
        XCTAssertTrue(MusicAppleScriptBridge.trustsArtwork(trackClass: "file track"))
        XCTAssertTrue(MusicAppleScriptBridge.trustsArtwork(trackClass: "shared track"))
    }
}

// MARK: - Authorization and host

private final class StubRegistry: PluginRegistryProtocol {
    var plugins: [PluginPackage]
    init(_ plugins: [PluginPackage]) { self.plugins = plugins }
    func reload() -> (plugins: [PluginPackage], failures: [PluginLoadFailure]) { (plugins, []) }
}

private final class GatedRegistry: PluginRegistryProtocol {
    let began: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(began: XCTestExpectation) { self.began = began }
    func reload() -> (plugins: [PluginPackage], failures: [PluginLoadFailure]) {
        XCTAssertFalse(Thread.isMainThread, "包扫描与 GLB 预检不能阻塞面板主线程")
        began.fulfill()
        _ = release.wait(timeout: .now() + 2)
        return ([], [])
    }
}

private final class WarmRuntime: PluginRuntimeProtocol {
    let manifest: PluginManifest
    var onInvalidate: (() -> Void)?
    private let onWarm: @MainActor (Int) async -> Void
    private let lock = NSLock()
    private var calls = 0
    init(manifest: PluginManifest, onWarm: @escaping @MainActor (Int) async -> Void) {
        self.manifest = manifest
        self.onWarm = onWarm
    }
    private func nextCall() -> Int {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls
    }
    func prewarmEngine() async { await onWarm(nextCall()) }
    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> { .success([]) }
    func performAction(id: String, value: Double?, context: PluginRenderContext) async -> Result<Void, PluginRuntimeError> { .success(()) }
    func unmount() {}
}

final class PluginAuthorizationTests: XCTestCase {
    @MainActor
    func testRapidHoverWarmupKeepsOnlyOneLatestPendingTarget() async throws {
        let manifest = PluginManifest(id: "com.example.warm", name: ["en":"Warm"], version: "1", apiVersion: 1,
            matches: ["com.apple.Music", "com.apple.finder", "com.apple.Safari"], permissions: [], entry: "main.js", refreshInterval: nil)
        let package = PluginPackage(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/warm"), source: "", origin: .builtin)
        let began = expectation(description: "first engine warmup began")
        let second = expectation(description: "only latest pending warmup runs")
        let unexpected = expectation(description: "intermediate pending target discarded")
        unexpected.isInverted = true
        var finishFirst: (() -> Void)?
        let runtime = WarmRuntime(manifest: manifest) { count in
            if count == 1 {
                await withCheckedContinuation { continuation in
                    finishFirst = { continuation.resume() }
                    began.fulfill()
                }
            } else if count == 2 { second.fulfill() } else { unexpected.fulfill() }
        }
        let host = PluginHost(registry: StubRegistry([package]), grants: { [:] }, mediaBridge: FakeMediaBridge(),
                              makeRuntime: { _, _ in runtime })
        defer { finishFirst?(); host.unmountAll() }
        let music = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music"))
        let finder = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        let safari = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"))
        host.prewarmEngine(for: music)
        await fulfillment(of: [began], timeout: 2)
        host.prewarmEngine(for: finder)
        host.prewarmEngine(for: safari)
        finishFirst?(); finishFirst = nil
        await fulfillment(of: [second], timeout: 2)
        await fulfillment(of: [unexpected], timeout: 0.1)
    }
    @MainActor
    func testAsyncPluginDiscoveryLeavesMainThreadAvailable() async {
        let began = expectation(description: "background package scan began")
        let finished = expectation(description: "package scan returned")
        let registry = GatedRegistry(began: began)
        let host = PluginHost(registry: registry, grants: { [:] }, mediaBridge: FakeMediaBridge())
        let task = Task {
            let runtimes = await host.loadRuntimes(for: "com.apple.Music")
            XCTAssertTrue(runtimes.isEmpty)
            finished.fulfill()
        }
        defer { registry.release.signal(); task.cancel() }
        await fulfillment(of: [began], timeout: 1)
        registry.release.signal()
        await fulfillment(of: [finished], timeout: 1)
    }
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

    func testTimeoutsWaitingOnHostDoNotDisablePlugin() async throws {
        let source = #"globalThis.__switchlyPlugin = { render(ctx) { return ctx.media.nowPlaying().then(n => [{ slot: "center", node: { type: "text", value: n ? n.title : "-" } }]); } };"#
        let p = PluginPackage(manifest: package(.user).manifest, directory: URL(fileURLWithPath: "/tmp/p"),
                              source: source, origin: .user)
        let ctx = PluginRenderContext(bundleID: "com.apple.Music", pid: 1, appName: "Music", windowID: 1, titleSummary: "")
        let bridge = FakeMediaBridge()
        bridge.nowPlayingDelay = 0.1
        let rt = PluginRuntime(package: p, timeout: 0.02, mediaBridge: bridge, permissions: [.mediaNowPlaying])
        for _ in 0..<4 {
            let result = await rt.render(context: ctx)
            XCTAssertEqual(result.map { _ in 0 }, .failure(.timedOut))
        }
        XCTAssertFalse(rt.isDisabled)
        bridge.nowPlayingDelay = 0
        try await Task.sleep(nanoseconds: 500_000_000)  // drain the queued slow reads
        let recovered = try await rt.render(context: ctx).get()
        XCTAssertEqual(recovered.first?.node, .text(value: "Song", style: .body, lines: nil))
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
