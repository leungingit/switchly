//
//  PluginSurfaceRenderer.swift
//  Switchly
//
//  Owns the content-signature cache for one 3D scene instance. The renderer
//  rejects forbidden §9.4 content, clamps the requested surface to 1024×1024
//  pixels while preserving aspect ratio, computes a deterministic signature,
//  and only calls the injected rasterizer when the signature is not cached.
//  Textures are immutable and owned by the caller that asked for them.
//

import CoreGraphics
import Foundation

@MainActor
final class PluginSurfaceRenderer {
    private let rasterizer: PluginSurfaceRasterizing
    private let cacheCapacity: Int
    private var cache: [String: PluginSurfaceTexture] = [:]
    /// Least-recently-used order, oldest first.
    private var order: [String] = []

    init(rasterizer: PluginSurfaceRasterizing, cacheCapacity: Int = 4) {
        self.rasterizer = rasterizer
        self.cacheCapacity = max(0, cacheCapacity)
    }

    /// Returns a cached texture when the content is unchanged, otherwise
    /// rasterizes once and stores the result. Returns nil for content outside
    /// the §9.4 allowlist, an invalid size, or a failed bitmap allocation.
    func texture(for request: PluginSurfaceRequest) -> PluginSurfaceTexture? {
        guard PluginSurfaceContentValidator.allows(request.content) else { return nil }
        let width = request.pointSize.width
        let height = request.pointSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              request.pixelsPerPoint.isFinite, request.pixelsPerPoint > 0 else { return nil }

        // A caller cannot raise the frozen 1024 px per-surface limit.
        let maxEdge = CGFloat(min(max(1, request.maxPixelEdge), PluginSurfaceRequest.defaultMaxPixelEdge))
        let fitScale = min(maxEdge / width, maxEdge / height)
        let scale = min(request.pixelsPerPoint, fitScale)
        let pixelWidth = max(1, Int((width * scale).rounded()))
        let pixelHeight = max(1, Int((height * scale).rounded()))
        let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        let pixelsPerPoint = min(scale, CGFloat(pixelWidth) / width, CGFloat(pixelHeight) / height)

        let signature = PluginSurfaceSignature.make(for: request,
                                                    pixelSize: pixelSize,
                                                    pixelsPerPoint: pixelsPerPoint)
        if let cached = cache[signature] {
            touch(signature)
            return cached
        }

        let plan = PluginSurfaceRasterPlan(request: request,
                                           pointSize: request.pointSize,
                                           pixelSize: pixelSize,
                                           pixelsPerPoint: pixelsPerPoint,
                                           contentSignature: signature)
        guard let texture = rasterizer.rasterize(plan) else { return nil }
        store(texture, for: signature)
        return texture
    }

    /// Drops one signature, for example when a plugin asset file changes
    /// outside the normal content-tree flow.
    func invalidate(_ signature: String) {
        cache.removeValue(forKey: signature)
        order.removeAll { $0 == signature }
    }

    /// Releases all textures owned by this renderer. Scene teardown must call
    /// this so a hidden or unloaded view does not keep GPU-backed bitmaps alive.
    func removeAll() {
        cache.removeAll()
        order.removeAll()
    }

    var cachedTextureCount: Int { cache.count }

    private func store(_ texture: PluginSurfaceTexture, for signature: String) {
        guard cacheCapacity > 0 else { return }
        cache[signature] = texture
        touch(signature)
        while order.count > cacheCapacity {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func touch(_ signature: String) {
        order.removeAll { $0 == signature }
        order.append(signature)
    }
}
