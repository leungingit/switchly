//
//  Scene3DHitTestAdapter.swift
//  Switchly
//
//  T05: SceneKit adapter behind `Scene3DHitProviding`. It converts
//  `SCNView.hitTest` results into geometry-only candidates; action mapping
//  stays in `Scene3DHitRouter` so the rule is testable without a GPU.
//
//  The adapter never calls plugin callbacks and never walks `mesh.name`:
//  assets declare semantic names in glTF `node.name`.
//

import AppKit
import SceneKit

@MainActor
final class Scene3DHitTestAdapter: Scene3DHitProviding {
    weak var view: SCNView?

    init(view: SCNView?) {
        self.view = view
    }

    func hitCandidates(at point: CGPoint) -> [Scene3DHitRouter.Candidate] {
        guard let view else { return [] }
        let results = view.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .backFaceCulling: true,
            .ignoreHiddenNodes: true,
        ])
        return results.map { result in
            Scene3DHitRouter.Candidate(nodeNameChain: Self.nameChain(from: result.node),
                                       worldNormal: Self.simd(result.worldNormal),
                                       worldPoint: Self.simd(result.worldCoordinates),
                                       passesThrough: Self.isTransparentPlaceholder(result.node),
                                       localPoint: Self.localPoint(of: result))
        }
    }

    /// Fully transparent nodes (opacity or every material) are placeholders
    /// and must not block a declared hit behind them.
    static func isTransparentPlaceholder(_ node: SCNNode) -> Bool {
        if node.opacity < 0.01 { return true }
        guard let materials = node.geometry?.materials, !materials.isEmpty else { return false }
        return materials.allSatisfy { $0.transparency < 0.01 }
    }

    /// Nearest-first chain of non-empty node names. glTF imports keep the
    /// declared semantic name on the node, while `mesh.name` is often empty.
    static func nameChain(from node: SCNNode?) -> [String] {
        var names: [String] = []
        var current = node
        while let node = current {
            if let name = node.name, !name.isEmpty {
                names.append(name)
            }
            current = node.parent
        }
        return names
    }

    private static func localPoint(of result: SCNHitTestResult) -> SIMD2<Float> {
        let (minimum, maximum) = result.node.boundingBox
        let local = result.localCoordinates
        return SIMD2(Float(local.x - (minimum.x + maximum.x) / 2),
                     Float(local.y - (minimum.y + maximum.y) / 2))
    }

    private static func simd(_ vector: SCNVector3) -> SIMD3<Float> {
        SIMD3(Float(vector.x), Float(vector.y), Float(vector.z))
    }
}
