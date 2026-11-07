//
//  Scene3DHitRouter.swift
//  Switchly
//
//  T05: turns SceneKit hit-test results into plugin action IDs. Hit results
//  from the adapter carry the glTF node name chain (nearest first), the world
//  point and the world normal. The router only accepts front-facing hits
//  declared in the plugin's `hits` list and never lets a back face trigger a
//  front control on the same model.
//

import Foundation
import simd

struct Scene3DHitRouter {
    /// One declared `hits` entry. `node` is a glTF `node.name`; the same node
    /// must be unique inside the asset and correspond to one visible mesh.
    struct Hit: Equatable {
        var node: String
        var actionID: String
        var label: String
        var value: Double?
        var enabled: Bool
        /// True for stateful controls such as "like"; the accessibility model
        /// then exposes a toggle with the current state.
        var isToggle: Bool
        var selected: Bool

        init(node: String,
             actionID: String,
             label: String,
             value: Double? = nil,
             enabled: Bool = true,
             isToggle: Bool = false,
             selected: Bool = false) {
            self.node = node
            self.actionID = actionID
            self.label = label
            self.value = value
            self.enabled = enabled
            self.isToggle = isToggle
            self.selected = selected
        }
    }

    /// Adapter output for a single `SCNHitTestResult`. Node names are ordered
    /// from the hit node up to the root; empty `mesh.name` values are omitted.
    struct Candidate: Equatable {
        var nodeNameChain: [String]
        var worldNormal: SIMD3<Float>
        var worldPoint: SIMD3<Float>
        /// True for fully transparent placeholders. Undeclared opaque surfaces
        /// in front of a declared hit block it instead of being clicked through.
        var passesThrough: Bool

        init(nodeNameChain: [String],
             worldNormal: SIMD3<Float>,
             worldPoint: SIMD3<Float>,
             passesThrough: Bool = false) {
            self.nodeNameChain = nodeNameChain
            self.worldNormal = worldNormal
            self.worldPoint = worldPoint
            self.passesThrough = passesThrough
        }
    }

    struct RoutedAction: Equatable {
        var id: String
        var value: Double?
    }

    /// Minimum dot product of the outward normal and the view direction.
    /// Slightly above zero rejects grazing side faces that SceneKit may return
    /// when the camera looks almost parallel to the surface.
    static let frontFacingThreshold: Float = 0.05

    private let hitsByNode: [String: Hit]

    init(hits: [Hit]) {
        var map: [String: Hit] = [:]
        for hit in hits where map[hit.node] == nil {
            map[hit.node] = hit
        }
        hitsByNode = map
    }

    /// Routes the nearest front-facing, declared, enabled hit. Candidates are
    /// evaluated in the order SceneKit returned them (nearest first). Back
    /// faces and side faces are skipped entirely, so they cannot fall through
    /// to a different visible node.
    func route(candidates: [Candidate], cameraPosition: SIMD3<Float>) -> RoutedAction? {
        for candidate in candidates {
            guard Self.isFrontFacing(candidate, cameraPosition: cameraPosition) else { continue }
            guard let hit = declaredHit(for: candidate) else {
                if candidate.passesThrough { continue }
                return nil   // 未声明的不透明前表面遮挡其后的命中
            }
            guard hit.enabled else { return nil }
            return RoutedAction(id: hit.actionID, value: hit.value)
        }
        return nil
    }

    /// Looks up a declared hit by action ID, used by keyboard and
    /// accessibility paths that do not go through geometry.
    func hit(actionID: String) -> Hit? {
        hitsByNode.values.first { $0.actionID == actionID }
    }

    static func isFrontFacing(_ candidate: Candidate, cameraPosition: SIMD3<Float>) -> Bool {
        let normalLength = simd_length(candidate.worldNormal)
        let viewLength = simd_length(cameraPosition - candidate.worldPoint)
        guard normalLength > 1e-6, viewLength > 1e-6 else { return false }
        let normal = candidate.worldNormal / normalLength
        let view = (cameraPosition - candidate.worldPoint) / viewLength
        return simd_dot(normal, view) >= frontFacingThreshold
    }

    private func declaredHit(for candidate: Candidate) -> Hit? {
        for name in candidate.nodeNameChain {
            if let hit = hitsByNode[name] { return hit }
        }
        return nil
    }
}
