import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Switchly

final class MediaArtworkDecoderTests: XCTestCase {
    /// 用 CGContext 生成真实压缩编码，避免测试夹具依赖仓库资源。
    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func pixelSize(of image: NSImage) throws -> CGSize {
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    func testValidPNGProducesDecodedThumbnailWithinMemoryBudget() throws {
        let source = try png(width: 900, height: 450)
        let image = try XCTUnwrap(MediaArtworkDecoder.decode(source))
        let size = try pixelSize(of: image)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.bitsPerSample, 8)
        XCTAssertLessThanOrEqual(rep.bytesPerRow * rep.pixelsHigh, MediaArtworkDecoder.Budget.maxDecodedBytes)
        let original = try XCTUnwrap(NSBitmapImageRep(data: source)?.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))
        let color = try XCTUnwrap(rep.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, original.redComponent, accuracy: 0.02)
        XCTAssertEqual(color.greenComponent, original.greenComponent, accuracy: 0.02)
        XCTAssertEqual(color.blueComponent, original.blueComponent, accuracy: 0.02)
        XCTAssertEqual(size, CGSize(width: 512, height: 256))
        XCTAssertLessThanOrEqual(Int(size.width * size.height) * MediaArtworkDecoder.Budget.bytesPerPixel,
                                MediaArtworkDecoder.Budget.maxDecodedBytes)
    }

    func testSmallImageIsNotUpscaled() throws {
        let image = try XCTUnwrap(MediaArtworkDecoder.decode(png(width: 30, height: 20)))
        XCTAssertEqual(try pixelSize(of: image), CGSize(width: 30, height: 20))
    }

    func testMalformedAndUnsupportedDataAreRejected() throws {
        let pngData = try png(width: 8, height: 8)
        for data in [Data(), Data([0x00, 0x01, 0x02]), Data(pngData.prefix(40)),
                     Data("not an image".utf8), Data(repeating: 0xFF, count: 64)] {
            XCTAssertNil(MediaArtworkDecoder.decode(data))
        }
    }

    func testCompressedByteLimitIsRejectedBeforeDecoding() throws {
        var data = try png(width: 8, height: 8)
        data.append(Data(count: MediaArtworkDecoder.Budget.maxCompressedBytes))
        XCTAssertNil(MediaArtworkDecoder.decode(data))
        XCTAssertEqual(MediaArtworkDecoder.Budget.maxCompressedBytes, MediaRemoteBudget.artworkBytes)
    }

    func testOversizedSourcePixelsAreRejected() throws {
        // 4096×4097 的稀疏 PNG 压缩远低于 8 MiB，用元数据阻止潜在像素炸弹。
        let data = try png(width: MediaArtworkDecoder.Budget.maxSourceEdge,
                           height: MediaArtworkDecoder.Budget.maxSourceEdge + 1)
        XCTAssertLessThan(data.count, MediaArtworkDecoder.Budget.maxCompressedBytes)
        XCTAssertNil(MediaArtworkDecoder.decode(data))
    }

    func testBudgetConstantsMatchTheAgreedBounds() {
        XCTAssertEqual(MediaArtworkDecoder.Budget.maxSourcePixels, 4096 * 4096)
        XCTAssertEqual(MediaArtworkDecoder.Budget.maxThumbnailEdge, 512)
        XCTAssertEqual(MediaArtworkDecoder.Budget.maxDecodedBytes, 1024 * 1024)
        XCTAssertEqual(MediaArtworkDecoder.allowedTypes, [.png, .jpeg, .heic, .heif])
    }
}
