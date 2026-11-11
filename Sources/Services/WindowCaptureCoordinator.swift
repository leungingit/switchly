import CoreGraphics
import Foundation

@MainActor
protocol WindowCapturePresenting: AnyObject {
    func present(image: CGImage, mode: WindowCaptureMode, sessionID: UUID, finished: @escaping () -> Void)
    func showFailure(_ failure: WindowCaptureFailure)
    func interrupt()
    func abandon()
}

/// A short plugin submission transfers ownership to this host session before Dock is hidden.
final class WindowCaptureCoordinator: WindowCaptureRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var active: (id: UUID, pluginID: String)?
    private let capturer: RawWindowCapturing
    private let presenter: WindowCapturePresenting
    private let screenAccess: () -> Bool
    private let authorized: (String) -> Bool
    private let dismissDock: @MainActor () -> Void
    @MainActor private var captureTask: Task<Void, Never>?
    @MainActor private var presenting = false

    init(capturer: RawWindowCapturing, presenter: WindowCapturePresenting,
         screenAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         authorized: @escaping (String) -> Bool,
         dismissDock: @escaping @MainActor () -> Void) {
        self.capturer = capturer; self.presenter = presenter
        self.screenAccess = screenAccess; self.authorized = authorized; self.dismissDock = dismissDock
    }

    var isAvailable: Bool { screenAccess() }

    func submit(_ request: WindowCaptureRequest) -> WindowCaptureSubmission {
        guard authorized(request.pluginID) else { return .init(failure: .permissionDenied) }
        guard screenAccess() else { return .init(failure: .noScreenPermission) }
        guard request.target.windowID != 0 else { return .init(failure: .invalidRequest) }
        guard !request.target.isMinimized, !request.target.isHidden else { return .init(failure: .windowUnavailable) }
        lock.lock()
        guard active == nil else { lock.unlock(); return .init(failure: .busy) }
        let id = UUID()
        active = (id, request.pluginID)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.begin(request, id: id) }
        return .accepted
    }

    @MainActor
    private func begin(_ request: WindowCaptureRequest, id: UUID) {
        guard isCurrent(id), authorized(request.pluginID) else { finish(id); return }
        dismissDock()
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await capturer.capture(target: request.target)
                try Task.checkCancellation()
                guard isCurrent(id), authorized(request.pluginID) else { finish(id); return }
                captureTask = nil
                presenting = true
                presenter.present(image: image, mode: request.mode, sessionID: id) { [weak self] in self?.finish(id) }
            } catch {
                guard isCurrent(id) else { return }
                finish(id)
                if !(error is CancellationError), error as? WindowCaptureFailure != .cancelled {
                    presenter.showFailure(error as? WindowCaptureFailure ?? .captureFailed)
                }
            }
        }
    }

    @MainActor
    func validateAuthorization() {
        lock.lock(); let current = active; lock.unlock()
        guard let current, !authorized(current.pluginID) else { return }
        captureTask?.cancel()
        if presenting { presenter.interrupt() }
        else { finish(current.id) }
    }

    @MainActor
    func shutdown() {
        captureTask?.cancel(); captureTask = nil
        presenter.abandon()
        lock.lock(); active = nil; lock.unlock()
        presenting = false
    }

    private func isCurrent(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active?.id == id
    }

    @MainActor
    private func finish(_ id: UUID) {
        lock.lock()
        guard active?.id == id else { lock.unlock(); return }
        active = nil
        lock.unlock()
        captureTask?.cancel(); captureTask = nil
        presenting = false
    }
}
