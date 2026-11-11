import AppKit
import XCTest
@testable import Switchly

final class WindowCaptureGeometryTests: XCTestCase {
    func testLetterboxedSelectionMapsToOriginalPixelsAndClipsOutside() throws {
        let pixels = CGSize(width: 1120, height: 744)
        let displayed = WindowCaptureGeometry.imageRect(image: pixels, in: CGSize(width: 900, height: 500))
        XCTAssertEqual(displayed.height, 500, accuracy: 0.001)
        let selected = CGRect(x: displayed.minX - 20, y: displayed.minY, width: displayed.width / 2 + 20, height: displayed.height / 2)
        let crop = try XCTUnwrap(WindowCaptureGeometry.pixelRect(selection: selected, imageRect: displayed, pixels: pixels))
        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 560, height: 372))
        XCTAssertNil(WindowCaptureGeometry.pixelRect(selection: CGRect(x: -50, y: -50, width: 10, height: 10), imageRect: displayed, pixels: pixels))
    }

    func testFractionalScaleRoundsOutwardAndNeverExceedsImage() throws {
        let rect = CGRect(x: 12.5, y: 7.5, width: 600, height: 400)
        let result = try XCTUnwrap(WindowCaptureGeometry.pixelRect(selection: CGRect(x: 12.6, y: 7.6, width: 599.9, height: 399.9),
                                                                 imageRect: rect, pixels: CGSize(width: 1500, height: 1000)))
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 1500, height: 1000))
        XCTAssertFalse(WindowCaptureLimits.accepts(width: .max, height: .max))
    }
}

private func captureTestImage() -> CGImage {
    let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    return context.makeImage()!
}

private final class CaptureBackendFake: WindowImageCapturing {
    var calls = 0
    var afterCapture: (() -> Void)?
    func captureCG(windowID: CGWindowID, timeout: TimeInterval) async throws -> CGImage {
        calls += 1; afterCapture?(); return captureTestImage()
    }
    func captureSCK(windowID: CGWindowID, pid: Int32, pixelSize: CGSize?, timeout: TimeInterval) async throws -> CGImage {
        XCTFail("Valid raw captures must not fall back or scale"); return captureTestImage()
    }
}

final class RawWindowCaptureTests: XCTestCase {
    func testPermissionDeniedNeverCallsBackend() async {
        let backend = CaptureBackendFake()
        let service = RawWindowCaptureService(backend: backend, screenAccess: { false })
        do { _ = try await service.capture(target: .init(windowID: 7, pid: 8, processStartedAt: Date())); XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .noScreenPermission) }
        XCTAssertEqual(backend.calls, 0)
    }

    func testProcessAndWindowIdentityCheckedBeforeAndAfterCapture() async throws {
        let date = Date(timeIntervalSince1970: 12)
        let backend = CaptureBackendFake()
        var alive = true
        let service = RawWindowCaptureService(backend: backend, screenAccess: { true }, processStart: { _ in alive ? date : nil },
                                             windowDetails: { id in [[kCGWindowNumber as String: id, kCGWindowOwnerPID as String: 8]] })
        let target = WindowCaptureTarget(windowID: 7, pid: 8, processStartedAt: date)
        let image = try await service.capture(target: target)
        XCTAssertEqual(image.width, 40); XCTAssertEqual(image.height, 20)
        backend.afterCapture = { alive = false }
        do { _ = try await service.capture(target: target); XCTFail("Late result must be rejected") }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .windowGone) }
        XCTAssertEqual(backend.calls, 2)
        do { _ = try await service.capture(target: target); XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .windowGone) }
        XCTAssertEqual(backend.calls, 2)
    }
}

private final class CaptureRequestFake: WindowCaptureRequesting {
    let lock = NSLock()
    var isAvailable = true
    private(set) var requests: [WindowCaptureRequest] = []
    func submit(_ request: WindowCaptureRequest) -> WindowCaptureSubmission {
        lock.lock(); requests.append(request); lock.unlock(); return .accepted
    }
}

final class PluginWindowCaptureTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func runtime(_ script: String, requester: CaptureRequestFake, granted: Bool = true) throws -> PluginRuntime {
        let manifest = """
        {"id":"com.test.capture","name":{"en":"Capture","zh-Hans":"截图"},"version":"1","apiVersion":2,
         "matches":["*"],"permissions":["window.capture"],"entry":"main.js","renderScope":"window"}
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data(script.utf8).write(to: root.appendingPathComponent("main.js"))
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(manifest.utf8))
        let package = PluginPackage(manifest: decoded, directory: root, source: script, origin: .user)
        return PluginRuntime(package: package, timeout: 1, permissions: granted ? [.windowCapture] : [], captureRequester: requester)
    }

    private var context: PluginRenderContext {
        PluginRenderContext(bundleID: "com.test.app", pid: 20, appName: "Test", windowID: 41, titleSummary: "Fixture",
                            captureTarget: WindowCaptureTarget(windowID: 41, pid: 20, processStartedAt: Date(timeIntervalSince1970: 10)))
    }

    func testWindowScopeRejectsApplicationCenterOutput() async throws {
        let requester = CaptureRequestFake()
        let runtime = try runtime(#"globalThis.__switchlyPlugin={render(){return [{slot:'center',node:{type:'text',value:'Wrong scope'}}]}};"#, requester: requester)
        defer { runtime.unmount() }
        guard case .failure(.invalidOutput) = await runtime.render(context: context) else {
            return XCTFail("A window plugin must not mount an application-level center card")
        }
        XCTAssertEqual(requester.requests.count, 0)
    }

    func testRenderAndReplayedActionCannotCaptureAndNoPixelsReturned() async throws {
        let requester = CaptureRequestFake()
        let runtime = try runtime("""
        let previous;
        globalThis.__switchlyPlugin = {
          async render(ctx) {
            const result = await (previous || ctx.capture).window({mode:'full'});
            if (result.reason !== 'noUserAction') throw Error('render/replay allowed');
            return [];
          },
          async onAction(ctx) {
            previous = ctx.capture;
            const result = await ctx.capture.window({mode:'full'});
            if (JSON.stringify(result) !== '{"status":"accepted"}') throw Error('unexpected data');
            const again = await ctx.capture.window({mode:'region'});
            if (again.reason !== 'noUserAction') throw Error('duplicate accepted');
          }
        };
        """, requester: requester)
        defer { runtime.unmount() }
        if case .failure(let error) = await runtime.render(context: context) { XCTFail("\(error)") }
        XCTAssertEqual(requester.requests.count, 0)
        if case .failure(let error) = await runtime.performAction(id: "capture", value: nil, context: context) { XCTFail("\(error)") }
        XCTAssertEqual(requester.requests.count, 1)
        if case .failure(let error) = await runtime.render(context: context) { XCTFail("\(error)") }
        XCTAssertEqual(requester.requests.count, 1)
    }

    func testCannotReplaceHostTargetOrUseUnconfirmedPermission() async throws {
        let requester = CaptureRequestFake()
        let runtime = try runtime("""
        globalThis.__switchlyPlugin = { render(){return [];}, async onAction(ctx) {
          const invalid = await ctx.capture.window({mode:'full',windowID:999});
          if (invalid.reason !== 'invalidRequest') throw Error('target accepted');
          ctx.window.windowID = 999;
          const valid = await ctx.capture.window({mode:'region'});
          if (valid.status !== 'accepted') throw Error('failed');
        }};
        """, requester: requester)
        defer { runtime.unmount() }
        if case .failure(let error) = await runtime.performAction(id: "capture", value: nil, context: context) { XCTFail("\(error)") }
        XCTAssertEqual(requester.requests.first?.target.windowID, 41)
        XCTAssertEqual(requester.requests.first?.mode, .region)
        let denied = try self.runtime("""
        globalThis.__switchlyPlugin = {render(ctx){if(ctx.capture !== undefined) throw Error('permission leaked'); return [];}};
        """, requester: requester, granted: false)
        defer { denied.unmount() }
        if case .failure(let error) = await denied.render(context: context) { XCTFail("\(error)") }
        XCTAssertEqual(requester.requests.count, 1)
    }
}
