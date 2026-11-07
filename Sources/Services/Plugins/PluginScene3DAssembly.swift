//
//  PluginScene3DAssembly.swift
//  Switchly
//
//  T06: assembles one live scene3d instance from the immutable cached asset.
//  The cached template is never rendered or mutated: this assembly clones the
//  content, strips imported cameras/lights, frames the model with the host's
//  fixed camera, and gives every surface its own geometry copy, texture and
//  material. All SceneKit work here runs on the main actor.
//
//  This file deliberately does not know about SwiftUI or SCNView. The view
//  layer supplies a `PluginSurfaceRasterizing` implementation and a scene host;
//  keeping the assembly scene-only lets the lifecycle be unit-tested without a
//  GPU or a visible window.
//

import AppKit
import Foundation
import SceneKit
import simd

/// Axis-aligned bounds in the content node's coordinate space.
struct PluginScene3DBounds: Equatable {
    var minimum: SIMD3<Float>
    var maximum: SIMD3<Float>

    var center: SIMD3<Float> { (minimum + maximum) * 0.5 }
    var extents: SIMD3<Float> { (maximum - minimum) * 0.5 }
    var radius: Float { simd_length(extents) }
    var isUsable: Bool {
        minimum.x.isFinite && minimum.y.isFinite && minimum.z.isFinite
            && maximum.x.isFinite && maximum.y.isFinite && maximum.z.isFinite
            && radius.isFinite && radius > 0
    }
}

/// One live, per-slot scene. The instance owns its cloned scene tree, camera,
/// surface materials, textures and renderer cache. `teardown()` is mandatory
/// before the instance is released so the SCNView stops retaining the scene and
/// the surface renderer releases its bitmaps.
@MainActor
final class PluginScene3DInstance {
    let identity: PluginScene3DIdentity
    let scene: SCNScene
    let contentRoot: SCNNode
    let cameraNode: SCNNode
    let cameraDistance: Float
    let hits: [Scene3DHitRouter.Hit]
    let texts: [Scene3DAccessibilityModel.TextSource]
    let viewportSize: CGSize
    let appliedScale: Float

    private let surfaceRenderer: PluginSurfaceRenderer
    private(set) var isTornDown = false

    init(identity: PluginScene3DIdentity,
         scene: SCNScene,
         contentRoot: SCNNode,
         cameraNode: SCNNode,
         cameraDistance: Float,
         hits: [Scene3DHitRouter.Hit],
         texts: [Scene3DAccessibilityModel.TextSource],
         viewportSize: CGSize,
         appliedScale: Float,
         surfaceRenderer: PluginSurfaceRenderer) {
        self.identity = identity
        self.scene = scene
        self.contentRoot = contentRoot
        self.cameraNode = cameraNode
        self.cameraDistance = cameraDistance
        self.hits = hits
        self.texts = texts
        self.viewportSize = viewportSize
        self.appliedScale = appliedScale
        self.surfaceRenderer = surfaceRenderer
    }

    /// Applies an orbit angle to the fixed host camera. The camera always looks
    /// at the model origin through a look-at constraint; only its position
    /// changes.
    func apply(_ pose: Scene3DCameraController.Pose) {
        guard !isTornDown else { return }
        let position = Scene3DCameraController.Geometry.worldPosition(
            for: pose,
            distance: cameraDistance
        )
        cameraNode.position = SCNVector3(position.x, position.y, position.z)
    }

    /// Only exposed for lifecycle tests; textures must never be released
    /// without `teardown()`.
    var surfaceTextureCount: Int { surfaceRenderer.cachedTextureCount }

    /// Removes the cloned scene from the host and releases surface textures.
    /// Idempotent; callers must also clear any SCNView reference to `scene`.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        contentRoot.removeFromParentNode()
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
        }
        scene.background.contents = nil
        surfaceRenderer.removeAll()
    }
}

enum PluginScene3DAssembly {
    static let cameraDistance: Float = 4
    static let fieldOfView: Double = 30
    /// Leaves a small margin around the fitted model so surfaces are not
    /// clipped by the viewport edge.
    static let containPadding: Float = 0.9
    static let maximumScale: Float = 10_000

    /// Builds an instance from an immutable template. Any failure throws a
    /// runtime `PluginScene3DFailure`; the caller switches to the plugin fallback.
    @MainActor
    static func assemble(asset: PluginScene3DAsset,
                         descriptor: PluginScene3DDescriptor,
                         assetDirectory: URL,
                         slotSize: CGSize,
                         artwork: PluginSurfaceArtwork?,
                         palette: PluginSurfacePalette,
                         rasterizer: PluginSurfaceRasterizing) throws -> PluginScene3DInstance {
        let renderer = PluginSurfaceRenderer(rasterizer: rasterizer)
        do {
            let scene = SCNScene()
            scene.background.contents = NSColor.clear
            scene.background.intensity = 1

            let contentRoot = cloneTemplateContent(from: asset.templateScene)
            guard let bounds = bounds(of: contentRoot) else {
                throw PluginScene3DFailure.decodeFailed("scene3d asset has no renderable geometry")
            }
            guard let scale = containScale(bounds: bounds,
                                           cameraDistance: cameraDistance,
                                           fieldOfView: fieldOfView,
                                           aspect: aspectRatio(of: slotSize)) else {
                throw PluginScene3DFailure.decodeFailed("scene3d asset bounds are invalid")
            }

            contentRoot.scale = SCNVector3(scale, scale, scale)
            let centered = -bounds.center * scale
            contentRoot.position = SCNVector3(centered.x, centered.y, centered.z)
            let root = SCNNode()
            root.name = "scene3d.root"
            root.addChildNode(contentRoot)
            scene.rootNode.addChildNode(root)

            let cameraNode = makeCameraNode()
            let targetNode = SCNNode()
            targetNode.position = SCNVector3Zero
            root.addChildNode(targetNode)
            root.addChildNode(cameraNode)
            let lookAt = SCNLookAtConstraint(target: targetNode)
            lookAt.isGimbalLockEnabled = true
            cameraNode.constraints = [lookAt]
            addFixedLights(to: root)

            try bindSurfaces(descriptor: descriptor,
                             contentRoot: contentRoot,
                             assetDirectory: assetDirectory,
                             artwork: artwork,
                             palette: palette,
                             renderer: renderer)
            let hits = try bindHits(descriptor: descriptor, contentRoot: contentRoot)
            let texts = collectTexts(descriptor: descriptor)

            let instance = PluginScene3DInstance(
                identity: asset.identity,
                scene: scene,
                contentRoot: contentRoot,
                cameraNode: cameraNode,
                cameraDistance: cameraDistance,
                hits: hits,
                texts: texts,
                viewportSize: slotSize,
                appliedScale: scale,
                surfaceRenderer: renderer
            )
            instance.apply(Scene3DCameraController.Pose(yaw: descriptor.camera.yaw,
                                                        pitch: descriptor.camera.pitch))
            return instance
        } catch {
            renderer.removeAll()
            throw error
        }
    }

    // MARK: - Fitting

    /// Recursively accumulates geometry bounds through node transforms. Pure
    /// SceneKit traversal, exposed for the fit unit tests.
    static func bounds(of node: SCNNode) -> PluginScene3DBounds? {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false

        func visit(_ current: SCNNode, _ transform: simd_float4x4) {
            let world = transform * current.simdTransform
            if let geometry = current.geometry {
                let box = geometry.boundingBox
                let corners = [
                    SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z)),
                    SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.max.z)),
                    SIMD3<Float>(Float(box.min.x), Float(box.max.y), Float(box.min.z)),
                    SIMD3<Float>(Float(box.min.x), Float(box.max.y), Float(box.max.z)),
                    SIMD3<Float>(Float(box.max.x), Float(box.min.y), Float(box.min.z)),
                    SIMD3<Float>(Float(box.max.x), Float(box.min.y), Float(box.max.z)),
                    SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.min.z)),
                    SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z)),
                ]
                for corner in corners {
                    let point = (world * SIMD4<Float>(corner, 1)).xyz
                    minimum = simd_min(minimum, point)
                    maximum = simd_max(maximum, point)
                    found = true
                }
            }
            for child in current.childNodes {
                visit(child, world)
            }
        }

        visit(node, matrix_identity_float4x4)
        guard found else { return nil }
        return PluginScene3DBounds(minimum: minimum, maximum: maximum)
    }

    /// Scale that keeps the whole model inside a camera at the origin looking
    /// down +Z, using a sphere bound and a small padding.
    static func containScale(bounds: PluginScene3DBounds,
                             cameraDistance: Float,
                             fieldOfView: Double,
                             aspect: CGFloat) -> Float? {
        guard bounds.isUsable,
              cameraDistance > 0,
              fieldOfView > 0, fieldOfView < 180,
              aspect.isFinite, aspect > 0 else {
            return nil
        }
        let verticalHalf = Float(fieldOfView) * .pi / 360
        let horizontalHalf = atan(tan(verticalHalf) * Float(aspect))
        let limitingHalf = min(verticalHalf, horizontalHalf)
        let maxRadius = cameraDistance * sin(limitingHalf) * containPadding
        guard maxRadius.isFinite, maxRadius > 0 else { return nil }
        let scale = maxRadius / bounds.radius
        guard scale.isFinite, scale > 0 else { return nil }
        return min(scale, maximumScale)
    }

    private static func aspectRatio(of size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    // MARK: - Template cloning

    private static func cloneTemplateContent(from template: SCNScene) -> SCNNode {
        let holder = SCNNode()
        holder.name = "scene3d.content"
        for child in template.rootNode.childNodes {
            let clone = child.clone()
            // The imported glTF root itself may carry a camera or light, so it
            // must be checked before descending into children.
            if clone.camera != nil || clone.light != nil { continue }
            removeCamerasAndLights(from: clone)
            holder.addChildNode(clone)
        }
        return holder
    }

    private static func removeCamerasAndLights(from node: SCNNode) {
        for child in node.childNodes {
            if child.camera != nil || child.light != nil {
                child.removeFromParentNode()
            } else {
                removeCamerasAndLights(from: child)
            }
        }
    }

    // MARK: - Camera and lighting

    private static func makeCameraNode() -> SCNNode {
        let node = SCNNode()
        node.name = "scene3d.camera"
        let camera = SCNCamera()
        camera.fieldOfView = fieldOfView
        camera.projectionDirection = .vertical
        camera.zNear = 0.05
        camera.zFar = 50
        camera.wantsDepthOfField = false
        camera.wantsHDR = false
        node.camera = camera
        node.position = SCNVector3(0, 0, cameraDistance)
        return node
    }

    private static func addFixedLights(to root: SCNNode) {
        let ambientNode = SCNNode()
        ambientNode.name = "scene3d.ambient"
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 650
        ambient.color = NSColor.white
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let keyNode = SCNNode()
        keyNode.name = "scene3d.key"
        let key = SCNLight()
        key.type = .directional
        key.intensity = 750
        key.color = NSColor.white
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.7, 0.6, 0)
        root.addChildNode(keyNode)
    }

    // MARK: - Surfaces

    @MainActor
    private static func bindSurfaces(descriptor: PluginScene3DDescriptor,
                                     contentRoot: SCNNode,
                                     assetDirectory: URL,
                                     artwork: PluginSurfaceArtwork?,
                                     palette: PluginSurfacePalette,
                                     renderer: PluginSurfaceRenderer) throws {
        for surface in descriptor.surfaces {
            let node = try uniqueNode(named: surface.node, in: contentRoot)
            guard let geometry = node.geometry?.copy() as? SCNGeometry,
                  !geometry.sources(for: .texcoord).isEmpty else {
                throw PluginScene3DFailure.uvMissing(surface.node)
            }

            // §9.4 declares `size` in output texture pixels, so the rasterized
            // bitmap must match it exactly. `pixelsPerPoint: 1` keeps the
            // declared dimensions from being multiplied by a backing scale.
            let request = PluginSurfaceRequest(
                content: surface.content,
                pointSize: CGSize(width: surface.size.width, height: surface.size.height),
                pixelsPerPoint: 1,
                artwork: artwork,
                assetDirectory: assetDirectory,
                palette: palette
            )
            guard let texture = renderer.texture(for: request) else {
                throw PluginScene3DFailure.renderFailed
            }

            let material = SCNMaterial()
            material.name = "scene3d.surface.\(surface.node)"
            material.lightingModel = .constant
            material.isDoubleSided = false
            material.diffuse.contents = texture.image
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            material.diffuse.minificationFilter = .linear
            material.diffuse.magnificationFilter = .linear
            material.diffuse.mipFilter = .none
            material.diffuse.intensity = 1
            // The bitmap is already top-left oriented; no second flip.
            material.diffuse.contentsTransform = SCNMatrix4Identity

            let materialCount = max(1, geometry.elements.count)
            geometry.materials = Array(repeating: material, count: materialCount)
            node.geometry = geometry
        }
    }

    // MARK: - Hits

    private static func bindHits(descriptor: PluginScene3DDescriptor,
                                 contentRoot: SCNNode) throws -> [Scene3DHitRouter.Hit] {
        var hits: [Scene3DHitRouter.Hit] = []
        for hit in descriptor.hits {
            let node = try uniqueNode(named: hit.node, in: contentRoot)
            try requireSingleVisibleMesh(node, name: hit.node)
            hits.append(Scene3DHitRouter.Hit(node: hit.node,
                                             actionID: hit.id,
                                             label: hit.label,
                                             value: hit.value,
                                             enabled: hit.enabled))
        }
        return hits
    }

    /// 命中节点必须恰好对应一个可见 mesh；隐藏/全透明占位或多 mesh 都无法定位点击目标。
    static func requireSingleVisibleMesh(_ node: SCNNode, name: String) throws {
        var count = 0
        func visit(_ n: SCNNode) {
            if n.isHidden || n.opacity < 0.01 { return }
            if let g = n.geometry,
               !g.materials.allSatisfy({ $0.transparency < 0.01 }) { count += 1 }
            for child in n.childNodes { visit(child) }
        }
        visit(node)
        switch count {
        case 0: throw PluginScene3DFailure.nodeNotFound(name)
        case 1: return
        default: throw PluginScene3DFailure.nodeAmbiguous(name)
        }
    }

    private static func uniqueNode(named name: String, in root: SCNNode) throws -> SCNNode {
        var matches: [SCNNode] = []
        func visit(_ node: SCNNode) {
            if node.name == name { matches.append(node) }
            for child in node.childNodes { visit(child) }
        }
        visit(root)
        switch matches.count {
        case 0: throw PluginScene3DFailure.nodeNotFound(name)
        case 1: return matches[0]
        default: throw PluginScene3DFailure.nodeAmbiguous(name)
        }
    }

    // MARK: - Accessibility text sources

    /// Stable IDs only; the visible string stay on the surface texture so
    /// VoiceOver reads the same content the plugin rendered.
    private static func collectTexts(descriptor: PluginScene3DDescriptor) -> [Scene3DAccessibilityModel.TextSource] {
        var sources: [Scene3DAccessibilityModel.TextSource] = []
        for surface in descriptor.surfaces {
            collectTexts(from: surface.content,
                         path: "scene3d.surface.\(surface.node)",
                         into: &sources)
        }
        return sources
    }

    private static func collectTexts(from node: PluginUINode,
                                     path: String,
                                     into sources: inout [Scene3DAccessibilityModel.TextSource]) {
        switch node {
        case .text(let value, _, _), .marquee(let value), .badge(let value, _):
            guard !value.isEmpty else { return }
            sources.append(.init(id: "\(path).\(sources.count)", label: value, value: ""))
        case .progress(let value, _, _):
            let percent = Int((min(max(value, 0), 1) * 100).rounded())
            sources.append(.init(id: "\(path).\(sources.count)",
                                 label: "\(percent)%",
                                 value: ""))
        default:
            for (index, child) in node.children.enumerated() {
                collectTexts(from: child,
                             path: "\(path).\(index)",
                             into: &sources)
            }
        }
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
