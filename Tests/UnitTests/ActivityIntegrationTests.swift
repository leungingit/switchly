import AppKit
import XCTest
@testable import Switchly

private final class ActivityTestProvider: PluginActivityProviding {
    func query(method: String, options: [String: Any], pluginID: String, snapshotsAllowed: Bool) async throws -> [String: Any] {
        if method == "summary" {
            return ["items": [["bundleID": "com.example.test", "name": "测试应用", "seconds": 600, "sessions": 1]], "availableFrom": NSNull(), "revision": 1, "recording": false, "screenshotsEnabled": false]
        }
        return ["items": [], "nextCursor": NSNull(), "revision": 1]
    }
}

final class ActivityIntegrationTests: XCTestCase {
    func testSettingsDefaultsAndPartialDecodeStayOff() throws {
        let value = try JSONDecoder().decode(ActivityTrackingSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(value.enabled); XCTAssertFalse(value.screenshotsEnabled)
        XCTAssertEqual(value.resolvedRetentionDays, 400)
        XCTAssertTrue(value.screenshotBundleIDs.isEmpty)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings.default))
        XCTAssertFalse(legacy.activityTracking.enabled)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "activityTracking")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.activityTracking.enabled)
    }
    func testBuiltinsNeedExplicitActivityGrantsAndPanelDoesNotMatchDock() async throws {
        let package = try package()
        let denied = PluginAuthorization.resolve(manifest: package.manifest, origin: .builtin, grant: nil)
        XCTAssertFalse(denied.isEnabled)
        XCTAssertFalse(denied.permissions.contains(.activityRead)); XCTAssertFalse(denied.permissions.contains(.activitySnapshots))
        XCTAssertEqual(Set(denied.pendingPermissions), [.activityRead, .activitySnapshots])
        XCTAssertTrue(package.manifest.supportsPanel); XCTAssertFalse(package.manifest.supportsDock)
        let host = PluginHost(registry: PluginRegistry(directory: package.directory.deletingLastPathComponent(), origin: .builtin), grants: { [:] }, mediaBridge: ActivityNoMedia())
        XCTAssertTrue(host.runtimes(for: "com.apple.Music").allSatisfy { $0.manifest.id != package.manifest.id })
        let panel = await host.loadPanelRuntime(pluginID: package.manifest.id)
        XCTAssertNil(panel)
    }
    func testRealExternalPluginRendersThroughJSCAndHostDecoder() async throws {
        let package = try package()
        let runtime = PluginRuntime(package: package, timeout: 2, preferredLanguages: ["zh-Hans"], permissions: [.activityRead, .activitySnapshots], activityProvider: ActivityTestProvider())
        let context = PluginRenderContext(bundleID: "", pid: 0, appName: "", windowID: 0, titleSummary: "", presentationID: "test-panel", surface: "panel")
        let output = try await runtime.render(context: context).get()
        XCTAssertEqual(output.map(\.slot), [.panel]); XCTAssertLessThanOrEqual(output.reduce(0) { $0 + $1.node.nodeCount }, 64)
        XCTAssertTrue(output[0].node.actionIDs.contains("timeline-preset"))
        try await runtime.performAction(id: "timeline-preset", value: 5, context: context).get()
        let custom = try await runtime.render(context: context).get()
        XCTAssertTrue(custom[0].node.actionIDs.contains("timeline-range.from"))
        runtime.unmount()
    }
    func testExternalPanelRecoversExpiredCursorThroughRealBridgeWithinCallBudget() async throws {
        let provider = ExpiringActivityTestProvider()
        let runtime = PluginRuntime(package: try package(), timeout: 2, preferredLanguages: ["en"],
                                    permissions: [.activityRead], activityProvider: provider)
        defer { runtime.unmount() }
        let context = PluginRenderContext(bundleID: "", pid: 0, appName: "", windowID: 0,
                                          titleSummary: "", presentationID: "cursor-recovery", surface: "panel")
        let first = try await runtime.render(context: context).get()
        XCTAssertTrue(first[0].node.actionIDs.contains("sessions-page-next"))
        let callsBefore = provider.queryCount
        try await runtime.performAction(id: "sessions-page-next", value: 0, context: context).get()
        let recovered = try await runtime.render(context: context).get()
        XCTAssertTrue(nodeText(recovered).contains { $0.contains("Activity records updated; returned to the first page.") })
        XCTAssertEqual(provider.queryCount - callsBefore, 6, "Two settled batches of summary, sessions and trend")
        XCTAssertLessThanOrEqual(recovered.reduce(0) { $0 + $1.node.nodeCount }, 64)
    }
    func testHostLanguageChangeRebuildsPanelRuntimeAndLocalizesJSCContent() async throws {
        let package = try package()
        let language = LockedActivityLanguage("zh-Hans")
        let grant = PluginGrant(isEnabled: true, permissions: [PluginCapability.activityRead.rawValue,
                                                               PluginCapability.activitySnapshots.rawValue])
        let host = PluginHost(
            registry: PluginRegistry(directory: package.directory.deletingLastPathComponent(), origin: .builtin),
            grants: { [package.manifest.id: grant] },
            mediaBridge: ActivityNoMedia(),
            preferredLanguages: { [language.value] },
            pluginSettings: { _ in [:] },
            pluginValues: { _ in [:] }
        )
        host.configureActivity(ActivityTestProvider())
        defer { host.unmountAll() }
        let context = PluginRenderContext(bundleID: "", pid: 0, appName: "", windowID: 0,
                                          titleSummary: "", presentationID: "language-panel", surface: "panel")

        let chineseRuntimeResult = await host.loadPanelRuntime(pluginID: package.manifest.id)
        let chineseRuntime = try XCTUnwrap(chineseRuntimeResult)
        let chineseOutput = try await chineseRuntime.render(context: context).get()
        let chineseText = nodeText(chineseOutput)
        XCTAssertTrue(chineseText.contains("活动时间线"))
        XCTAssertFalse(chineseText.contains("Activity Timeline"))

        language.set("en")
        let englishRuntimeResult = await host.loadPanelRuntime(pluginID: package.manifest.id)
        let englishRuntime = try XCTUnwrap(englishRuntimeResult)
        XCTAssertFalse(chineseRuntime === englishRuntime)
        let englishOutput = try await englishRuntime.render(context: context).get()
        let englishText = nodeText(englishOutput)
        XCTAssertTrue(englishText.contains("Activity Timeline"))
        XCTAssertFalse(englishText.contains("活动时间线"))
    }
    func testUnapprovedActivityIsAbsentAndDockContextStaysCompatible() async throws {
        let package = try package()
        let runtime = PluginRuntime(package: package, timeout: 2, permissions: [], activityProvider: ActivityTestProvider())
        let context = PluginRenderContext(bundleID: "", pid: 0, appName: "", windowID: 0, titleSummary: "", surface: "panel")
        let output = try await runtime.render(context: context).get()
        XCTAssertEqual(output.first?.slot, .panel)
        let dock = PluginRenderContext(bundleID: "com.example", pid: 1, appName: "Example", windowID: 1, titleSummary: "")
        let dockOutput = try await runtime.render(context: dock).get()
        XCTAssertTrue(dockOutput.isEmpty)
    }
    func testPanelOnlyNodesAndImagesAreRejectedBySceneTextures() throws {
        XCTAssertFalse(PluginSurfaceContentValidator.allows(.image(source: .activitySnapshot(UUID().uuidString), size: .l, corner: nil)))
        XCTAssertFalse(PluginSurfaceContentValidator.allows(.segmented(id: "a", options: ["One"], selected: 0)))
    }
    private func package() throws -> PluginPackage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try PluginRegistry(directory: root.appendingPathComponent(".build/Plugins"), origin: .builtin)
            .reload().plugins.first(where: { $0.manifest.id == "com.switchly.activity-timeline" }).unwrap()
    }
    private func nodeText(_ output: [PluginSlotContent]) -> [String] {
        output.flatMap { content in
            func text(in node: PluginUINode) -> [String] {
                let own: [String]
                switch node {
                case .text(let value, _, _), .badge(let value, _), .marquee(let value):
                    own = [value]
                case .button(_, _, let label, _, _, _, _), .toggle(_, _, _, _, let label),
                     .slider(_, _, let label, _), .dateRange(_, _, _, let label):
                    own = [label]
                case .segmented(_, let options, _):
                    own = options
                case .barChart(let items):
                    own = items.map(\.label)
                default:
                    own = []
                }
                return own + node.children.flatMap(text)
            }
            return text(in: content.node)
        }
    }
}

private final class ExpiringActivityTestProvider: PluginActivityProviding {
    private let base = ActivityTestProvider()
    private let lock = NSLock()
    private var count = 0
    var queryCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func recordQuery() { lock.lock(); count += 1; lock.unlock() }
    func query(method: String, options: [String: Any], pluginID: String,
               snapshotsAllowed: Bool) async throws -> [String: Any] {
        recordQuery()
        guard method == "sessions" else {
            return try await base.query(method: method, options: options, pluginID: pluginID, snapshotsAllowed: snapshotsAllowed)
        }
        if options["cursor"] as? String != nil { throw ActivityDataError.staleCursor }
        let start = (options["from"] as? Double ?? 0) + 1
        return ["items": [["id": "session", "bundleID": "com.example.test", "appName": "Test app",
                           "start": start, "end": start + 600, "seconds": 600, "endReason": "checkpoint"]],
                "nextCursor": "old-revision", "revision": 1]
    }
}

private final class LockedActivityLanguage: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String
    init(_ value: String) { storage = value }
    var value: String {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func set(_ value: String) {
        lock.lock(); storage = value; lock.unlock()
    }
}

private extension Optional {
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped { try XCTUnwrap(self, file: file, line: line) }
}
private final class ActivityNoMedia: MediaBridging {
    let queue = DispatchQueue(label: "activity.test.no-media")
    func supports(bundleID: String) -> Bool { false }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { nil }
    func artwork(bundleID: String) throws -> Data? { nil }
    func perform(_ command: MediaCommand, bundleID: String) throws {}
}

@MainActor
final class ActivitySnapshotIntegrationTests: XCTestCase {
    func testSessionCursorSurvivesTailAppendButRejectsChangedPrefixAndQuery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-cursor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory)
        let snapshots = ActivitySnapshotStore(directory: directory.appendingPathComponent("Snapshots"))
        let tracking = ActivityTrackingService(store: store, snapshots: snapshots,
            tracker: AppActivationTracker(center: NotificationCenter(), frontmost: nil))
        defer { tracking.stop() }
        await tracking.flushAndWait()
        let start = Date().addingTimeInterval(-1000)
        let rows = (0..<4).map { index in
            ActivitySession(id: UUID(), bundleID: "app.test", appName: "样例", start: start.addingTimeInterval(Double(index) * 100),
                end: start.addingTimeInterval(Double(index) * 100 + 50), seconds: 50, endReason: .switched)
        }
        try await store.apply(Array(rows.prefix(3)), generation: tracking.generation)
        let provider = ActivityDataProvider(tracking: tracking, authorized: { _, _ in true })
        var options: [String: Any] = ["from": start.timeIntervalSince1970, "to": start.addingTimeInterval(600).timeIntervalSince1970, "limit": 1.0]
        let first = try await provider.query(method: "sessions", options: options, pluginID: "test", snapshotsAllowed: true)
        options["cursor"] = try XCTUnwrap(first["nextCursor"] as? String)
        try await store.apply([rows[3]], generation: tracking.generation)
        var settings = tracking.settings
        settings.screenshotsEnabled = true
        tracking.apply(settings)
        let second = try await provider.query(method: "sessions", options: options, pluginID: "test", snapshotsAllowed: true)
        XCTAssertGreaterThan(try XCTUnwrap(second["revision"] as? Int), try XCTUnwrap(first["revision"] as? Int))
        XCTAssertEqual((second["items"] as? [[String: Any]])?.first?["id"] as? String, rows[1].id.uuidString)
        var differentQuery = options
        differentQuery["limit"] = 2.0
        do {
            _ = try await provider.query(method: "sessions", options: differentQuery, pluginID: "test", snapshotsAllowed: true)
            XCTFail("查询变化必须拒绝旧游标")
        } catch { XCTAssertEqual(error as? ActivityDataError, .staleCursor) }
        let changed = ActivitySession(id: rows[0].id, bundleID: rows[0].bundleID, appName: rows[0].appName,
            start: rows[0].start, end: rows[0].end, seconds: 40, endReason: .switched)
        try await store.apply([changed], generation: tracking.generation)
        do {
            _ = try await provider.query(method: "sessions", options: options, pluginID: "test", snapshotsAllowed: true)
            XCTFail("已读前缀变化必须拒绝旧游标")
        } catch { XCTAssertEqual(error as? ActivityDataError, .staleCursor) }
        await tracking.clear()
        do {
            _ = try await provider.query(method: "sessions", options: options, pluginID: "test", snapshotsAllowed: true)
            XCTFail("清除换代必须拒绝旧游标")
        } catch { XCTAssertEqual(error as? ActivityDataError, .staleCursor) }
    }

    func testSnapshotCursorSurvivesTailAppendButRejectsDeletedPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-cursor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory)
        let snapshots = ActivitySnapshotStore(directory: directory.appendingPathComponent("Snapshots"))
        let tracking = ActivityTrackingService(store: store, snapshots: snapshots,
            tracker: AppActivationTracker(center: NotificationCenter(), frontmost: nil))
        defer { tracking.stop() }
        await tracking.flushAndWait()
        let session = ActivitySession(id: UUID(), bundleID: "app.test", appName: "样例",
            start: Date().addingTimeInterval(-100), end: Date().addingTimeInterval(100), seconds: 100, endReason: .switched)
        try await store.apply([session], generation: tracking.generation)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for _ in 0..<3 { try await snapshots.save(image, session: session, generation: tracking.generation, retentionDays: 7) }
        let provider = ActivityDataProvider(tracking: tracking, authorized: { _, _ in true })
        var options: [String: Any] = ["from": session.start.timeIntervalSince1970, "to": session.end.timeIntervalSince1970, "limit": 1.0]
        let first = try await provider.query(method: "snapshots", options: options, pluginID: "test", snapshotsAllowed: true)
        options["cursor"] = try XCTUnwrap(first["nextCursor"] as? String)
        let original = try await snapshots.list(from: session.start, to: session.end, retentionDays: 7)
        try await snapshots.save(image, session: session, generation: tracking.generation, retentionDays: 7)
        var settings = tracking.settings
        settings.screenshotsEnabled = true
        tracking.apply(settings)
        let second = try await provider.query(method: "snapshots", options: options, pluginID: "test", snapshotsAllowed: true)
        XCTAssertGreaterThan(try XCTUnwrap(second["revision"] as? Int), try XCTUnwrap(first["revision"] as? Int))
        XCTAssertEqual((second["items"] as? [[String: Any]])?.first?["capturedAt"] as? Double, original[1].capturedAt.timeIntervalSince1970)
        try await snapshots.clear(generation: tracking.generation)
        for _ in 0..<3 { try await snapshots.save(image, session: session, generation: tracking.generation, retentionDays: 7) }
        do {
            _ = try await provider.query(method: "snapshots", options: options, pluginID: "test", snapshotsAllowed: true)
            XCTFail("删除已读截图后必须拒绝旧游标")
        } catch { XCTAssertEqual(error as? ActivityDataError, .staleCursor) }
    }

    func testSmallSnapshotAndOpaqueReferenceClearAndAuthorization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(directory: directory), snapshots = ActivitySnapshotStore(directory: directory.appendingPathComponent("Snapshots"))
        let tracking = ActivityTrackingService(store: store, snapshots: snapshots, tracker: AppActivationTracker(center: NotificationCenter(), frontmost: nil))
        await tracking.flushAndWait()
        let session = ActivitySession(id: UUID(), bundleID: "com.example", appName: "样例", start: Date().addingTimeInterval(-120), end: Date(), seconds: 120, endReason: .switched)
        try await store.apply([session], generation: tracking.generation)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        try await snapshots.save(XCTUnwrap(context.makeImage()), session: session, generation: tracking.generation, retentionDays: 7)
        var allowed = true
        let provider = ActivityDataProvider(tracking: tracking, authorized: { _, _ in allowed })
        let options: [String: Any] = ["from": Date().addingTimeInterval(-3600).timeIntervalSince1970, "to": Date().addingTimeInterval(30).timeIntervalSince1970, "limit": 6]
        let response = try await provider.query(method: "snapshots", options: options, pluginID: "com.example.plugin", snapshotsAllowed: true)
        let item = try XCTUnwrap((response["items"] as? [[String: Any]])?.first), ref = try XCTUnwrap(item["ref"] as? String)
        XCTAssertNotNil(UUID(uuidString: ref)); XCTAssertNil(item["fileName"])
        XCTAssertEqual(item["sessionID"] as? String, session.id.uuidString)
        let image = await provider.image(reference: ref, pluginID: "com.example.plugin")
        XCTAssertEqual(image?.size.width, 640)
        let otherPluginImage = await provider.image(reference: ref, pluginID: "another.plugin")
        XCTAssertNil(otherPluginImage)
        allowed = false
        provider.invalidateAuthorization()
        let revokedImage = await provider.image(reference: ref, pluginID: "com.example.plugin")
        XCTAssertNil(revokedImage)
        allowed = true
        let restoredPermissionImage = await provider.image(reference: ref, pluginID: "com.example.plugin")
        XCTAssertNil(restoredPermissionImage)
        await tracking.clear()
        let clearedImage = await provider.image(reference: ref, pluginID: "com.example.plugin")
        XCTAssertNil(clearedImage)
        let remaining = try await store.read(from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(30))
        XCTAssertTrue(remaining.isEmpty)
        tracking.stop()
    }
}
