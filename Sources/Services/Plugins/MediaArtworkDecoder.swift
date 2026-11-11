import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 媒体封面的同步、有界解码器。调用方负责在后台队列调用；这里不切换线程，也不缓存图片。
enum MediaArtworkDecoder {
    enum Budget {
        /// 与 MediaRemote 的 Base64 解码结果使用同一个压缩字节上限。
        static let maxCompressedBytes = MediaRemoteBudget.artworkBytes
        /// 解码前根据 ImageIO 元数据拒绝任意大尺寸或像素炸弹。
        static let maxSourceEdge = 4096
        static let maxSourcePixels = maxSourceEdge * maxSourceEdge
        /// 最长的缩略图边；等比缩放后像素数约在此边长的平方以内。
        static let maxThumbnailEdge = 512
        /// 最终位图按 4 字节／像素计费，含隐形字节对齐余量。
        static let maxDecodedBytes = 1024 * 1024
        static let bytesPerPixel = 4
    }

    /// 明确允许的单帧静态格式；动图、位图与其他容器均不交给 ImageIO 解码。
    static let allowedTypes: Set<UTType> = [.png, .jpeg, .heic, .heif]

    /// 返回已经实际解码并等比缩小的位图；任何格式、尺寸、预算或解码异常均返回 nil。
    /// 不使用 `NSImage(data:)`；ImageIO 缩略图也只是中间结果，最终一律重绘为 RGBA8 位图。
    static func decode(_ data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= Budget.maxCompressedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              allowedTypes.contains(type),
              // 动图与多帧 HEIC 在元数据阶段就拒绝，避免解码器逐帧展开。
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let width = Int(exactly: widthNumber.doubleValue),
              let height = Int(exactly: heightNumber.doubleValue),
              width > 0, height > 0,
              width <= Budget.maxSourceEdge, height <= Budget.maxSourceEdge else { return nil }

        let (sourcePixels, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelsOverflow, sourcePixels <= Budget.maxSourcePixels else { return nil }

        // 带旋转方向的图片在生成缩略图后会交换宽高，预算预检须按显示尺寸计算。
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let expected = fittedSize(width: rotated ? height : width, height: rotated ? width : height)
        let (expectedPixels, expectedPixelOverflow) = expected.width.multipliedReportingOverflow(by: expected.height)
        let (expectedBytes, expectedByteOverflow) = expectedPixels.multipliedReportingOverflow(by: Budget.bytesPerPixel)
        guard !expectedPixelOverflow, !expectedByteOverflow,
              expectedBytes <= Budget.maxDecodedBytes,
              // 禁止 ImageIO 缓存全尺寸像素，直接取缩略图；预检已限制源尺寸。
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Budget.maxThumbnailEdge,
                kCGImageSourceShouldCache: false
            ] as CFDictionary),
              cgImage.width > 0, cgImage.height > 0,
              cgImage.width <= Budget.maxThumbnailEdge, cgImage.height <= Budget.maxThumbnailEdge else { return nil }

        // 16 位／宽色或懒解码的 ImageIO 图片在这里被强制绘制成确定的 RGBA8 像素。
        let target = fittedSize(width: cgImage.width, height: cgImage.height)
        guard let bitmap = rasterize(cgImage, width: target.width, height: target.height) else { return nil }
        let rep = NSBitmapImageRep(cgImage: bitmap)
        guard rep.bitsPerSample == 8, rep.samplesPerPixel == Budget.bytesPerPixel,
              rep.pixelsWide > 0, rep.pixelsHigh > 0,
              rep.pixelsWide <= Budget.maxThumbnailEdge,
              rep.pixelsHigh <= Budget.maxThumbnailEdge else { return nil }
        let (repBytes, repOverflow) = rep.bytesPerRow.multipliedReportingOverflow(by: rep.pixelsHigh)
        guard !repOverflow, repBytes <= Budget.maxDecodedBytes else { return nil }
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    /// 复用缩略图缓存的等比适配规则；边长始终受本解码器的预算约束。
    private static func fittedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let fitted = ThumbnailService.fittedPixelSize(
            source: CGSize(width: width, height: height),
            into: CGSize(width: Budget.maxThumbnailEdge, height: Budget.maxThumbnailEdge)
        )
        return (max(1, min(Budget.maxThumbnailEdge, Int(fitted.width.rounded()))),
                max(1, min(Budget.maxThumbnailEdge, Int(fitted.height.rounded()))))
    }

    /// 绘制到显式的 8 位／通道 RGBA 上下文，由 makeImage 持有已经解码的最终像素。
    /// CGContext 可能对行宽做对齐，因此按实际 bytesPerRow 而不是 width×4 计费。
    private static func rasterize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let rowBytes = width * Budget.bytesPerPixel
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue),
              context.bytesPerRow * context.height <= Budget.maxDecodedBytes else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bitmap = context.makeImage(), bitmap.bitsPerComponent == 8,
              bitmap.bitsPerPixel == Budget.bytesPerPixel * 8,
              bitmap.bytesPerRow * bitmap.height <= Budget.maxDecodedBytes else { return nil }
        return bitmap
    }
}
