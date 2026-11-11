import CoreGraphics
import Foundation

enum WindowCaptureMode: String, Codable { case full, region }

enum WindowCaptureFailure: String, Error, Equatable {
    case permissionDenied, noScreenPermission, noUserAction, invalidRequest
    case windowGone, windowUnavailable, busy, captureFailed, timeout, tooLarge, cancelled

    var messageKey: String {
        switch self {
        case .noScreenPermission: return "Allow Screen Recording in System Settings to capture windows."
        case .permissionDenied: return "Window capture permission was revoked."
        case .windowGone: return "This window is no longer available."
        case .windowUnavailable: return "This window cannot be captured. Restore it and try again."
        case .busy: return "Finish the current screenshot before starting another."
        case .timeout: return "Capturing the window timed out. Please try again."
        case .tooLarge: return "This image is too large to edit safely."
        case .cancelled: return "Screenshot cancelled."
        default: return "The screenshot could not be completed. Please try again."
        }
    }
}

struct WindowCaptureSubmission: Equatable {
    let failure: WindowCaptureFailure?
    static let accepted = WindowCaptureSubmission(failure: nil)
    var jsObject: [String: String] {
        if let failure { return ["status": "failed", "reason": failure.rawValue] }
        return ["status": "accepted"]
    }
}

/// Created from the host's immutable action context, never from JS-supplied IDs.
struct WindowCaptureTarget: Equatable {
    let windowID: CGWindowID
    let pid: Int32
    let processStartedAt: Date
    var isMinimized = false
    var isHidden = false
}

struct WindowCaptureRequest {
    let pluginID: String
    let target: WindowCaptureTarget
    let mode: WindowCaptureMode
}

protocol WindowCaptureRequesting: AnyObject {
    var isAvailable: Bool { get }
    func submit(_ request: WindowCaptureRequest) -> WindowCaptureSubmission
    @MainActor func validateAuthorization()
}

extension WindowCaptureRequesting {
    @MainActor func validateAuthorization() {}
}

enum WindowCaptureLimits {
    static let maxPixels = 40_000_000
    static let maxFileBytes = 128 * 1024 * 1024
    static let staleFileAge: TimeInterval = 24 * 60 * 60

    static func accepts(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxPixels / height
    }
}

/// Image display uses a top-left origin; crop coordinates use the bitmap's pixels.
enum WindowCaptureGeometry {
    static func imageRect(image: CGSize, in viewport: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func pixelRect(selection: CGRect, imageRect: CGRect, pixels: CGSize) -> CGRect? {
        guard imageRect.width > 0, imageRect.height > 0, pixels.width > 0, pixels.height > 0,
              !selection.isNull, !selection.isInfinite else { return nil }
        let clipped = selection.standardized.intersection(imageRect)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let sx = pixels.width / imageRect.width, sy = pixels.height / imageRect.height
        let left = floor((clipped.minX - imageRect.minX) * sx)
        let top = floor((clipped.minY - imageRect.minY) * sy)
        let right = ceil((clipped.maxX - imageRect.minX) * sx)
        let bottom = ceil((clipped.maxY - imageRect.minY) * sy)
        let result = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(origin: .zero, size: pixels))
        return result.width >= 1 && result.height >= 1 ? result : nil
    }
}
