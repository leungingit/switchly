import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Switchly

private func sessionImage(_ width: Int, height: Int = 20) -> CGImage {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

private final class CaptureMemoryDocuments: WindowCaptureDocumentServicing {
    var copyCalls = 0
    var cleanupCalls = 0
    func makeEditingFile(image: CGImage, sessionID: UUID) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(sessionID).png")
    }
    func loadEditedImage(url: URL) async throws -> CGImage { sessionImage(12) }
    func save(image: CGImage, to url: URL) async throws {}
    func cleanup(sessionID: UUID) async { cleanupCalls += 1 }
    func cleanupStale() async {}
    @MainActor func copy(image: CGImage) async throws { copyCalls += 1 }
}

@MainActor
final class WindowCaptureSessionTests: XCTestCase {
    func testQueuedCropFromAbandonedSessionCannotChangeTheNextCapture() async throws {
        let presenter = WindowCapturePresenter(documents: CaptureMemoryDocuments(), settings: { .default })
        defer { presenter.abandon() }
        let image = sessionImage(640, height: 504)
        presenter.present(image: image, mode: .region, sourceBounds: CGRect(x: 80, y: 90, width: 320, height: 252),
                          sessionID: UUID(), finished: {})
        let old = try XCTUnwrap(NSApp.windows.first { $0.delegate === presenter && $0.isVisible })
        let hosting = try XCTUnwrap(old.contentView as? NSHostingView<WindowCaptureRegionView>)
        hosting.rootView.model.crop(CGRect(x: 0, y: 0, width: 40, height: 20))
        presenter.abandon()
        let bounds = CGRect(x: 480, y: 90, width: 320, height: 252)
        presenter.present(image: image, mode: .region, sourceBounds: bounds, sessionID: UUID(), finished: {})
        let settled = expectation(description: "丢弃旧会话的排队窗口切换")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 1)
        let current = try XCTUnwrap(NSApp.windows.first { $0.delegate === presenter && $0.isVisible })
        XCTAssertTrue(current is WindowCaptureRegionPanel)
        XCTAssertEqual(current.frame, PreviewReplicaPanel.replicaRect(forWindowBounds: bounds,
                                                                      primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0,
                                                                      visibleFrame: .zero))
    }

    func testRegionOverlayKeepsSourceFrameAndReturnsThereAfterRecropping() async throws {
        let presenter = WindowCapturePresenter(documents: CaptureMemoryDocuments(), settings: { .default })
        let bounds = CGRect(x: 80, y: 90, width: 320, height: 252)
        let original = sessionImage(640, height: 504)
        presenter.present(image: original, mode: .region, sourceBounds: bounds, sessionID: UUID(), finished: {})
        defer { presenter.abandon() }
        let expected = PreviewReplicaPanel.replicaRect(forWindowBounds: bounds,
                                                      primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0,
                                                      visibleFrame: .zero)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.delegate === presenter && $0.isVisible })
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame, expected, "操作栏不能使图像缩放或移位")
        XCTAssertFalse(panel.styleMask.contains(.titled))
        let hosting = try XCTUnwrap(panel.contentView as? NSHostingView<WindowCaptureRegionView>)
        XCTAssertTrue(hosting.acceptsFirstMouse(for: nil), "首次拖动即开始框选，无需先点击激活")
        let model = hosting.rootView.model
        XCTAssertTrue(model.image === original)
        model.crop(CGRect(x: 20, y: 30, width: 300, height: 200))
        let cropped = expectation(description: "进入结果窗口")
        DispatchQueue.main.async { cropped.fulfill() }
        await fulfillment(of: [cropped], timeout: 1)
        XCTAssertTrue(NSApp.windows.contains { $0.delegate === presenter && $0.isVisible && $0.styleMask.contains(.titled) })
        XCTAssertFalse(panel.isVisible)
        model.reselect()
        let reselected = expectation(description: "返回原位框选")
        DispatchQueue.main.async { reselected.fulfill() }
        await fulfillment(of: [reselected], timeout: 1)
        let restored = try XCTUnwrap(NSApp.windows.first { $0.delegate === presenter && $0.isVisible })
        XCTAssertEqual(restored.frame, expected)
        XCTAssertTrue(model.image === original)
        XCTAssertTrue(model.selecting)
    }

    func testReselectUsesFrozenOriginalForRepeatedCrops() {
        let original = sessionImage(80)
        let model = WindowCaptureSessionModel(image: original, mode: .region, sessionID: UUID(), language: .english,
                                             documents: CaptureMemoryDocuments(), openEditor: { _ in }, finished: {})
        defer { model.abandon() }
        model.crop(CGRect(x: 30, y: 2, width: 20, height: 10))
        XCTAssertEqual(model.image.width, 20)
        XCTAssertTrue(model.canOutput)
        model.reselect()
        XCTAssertTrue(model.image === original)
        XCTAssertTrue(model.selecting)
        XCTAssertFalse(model.canOutput)
        model.crop(CGRect(x: 0, y: 0, width: 60, height: 20))
        XCTAssertEqual(model.image.width, 60, "第二次框选必须能选择第一次裁剪以外的像素")
        model.reselect()
        XCTAssertTrue(model.image === original)
    }

    func testPresenterRetainsMinimumWindowSizeAfterHostingLayout() throws {
        var settings = AppSettings.default
        settings.language = .english
        let presenter = WindowCapturePresenter(documents: CaptureMemoryDocuments(), settings: { settings })
        presenter.present(image: sessionImage(640), mode: .full, sessionID: UUID(), finished: {})
        defer { presenter.abandon() }
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === presenter })
        let available = window.screen?.visibleFrame.size ?? NSSize(width: 1024, height: 768)
        let minimum = NSSize(width: min(available.width, DesignTokens.Capture.minimumWidth),
                             height: min(available.height, DesignTokens.Capture.minimumHeight))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(window.minSize.width, minimum.width)
        XCTAssertGreaterThanOrEqual(window.minSize.height, minimum.height)
        var compact = window.frame
        compact.size = minimum
        window.setFrame(compact, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.width, minimum.width, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, minimum.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(window.minSize.width, minimum.width)
    }

    func testExternalEditorBlocksOutputAndCleanupUntilExplicitReloadOrClose() async {
        let documents = CaptureMemoryDocuments()
        let ended = expectation(description: "explicit session end")
        let model = WindowCaptureSessionModel(image: sessionImage(40), mode: .full, sessionID: UUID(), language: .english,
                                             documents: documents, openEditor: { _ in }, finished: { ended.fulfill() })
        let editing = expectation(description: "external editor open")
        let subscription = model.$editingExternally.combineLatest(model.$working).filter { $0 && !$1 }.prefix(1).sink { _ in editing.fulfill() }
        model.edit()
        await fulfillment(of: [editing], timeout: 1)
        XCTAssertFalse(model.canOutput)
        model.reselect()
        XCTAssertFalse(model.selecting, "外部编辑尚未确认结束时不得重置图像")
        model.copy(); model.close()
        XCTAssertEqual(documents.copyCalls, 0)
        XCTAssertEqual(documents.cleanupCalls, 0)
        let reloaded = expectation(description: "new saved image ready")
        let reloadSubscription = model.$editingExternally.combineLatest(model.$working)
            .filter { !$0 && !$1 }.prefix(1).sink { _ in reloaded.fulfill() }
        model.reloadEdits()
        await fulfillment(of: [reloaded], timeout: 1)
        XCTAssertEqual(model.image.width, 12)
        XCTAssertTrue(model.canOutput)
        let edited = model.image
        model.reselect()
        XCTAssertTrue(model.image === edited, "重读后的标注成为新的裁剪基图")
        model.crop(CGRect(x: 0, y: 0, width: 6, height: 10))
        model.reselect()
        XCTAssertTrue(model.image === edited)
        model.close()
        await fulfillment(of: [ended], timeout: 1)
        withExtendedLifetime([subscription, reloadSubscription]) {}
    }

    func testRevocationCannotExportAnExternalEdit() async {
        let documents = CaptureMemoryDocuments()
        let ended = expectation(description: "closed after external image acknowledgement")
        let model = WindowCaptureSessionModel(image: sessionImage(40), mode: .full, sessionID: UUID(), language: .english,
                                             documents: documents, openEditor: { _ in }, finished: { ended.fulfill() })
        let editing = expectation(description: "editing")
        let subscription = model.$editingExternally.combineLatest(model.$working).filter { $0 && !$1 }.prefix(1).sink { _ in editing.fulfill() }
        model.edit(); await fulfillment(of: [editing], timeout: 1)
        model.interrupt(); model.copy(); model.reloadEdits(); model.close()
        XCTAssertFalse(model.canOutput)
        XCTAssertEqual(documents.copyCalls, 0)
        XCTAssertEqual(documents.cleanupCalls, 0)
        model.close(editorClosed: true)
        await fulfillment(of: [ended], timeout: 1)
        withExtendedLifetime(subscription) {}
    }
}

@MainActor
private final class CapturePresenterMock: WindowCapturePresenting {
    var onPresent: (() -> Void)?
    var finished: (() -> Void)?
    var interrupted = false
    func present(image: CGImage, mode: WindowCaptureMode, sourceBounds: CGRect?, sessionID: UUID, finished: @escaping () -> Void) {
        self.finished = finished; onPresent?()
    }
    func showFailure(_ failure: WindowCaptureFailure) { XCTFail("Unexpected failure: \(failure)") }
    func interrupt() { interrupted = true }
    func abandon() {}
}

private struct CaptureImmediateRaw: RawWindowCapturing {
    func capture(target: WindowCaptureTarget) async throws -> CGImage { sessionImage(40) }
}

@MainActor
final class WindowCaptureCoordinatorTests: XCTestCase {
    func testAcceptedSessionOwnsBusyStateAndRechecksRevocation() async {
        let presenter = CapturePresenterMock()
        let presented = expectation(description: "host owns capture")
        presenter.onPresent = { presented.fulfill() }
        var authorized = true
        var hidden = false
        let coordinator = WindowCaptureCoordinator(capturer: CaptureImmediateRaw(), presenter: presenter,
                                                   screenAccess: { true }, authorized: { _ in authorized }, dismissDock: { hidden = true })
        let request = WindowCaptureRequest(pluginID: "com.test.capture", target: .init(windowID: 3, pid: 4, processStartedAt: Date()), mode: .full)
        XCTAssertEqual(coordinator.submit(request), .accepted)
        XCTAssertEqual(coordinator.submit(request).failure, .busy)
        await fulfillment(of: [presented], timeout: 1)
        XCTAssertTrue(hidden)
        XCTAssertEqual(coordinator.submit(request).failure, .busy)
        authorized = false; coordinator.validateAuthorization()
        XCTAssertTrue(presenter.interrupted)
        XCTAssertEqual(coordinator.submit(request).failure, .permissionDenied)
        presenter.finished?()
        coordinator.shutdown()
    }
}
