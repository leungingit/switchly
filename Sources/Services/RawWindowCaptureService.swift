import AppKit
import CoreGraphics

protocol RawWindowCapturing {
    func capture(target: WindowCaptureTarget) async throws -> CGImage
}

final class RawWindowCaptureService: RawWindowCapturing {
    private let backend: WindowImageCapturing
    private let screenAccess: () -> Bool
    private let processStart: (Int32) -> Date?
    private let windowDetails: (CGWindowID) -> [[String: Any]]

    init(backend: WindowImageCapturing = WindowImageCaptureBackend.shared,
         screenAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         processStart: @escaping (Int32) -> Date? = { NSRunningApplication(processIdentifier: $0)?.launchDate },
         windowDetails: @escaping (CGWindowID) -> [[String: Any]] = {
             CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]] ?? []
         }) {
        self.backend = backend; self.screenAccess = screenAccess
        self.processStart = processStart; self.windowDetails = windowDetails
    }

    func capture(target: WindowCaptureTarget) async throws -> CGImage {
        try Task.checkCancellation()
        guard screenAccess() else { throw WindowCaptureFailure.noScreenPermission }
        guard !target.isMinimized, !target.isHidden else { throw WindowCaptureFailure.windowUnavailable }
        try validate(target)
        let cgImage: CGImage?
        do { cgImage = try await backend.captureCG(windowID: target.windowID, timeout: 1.5) }
        catch {
            try Task.checkCancellation()
            if error as? WindowCaptureFailure == .busy { throw error }
            cgImage = nil
        }
        let image: CGImage
        if let cgImage, !WindowImageCaptureBackend.isBlankCapture(cgImage) { image = cgImage }
        else {
            image = try await backend.captureSCK(windowID: target.windowID, pid: target.pid, pixelSize: nil, timeout: 3)
        }
        try Task.checkCancellation()
        guard screenAccess() else { throw WindowCaptureFailure.noScreenPermission }
        try validate(target)
        guard WindowCaptureLimits.accepts(width: image.width, height: image.height) else { throw WindowCaptureFailure.tooLarge }
        guard !WindowImageCaptureBackend.isBlankCapture(image) else { throw WindowCaptureFailure.windowUnavailable }
        return image
    }

    private func validate(_ target: WindowCaptureTarget) throws {
        guard target.windowID != 0, processStart(target.pid) == target.processStartedAt,
              windowDetails(target.windowID).contains(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID &&
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid
              }) else { throw WindowCaptureFailure.windowGone }
    }
}
