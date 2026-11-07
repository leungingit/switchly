//
//  PluginScene3DAsset.swift
//  Switchly
//
//  Immutable asset identity shared by the scene3d cache and every instance.
//  Only decoded, immutable data lives here; camera state, surface textures and
//  material overrides belong to one `PluginScene3DInstance`.
//

import Foundation
import SceneKit

/// Cache key for a plugin asset. The plugin ID keeps two plugins with the same
/// bytes from sharing asset state; the hash makes in-place asset edits produce
/// a new entry.
struct PluginScene3DIdentity: Hashable {
    let pluginID: String
    let assetHash: String

    var cacheKey: String { "\(pluginID)#\(assetHash)" }
}

/// Decoded template scene plus the preflight report. Callers must clone the
/// template before mutating anything; the cached object is never handed to a
/// live view.
struct PluginScene3DAsset {
    let identity: PluginScene3DIdentity
    let templateScene: SCNScene
    let nodeNames: Set<String>
    let fileBytes: Int
    let report: GLBPreflight.Report
}

/// Runtime failure modes that switch the slot to the plugin-provided fallback.
/// Preflight/decode details stay in logs; the UI only needs the stable code.
enum PluginScene3DFailure: Error, Equatable {
    case assetMissing
    case preflightRejected(String)
    case decodeFailed(String)
    case nodeNotFound(String)
    case nodeAmbiguous(String)
    case uvMissing(String)
    case renderFailed
    case slotTooSmall

    var code: String {
        switch self {
        case .assetMissing: return "scene3d.assetMissing"
        case .preflightRejected: return "scene3d.preflightRejected"
        case .decodeFailed: return "scene3d.decodeFailed"
        case .nodeNotFound: return "scene3d.nodeNotFound"
        case .nodeAmbiguous: return "scene3d.nodeAmbiguous"
        case .uvMissing: return "scene3d.uvMissing"
        case .renderFailed: return "scene3d.renderFailed"
        case .slotTooSmall: return "scene3d.slotTooSmall"
        }
    }

    /// Diagnostic detail for logs only; never shown to the user.
    var detail: String? {
        switch self {
        case .preflightRejected(let detail), .decodeFailed(let detail):
            return detail
        case .nodeNotFound(let node), .nodeAmbiguous(let node), .uvMissing(let node):
            return node
        case .assetMissing, .renderFailed, .slotTooSmall:
            return nil
        }
    }
}

extension PluginScene3DFailure: LocalizedError {
    var errorDescription: String? { code }
}

enum PluginScene3DState: Equatable {
    case idle
    case loading
    case ready(PluginScene3DIdentity)
    case fallback(PluginScene3DFailure)
}
