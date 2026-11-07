import XCTest
import SceneKit
import GLTFKit2
@testable import Switchly

final class GLTFKit2IntegrationTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testLoadsProbeGLBAndKeepsNodeNames() throws {
        let url = Self.repoRoot
            .appendingPathComponent("docs/plugins/assets/3d-loading-probe-2026-11-06/ipod-source-geometry.glb")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("probe asset missing") }
        let data = try Data(contentsOf: url)
        _ = try GLBPreflight.inspect(data)
        let asset = try GLTFAsset(data: data, options: [:])
        let scene = SCNScene(gltfAsset: asset)
        XCTAssertNotNil(scene.rootNode.childNode(withName: "mesh_wheel_play", recursively: true))
    }

    /// The real iPod GLB must satisfy the music plugin v2 descriptor: UV on the
    /// screen mesh, one unique visible wheel mesh. Otherwise the host silently
    /// shows the 2D fallback.
    @MainActor
    func testRealIPodAssemblesWithMusicV2Descriptor() throws {
        let url = Self.repoRoot
            .appendingPathComponent("docs/plugins/assets/3d-loading-probe-2026-11-06/ipod-source-geometry.glb")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("probe asset missing") }
        let data = try Data(contentsOf: url)
        let report = try GLBPreflight.inspect(data)
        let gltf = try GLTFAsset(data: data, options: [:])
        let template = SCNScene(gltfAsset: gltf)
        let asset = PluginScene3DAsset(
            identity: PluginScene3DIdentity(pluginID: "test.plugin", assetHash: "real"),
            templateScene: template, nodeNames: [], fileBytes: data.count, report: report)
        let text = PluginUINode.text(value: "Now playing", style: .body, lines: nil)
        let descriptor = PluginScene3DDescriptor(
            key: "music-player", asset: "assets/ipod.glb",
            surfaces: [PluginScene3DSurface(node: "mesh_screen", size: .init(width: 320, height: 252), content: text)],
            hits: [PluginScene3DHit(node: "mesh_wheel_play", id: "toggle", label: "Play", value: nil)],
            fallback: text)
        let instance = try PluginScene3DAssembly.assemble(
            asset: asset, descriptor: descriptor, assetDirectory: Self.repoRoot,
            slotSize: CGSize(width: 320, height: 420), artwork: nil, palette: .system(),
            rasterizer: RealAssetFakeRasterizer())
        XCTAssertEqual(instance.hits.map(\.actionID), ["toggle"])
        XCTAssertEqual(instance.surfaceTextureCount, 1)
        instance.teardown()
    }
}

@MainActor
private final class RealAssetFakeRasterizer: PluginSurfaceRasterizing {
    func rasterize(_ plan: PluginSurfaceRasterPlan) -> PluginSurfaceTexture? {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return PluginSurfaceTexture(image: ctx.makeImage()!, pointSize: plan.pointSize,
                                    pixelsPerPoint: plan.pixelsPerPoint,
                                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                                    orientation: .up, contentSignature: plan.contentSignature)
    }
}
