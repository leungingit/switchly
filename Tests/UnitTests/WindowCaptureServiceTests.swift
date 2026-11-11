import AppKit
import XCTest
import zlib
@testable import Switchly

private func serviceCaptureImage(width: Int = 40, height: Int = 20) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private final class CaptureCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Result<CGImage, Error>) -> Void)?
    func set(_ callback: @escaping (Result<CGImage, Error>) -> Void) { lock.lock(); self.callback = callback; lock.unlock() }
    func succeed() { lock.lock(); let callback = callback; lock.unlock(); callback?(.success(serviceCaptureImage())) }
}

final class WindowCaptureWorkPoolTests: XCTestCase {
    func testTimeoutReturnsWithoutWaitingButPhysicalSlotRemainsOccupied() async throws {
        let pool = WindowCaptureWorkPool(limit: 1), box = CaptureCallbackBox()
        let start = Date()
        var isActive: (() -> Bool)?
        do { _ = try await pool.runCancellable(timeout: 0.03) { isActive = $0; box.set($1) }; XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(isActive?(), false, "A late enumeration callback must not start another system capture")
        do { _ = try await pool.run(timeout: 1) { _ in XCTFail("Timed-out work must still occupy its slot") }; XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .busy) }
        box.succeed(); box.succeed()
        let image = try await pool.run(timeout: 1) { $0(.success(serviceCaptureImage())) }
        XCTAssertEqual(image.width, 40)
    }

    func testCancellationReturnsAndLateDuplicateCallbackDoesNotOverRelease() async throws {
        let pool = WindowCaptureWorkPool(limit: 1), box = CaptureCallbackBox()
        let started = expectation(description: "started")
        let task = Task { try await pool.run(timeout: 1) { box.set($0); started.fulfill() } }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await pool.run(timeout: 1) { _ in XCTFail() }; XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .busy) }
        box.succeed(); box.succeed()
        let secondStarted = expectation(description: "second started"), secondBox = CaptureCallbackBox()
        let second = Task { try await pool.run(timeout: 1) { secondBox.set($0); secondStarted.fulfill() } }
        await fulfillment(of: [secondStarted], timeout: 1)
        do { _ = try await pool.run(timeout: 1) { _ in XCTFail("Duplicate callback over-released the slot") }; XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .busy) }
        secondBox.succeed(); _ = try await second.value
    }
}

final class WindowCaptureDocumentServiceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-files-test-\(UUID())")
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }

    func testPrivateFilesReloadChangesAndCleanupOnlyOwnSession() async throws {
        let documents = WindowCaptureDocumentService(root: root)
        let firstID = UUID(), secondID = UUID()
        let first = try await documents.makeEditingFile(image: serviceCaptureImage(), sessionID: firstID)
        let second = try await documents.makeEditingFile(image: serviceCaptureImage(), sessionID: secondID)
        let manager = FileManager.default
        XCTAssertEqual(try manager.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try manager.attributesOfItem(atPath: first.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        try await documents.save(image: serviceCaptureImage(width: 12, height: 8), to: first)
        let reloaded = try await documents.loadEditedImage(url: first)
        XCTAssertEqual(reloaded.width, 12); XCTAssertEqual(reloaded.height, 8)
        await documents.cleanup(sessionID: firstID)
        XCTAssertFalse(manager.fileExists(atPath: first.path))
        XCTAssertTrue(manager.fileExists(atPath: second.path))
        await documents.cleanup(sessionID: secondID)
    }

    func testReloadRejectsSymlinkAndUnownedPath() async throws {
        let documents = WindowCaptureDocumentService(root: root)
        let id = UUID()
        let file = try await documents.makeEditingFile(image: serviceCaptureImage(), sessionID: id)
        let outside = root.appendingPathComponent("outside.png")
        try await documents.save(image: serviceCaptureImage(), to: outside)
        do { _ = try await documents.loadEditedImage(url: outside); XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .invalidRequest) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { _ = try await documents.loadEditedImage(url: file); XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .invalidRequest) }
        await documents.cleanup(sessionID: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testCancelledExportDoesNotCreateOutputFile() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let documents = WindowCaptureDocumentService(root: root)
        let url = root.appendingPathComponent("cancelled.png")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await documents.save(image: serviceCaptureImage(), to: url)
        }
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOversizedPNGHeaderRejectedBeforePixelDecode() async throws {
        let documents = WindowCaptureDocumentService(root: root)
        let id = UUID()
        let file = try await documents.makeEditingFile(image: serviceCaptureImage(), sessionID: id)
        func chunk(_ type: String, _ payload: Data) -> Data {
            var length = UInt32(payload.count).bigEndian
            var bytes = Data(type.utf8); bytes.append(payload)
            var checksum = UInt32(bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }).bigEndian
            var result = withUnsafeBytes(of: &length) { Data($0) }
            result.append(bytes); result.append(withUnsafeBytes(of: &checksum) { Data($0) })
            return result
        }
        // A valid 50 MP grayscale PNG needs only 6.3 MB of uncompressed 1-bit scanlines.
        // This exercises metadata rejection without allocating its 200 MB decoded RGBA bitmap.
        var width = UInt32(10_000).bigEndian, height = UInt32(5_000).bigEndian
        var header = withUnsafeBytes(of: &width) { Data($0) }
        header.append(withUnsafeBytes(of: &height) { Data($0) }); header.append(contentsOf: [1, 0, 0, 0, 0])
        let raw = Data(repeating: 0, count: 1251 * 5000)
        var length = compressBound(uLong(raw.count))
        var compressed = Data(count: Int(length))
        let status = compressed.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: UInt8.self).baseAddress, &length,
                          source.bindMemory(to: UInt8.self).baseAddress, uLong(source.count), Z_BEST_SPEED)
            }
        }
        XCTAssertEqual(status, Z_OK)
        compressed.count = Int(length)
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        data.append(chunk("IHDR", header)); data.append(chunk("IDAT", compressed)); data.append(chunk("IEND", Data()))
        try data.write(to: file, options: .atomic)
        do { _ = try await documents.loadEditedImage(url: file); XCTFail() }
        catch { XCTAssertEqual(error as? WindowCaptureFailure, .tooLarge) }
        await documents.cleanup(sessionID: id)
    }

    func testStaleCleanupPreservesRunningInstanceAndUnrelatedDirectories() async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let active = root.appendingPathComponent("window-capture-\(getpid())-\(UUID())")
        let abandoned = root.appendingPathComponent("window-capture-2147483647-\(UUID())")
        let unrelated = root.appendingPathComponent("unrelated")
        for directory in [active, abandoned, unrelated] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try manager.setAttributes([.creationDate: Date(timeIntervalSinceNow: -WindowCaptureLimits.staleFileAge - 60)], ofItemAtPath: directory.path)
        }
        await WindowCaptureDocumentService(root: root).cleanupStale()
        XCTAssertTrue(manager.fileExists(atPath: active.path))
        XCTAssertTrue(manager.fileExists(atPath: unrelated.path))
        XCTAssertFalse(manager.fileExists(atPath: abandoned.path))
    }
}

final class WindowCaptureManifestTests: XCTestCase {
    func testScopeCompatibilityAndCaptureRequiresExplicitBuiltinGrant() throws {
        let json = """
        {"id":"com.test.capture","name":{"en":"Capture"},"version":"1","apiVersion":2,
         "matches":["*"],"permissions":["window.capture"],"entry":"main.js"}
        """
        let old = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertNil(old.renderScope)
        XCTAssertTrue(old.matches(bundleID: "com.test.any"))
        let unauthorized = PluginAuthorization.resolve(manifest: old, origin: .builtin, grant: nil)
        XCTAssertFalse(unauthorized.permissions.contains(.windowCapture))
        XCTAssertEqual(unauthorized.pendingPermissions, [.windowCapture])
        let authorized = PluginAuthorization.resolve(manifest: old, origin: .builtin,
                                                      grant: PluginGrant(isEnabled: true, permissions: ["window.capture"]))
        XCTAssertTrue(authorized.permissions.contains(.windowCapture))
        let scoped = json.replacingOccurrences(of: "\"entry\":\"main.js\"", with: "\"entry\":\"main.js\",\"renderScope\":\"window\"")
        XCTAssertEqual(try JSONDecoder().decode(PluginManifest.self, from: Data(scoped.utf8)).renderScope, .window)
        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: Data(scoped.replacingOccurrences(of: "\"renderScope\":\"window\"", with: "\"renderScope\":\"invalid\"").utf8)))
    }
}
