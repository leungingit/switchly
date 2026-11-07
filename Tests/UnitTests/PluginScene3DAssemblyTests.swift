//
//  PluginScene3DAssemblyTests.swift
//  SwitchlyTests
//
//  T06: assembly owns cloning the immutable template, framing, surface binding
//  and teardown. These tests use programmatically built SCNScene trees so they
//  do not depend on a binary fixture, and they assert that two live instances
//  never share mutable geometry or materials.
//

import AppKit
import CoreGraphics
import ImageIO
import SceneKit
import XCTest
@testable import Switchly

@MainActor
final class PluginScene3DAssemblyTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/switchly-scene3d-tests")

    // MARK: - Framing and cloning

    func testAssemblyClonesTemplateFramesContentAndStripsImportedCameraAndLight() throws {
        let template = makeTemplate()
        let asset = makeAsset(template: template)
        let instance = try assemble(asset: asset, descriptor: baseDescriptor())

        XCTAssertTrue(instance.appliedScale.isFinite)
        XCTAssertGreaterThan(instance.appliedScale, 0)
        XCTAssertEqual(instance.viewportSize, CGSize(width: 320, height: 420))

        let bounds = try XCTUnwrap(PluginScene3DAssembly.bounds(of: instance.contentRoot))
        XCTAssertTrue(bounds.isUsable)
        XCTAssertEqual(bounds.center.x, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.center.y, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.center.z, 0, accuracy: 0.01)

        XCTAssertEqual(instance.contentRoot.name, "scene3d.content")
        XCTAssertNotNil(instance.scene.rootNode.childNode(withName: "scene3d.root", recursively: false))
        XCTAssertNil(instance.scene.rootNode.childNode(withName: "importedCamera", recursively: true))
        XCTAssertNil(instance.scene.rootNode.childNode(withName: "importedLight", recursively: true))
        XCTAssertNotNil(instance.cameraNode.camera)
        XCTAssertEqual(Double(instance.cameraNode.camera?.fieldOfView ?? 0),
                       PluginScene3DAssembly.fieldOfView)
        XCTAssertEqual(instance.cameraNode.constraints?.count, 1)

        // The template itself must stay untouched.
        XCTAssertNotNil(template.rootNode.childNode(withName: "model", recursively: false))
        XCTAssertNil(template.rootNode.childNode(withName: "scene3d.root", recursively: false))
        XCTAssertFalse(template.rootNode.childNodes.isEmpty)
    }

    func testApplyMovesOnlyTheCameraAroundTheFixedDistance() throws {
        let instance = try assemble(asset: makeAsset(template: makeTemplate()),
                                    descriptor: baseDescriptor())

        let origin = Scene3DCameraController.Geometry.worldPosition(for: .init(), distance: instance.cameraDistance)
        instance.apply(.init())
        XCTAssertEqual(instance.cameraNode.position.x, CGFloat(origin.x), accuracy: 0.0001)
        XCTAssertEqual(instance.cameraNode.position.y, CGFloat(origin.y), accuracy: 0.0001)
        XCTAssertEqual(instance.cameraNode.position.z, CGFloat(origin.z), accuracy: 0.0001)

        let rotated = Scene3DCameraController.Geometry.worldPosition(for: .init(yaw: 40, pitch: 20),
                                                                     distance: instance.cameraDistance)
        instance.apply(.init(yaw: 40, pitch: 20))
        XCTAssertEqual(instance.cameraNode.position.x, CGFloat(rotated.x), accuracy: 0.0001)
        XCTAssertEqual(instance.cameraNode.position.y, CGFloat(rotated.y), accuracy: 0.0001)
        XCTAssertEqual(instance.cameraNode.position.z, CGFloat(rotated.z), accuracy: 0.0001)

        instance.apply(.init(yaw: 40, pitch: 20))
        XCTAssertEqual(instance.cameraNode.position.z, CGFloat(rotated.z), accuracy: 0.0001)
    }

    // MARK: - Surfaces

    func testSurfaceBindingCopiesGeometryAndUsesOneTexture() throws {
        let rasterizer = AssemblyFakeRasterizer(image: Self.makeImage())
        let asset = makeAsset(template: makeTemplate())
        let descriptor = descriptorWithSurface(content: .text(value: "Now playing", style: .body, lines: nil))
        let instance = try PluginScene3DAssembly.assemble(
            asset: asset,
            descriptor: descriptor,
            assetDirectory: directory,
            slotSize: CGSize(width: 320, height: 420),
            artwork: nil,
            palette: .system(),
            rasterizer: rasterizer
        )

        let assembled = try XCTUnwrap(instance.contentRoot.childNode(withName: "screen", recursively: true))
        let templateNode = try XCTUnwrap(asset.templateScene.rootNode.childNode(withName: "screen", recursively: true))
        XCTAssertFalse(assembled.geometry === templateNode.geometry)

        let material = try XCTUnwrap(assembled.geometry?.firstMaterial)
        XCTAssertEqual(material.name, "scene3d.surface.screen")
        XCTAssertEqual(material.lightingModel, .constant)
        XCTAssertFalse(material.isDoubleSided)
        XCTAssertNotNil(material.diffuse.contents)
        XCTAssertEqual(material.diffuse.wrapS, .clamp)
        XCTAssertEqual(material.diffuse.wrapT, .clamp)
        // SCNMatrix4 / CATransform3D is not Equatable, so check the identity
        // components directly.
        let transform = material.diffuse.contentsTransform
        XCTAssertEqual(transform.m11, 1)
        XCTAssertEqual(transform.m22, 1)
        XCTAssertEqual(transform.m41, 0)
        XCTAssertEqual(transform.m42, 0)
        XCTAssertEqual(instance.surfaceTextureCount, 1)
        XCTAssertEqual(rasterizer.plans.count, 1)
        XCTAssertEqual(rasterizer.plans.first?.pointSize, CGSize(width: 64, height: 64))
        XCTAssertEqual(rasterizer.plans.first?.pixelSize, CGSize(width: 64, height: 64))
        XCTAssertEqual(rasterizer.plans.first?.pixelsPerPoint, 1)
    }

    /// §9.4: `size` is an output-texture pixel budget, so the rasterized bitmap
    /// must equal the declaration and never be multiplied by a backing scale.
    func testSurfaceSizeIsUsedAsOutputPixelsWithoutBackingScale() throws {
        var descriptor = baseDescriptor()
        descriptor.surfaces = [
            PluginScene3DSurface(node: "screen",
                                 size: .init(width: 241, height: 161),
                                 content: .text(value: "Now playing", style: .body, lines: nil))
        ]
        let rasterizer = AssemblyFakeRasterizer(image: Self.makeImage())
        let instance = try PluginScene3DAssembly.assemble(
            asset: makeAsset(template: makeTemplate()),
            descriptor: descriptor,
            assetDirectory: directory,
            slotSize: CGSize(width: 320, height: 420),
            artwork: nil,
            palette: .system(),
            rasterizer: rasterizer
        )

        XCTAssertEqual(instance.surfaceTextureCount, 1)
        let plan = try XCTUnwrap(rasterizer.plans.first)
        XCTAssertEqual(plan.pointSize, CGSize(width: 241, height: 161))
        XCTAssertEqual(plan.pixelsPerPoint, 1)
        XCTAssertEqual(plan.pixelSize, CGSize(width: 241, height: 161))
    }

    func testTwoInstancesDoNotShareSurfaceGeometryOrMaterials() throws {
        let asset = makeAsset(template: makeTemplate())
        let descriptor = descriptorWithSurface(content: .text(value: "A", style: .body, lines: nil))
        let first = try assemble(asset: asset, descriptor: descriptor)
        let second = try assemble(asset: asset, descriptor: descriptor)

        let firstScreen = try XCTUnwrap(first.contentRoot.childNode(withName: "screen", recursively: true))
        let secondScreen = try XCTUnwrap(second.contentRoot.childNode(withName: "screen", recursively: true))
        XCTAssertFalse(firstScreen.geometry === secondScreen.geometry)
        XCTAssertFalse(firstScreen.geometry?.firstMaterial === secondScreen.geometry?.firstMaterial)

        // Mutating one live instance must not leak into the other or the template.
        firstScreen.geometry?.firstMaterial?.diffuse.contents = NSColor.red
        XCTAssertNotNil(secondScreen.geometry?.firstMaterial?.diffuse.contents)
        XCTAssertFalse(secondScreen.geometry?.firstMaterial?.diffuse.contents is NSColor)
        let templateScreen = try XCTUnwrap(asset.templateScene.rootNode.childNode(withName: "screen", recursively: true))
        XCTAssertNotEqual(templateScreen.geometry?.firstMaterial?.name, "scene3d.surface.screen")

        XCTAssertEqual(first.surfaceTextureCount, 1)
        XCTAssertEqual(second.surfaceTextureCount, 1)
    }

    func testHitsMapToRouterHitsAndAccessibilityTexts() throws {
        let descriptor = descriptorWithSurface(
            content: .vstack(children: [
                .text(value: "Now playing", style: .title, lines: nil),
                .progress(value: 0.5, style: .linear, rate: nil),
            ], spacing: nil, align: nil)
        )
        let instance = try assemble(asset: makeAsset(template: makeTemplate()),
                                    descriptor: descriptor)

        XCTAssertEqual(instance.hits, [
            Scene3DHitRouter.Hit(node: "button", actionID: "press", label: "Play", value: 0.5, enabled: true)
        ])
        XCTAssertEqual(instance.texts.count, 2)
        XCTAssertEqual(instance.texts.map(\.label), ["Now playing", "50%"])
        XCTAssertTrue(instance.texts.allSatisfy { $0.value.isEmpty })
        XCTAssertEqual(instance.texts[0].id, "scene3d.surface.screen.0.0")
        XCTAssertEqual(instance.texts[1].id, "scene3d.surface.screen.1.1")
    }

    // MARK: - Teardown

    func testTeardownIsIdempotentAndReleasesTextures() throws {
        let asset = makeAsset(template: makeTemplate())
        let instance = try assemble(asset: asset, descriptor: descriptorWithSurface(
            content: .text(value: "A", style: .body, lines: nil)
        ))

        XCTAssertEqual(instance.surfaceTextureCount, 1)
        XCTAssertFalse(instance.isTornDown)
        instance.teardown()
        XCTAssertTrue(instance.isTornDown)
        XCTAssertEqual(instance.surfaceTextureCount, 0)
        XCTAssertNil(instance.contentRoot.parent)
        XCTAssertTrue(instance.scene.rootNode.childNodes.isEmpty)
        XCTAssertNil(instance.scene.background.contents)

        instance.teardown()
        XCTAssertEqual(instance.surfaceTextureCount, 0)
    }

    func testTornDownInstanceIgnoresCameraUpdates() throws {
        let instance = try assemble(asset: makeAsset(template: makeTemplate()),
                                    descriptor: baseDescriptor())
        let before = instance.cameraNode.position
        instance.teardown()
        instance.apply(.init(yaw: 90, pitch: 0))
        XCTAssertEqual(instance.cameraNode.position.x, before.x)
        XCTAssertEqual(instance.cameraNode.position.y, before.y)
        XCTAssertEqual(instance.cameraNode.position.z, before.z)
    }

    // MARK: - Failures

    func testMissingNodeFallsBackToNodeNotFound() throws {
        var descriptor = baseDescriptor()
        descriptor.surfaces = [
            PluginScene3DSurface(node: "missing", size: .init(width: 64, height: 64),
                                 content: .text(value: "x", style: .body, lines: nil))
        ]
        let asset = makeAsset(template: makeTemplate())

        XCTAssertThrowsError(try assemble(asset: asset, descriptor: descriptor)) { error in
            XCTAssertEqual(error as? PluginScene3DFailure, .nodeNotFound("missing"))
        }
    }

    func testDuplicateNodeFallsBackToNodeAmbiguous() throws {
        let template = makeTemplate()
        let model = try XCTUnwrap(template.rootNode.childNode(withName: "model", recursively: false))
        let duplicate = SCNNode(geometry: SCNPlane(width: 2, height: 1))
        duplicate.name = "screen"
        model.addChildNode(duplicate)
        var descriptor = baseDescriptor()
        descriptor.surfaces = [
            PluginScene3DSurface(node: "screen", size: .init(width: 64, height: 64),
                                 content: .text(value: "x", style: .body, lines: nil))
        ]

        XCTAssertThrowsError(try assemble(asset: makeAsset(template: template), descriptor: descriptor)) { error in
            XCTAssertEqual(error as? PluginScene3DFailure, .nodeAmbiguous("screen"))
        }
    }

    func testGeometryWithoutTexcoordsFallsBackToUVMissing() throws {
        let template = SCNScene()
        let node = SCNNode(geometry: makeUntexturedGeometry())
        node.name = "plain"
        template.rootNode.addChildNode(node)
        var descriptor = baseDescriptor()
        descriptor.surfaces = [
            PluginScene3DSurface(node: "plain", size: .init(width: 64, height: 64),
                                 content: .text(value: "x", style: .body, lines: nil))
        ]

        XCTAssertThrowsError(try assemble(asset: makeAsset(template: template), descriptor: descriptor)) { error in
            XCTAssertEqual(error as? PluginScene3DFailure, .uvMissing("plain"))
        }
    }

    func testRasterizerNilFallsBackToRenderFailed() throws {
        let descriptor = descriptorWithSurface(content: .text(value: "x", style: .body, lines: nil))
        let asset = makeAsset(template: makeTemplate())

        XCTAssertThrowsError(try PluginScene3DAssembly.assemble(
            asset: asset,
            descriptor: descriptor,
            assetDirectory: directory,
            slotSize: CGSize(width: 320, height: 420),
            artwork: nil,
            palette: .system(),
            rasterizer: AssemblyFakeRasterizer(image: nil)
        )) { error in
            XCTAssertEqual(error as? PluginScene3DFailure, .renderFailed)
        }
    }

    func testEmptyTemplateFallsBackToDecodeFailed() throws {
        let asset = makeAsset(template: SCNScene())
        XCTAssertThrowsError(try assemble(asset: asset, descriptor: baseDescriptor())) { error in
            guard case .decodeFailed = (error as? PluginScene3DFailure) else {
                return XCTFail("expected decodeFailed, got \(error)")
            }
        }
    }

    // MARK: - Hit node mesh validation

    private func meshNode(_ name: String) -> SCNNode {
        let node = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
        node.name = name
        return node
    }

    func testHitNodeWithOneVisibleMeshPasses() throws {
        XCTAssertNoThrow(try PluginScene3DAssembly.requireSingleVisibleMesh(meshNode("a"), name: "a"))
    }

    func testHitNodeWithHiddenOrTransparentMeshIsRejected() {
        let hidden = meshNode("h")
        hidden.isHidden = true
        XCTAssertThrowsError(try PluginScene3DAssembly.requireSingleVisibleMesh(hidden, name: "h"))
        let ghost = meshNode("g")
        ghost.opacity = 0
        XCTAssertThrowsError(try PluginScene3DAssembly.requireSingleVisibleMesh(ghost, name: "g"))
    }

    func testHitNodeWithMultipleVisibleMeshesIsAmbiguous() {
        let group = SCNNode()
        group.name = "grp"
        group.addChildNode(meshNode("x"))
        group.addChildNode(meshNode("y"))
        XCTAssertThrowsError(try PluginScene3DAssembly.requireSingleVisibleMesh(group, name: "grp")) { error in
            guard case PluginScene3DFailure.nodeAmbiguous = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Fit math

    func testContainScaleRejectsInvalidInputs() {
        XCTAssertNil(PluginScene3DAssembly.containScale(
            bounds: PluginScene3DBounds(minimum: .zero, maximum: .zero),
            cameraDistance: 4, fieldOfView: 30, aspect: 1
        ))
        XCTAssertNil(PluginScene3DAssembly.containScale(
            bounds: PluginScene3DBounds(minimum: SIMD3(repeating: -1), maximum: SIMD3(repeating: 1)),
            cameraDistance: 0, fieldOfView: 30, aspect: 1
        ))
        XCTAssertNil(PluginScene3DAssembly.containScale(
            bounds: PluginScene3DBounds(minimum: SIMD3(repeating: -1), maximum: SIMD3(repeating: 1)),
            cameraDistance: 4, fieldOfView: 30, aspect: 0
        ))
    }

    // MARK: - Builders

    private func makeTemplate() -> SCNScene {
        let scene = SCNScene()
        let model = SCNNode()
        model.name = "model"

        let screen = SCNNode(geometry: SCNPlane(width: 2, height: 1))
        screen.name = "screen"
        model.addChildNode(screen)

        let button = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
        button.name = "button"
        button.position = SCNVector3(0, -1.5, 0)
        model.addChildNode(button)

        let importedCamera = SCNNode()
        importedCamera.name = "importedCamera"
        importedCamera.camera = SCNCamera()
        model.addChildNode(importedCamera)

        let importedLight = SCNNode()
        importedLight.name = "importedLight"
        importedLight.light = SCNLight()
        model.addChildNode(importedLight)

        scene.rootNode.addChildNode(model)
        return scene
    }

    /// A geometry with vertices/elements but deliberately no `.texcoord` source.
    private func makeUntexturedGeometry() -> SCNGeometry {
        let vertices: [SCNVector3] = [
            SCNVector3(0, 0, 0), SCNVector3(1, 0, 0), SCNVector3(0, 1, 0)
        ]
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: [UInt16(0), 1, 2], primitiveType: .triangles)
        return SCNGeometry(sources: [source], elements: [element])
    }

    private func baseDescriptor() -> PluginScene3DDescriptor {
        PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                hits: [PluginScene3DHit(node: "button", id: "press", label: "Play", value: 0.5)],
                                fallback: .text(value: "fallback", style: .body, lines: nil))
    }

    private func descriptorWithSurface(content: PluginUINode) -> PluginScene3DDescriptor {
        var descriptor = baseDescriptor()
        descriptor.surfaces = [
            PluginScene3DSurface(node: "screen", size: .init(width: 64, height: 64), content: content)
        ]
        return descriptor
    }

    private func makeAsset(template: SCNScene) -> PluginScene3DAsset {
        PluginScene3DAsset(
            identity: PluginScene3DIdentity(pluginID: "test.plugin", assetHash: "h"),
            templateScene: template,
            nodeNames: [],
            fileBytes: 0,
            report: GLBPreflight.Report(
                nodeNames: [],
                meshCount: 0,
                nodeCount: 0,
                triangleCount: 0,
                decodedTextureBytes: 0
            )
        )
    }

    private func assemble(asset: PluginScene3DAsset,
                          descriptor: PluginScene3DDescriptor) throws -> PluginScene3DInstance {
        try PluginScene3DAssembly.assemble(
            asset: asset,
            descriptor: descriptor,
            assetDirectory: directory,
            slotSize: CGSize(width: 320, height: 420),
            artwork: nil,
            palette: .system(),
            rasterizer: AssemblyFakeRasterizer(image: Self.makeImage())
        )
    }

    private static func makeImage(width: Int = 4, height: Int = 4) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

/// Namespaced differently from the file-private fake in the surface renderer
/// tests because two `FakeRasterizer` types in one module would collide.
@MainActor
private final class AssemblyFakeRasterizer: PluginSurfaceRasterizing {
    var image: CGImage?
    private(set) var plans: [PluginSurfaceRasterPlan] = []

    init(image: CGImage?) {
        self.image = image
    }

    func rasterize(_ plan: PluginSurfaceRasterPlan) -> PluginSurfaceTexture? {
        plans.append(plan)
        guard let image else { return nil }
        return PluginSurfaceTexture(
            image: image,
            pointSize: plan.pointSize,
            pixelsPerPoint: plan.pixelsPerPoint,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            orientation: .up,
            contentSignature: plan.contentSignature
        )
    }
}
