//
//  PluginSurfaceRasterizing.swift
//  Switchly
//
//  Injected rasterization boundary. The cache, signature and pixel-budget
//  rules live in `PluginSurfaceRenderer`; the AppKit/Core Graphics drawing
//  implementation lives in `Sources/Views/Plugins`. A fake rasterizer can count
//  calls and return a tiny texture in unit tests.
//

import CoreGraphics

/// A fully resolved rasterization job. `pixelSize` and `pixelsPerPoint` are
/// already clamped to the request's pixel edge limit.
struct PluginSurfaceRasterPlan {
    let request: PluginSurfaceRequest
    let pointSize: CGSize
    let pixelSize: CGSize
    let pixelsPerPoint: CGFloat
    let contentSignature: String
}

@MainActor
protocol PluginSurfaceRasterizing: AnyObject {
    /// Returns nil only when the bitmap cannot be created. Implementations
    /// must not mutate the request and must produce `.up`-oriented sRGB output.
    func rasterize(_ plan: PluginSurfaceRasterPlan) -> PluginSurfaceTexture?
}
