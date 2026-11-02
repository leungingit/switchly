import AppKit
import SwiftUI
import XCTest
@testable import Switchly

@MainActor
final class PluginAssetBudgetTests: XCTestCase {
    func testImageLayersCannotEscapeThePluginDirectory() throws {
        for path in ["../x.png", "/etc/passwd", "a/../../x.png", ""] {
            let json = #"{"kind":"image","image":"\#(path)","w":10,"h":10}"#
            XCTAssertThrowsError(try JSONDecoder().decode(SceneLayer.self, from: Data(json.utf8)), path)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SceneLayer.self, from: Data(#"{"kind":"image","w":10,"h":10}"#.utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(SceneLayer.self, from: Data(#"{"kind":"image","image":"assets/a.png","w":10,"h":10}"#.utf8)))
    }

    func testOversizedTextureIsRefusedOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-texture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = SceneAssets.maxEdge + 1
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("wide.png"))
        let assets = SceneAssets(directory: dir)
        XCTAssertNil(assets.image("wide.png"))
        XCTAssertEqual(assets.decodedBytes, 0)
    }
    @available(macOS 13.0, *)
    func testOrdinaryPluginImageRendersThroughSharedAssetBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(image.bitmapData)
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = y * image.bytesPerRow + x * 4
                pixels[offset] = 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 255
            }
        }
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("fixture.png"))
        let assets = SceneAssets(directory: directory)
        XCTAssertNotNil(assets.image("fixture.png"))
        XCTAssertNil(assets.image("../fixture.png"))
        let view = PluginOverlayView(node: .image(source: .pluginAsset("fixture.png"), size: .l, corner: nil),
            material: AppSettings.default.crystalMaterial, isGlassActive: false, assetDirectory: directory,
            onAction: { _, _ in }).frame(width: 80, height: 80).background(Color.white)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 80, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        // SwiftUI 图片由合成层绘制，NSView.cacheDisplay 不包含该层；使用原生 SwiftUI 渲染器取证。
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rendered = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(rendered.tiffRepresentation)))
        let center = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.redComponent, 0.8)
        XCTAssertLessThan(center.greenComponent, 0.2, "应渲染真实红色资产而不是占位图")
        if let output = ProcessInfo.processInfo.environment["SWITCHLY_PLUGIN_QA_DIR"] {
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("plugin-image.png"))
        }
    }
}
