import AppKit
import Combine
import XCTest
@testable import Switchly

private func sessionImage(_ width: Int) -> CGImage {
    CGContext(data: nil, width: width, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
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
    func present(image: CGImage, mode: WindowCaptureMode, sessionID: UUID, finished: @escaping () -> Void) {
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
