//
//  PluginScene3DDescriptor.swift
//  Switchly
//
//  T06 model input contract for the generic `scene3d` component. The future
//  scene3d decoder (T07) decodes one slot root into this descriptor and then
//  calls `PluginScene3DDeclaration.validate()` before handing it to the
//  component. Keeping the contract separate from `PluginUINode` lets the
//  component be built and tested before the formal node case exists.
//
//  The declaration is frozen by D26: a single self-contained `.glb`, node
//  identity only from glTF `node.name`, angle-based camera, `fit: contain`,
//  bounded surfaces/hits and a required 2D fallback.
//

import CoreGraphics
import Foundation

enum PluginScene3DFit: String, Codable, Equatable, CaseIterable {
    case contain
}

/// Angle-based initial camera pose in degrees. Zero yaw/pitch places the host
/// camera on the glTF +Z axis looking at the origin with +Y up; positive yaw
/// turns toward +X and positive pitch raises the camera.
struct PluginScene3DCamera: Decodable, Equatable {
    var yaw: Double
    var pitch: Double

    init(yaw: Double = 0, pitch: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
    }

    private enum CodingKeys: String, CodingKey {
        case yaw, pitch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        yaw = try container.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
        pitch = try container.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
    }
}

/// Camera drag limits. Horizontal and vertical rotation are enabled by
/// default; pitch limits must be supplied as a pair and stay inside ±89°.
struct PluginScene3DRotate: Decodable, Equatable {
    var horizontal: Bool
    var vertical: Bool
    var pitchMin: Double?
    var pitchMax: Double?

    init(horizontal: Bool = true,
         vertical: Bool = true,
         pitchMin: Double? = nil,
         pitchMax: Double? = nil) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.pitchMin = pitchMin
        self.pitchMax = pitchMax
    }

    private enum CodingKeys: String, CodingKey {
        case horizontal, vertical, pitchMin, pitchMax
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        horizontal = try container.decodeIfPresent(Bool.self, forKey: .horizontal) ?? true
        vertical = try container.decodeIfPresent(Bool.self, forKey: .vertical) ?? true
        pitchMin = try container.decodeIfPresent(Double.self, forKey: .pitchMin)
        pitchMax = try container.decodeIfPresent(Double.self, forKey: .pitchMax)
    }

    /// Resolves the frozen default limits when the declaration omits them.
    var resolvedPitchRange: ClosedRange<Double> {
        (pitchMin ?? -55)...(pitchMax ?? 55)
    }
}

/// Declared surface size in output texture pixels, encoded as `[width, height]`.
/// §9.4: this is a pixel budget, not a layout point size, so the rasterizer must
/// not multiply it by a backing scale.
struct PluginScene3DSize: Decodable, Equatable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let width = try container.decode(Int.self)
        let height = try container.decode(Int.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "scene3d size must contain exactly width and height"
            )
        }
        self.init(width: width, height: height)
    }
}

/// A single 3D surface bound to one glTF node name. `content` is restricted
/// to the §9.4 allowlist and is validated with
/// `PluginSurfaceContentValidator`.
struct PluginScene3DSurface: Decodable, Equatable {
    var node: String
    var size: PluginScene3DSize
    var content: PluginUINode

    init(node: String, size: PluginScene3DSize, content: PluginUINode) {
        self.node = node
        self.size = size
        self.content = content
    }
}

struct PluginScene3DHit: Decodable, Equatable {
    var node: String
    var id: String
    var label: String
    var value: Double?
    var enabled: Bool

    init(node: String, id: String, label: String, value: Double? = nil, enabled: Bool = true) {
        self.node = node
        self.id = id
        self.label = label
        self.value = value
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case node, id, label, value, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decode(String.self, forKey: .node)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Complete input for one scene3d slot root.
struct PluginScene3DDescriptor: Decodable, Equatable {
    var key: String
    var asset: String
    var fit: PluginScene3DFit
    var camera: PluginScene3DCamera
    var rotate: PluginScene3DRotate
    var surfaces: [PluginScene3DSurface]
    var hits: [PluginScene3DHit]
    var fallback: PluginUINode

    init(key: String,
         asset: String,
         fit: PluginScene3DFit = .contain,
         camera: PluginScene3DCamera = PluginScene3DCamera(),
         rotate: PluginScene3DRotate = PluginScene3DRotate(),
         surfaces: [PluginScene3DSurface] = [],
         hits: [PluginScene3DHit] = [],
         fallback: PluginUINode) {
        self.key = key
        self.asset = asset
        self.fit = fit
        self.camera = camera
        self.rotate = rotate
        self.surfaces = surfaces
        self.hits = hits
        self.fallback = fallback
    }

    private enum CodingKeys: String, CodingKey {
        case key, asset, fit, camera, rotate, surfaces, hits, fallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        asset = try container.decode(String.self, forKey: .asset)
        fit = try container.decodeIfPresent(PluginScene3DFit.self, forKey: .fit) ?? .contain
        camera = try container.decodeIfPresent(PluginScene3DCamera.self, forKey: .camera) ?? PluginScene3DCamera()
        rotate = try container.decodeIfPresent(PluginScene3DRotate.self, forKey: .rotate) ?? PluginScene3DRotate()
        surfaces = try container.decodeIfPresent([PluginScene3DSurface].self, forKey: .surfaces) ?? []
        hits = try container.decodeIfPresent([PluginScene3DHit].self, forKey: .hits) ?? []
        fallback = try container.decode(PluginUINode.self, forKey: .fallback)
    }

    /// Resolves the package-relative asset path without leaving the plugin
    /// package. Validation has already rejected absolute and parent paths.
    func assetURL(in directory: URL) -> URL {
        directory.appendingPathComponent(asset)
    }
}

enum PluginScene3DLimits {
    static let maxSurfaces = 2
    static let maxHits = 12
    static let maxSurfaceEdge = 1024
    static let minSurfaceEdge = 1
    static let maxKeyLength = 64
    static let maxYawDegrees = 180.0
    static let maxPitchDegrees = 89.0
}

enum PluginScene3DDeclarationError: LocalizedError, Equatable {
    case emptyKey
    case keyTooLong
    case invalidAssetPath
    case nonFiniteCamera
    case cameraOutOfRange(field: String)
    case pitchRangeNotPaired
    case invalidPitchRange
    case tooManySurfaces
    case emptySurfaceNode
    case duplicateSurfaceNode(String)
    case surfaceSizeOutOfRange(String)
    case forbiddenSurfaceContent(String)
    case tooManyHits
    case emptyHitField(String)
    case duplicateHitNode(String)
    case duplicateActionID(String)
    case nonFiniteHitValue(String)
    case surfaceAndHitNodeOverlap(String)
    case duplicateFallbackActionID(String)
    case declarationTooDeep
    case declarationTooManyNodes

    var errorDescription: String? {
        switch self {
        case .emptyKey: return "scene3d key is required"
        case .keyTooLong: return "scene3d key exceeds \(PluginScene3DLimits.maxKeyLength) characters"
        case .invalidAssetPath: return "scene3d asset must be a package-relative .glb path"
        case .nonFiniteCamera: return "scene3d camera angles must be finite"
        case .cameraOutOfRange(let field): return "scene3d \(field) is out of range"
        case .pitchRangeNotPaired: return "scene3d pitchMin and pitchMax must be supplied together"
        case .invalidPitchRange: return "scene3d pitch range is invalid"
        case .tooManySurfaces: return "scene3d has too many surfaces"
        case .emptySurfaceNode: return "scene3d surface node is required"
        case .duplicateSurfaceNode(let node): return "scene3d surface node is duplicated: \(node)"
        case .surfaceSizeOutOfRange(let node): return "scene3d surface size is out of range: \(node)"
        case .forbiddenSurfaceContent(let node): return "scene3d surface content is forbidden: \(node)"
        case .tooManyHits: return "scene3d has too many hits"
        case .emptyHitField(let field): return "scene3d hit \(field) is required"
        case .duplicateHitNode(let node): return "scene3d hit node is duplicated: \(node)"
        case .duplicateActionID(let id): return "scene3d action id is duplicated: \(id)"
        case .nonFiniteHitValue(let id): return "scene3d hit value is not finite: \(id)"
        case .surfaceAndHitNodeOverlap(let node): return "scene3d node is used by both a surface and a hit: \(node)"
        case .duplicateFallbackActionID(let id): return "scene3d fallback action id is duplicated: \(id)"
        case .declarationTooDeep: return "scene3d declaration exceeds \(PluginRenderOutput.maxDepth) levels"
        case .declarationTooManyNodes: return "scene3d declaration exceeds \(PluginRenderOutput.maxNodes) nodes"
        }
    }
}

enum PluginScene3DDeclaration {
    /// Validates the decoded descriptor. The decoder must call this before the
    /// render output is accepted: §9.4 requires rejecting the whole render
    /// output when any surface content is forbidden. A missing named glTF node
    /// is not a declaration error; it is a runtime fallback
    /// (`scene3d.nodeNotFound`).
    static func validate(_ descriptor: PluginScene3DDescriptor) throws {
        guard !descriptor.key.isEmpty else { throw PluginScene3DDeclarationError.emptyKey }
        guard descriptor.key.count <= PluginScene3DLimits.maxKeyLength else {
            throw PluginScene3DDeclarationError.keyTooLong
        }
        try validateAssetPath(descriptor.asset)
        try validateCamera(descriptor.camera)
        try validateRotation(descriptor.rotate)
        try validateSurfaces(descriptor.surfaces)
        try validateHits(descriptor.hits)
        try validateNodeDisjointness(surfaces: descriptor.surfaces, hits: descriptor.hits)
        try validateFallback(descriptor.fallback)
        try validateBudget(descriptor)
    }

    private static func validateAssetPath(_ asset: String) throws {
        guard !asset.hasPrefix("/"), asset.hasSuffix(".glb") else {
            throw PluginScene3DDeclarationError.invalidAssetPath
        }
        let components = asset.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PluginScene3DDeclarationError.invalidAssetPath
        }
    }

    private static func validateCamera(_ camera: PluginScene3DCamera) throws {
        guard camera.yaw.isFinite, camera.pitch.isFinite else {
            throw PluginScene3DDeclarationError.nonFiniteCamera
        }
        guard abs(camera.yaw) <= PluginScene3DLimits.maxYawDegrees else {
            throw PluginScene3DDeclarationError.cameraOutOfRange(field: "camera.yaw")
        }
        guard abs(camera.pitch) <= PluginScene3DLimits.maxPitchDegrees else {
            throw PluginScene3DDeclarationError.cameraOutOfRange(field: "camera.pitch")
        }
    }

    private static func validateRotation(_ rotate: PluginScene3DRotate) throws {
        switch (rotate.pitchMin, rotate.pitchMax) {
        case (nil, nil):
            return
        case (let min?, let max?):
            guard min.isFinite, max.isFinite,
                  abs(min) <= PluginScene3DLimits.maxPitchDegrees,
                  abs(max) <= PluginScene3DLimits.maxPitchDegrees,
                  min <= max else {
                throw PluginScene3DDeclarationError.invalidPitchRange
            }
        default:
            throw PluginScene3DDeclarationError.pitchRangeNotPaired
        }
    }

    private static func validateSurfaces(_ surfaces: [PluginScene3DSurface]) throws {
        guard surfaces.count <= PluginScene3DLimits.maxSurfaces else {
            throw PluginScene3DDeclarationError.tooManySurfaces
        }
        var nodes = Set<String>()
        for surface in surfaces {
            guard !surface.node.isEmpty else { throw PluginScene3DDeclarationError.emptySurfaceNode }
            guard nodes.insert(surface.node).inserted else {
                throw PluginScene3DDeclarationError.duplicateSurfaceNode(surface.node)
            }
            let width = surface.size.width
            let height = surface.size.height
            guard (PluginScene3DLimits.minSurfaceEdge...PluginScene3DLimits.maxSurfaceEdge).contains(width),
                  (PluginScene3DLimits.minSurfaceEdge...PluginScene3DLimits.maxSurfaceEdge).contains(height) else {
                throw PluginScene3DDeclarationError.surfaceSizeOutOfRange(surface.node)
            }
            do {
                try PluginSurfaceContentValidator.validate(surface.content)
            } catch {
                throw PluginScene3DDeclarationError.forbiddenSurfaceContent(surface.node)
            }
        }
    }

    private static func validateHits(_ hits: [PluginScene3DHit]) throws {
        guard hits.count <= PluginScene3DLimits.maxHits else {
            throw PluginScene3DDeclarationError.tooManyHits
        }
        var nodes = Set<String>()
        var actionIDs = Set<String>()
        for hit in hits {
            guard !hit.node.isEmpty else { throw PluginScene3DDeclarationError.emptyHitField("node") }
            guard !hit.id.isEmpty else { throw PluginScene3DDeclarationError.emptyHitField("id") }
            guard !hit.label.isEmpty else { throw PluginScene3DDeclarationError.emptyHitField("label") }
            guard nodes.insert(hit.node).inserted else {
                throw PluginScene3DDeclarationError.duplicateHitNode(hit.node)
            }
            guard actionIDs.insert(hit.id).inserted else {
                throw PluginScene3DDeclarationError.duplicateActionID(hit.id)
            }
            if let value = hit.value, !value.isFinite {
                throw PluginScene3DDeclarationError.nonFiniteHitValue(hit.id)
            }
        }
    }

    private static func validateFallback(_ fallback: PluginUINode) throws {
        var actionIDs = Set<String>()
        for id in fallback.actionIDs where !actionIDs.insert(id).inserted {
            throw PluginScene3DDeclarationError.duplicateFallbackActionID(id)
        }
    }

    /// §9.7: the `scene3d` root, every surface content tree and the fallback
    /// subtree share the single 64-node / depth-8 UI budget of the slot. The
    /// scene3d root is one level above the fallback and surface content trees.
    private static func validateBudget(_ descriptor: PluginScene3DDescriptor) throws {
        var nodes = 1
        var deepestChild = 0
        for surface in descriptor.surfaces {
            nodes += surface.content.nodeCount
            deepestChild = max(deepestChild, surface.content.depth)
        }
        nodes += descriptor.fallback.nodeCount
        deepestChild = max(deepestChild, descriptor.fallback.depth)

        guard nodes <= PluginRenderOutput.maxNodes else {
            throw PluginScene3DDeclarationError.declarationTooManyNodes
        }
        guard deepestChild + 1 <= PluginRenderOutput.maxDepth else {
            throw PluginScene3DDeclarationError.declarationTooDeep
        }
    }

    /// Surfaces and hits must name disjoint glTF nodes so a node cannot be both
    /// a dynamic texture target and an interactive target.
    static func validateNodeDisjointness(surfaces: [PluginScene3DSurface], hits: [PluginScene3DHit]) throws {
        let surfaceNodes = Set(surfaces.map(\.node))
        for hit in hits where surfaceNodes.contains(hit.node) {
            throw PluginScene3DDeclarationError.surfaceAndHitNodeOverlap(hit.node)
        }
    }
}

/// Size policy for an independent 3D slot view. The minimum is the frozen
/// 220×380 pt candidate readable boundary; the ideal is roughly 3:4 and keeps
/// the model large enough for surfaces and hits without dominating the Dock.
/// A layout that cannot meet the minimum must show the plugin-provided 2D
/// fallback instead of a squeezed 3D view.
enum PluginScene3DViewport {
    static let minimumSize = CGSize(width: 220, height: 380)
    static let idealSize = CGSize(width: 320, height: 420)

    static func canHost3D(in size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width >= minimumSize.width
            && size.height >= minimumSize.height
    }

    /// Returns the largest size up to the ideal that fits `available`, or nil
    /// when 3D cannot be hosted at all.
    static func size(fitting available: CGSize) -> CGSize? {
        guard canHost3D(in: available) else { return nil }
        return CGSize(width: min(idealSize.width, available.width),
                      height: min(idealSize.height, available.height))
    }
}
