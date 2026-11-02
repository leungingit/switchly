import Foundation
import XCTest
@testable import Switchly

@MainActor
final class PluginLifecycleTests: XCTestCase {
    private let context = PluginRenderContext(
        bundleID: "com.example.host",
        pid: 42,
        appName: "Host",
        windowID: 7,
        titleSummary: "Window"
    )

    func testDuplicateActionIDsRouteToTheirOwnPlugin() async throws {
        let first = TestRuntime(id: "com.example.first", node: actionNode)
        let second = TestRuntime(id: "com.example.second", node: actionNode)
        let host = TestHost(runtimes: [first, second])
        let model = DockPluginOverlayModel(host: host)
        let rendered = expectation(description: "both plugins rendered")
        rendered.expectedFulfillmentCount = 2
        first.onRender = { rendered.fulfill() }
        second.onRender = { rendered.fulfill() }

        model.start(context: context)
        await fulfillment(of: [rendered], timeout: 1)
        first.onRender = nil
        second.onRender = nil
        let entries = try XCTUnwrap(model.slots[.center])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0.node.actionIDs }, [["toggle"], ["toggle"]])
        XCTAssertNotEqual(PluginActionNamespace(pluginID: first.manifest.id, actionID: "toggle").identifier,
                          PluginActionNamespace(pluginID: second.manifest.id, actionID: "toggle").identifier)

        let firstCalled = expectation(description: "first action")
        let secondCalled = expectation(description: "second action")
        first.onAction = { firstCalled.fulfill() }
        second.onAction = { secondCalled.fulfill() }
        model.perform(pluginID: first.manifest.id, actionID: "toggle")
        model.perform(pluginID: second.manifest.id, actionID: "toggle")
        await fulfillment(of: [firstCalled, secondCalled], timeout: 1)

        XCTAssertEqual(first.actions, ["toggle"])
        XCTAssertEqual(second.actions, ["toggle"])
        model.stop()
    }

    func testLegacyPerformStillAcceptsUniqueRawActionID() async throws {
        let runtime = TestRuntime(id: "com.example.legacy", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)
        let rendered = expectation(description: "plugin rendered")
        runtime.onRender = { rendered.fulfill() }

        model.start(context: context)
        await fulfillment(of: [rendered], timeout: 1)
        runtime.onRender = nil
        let called = expectation(description: "legacy action")
        runtime.onAction = { called.fulfill() }
        model.perform(actionID: "toggle")
        await fulfillment(of: [called], timeout: 1)
        XCTAssertEqual(runtime.actions, ["toggle"])
        model.stop()
    }

    func testStartResumesAndStopSuspendsWithoutUnmounting() {
        let runtime = TestRuntime(id: "com.example.lifecycle", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)

        model.start(context: context)
        XCTAssertEqual(runtime.resumeCount, 1)
        XCTAssertEqual(runtime.suspendCount, 0)
        XCTAssertEqual(runtime.unmountCount, 0)

        model.stop()
        XCTAssertEqual(runtime.suspendCount, 1)
        XCTAssertEqual(runtime.unmountCount, 0)

        model.start(context: context)
        XCTAssertEqual(runtime.resumeCount, 2)
        model.stop()
    }

    func testAuthorizationRefreshDetachesPreviouslyVisibleRuntime() {
        let runtime = TestRuntime(id: "com.example.revoked", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)
        model.start(context: context)
        host.runtimes = []
        model.reloadCurrentContext()
        XCTAssertEqual(runtime.suspendCount, 1)
        XCTAssertTrue(model.slots.isEmpty)
        XCTAssertNil(runtime.onInvalidate)
    }

    func testSuspendReleasesPendingCallAndPausesTimers() async throws {
        let source = """
        let fired = 0;
        let latestCtx = null;
        globalThis.__switchlyPlugin = {
          render() {
            return [{ slot: "center", node: { type: "badge", value: String(fired), tone: "neutral" } }];
          },
          onAction(ctx) {
            latestCtx = ctx;
            return new Promise(function (resolve) {
              setTimeout(function () {
                fired += 1;
                latestCtx.invalidate();
                resolve();
              }, 40);
            });
          }
        };
        """
        let (runtime, root) = try makeRuntime(source: source, timeout: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await runtime.render(context: context).get()

        let invalidated = expectation(description: "timer resumed")
        let invalidations = LockedCounter()
        runtime.onInvalidate = {
            invalidations.increment()
            invalidated.fulfill()
        }
        let pendingAction = Task {
            await runtime.performAction(id: "start", value: nil, context: self.context)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        runtime.suspend()

        let result = await pendingAction.value
        XCTAssertEqual(result.map { _ in 0 }, .failure(.suspended))
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(invalidations.value, 0)

        runtime.resume()
        await fulfillment(of: [invalidated], timeout: 1)
        let rendered = try await runtime.render(context: context).get()
        XCTAssertEqual(rendered.first?.node, .badge(value: "1", tone: .neutral))
    }

    func testStorageIsInjectedIntoPluginContext() async throws {
        let source = """
        globalThis.__switchlyPlugin = {
          async render(ctx) {
            await ctx.storage.set("count", 7);
            const value = await ctx.storage.get("count");
            return [{ slot: "center", node: { type: "text", value: String(value) } }];
          }
        };
        """
        let storage = TestStorage()
        let (runtime, root) = try makeRuntime(source: source, timeout: 1, storage: storage)
        defer { try? FileManager.default.removeItem(at: root) }

        let rendered = try await runtime.render(context: context).get()
        XCTAssertEqual(rendered.first?.node, .text(value: "7", style: .body, lines: nil))
        XCTAssertEqual((storage.values["count"] as? NSNumber)?.intValue, 7)
    }

    func testUnmountDoesNotWaitForBusyPluginQueue() async throws {
        let source = """
        globalThis.__switchlyPlugin = {
          render() {
            const until = Date.now() + 120;
            while (Date.now() < until) {}
            return [];
          }
        };
        """
        let (runtime, root) = try makeRuntime(source: source, timeout: 0.02)
        defer { try? FileManager.default.removeItem(at: root) }
        let rendering = Task { await runtime.render(context: self.context) }
        try await Task.sleep(nanoseconds: 10_000_000)

        let started = DispatchTime.now().uptimeNanoseconds
        runtime.unmount()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        XCTAssertLessThan(elapsed, 50)
        _ = await rendering.value
    }

    private var actionNode: PluginUINode {
        .button(id: "toggle", symbol: "play.fill", label: "Play", size: .m,
                variant: .plain, enabled: true, selected: false)
    }

    private func makeRuntime(source: String,
                             timeout: TimeInterval,
                             storage: PluginStorageProviding? = nil) throws -> (PluginRuntime, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginLifecycleTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        {"id":"com.example.lifecycle","name":{"en":"Lifecycle"},"version":"1","apiVersion":1,
         "matches":["com.example.host"],"permissions":[],"entry":"main.js"}
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try source.write(to: directory.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        let package = try XCTUnwrap(PluginRegistry(directory: root).reload().plugins.first)
        return (PluginRuntime(package: package, timeout: timeout, storage: storage), root)
    }
}

private final class TestRuntime: PluginRuntimeProtocol {
    let manifest: PluginManifest
    let node: PluginUINode
    var onInvalidate: (() -> Void)?
    var assetDirectory: URL? { nil }
    var onRender: (() -> Void)?
    var onAction: (() -> Void)?
    private(set) var actions: [String] = []
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    private(set) var unmountCount = 0

    init(id: String, node: PluginUINode) {
        self.manifest = PluginManifest(
            id: id,
            name: ["en": id],
            version: "1",
            apiVersion: 1,
            matches: ["com.example.host"],
            permissions: [],
            entry: "main.js",
            refreshInterval: nil
        )
        self.node = node
    }

    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        onRender?()
        return .success([PluginSlotContent(slot: .center, node: node)])
    }

    func performAction(id: String, value: Double?,
                       context: PluginRenderContext) async -> Result<Void, PluginRuntimeError> {
        actions.append(id)
        onAction?()
        return .success(())
    }

    func suspend() { suspendCount += 1 }
    func resume() { resumeCount += 1 }
    func unmount() { unmountCount += 1 }
}

private final class TestHost: PluginHosting {
    var runtimes: [PluginRuntimeProtocol]

    init(runtimes: [PluginRuntimeProtocol]) {
        self.runtimes = runtimes
    }

    func runtimes(for bundleID: String) -> [PluginRuntimeProtocol] { runtimes }
    func installedPlugins() -> [InstalledPlugin] { [] }
    func artwork(for bundleID: String) async -> Data? { nil }
    func unmountAll() { runtimes.forEach { $0.unmount() } }
    func reload() {}
}

private final class TestStorage: PluginStorageProviding {
    var values: [String: Any] = [:]

    func get(_ key: String) throws -> Any? { values[key] }
    func set(_ key: String, value: Any) throws { values[key] = value }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
    func clear() throws { values.removeAll() }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
