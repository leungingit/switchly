import AppKit
import CoreGraphics
import ScreenCaptureKit

protocol WindowImageCapturing {
    func captureCG(windowID: CGWindowID, timeout: TimeInterval) async throws -> CGImage
    func captureSCK(windowID: CGWindowID, pid: Int32, pixelSize: CGSize?, timeout: TimeInterval) async throws -> CGImage
}

/// Shared system capture only. Scaling, cache policy and editor state belong to callers.
final class WindowImageCaptureBackend: WindowImageCapturing {
    static let shared = WindowImageCaptureBackend()
    private let pool: WindowCaptureWorkPool

    init(pool: WindowCaptureWorkPool = .shared) { self.pool = pool }

    func captureCG(windowID: CGWindowID, timeout: TimeInterval) async throws -> CGImage {
        try await pool.runCancellable(timeout: timeout) { isActive, done in
            DispatchQueue.global(qos: .userInitiated).async {
                guard isActive() else { done(.failure(CancellationError())); return }
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                     [.boundsIgnoreFraming, .bestResolution]) {
                    done(.success(image))
                } else { done(.failure(WindowCaptureFailure.captureFailed)) }
            }
        }
    }

    func captureSCK(windowID: CGWindowID, pid: Int32, pixelSize: CGSize?, timeout: TimeInterval) async throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw WindowCaptureFailure.windowUnavailable }
        return try await pool.runCancellable(timeout: timeout) { isActive, done in
            let receive: @Sendable (SCShareableContent?, Error?) -> Void = { content, error in
                guard isActive() else { done(.failure(CancellationError())); return }
                guard let content else { done(.failure(error ?? WindowCaptureFailure.captureFailed)); return }
                guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == pid }) else {
                    done(.failure(WindowCaptureFailure.windowGone)); return
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let native = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                                    height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
                let size = pixelSize ?? native
                guard size.width.isFinite, size.height.isFinite,
                      WindowCaptureLimits.accepts(width: Int(size.width.rounded()), height: Int(size.height.rounded())) else {
                    done(.failure(WindowCaptureFailure.tooLarge)); return
                }
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(size.width.rounded()))
                configuration.height = max(1, Int(size.height.rounded()))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                guard isActive() else { done(.failure(CancellationError())); return }
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    if let image { done(.success(image)) }
                    else { done(.failure(error ?? WindowCaptureFailure.captureFailed)) }
                }
            }
            if #available(macOS 14.4, *), pid == getpid() {
                SCShareableContent.getCurrentProcessShareableContent(completionHandler: receive)
            } else {
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false, completionHandler: receive)
            }
        }
    }
    /// Detects captures whose content is essentially uniform (blank white,
    /// blank black, or fully transparent) — e.g. an app window whose backing
    /// store has not been rendered yet. Downsampled luminance variance check.
    static func isBlankCapture(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return true }

        let sampleWidth = min(32, width)
        let sampleHeight = min(32, height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &buffer,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var sum: Int = 0
        var sumSquared: Int = 0
        var count = 0
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let alpha = Int(buffer[index + 3])
            guard alpha >= 16 else { continue }
            let luminance = (Int(buffer[index]) + Int(buffer[index + 1]) + Int(buffer[index + 2])) / 3
            sum += luminance
            sumSquared += luminance * luminance
            count += 1
        }
        // Fully transparent → nothing rendered → blank.
        guard count > 0 else { return true }

        let mean = sum / count
        let variance = sumSquared / count - mean * mean
        // Blank when there is almost no variance AND the content is uniformly
        // near-white or near-black (unrendered backing store).
        return variance < 120 && (mean > 240 || mean < 16)
    }


}
