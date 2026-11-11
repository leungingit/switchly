import AppKit
import GLTFKit2
import SceneKit
import XCTest
@testable import Switchly

/// 真实 iPod GLB 的交互验证：四个转盘扇区必须能被 SceneKit 命中并路由到声明的动作。
/// 使用真实资产与真实 SCNView.hitTest，而不是只测 Router 的纯逻辑。
@MainActor
final class PluginScene3DIPodInteractionTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// 四个动作都落在 `wheel_ring` 的环带上，按扇区区分；`point` 是环带中线（半径 67）上的局部坐标。
    private static let sectors: [(sector: PluginScene3DSector, id: String, point: SIMD2<Float>)] = [
        (.top, "love", SIMD2(0, 67)),
        (.left, "previous", SIMD2(-67, 0)),
        (.right, "next", SIMD2(67, 0)),
        (.bottom, "toggle", SIMD2(0, -67)),
    ]

    private func makeInstance(slot: CGSize) throws -> PluginScene3DInstance {
        // 预装插件产物（make prepare-plugins 生成）；缺失时跳过。
        let url = Self.repoRoot
            .appendingPathComponent(".build/Plugins/com.switchly.music-controls/assets/ipod.glb")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("ipod asset missing") }
        let data = try Data(contentsOf: url)
        let report = try GLBPreflight.inspect(data)
        let template = SCNScene(gltfAsset: try GLTFAsset(data: data, options: [:]))
        let asset = PluginScene3DAsset(
            identity: PluginScene3DIdentity(pluginID: "test.plugin", assetHash: "ipod-interaction"),
            templateScene: template, nodeNames: [], fileBytes: data.count, report: report)
        let text = PluginUINode.text(value: "x", style: .body, lines: nil)
        let descriptor = PluginScene3DDescriptor(
            key: "music-player", asset: "assets/ipod.glb",
            camera: .init(yaw: 0, pitch: 0),
            // 与音乐插件一致：环带既贴图（图标）又按扇区分成四个可点击动作。
            surfaces: [PluginScene3DSurface(node: "wheel_ring", size: .init(width: 368, height: 368),
                                            content: .image(source: .symbol("play.fill"), size: .m, corner: nil))],
            hits: Self.sectors.map {
                PluginScene3DHit(node: "wheel_ring", id: $0.id, label: $0.id, sector: $0.sector)
            },
            fallback: text)
        return try PluginScene3DAssembly.assemble(
            asset: asset, descriptor: descriptor, assetDirectory: Self.repoRoot,
            slotSize: slot, artwork: nil, palette: .system(),
            rasterizer: CoreGraphicsPluginSurfaceRasterizer(assetDirectory: Self.repoRoot))
    }

    func testEveryRingSectorRoutesToItsAction() throws {
        let slot = CGSize(width: 300, height: 470)
        let instance = try makeInstance(slot: slot)
        defer { instance.teardown() }
        XCTAssertEqual(instance.surfaceTextureCount, 1)

        let view = SCNView(frame: CGRect(origin: .zero, size: slot))
        view.scene = instance.scene
        view.backgroundColor = .clear
        view.pointOfView = instance.cameraNode
        let adapter = Scene3DHitTestAdapter(view: view)
        let router = Scene3DHitRouter(hits: instance.hits)
        let cameraPosition = Scene3DCameraController.Geometry.worldPosition(
            for: .init(yaw: 0, pitch: 0), distance: instance.cameraDistance)

        if let dir = ProcessInfo.processInfo.environment["IPOD_SNAPSHOT_DIR"] {
            let image = view.snapshot()
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("snapshot.png"))
            }
        }

        let node = try XCTUnwrap(instance.contentRoot.childNode(withName: "wheel_ring", recursively: true))
        for entry in Self.sectors {
            let world = node.convertPosition(SCNVector3(entry.point.x, entry.point.y, 0), to: nil)
            let projected = view.projectPoint(world)
            let appKit = CGPoint(x: projected.x, y: projected.y)
            let candidates = adapter.hitCandidates(at: appKit)
            let routed = router.route(candidates: candidates, cameraPosition: cameraPosition)
            XCTAssertEqual(routed?.id, entry.id,
                           "\(entry.sector) at \(appKit) candidates=\(candidates.map { $0.nodeNameChain.first ?? "?" })")
        }
    }
}
