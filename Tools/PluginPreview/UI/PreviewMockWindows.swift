import AppKit
import CoreGraphics
import Foundation

/// 预览工具模拟 Dock 用的确定性窗口与占位缩略图。
///
/// 不触碰真实窗口枚举与截图服务，UI 层可在没有屏幕录制权限时直接展示卡片。
enum PreviewMockWindows {
    /// 模拟窗口 ID 的起点；第 n 个窗口为 `firstWindowID + n`。
    static let firstWindowID: CGWindowID = 900001
    /// 模拟窗口数量的默认值与可调范围（0 用于查看无窗口空状态）。
    static let defaultWindowCount = 1
    static let windowCountRange = 0...5
    /// 与宿主 Dock 卡片缩略图一致的比例（`ThumbnailSize.medium` 为 200x125）。
    static let thumbnailSize = ThumbnailSize.medium.dimensions
    /// 缩略图按 2x 位图生成，和宿主缩略图服务按显示缩放取图的口径一致。
    static let thumbnailScale: CGFloat = 2

    /// 确定性的模拟窗口，默认 1 个。
    ///
    /// `WindowInfo` 不保存 bundle ID；该参数保留在接口上以对应宿主窗口归属，
    /// 供后续调用方按应用身份生成固定缩略图色调。
    static func make(appName: String, bundleID: String, count: Int = defaultWindowCount) -> [WindowInfo] {
        let clamped = min(max(count, windowCountRange.lowerBound), windowCountRange.upperBound)
        return (0..<clamped).map { index in
            let windowID = firstWindowID + CGWindowID(index)
            return WindowInfo(
                id: windowID,
                ownerPID: pid_t(4242 + index),
                ownerName: appName,
                windowTitle: "Example Window \(index + 1)",
                bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                isOnCurrentSpace: true,
                windowNumber: Int(windowID),
                isMinimized: false,
                isHidden: false,
                isOnOtherSpace: false
            )
        }
    }

    /// 渐变 + 标题的占位缩略图。相同入参得到相同像素，无随机与时间依赖。
    static func placeholderThumbnail(title: String,
                                     appName: String,
                                     bundleID: String,
                                     size: CGSize = thumbnailSize,
                                     scale: CGFloat = thumbnailScale) -> NSImage {
        let safeScale = max(scale, 1)
        let pixelWidth = max(Int((size.width * safeScale).rounded()), 1)
        let pixelHeight = max(Int((size.height * safeScale).rounded()), 1)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        bitmap?.size = size

        NSGraphicsContext.saveGraphicsState()
        if let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            let rect = NSRect(origin: .zero, size: size)
            let hue = tintHue(appName: appName, bundleID: bundleID)
            let bottom = NSColor(calibratedHue: hue,
                                 saturation: 0.55,
                                 brightness: 0.30,
                                 alpha: 1)
            let top = NSColor(calibratedHue: hue > 0.92 ? hue - 0.92 : hue + 0.08,
                              saturation: 0.45,
                              brightness: 0.62,
                              alpha: 1)
            NSGradient(starting: bottom, ending: top)?.draw(in: rect, angle: 90)

            // 顶部一条浅浅的窗口标题栏，让占位图更像窗口而不是纯色块。
            NSColor(white: 1, alpha: 0.12).setFill()
            NSRect(x: 0, y: rect.height - 22, width: rect.width, height: 22).fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                .paragraphStyle: paragraph
            ]
            let textRect = NSRect(x: 12,
                                  y: (rect.height - 24) / 2,
                                  width: rect.width - 24,
                                  height: 24)
            (title as NSString).draw(in: textRect, withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        if let bitmap {
            image.addRepresentation(bitmap)
        }
        return image
    }

    /// FNV-1a 固定哈希，避免 Swift `Hasher` 的进程随机种子。
    private static func tintHue(appName: String, bundleID: String) -> CGFloat {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(bundleID)|\(appName)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return CGFloat(hash % 360) / 360
    }
}
