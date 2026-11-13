import AppKit
import Combine
import XCTest
@testable import Switchly

@MainActor
final class PluginPanelConcurrencyTests: XCTestCase {
    func testSlowRenderQueuesActionUntilRenderFinishes() async {
        let renderStarted = expectation(description: "initial render started")
        let actionStarted = expectation(description: "queued action started")
        let renderFinished = expectation(description: "both renders finished")
        renderFinished.expectedFulfillmentCount = 2
        let runtime = PanelConcurrencyRuntime(renderStarted: renderStarted,
                                             actionStarted: actionStarted,
                                             renderFinished: renderFinished)
        let host = PanelConcurrencyHost(runtime: runtime)
        let model = PluginPanelModel(pluginID: runtime.manifest.id, host: host)
        defer {
            runtime.releaseFirstRender()
            model.stop()
        }

        model.start()
        await fulfillment(of: [renderStarted], timeout: 1)
        model.perform(id: "preset", value: 7)

        XCTAssertEqual(runtime.actionCalls, 0, "onAction must wait while render owns the pump")
        XCTAssertEqual(runtime.activeCalls, 1)

        runtime.releaseFirstRender()
        await fulfillment(of: [actionStarted, renderFinished], timeout: 2)

        XCTAssertEqual(runtime.maxConcurrentCalls, 1)
        XCTAssertEqual(runtime.events, [
            "render:start",
            "render:end",
            "action:start",
            "action:end",
            "render:start",
            "render:end",
        ])
    }

    func testQueuedActionResultWinsOverOlderInFlightRender() async {
        let renderStarted = expectation(description: "initial render started")
        let actionStarted = expectation(description: "queued action started")
        let renderFinished = expectation(description: "both renders finished")
        renderFinished.expectedFulfillmentCount = 2
        let freshPublished = expectation(description: "fresh action result published")
        let runtime = PanelConcurrencyRuntime(renderStarted: renderStarted,
                                             actionStarted: actionStarted,
                                             renderFinished: renderFinished,
                                             actionMutatesResult: true)
        let host = PanelConcurrencyHost(runtime: runtime)
        let model = PluginPanelModel(pluginID: runtime.manifest.id, host: host)
        let publication = model.$entries
            .dropFirst()
            .filter { entries in
                guard case .text(let value, _, _)? = entries.first?.node else { return false }
                return value == "fresh"
            }
            .prefix(1)
            .sink { _ in freshPublished.fulfill() }
        defer {
            publication.cancel()
            runtime.releaseFirstRender()
            model.stop()
        }

        model.start()
        await fulfillment(of: [renderStarted], timeout: 1)
        model.perform(id: "preset", value: 7)
        runtime.releaseFirstRender()

        await fulfillment(of: [actionStarted, renderFinished, freshPublished], timeout: 2)
        XCTAssertEqual(publishedText(in: model), "fresh")
    }

    func testStopDropsRenderThatFinishesAfterCancellation() async {
        let renderStarted = expectation(description: "initial render started")
        let renderReturned = expectation(description: "cancelled render returned")
        let runtime = PanelConcurrencyRuntime(renderStarted: renderStarted,
                                             actionStarted: nil,
                                             renderFinished: nil,
                                             renderReturned: renderReturned)
        let host = PanelConcurrencyHost(runtime: runtime)
        let model = PluginPanelModel(pluginID: runtime.manifest.id, host: host)
        defer { runtime.releaseFirstRender() }

        model.start()
        await fulfillment(of: [renderStarted], timeout: 1)
        model.stop()
        runtime.releaseFirstRender()
        await fulfillment(of: [renderReturned], timeout: 1)
        await Task.yield()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.isLoading)
    }

    func testInvalidatingActivityWhileQueryIsPendingRejectsResult() async throws {
        let queryStarted = expectation(description: "activity query started")
        let queryReturned = expectation(description: "activity query returned")
        let provider = ControlledActivityProvider(mode: .beforeQueryReturns,
                                                  queryStarted: queryStarted,
                                                  queryReturned: queryReturned)
        let fixture = try makeActivityRuntime(provider: provider)
        defer {
            provider.releaseQuery()
            fixture.runtime.unmount()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        async let rendering = fixture.runtime.render(context: fixture.context)
        await fulfillment(of: [queryStarted], timeout: 1)
        provider.gate.invalidate()
        provider.releaseQuery()

        let result = await rendering
        await fulfillment(of: [queryReturned], timeout: 1)
        let slots = try result.get()
        XCTAssertEqual(text(in: slots), "invalidated:activityInvalidated")
    }

    func testExpiredActivityCursorIsDistinctFromOtherFailureAndInvalidation() async throws {
        for (error, valid, expected) in [
            (ActivityDataError.staleCursor, true, "activityCursorExpired"),
            (.denied, true, "activityQueryFailed"),
            (.staleCursor, false, "activityInvalidated"),
        ] {
            let fixture = try makeActivityRuntime(provider: FailingActivityProvider(error: error, valid: valid))
            defer {
                fixture.runtime.unmount()
                try? FileManager.default.removeItem(at: fixture.directory)
            }
            let slots = try await fixture.runtime.render(context: fixture.context).get()
            XCTAssertEqual(text(in: slots), "invalidated:" + expected)
        }
    }

    func testInvalidatingAtDeliveryBoundaryRejectsAlreadyReturnedQuery() async throws {
        let queryReturned = expectation(description: "activity query returned")
        let deliveryCheckStarted = expectation(description: "activity delivery gate checked")
        let provider = ControlledActivityProvider(mode: .beforeQueueDelivery,
                                                  queryStarted: nil,
                                                  queryReturned: queryReturned,
                                                  deliveryCheckStarted: deliveryCheckStarted)
        let fixture = try makeActivityRuntime(provider: provider)
        defer {
            provider.releaseQuery()
            provider.releaseDeliveryCheck()
            fixture.runtime.unmount()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        async let rendering = fixture.runtime.render(context: fixture.context)
        await fulfillment(of: [queryReturned, deliveryCheckStarted], timeout: 1)
        provider.gate.invalidate()
        provider.releaseDeliveryCheck()

        let result = await rendering
        let slots = try result.get()
        XCTAssertEqual(text(in: slots), "invalidated:activityInvalidated")
    }

    func testPendingActivityReadStopsLoadingAndPublishesPermissions() async {
        let fixture = makePermissionFixture(.readPending)
        let model = fixture.model
        let settled = expectation(description: "pending activity permissions settled the loading state")
        let subscription = model.$isLoading
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in settled.fulfill() }
        defer {
            subscription.cancel()
            fixture.runtime.releaseFirstRender()
            model.stop()
        }

        model.start()
        await fulfillment(of: [settled], timeout: 1)

        XCTAssertEqual(model.pendingPermissions, [.activityRead, .activitySnapshots])
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(fixture.host.panelLoadCount, 0, "pending activity.read must not load a runtime")
        XCTAssertGreaterThanOrEqual(fixture.host.installedPluginsCallCount, 1)
        XCTAssertTrue(fixture.host.installedPluginsCalledOffMain)
        XCTAssertTrue(fixture.runtime.authorizedPermissions.isEmpty)
        XCTAssertEqual(fixture.runtime.events, [])
    }

    func testPendingSnapshotsStillLoadsRuntimeWithActivityRead() async {
        let fixture = makePermissionFixture(.readGrantedSnapshotsPending)
        let model = fixture.model
        fixture.runtime.releaseFirstRender()
        let rendered = expectation(description: "panel rendered with activity.read")
        let subscription = model.$entries
            .dropFirst()
            .filter { !$0.isEmpty }
            .prefix(1)
            .sink { _ in rendered.fulfill() }
        defer {
            subscription.cancel()
            model.stop()
        }

        model.start()
        await fulfillment(of: [rendered], timeout: 2)

        XCTAssertEqual(publishedText(in: model), "stale")
        XCTAssertEqual(model.pendingPermissions, [.activitySnapshots])
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(fixture.host.panelLoadCount, 1)
        XCTAssertEqual(fixture.host.installedPlugins().first?.authorization.permissions,
                       Set<PluginCapability>([.activityRead]))
        XCTAssertEqual(fixture.runtime.authorizedPermissions, Set<PluginCapability>([.activityRead]))
        XCTAssertEqual(fixture.runtime.events, ["render:start", "render:end"])
    }

    func testGrantingPermissionsAfterSettingsChangeReloadsAndRenders() async {
        let fixture = makePermissionFixture(.readPending)
        let model = fixture.model
        fixture.runtime.releaseFirstRender()
        defer { model.stop() }

        let pendingSettled = expectation(description: "pending activity permissions settled the loading state")
        let pendingSubscription = model.$isLoading
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in pendingSettled.fulfill() }
        model.start()
        await fulfillment(of: [pendingSettled], timeout: 1)
        pendingSubscription.cancel()
        XCTAssertEqual(fixture.host.panelLoadCount, 0)
        XCTAssertEqual(model.pendingPermissions, [.activityRead, .activitySnapshots])

        let rendered = expectation(description: "settings change rendered a newly granted runtime")
        let renderSubscription = model.$entries
            .dropFirst()
            .filter { !$0.isEmpty }
            .prefix(1)
            .sink { _ in rendered.fulfill() }
        defer { renderSubscription.cancel() }

        let queriesBeforeChange = fixture.host.installedPluginsCallCount
        fixture.host.setPermissionState(.allGranted)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        await fulfillment(of: [rendered], timeout: 2)

        XCTAssertEqual(publishedText(in: model), "stale")
        XCTAssertTrue(model.pendingPermissions.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(fixture.host.panelLoadCount, 1)
        XCTAssertGreaterThan(fixture.host.installedPluginsCallCount, queriesBeforeChange)
        XCTAssertTrue(fixture.host.installedPluginsCalledOffMain)
        XCTAssertEqual(fixture.runtime.authorizedPermissions,
                       Set<PluginCapability>([.activityRead, .activitySnapshots]))
        XCTAssertEqual(fixture.runtime.events, ["render:start", "render:end"])
    }

    private func makePermissionFixture(_ state: PanelActivityPermissionState) -> (
        runtime: PanelConcurrencyRuntime,
        host: PanelConcurrencyHost,
        model: PluginPanelModel
    ) {
        let runtime = PanelConcurrencyRuntime(renderStarted: nil,
                                             actionStarted: nil,
                                             renderFinished: nil,
                                             manifestPermissions: [.activityRead, .activitySnapshots])
        let host = PanelConcurrencyHost(runtime: runtime, permissionState: state)
        let model = PluginPanelModel(pluginID: runtime.manifest.id, host: host)
        return (runtime, host, model)
    }

    private func publishedText(in model: PluginPanelModel) -> String? {
        guard case .text(let value, _, _)? = model.entries.first?.node else { return nil }
        return value
    }

    private func text(in slots: [PluginSlotContent]) -> String? {
        guard case .text(let value, _, _)? = slots.first?.node else { return nil }
        return value
    }

    private func makeActivityRuntime(provider: PluginActivityProviding) throws -> (
        runtime: PluginRuntime,
        context: PluginRenderContext,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-plugin-panel-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = PluginManifest(
            id: "com.example.panel-concurrency",
            name: ["en": "Panel Concurrency"],
            version: "1",
            apiVersion: 2,
            matches: ["com.example.host"],
            permissions: [.activityRead],
            entry: "main.js",
            refreshInterval: nil
        )
        manifest.surfaces = ["panel"]
        manifest.defaultEnabled = true
        let source = """
        globalThis.__switchlyPlugin = {
          async render(ctx) {
            let outcome = "unexpected";
            try {
              const value = await ctx.activity.summary({});
              outcome = "old:" + value.items[0].name;
            } catch (error) {
              outcome = "invalidated:" + String(error);
            }
            return [{ slot: "panel", node: { type: "text", value: outcome } }];
          },
          onAction(ctx, id, value) { return null; }
        };
        """
        let package = PluginPackage(manifest: manifest, directory: directory, source: source, origin: .builtin)
        let context = PluginRenderContext(bundleID: "", pid: 0, appName: "", windowID: 0,
                                         titleSummary: "", presentationID: UUID().uuidString, surface: "panel")
        return (
            PluginRuntime(package: package, timeout: 2, permissions: [.activityRead],
                          activityProvider: provider),
            context,
            directory
        )
    }
}

private final class PanelConcurrencyRuntime: PluginRuntimeProtocol, @unchecked Sendable {
    let manifest: PluginManifest
    var onInvalidate: (() -> Void)?

    private let lock = NSLock()
    private let firstRenderGate = AsyncGate()
    private let renderStarted: XCTestExpectation?
    private let actionStarted: XCTestExpectation?
    private let renderFinished: XCTestExpectation?
    private let renderReturned: XCTestExpectation?
    private let actionMutatesResult: Bool
    private var value = "stale"
    private var concurrentCalls = 0
    private var recordedMaxConcurrentCalls = 0
    private var recordedEvents: [String] = []
    private var recordedRenderCalls = 0
    private var recordedActionCalls = 0
    private var recordedPermissions: Set<PluginCapability>

    init(renderStarted: XCTestExpectation?,
         actionStarted: XCTestExpectation?,
         renderFinished: XCTestExpectation?,
         renderReturned: XCTestExpectation? = nil,
         actionMutatesResult: Bool = false,
         manifestPermissions: [PluginCapability] = []) {
        self.renderStarted = renderStarted
        self.actionStarted = actionStarted
        self.renderFinished = renderFinished
        self.renderReturned = renderReturned
        self.actionMutatesResult = actionMutatesResult
        self.recordedPermissions = []
        var manifest = PluginManifest(
            id: "com.example.panel-concurrency-fake",
            name: ["en": "Panel Concurrency Fake"],
            version: "1",
            apiVersion: 2,
            matches: ["com.example.host"],
            permissions: manifestPermissions,
            entry: "main.js",
            refreshInterval: nil
        )
        manifest.surfaces = ["panel"]
        self.manifest = manifest
    }

    var activeCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return concurrentCalls
    }

    var maxConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaxConcurrentCalls
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var actionCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedActionCalls
    }

    var authorizedPermissions: Set<PluginCapability> {
        lock.lock()
        defer { lock.unlock() }
        return recordedPermissions
    }

    func setAuthorizedPermissions(_ permissions: Set<PluginCapability>) {
        lock.lock()
        recordedPermissions = permissions
        lock.unlock()
    }

    func releaseFirstRender() {
        firstRenderGate.release()
    }

    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        let call = begin("render")
        let renderedValue = currentValue()
        if call == 1 {
            renderStarted?.fulfill()
            await firstRenderGate.wait()
        }
        end("render")
        renderFinished?.fulfill()
        renderReturned?.fulfill()
        return .success([PluginSlotContent(slot: .panel,
                                          node: .text(value: renderedValue, style: .body, lines: nil))])
    }

    func performAction(id: String, value: Double?,
                       context: PluginRenderContext) async -> Result<Void, PluginRuntimeError> {
        _ = begin("action")
        actionStarted?.fulfill()
        if actionMutatesResult {
            markResultFresh()
        }
        end("action")
        return .success(())
    }

    func suspend() {}
    func resume() {}
    func unmount() {}

    private func begin(_ method: String) -> Int {
        lock.lock()
        concurrentCalls += 1
        recordedMaxConcurrentCalls = max(recordedMaxConcurrentCalls, concurrentCalls)
        recordedEvents.append("\(method):start")
        let call: Int
        if method == "render" {
            recordedRenderCalls += 1
            call = recordedRenderCalls
        } else {
            recordedActionCalls += 1
            call = recordedActionCalls
        }
        lock.unlock()
        return call
    }

    private func currentValue() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    private func markResultFresh() {
        lock.lock()
        value = "fresh"
        lock.unlock()
    }

    private func end(_ method: String) {
        lock.lock()
        recordedEvents.append("\(method):end")
        concurrentCalls -= 1
        lock.unlock()
    }
}

private enum PanelActivityPermissionState {
    case readPending
    case readGrantedSnapshotsPending
    case allGranted

    var grantPermissions: [PluginCapability] {
        switch self {
        case .readPending: return []
        case .readGrantedSnapshotsPending: return [.activityRead]
        case .allGranted: return [.activityRead, .activitySnapshots]
        }
    }
}

private final class PanelConcurrencyHost: PluginHosting, @unchecked Sendable {
    let runtime: PluginRuntimeProtocol
    private let lock = NSLock()
    private var permissionState: PanelActivityPermissionState?
    private var recordedPanelLoads = 0
    private var recordedInstalledPluginsCalls = 0
    private var recordedInstalledPluginsOffMain = false

    init(runtime: PluginRuntimeProtocol, permissionState: PanelActivityPermissionState? = nil) {
        self.runtime = runtime
        self.permissionState = permissionState
    }

    var panelLoadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedPanelLoads
    }

    var installedPluginsCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedInstalledPluginsCalls
    }

    var installedPluginsCalledOffMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedInstalledPluginsOffMain
    }

    func setPermissionState(_ state: PanelActivityPermissionState) {
        lock.lock()
        permissionState = state
        lock.unlock()
    }

    func runtimes(for bundleID: String) -> [PluginRuntimeProtocol] { [] }
    func installedPlugins() -> [InstalledPlugin] {
        recordInstalledPluginsRead()
        guard let authorization = authorization() else { return [] }
        let package = PluginPackage(manifest: runtime.manifest,
                                    directory: FileManager.default.temporaryDirectory,
                                    source: "",
                                    origin: .builtin)
        return [InstalledPlugin(package: package, authorization: authorization)]
    }
    func artwork(for bundleID: String) async -> Data? { nil }
    func loadPanelRuntime(pluginID: String) async -> PluginRuntimeProtocol? {
        recordPanelLoad()
        if let authorization = authorization() {
            (runtime as? PanelConcurrencyRuntime)?.setAuthorizedPermissions(authorization.permissions)
        }
        return runtime
    }
    func unmountAll() {}
    func reload() {}

    private func authorization() -> PluginAuthorization? {
        lock.lock()
        let state = permissionState
        lock.unlock()
        guard let state else { return nil }
        let grant = PluginGrant(isEnabled: true,
                                permissions: state.grantPermissions.map { $0.rawValue })
        return PluginAuthorization.resolve(manifest: runtime.manifest, origin: .builtin, grant: grant)
    }

    private func recordPanelLoad() {
        lock.lock()
        recordedPanelLoads += 1
        lock.unlock()
    }

    private func recordInstalledPluginsRead() {
        lock.lock()
        recordedInstalledPluginsCalls += 1
        if !Thread.isMainThread { recordedInstalledPluginsOffMain = true }
        lock.unlock()
    }
}

private enum ActivityQueryBoundary {
    case beforeQueryReturns
    case beforeQueueDelivery
}

private final class FailingActivityProvider: PluginActivityProviding {
    let error: ActivityDataError
    let valid: Bool
    init(error: ActivityDataError, valid: Bool) { self.error = error; self.valid = valid }
    func readValidity() -> PluginActivityReadValidity {
        let valid = valid
        return PluginActivityReadValidity { valid }
    }
    func query(method: String, options: [String: Any], pluginID: String,
               snapshotsAllowed: Bool) async throws -> [String: Any] {
        throw error
    }
}

private final class ControlledActivityProvider: PluginActivityProviding, @unchecked Sendable {
    let gate = PluginActivityValidityGate()

    private let mode: ActivityQueryBoundary
    private let queryStarted: XCTestExpectation?
    private let queryReturned: XCTestExpectation?
    private let deliveryCheckStarted: XCTestExpectation?
    private let queryGate = BlockingGate()
    private let deliveryGate = BlockingGate()

    init(mode: ActivityQueryBoundary,
         queryStarted: XCTestExpectation?,
         queryReturned: XCTestExpectation?,
         deliveryCheckStarted: XCTestExpectation? = nil) {
        self.mode = mode
        self.queryStarted = queryStarted
        self.queryReturned = queryReturned
        self.deliveryCheckStarted = deliveryCheckStarted
    }

    func readValidity() -> PluginActivityReadValidity {
        let captured = gate.capture()
        guard mode == .beforeQueueDelivery else { return captured }
        return PluginActivityReadValidity { [weak self] in
            guard let self else { return false }
            self.deliveryCheckStarted?.fulfill()
            self.deliveryGate.wait()
            return captured.isCurrent()
        }
    }

    func query(method: String, options: [String: Any], pluginID: String,
               snapshotsAllowed: Bool) async throws -> [String: Any] {
        queryStarted?.fulfill()
        if mode == .beforeQueryReturns {
            queryGate.wait()
        }
        queryReturned?.fulfill()
        return [
            "items": [["bundleID": "com.example.old", "name": "old-result", "seconds": 60, "sessions": 1]],
            "availableFrom": NSNull(),
            "revision": 1,
            "recording": false,
            "screenshotsEnabled": false,
        ]
    }

    func releaseQuery() {
        queryGate.release()
    }

    func releaseDeliveryCheck() {
        deliveryGate.release()
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
