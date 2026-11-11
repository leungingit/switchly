//
//  PluginScene3DAssetLoader.swift
//  Switchly
//
//  Decodes one self-contained `.glb` into an immutable template scene.
//  GLBPreflight runs first and enforces byte/structure budgets, but it
//  deliberately does not decode accessors, so a preflight pass is not a
//  guarantee that GLTFKit2 can read the accessor byte layout. Any GLTFKit2 or
//  scene-construction error is therefore captured and surfaced as
//  `.decodeFailed`, which the controller turns into the plugin fallback.
//

import Foundation
import GLTFKit2
import SceneKit

protocol PluginScene3DAssetLoading {
    func load(data: Data, identity: PluginScene3DIdentity) throws -> PluginScene3DAsset
}

struct GLTFKit2Scene3DAssetLoader: PluginScene3DAssetLoading {
    func load(data: Data, identity: PluginScene3DIdentity) throws -> PluginScene3DAsset {
        let report: GLBPreflight.Report
        do {
            report = try GLBPreflight.inspect(data)
        } catch {
            throw PluginScene3DFailure.preflightRejected(error.localizedDescription)
        }

        let asset: GLTFAsset
        do {
            // The GLB is self-contained; no asset directory or external URI is
            // allowed by preflight, so the empty options dictionary is final.
            asset = try GLTFAsset(data: data, options: [:])
        } catch {
            throw PluginScene3DFailure.decodeFailed(error.localizedDescription)
        }

        let scene = SCNScene(gltfAsset: asset)
        return PluginScene3DAsset(identity: identity,
                                  templateScene: scene,
                                  nodeNames: report.nodeNames,
                                  fileBytes: data.count,
                                  report: report)
    }
}
