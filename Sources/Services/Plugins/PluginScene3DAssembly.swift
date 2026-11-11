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
    private(set) var texts: [Scene3DAccessibilityModel.TextSource]
    let viewportSize: CGSize
    let appliedScale: Float
    let darkFinish: Bool

    private let surfaceRenderer: PluginSurfaceRenderer
    private let surfaceBases: [String: SCNMaterial]
    private var surfaceSignatures: [String: String]
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
         surfaceBases: [String: SCNMaterial],
         surfaceRenderer: PluginSurfaceRenderer,
         darkFinish: Bool = false,
         surfaceSignatures: [String: String] = [:]) {
        self.identity = identity
        self.scene = scene
        self.contentRoot = contentRoot
        self.cameraNode = cameraNode
        self.cameraDistance = cameraDistance
        self.hits = hits
        self.texts = texts
        self.viewportSize = viewportSize
        self.appliedScale = appliedScale
        self.darkFinish = darkFinish
        self.surfaceBases = surfaceBases
        self.surfaceSignatures = surfaceSignatures
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

    /// Repaints the surface textures in place for new content (track progress,
    /// play state, cover). The scene, camera pose and lights stay untouched, so
    /// nothing flickers. Returns false when the live scene cannot take it.
    func refreshSurfaces(descriptor: PluginScene3DDescriptor,
                         assetDirectory: URL,
                         artwork: PluginSurfaceArtwork?,
                         palette: PluginSurfacePalette) -> Bool {
        guard !isTornDown else { return false }
        do {
            try PluginScene3DAssembly.bindSurfaces(descriptor: descriptor,
                                                   contentRoot: contentRoot,
                                                   assetDirectory: assetDirectory,
                                                   artwork: artwork,
                                                   palette: palette,
                                                   surfaceBases: surfaceBases,
                                                   renderer: surfaceRenderer,
                                                   appliedSignatures: &surfaceSignatures)
        } catch {
            return false
        }
        texts = PluginScene3DAssembly.collectTexts(descriptor: descriptor)
        return true
    }

    /// Only exposed for lifecycle tests; textures must never be released
    /// without `teardown()`.
    var surfaceTextureCount: Int { surfaceRenderer.cachedTextureCount }

    /// Removes the cloned scene from the host and releases surface textures.
    /// Idempotent; callers must also clear any SCNView reference to `scene`.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        surfaceSignatures.removeAll()
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
    static let containPadding: Float = 0.96
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
        let started = DispatchTime.now().uptimeNanoseconds
        defer { AppLogger.performance("Scene3DAssembly", since: started) }
        let renderer = PluginSurfaceRenderer(rasterizer: rasterizer)
        do {
            let scene = SCNScene()
            scene.background.contents = NSColor.clear
            scene.background.intensity = 1

            let contentRoot = cloneTemplateContent(from: asset.templateScene)
            let surfaceBases = originalSurfaceMaterials(in: contentRoot, descriptor: descriptor)
            guard let bounds = bounds(of: contentRoot) else {
                throw PluginScene3DFailure.decodeFailed("scene3d asset has no renderable geometry")
            }
            guard let scale = containScale(bounds: bounds,
                                           cameraDistance: cameraDistance,
                                           fieldOfView: fieldOfView,
                                           aspect: aspectRatio(of: slotSize)) else {
                throw PluginScene3DFailure.decodeFailed("scene3d asset bounds are invalid")
            }

            if palette.darkFinish {
                applyDarkFinish(to: contentRoot, preserving: Set(descriptor.surfaces.map(\.node)))
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
            addFixedLights(to: root, scene: scene)

            var surfaceSignatures: [String: String] = [:]
            try bindSurfaces(descriptor: descriptor,
                             contentRoot: contentRoot,
                             assetDirectory: assetDirectory,
                             artwork: artwork,
                             palette: palette,
                             surfaceBases: surfaceBases,
                             renderer: renderer,
                             appliedSignatures: &surfaceSignatures)
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
                surfaceBases: surfaceBases,
                surfaceRenderer: renderer,
                darkFinish: palette.darkFinish,
                surfaceSignatures: surfaceSignatures
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

    /// Scale that keeps the whole model inside the viewport at every orbit
    /// angle. Orbiting is a rotation about the Y axis (yaw) and the X axis
    /// (pitch), so the horizontal extent never exceeds `hypot(x, z)` and the
    /// vertical extent never exceeds `hypot(y, z)`. Fitting each axis with its
    /// own radius keeps tall, thin models (the iPod) from being shrunk to the
    /// size of their full bounding sphere.
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
        let half = bounds.extents
        let horizontalRadius = hypot(half.x, half.z)
        let verticalRadius = hypot(half.y, half.z)
        guard horizontalRadius > 0, verticalRadius > 0 else { return nil }

        let verticalHalf = Float(fieldOfView) * .pi / 360
        let horizontalHalf = atan(tan(verticalHalf) * Float(aspect))
        let horizontalLimit = cameraDistance * sin(horizontalHalf) * containPadding
        let verticalLimit = cameraDistance * sin(verticalHalf) * containPadding
        let scale = min(horizontalLimit / horizontalRadius, verticalLimit / verticalRadius)
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

    // MARK: - Finish

    /// Space-gray variant: light plastic (front, wheel) is darkened, metal and
    /// the dark bezel stay as they are. Geometry and materials are copied first
    /// because cloned nodes share them with the cached template.
    private static func applyDarkFinish(to root: SCNNode, preserving surfaceNodes: Set<String>) {
        func visit(_ node: SCNNode) {
            guard !surfaceNodes.contains(node.name ?? "") else { return }
            if let geometry = node.geometry?.copy() as? SCNGeometry {
                geometry.materials = geometry.materials.map { original in
                    guard let material = original.copy() as? SCNMaterial else { return original }
                    if material.diffuse.contents is NSImage
                        || (material.diffuse.contents.map { CFGetTypeID($0 as CFTypeRef) == CGImage.typeID } ?? false) {
                        material.diffuse.intensity *= 0.23
                        return material
                    }
                    guard let color = baseColor(of: material.diffuse.contents),
                          (isNeutralLightPlastic(color)
                           || (isNeutralMetal(color)
                               && ((material.metalness.contents as? NSNumber)?.doubleValue ?? 0) > 0.3))
                    else { return original }
                    material.diffuse.contents = NSColor(deviceRed: color.redComponent * 0.17,
                                                        green: color.greenComponent * 0.17,
                                                        blue: color.blueComponent * 0.17,
                                                        alpha: color.alphaComponent)
                    return material
                }
                node.geometry = geometry
            }
            node.childNodes.forEach(visit)
        }
        visit(root)
    }

    private static func baseColor(of contents: Any?) -> NSColor? {
        let color: NSColor?
        if let value = contents as? NSColor {
            color = value
        } else if let value = contents, CFGetTypeID(value as CFTypeRef) == CGColor.typeID {
            color = NSColor(cgColor: value as! CGColor)
        } else {
            color = nil
        }
        return color?.usingColorSpace(.deviceRGB)
    }

    /// Bright, nearly colourless sRGB base colours (white front, wheel). The
    /// teal LCD backing and coloured metals fail the chroma test and stay.
    private static func isNeutralLightPlastic(_ color: NSColor) -> Bool {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let luminance = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        return luminance > 0.85 && (channels.max()! - channels.min()!) < 0.05
    }

    private static func isNeutralMetal(_ color: NSColor) -> Bool {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let luminance = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        return luminance > 0.6 && (channels.max()! - channels.min()!) < 0.1
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
        camera.wantsHDR = true
        // HDR auto-exposure adapts over a few seconds: the model starts bright
        // and then darkens toward the average luminance. Fix the exposure.
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0
        camera.exposureOffset = 0
        node.camera = camera
        node.position = SCNVector3(0, 0, cameraDistance)
        return node
    }

    private static func addFixedLights(to root: SCNNode, scene: SCNScene) {
        // PBR metal / clearcoat needs something to reflect: a soft studio
        // gradient drives IBL + specular. The image is rendered once into a
        // bitmap; a drawing-handler NSImage is rasterised lazily by SceneKit
        // and made the environment pop in a few frames after each rebuild.
        scene.lightingEnvironment.contents = studioEnvironment
        scene.lightingEnvironment.intensity = 0.4

        let ambientNode = SCNNode()
        ambientNode.name = "scene3d.ambient"
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 40
        ambient.color = NSColor.white
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        func directional(_ name: String, intensity: CGFloat, angles: SCNVector3) {
            let node = SCNNode()
            node.name = name
            let light = SCNLight()
            light.type = .directional
            light.intensity = intensity
            light.color = NSColor.white
            node.light = light
            node.eulerAngles = angles
            root.addChildNode(node)
        }
        // Lights shine along their local -Z, i.e. away from the camera at +Z
        // onto the front face. Key: from above-left of the camera; fill:
        // from the right; rim: faint edge light from behind.
        directional("scene3d.key", intensity: 520, angles: SCNVector3(-0.45, 0.35, 0))
        directional("scene3d.fill", intensity: 150, angles: SCNVector3(-0.1, -0.6, 0))
        directional("scene3d.rim", intensity: 250, angles: SCNVector3(0.5, 2.6, 0))
    }

    /// Cached so every rebuild reuses the same decoded bitmap.
    private static let studioEnvironment: CGImage? = {
        let width = 256, height = 128
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colorsAndLocations:
            (NSColor(white: 0.45, alpha: 1), 0),
            (NSColor(white: 0.7, alpha: 1), 0.45),
            (NSColor(white: 0.95, alpha: 1), 0.8),
            (NSColor(white: 1.0, alpha: 1), 1))?.draw(in: rect, angle: 90)
        // Soft box light for a crisp specular streak on glossy parts.
        NSColor(white: 1, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: 150, y: 70, width: 60, height: 40),
                     xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }()

    // MARK: - Surfaces

    private static func originalSurfaceMaterials(in root: SCNNode,
                                                 descriptor: PluginScene3DDescriptor) -> [String: SCNMaterial] {
        var result: [String: SCNMaterial] = [:]
        for surface in descriptor.surfaces {
            if let node = try? uniqueNode(named: surface.node, in: root),
               let material = node.geometry?.materials.first {
                result[surface.node] = material
            }
        }
        return result
    }

    @MainActor
    static func bindSurfaces(descriptor: PluginScene3DDescriptor,
                                     contentRoot: SCNNode,
                                     assetDirectory: URL,
                                     artwork: PluginSurfaceArtwork?,
                                     palette: PluginSurfacePalette,
                                     surfaceBases: [String: SCNMaterial],
                                     renderer: PluginSurfaceRenderer,
                                     appliedSignatures: inout [String: String]) throws {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        defer { SCNTransaction.commit() }
        for surface in descriptor.surfaces {
            let node = try uniqueNode(named: surface.node, in: contentRoot)
            // §9.4 declares `size` in output texture pixels, so the rasterized
            // bitmap must match it exactly. `pixelsPerPoint: 1` keeps the
            // declared dimensions from being multiplied by a backing scale.
            let request = PluginSurfaceRequest(
                content: surface.content,
                pointSize: CGSize(width: surface.size.width, height: surface.size.height),
                pixelsPerPoint: 1,
                artwork: surface.content.usesArtwork ? artwork : nil,
                assetDirectory: assetDirectory,
                palette: palette
            )
            guard let texture = renderer.texture(for: request) else {
                throw PluginScene3DFailure.renderFailed
            }
            // 未变表面连材质合成都跳过；播放进度不能反复复制背板大图。
            guard appliedSignatures[surface.node] != texture.contentSignature else { continue }
            guard let currentGeometry = node.geometry,
                  let geometry = currentGeometry.copy() as? SCNGeometry,
                  !geometry.sources(for: .texcoord).isEmpty else {
                throw PluginScene3DFailure.uvMissing(surface.node)
            }

            let material: SCNMaterial
            if let existing = currentGeometry.firstMaterial,
               existing.name == "scene3d.surface.\(surface.node)" {
                material = existing
            } else {
                material = SCNMaterial()
                material.name = "scene3d.surface.\(surface.node)"
                material.lightingModel = .constant
                material.isDoubleSided = false
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                material.diffuse.minificationFilter = .linear
                material.diffuse.magnificationFilter = .linear
                material.diffuse.mipFilter = .none
                material.diffuse.intensity = 1
                // The bitmap is top-left oriented but glTF UVs put v=1 at the top.
                material.diffuse.contentsTransform = surfaceTransform(for: geometry)
                let materialCount = max(1, geometry.elements.count)
                geometry.materials = Array(repeating: material, count: materialCount)
                node.geometry = geometry
            }
            material.diffuse.contents = compositedSurface(texture.image,
                                                           over: surfaceBases[surface.node]?.diffuse.contents,
                                                           darkFinish: palette.darkFinish
                                                               && ((surfaceBases[surface.node]?.metalness.contents as? NSNumber)?.doubleValue ?? 0) > 0.01)
            appliedSignatures[surface.node] = texture.contentSignature
        }
    }

    /// Meshes authored for tiling textures (the iPod back plate) carry UVs far
    /// outside 0...1. Stretch the bitmap over the mesh's own UV extent so one
    /// surface covers the whole face; 0...1 meshes keep the plain v flip.
    private static func surfaceTransform(for geometry: SCNGeometry) -> SCNMatrix4 {
        var matrix = SCNMatrix4Identity
        if let range = uvRange(of: geometry),
           range.maxU > 1.001 || range.minU < -0.001 || range.maxV > 1.001 || range.minV < -0.001,
           range.maxU > range.minU, range.maxV > range.minV {
            matrix = SCNMatrix4Translate(matrix, -range.minU, -range.minV, 0)
            matrix = SCNMatrix4Scale(matrix, 1 / (range.maxU - range.minU), 1 / (range.maxV - range.minV), 1)
        }
        matrix = SCNMatrix4Scale(matrix, 1, -1, 1)
        return SCNMatrix4Translate(matrix, 0, 1, 0)
    }

    private static func uvRange(of geometry: SCNGeometry) -> (minU: CGFloat, maxU: CGFloat, minV: CGFloat, maxV: CGFloat)? {
        guard let source = geometry.sources(for: .texcoord).first,
              source.componentsPerVector >= 2, source.bytesPerComponent == MemoryLayout<Float>.size,
              source.vectorCount > 0 else { return nil }
        var range = (minU: CGFloat.infinity, maxU: -CGFloat.infinity, minV: CGFloat.infinity, maxV: -CGFloat.infinity)
        source.data.withUnsafeBytes { raw in
            for index in 0..<source.vectorCount {
                let offset = source.dataOffset + index * source.dataStride
                guard offset + 2 * MemoryLayout<Float>.size <= raw.count else { return }
                let u = CGFloat(raw.loadUnaligned(fromByteOffset: offset, as: Float.self))
                let v = CGFloat(raw.loadUnaligned(fromByteOffset: offset + MemoryLayout<Float>.size, as: Float.self))
                range = (min(range.minU, u), max(range.maxU, u), min(range.minV, v), max(range.maxV, v))
            }
        }
        return range.minU.isFinite ? range : nil
    }

    /// Keep the model's own finish visible wherever a dynamic surface leaves
    /// transparent pixels (for example, between click-wheel symbols).
    private static func compositedSurface(_ image: CGImage, over contents: Any?,
                                          darkFinish: Bool) -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if let value = contents, CFGetTypeID(value as CFTypeRef) == CGImage.typeID {
            context.draw(value as! CGImage, in: rect)
        } else if let base = contents as? NSImage,
                  let cgImage = base.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(cgImage, in: rect)
        } else if let base = baseColor(of: contents) {
            let finish = darkFinish && isNeutralLightPlastic(base)
                ? NSColor(deviceRed: base.redComponent * 0.17,
                          green: base.greenComponent * 0.17,
                          blue: base.blueComponent * 0.17,
                          alpha: base.alphaComponent)
                : base
            context.setFillColor(finish.cgColor)
            context.fill(rect)
        }
        context.draw(image, in: rect)
        return context.makeImage() ?? image
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
                                             enabled: hit.enabled,
                                             sector: hit.sector))
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
    static func collectTexts(descriptor: PluginScene3DDescriptor) -> [Scene3DAccessibilityModel.TextSource] {
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
