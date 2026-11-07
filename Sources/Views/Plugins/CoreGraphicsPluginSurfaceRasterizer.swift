//
//  CoreGraphicsPluginSurfaceRasterizer.swift
//  Switchly
//
//  Production rasterizer for restricted dynamic surfaces. It owns only the
//  bitmap and the asset cache; all caching and pixel-budget decisions happen in
//  `PluginSurfaceRenderer`. Output is a top-left-origin, sRGB, premultiplied
//  8-bit RGBA bitmap tagged `.up`; the SceneKit material must not flip it again.
//

import AppKit
import CoreGraphics
import ImageIO

@MainActor
final class CoreGraphicsPluginSurfaceRasterizer: PluginSurfaceRasterizing {
    private var assets: SceneAssets
    private var assetsDirectory: URL?

    init(assetDirectory: URL? = nil) {
        assets = SceneAssets(directory: assetDirectory)
        assetsDirectory = assetDirectory?.standardizedFileURL
    }

    func rasterize(_ plan: PluginSurfaceRasterPlan) -> PluginSurfaceTexture? {
        let pixelWidth = Int(plan.pixelSize.width.rounded())
        let pixelHeight = Int(plan.pixelSize.height.rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= PluginSurfaceRequest.defaultMaxPixelEdge,
              pixelHeight <= PluginSurfaceRequest.defaultMaxPixelEdge,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: pixelWidth * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        context.setFillColor(plan.request.palette.background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        let directory = plan.request.assetDirectory?.standardizedFileURL
        if directory != assetsDirectory {
            assets = SceneAssets(directory: directory)
            assetsDirectory = directory
        }

        PluginSurfaceDrawing(context: context,
                             plan: plan,
                             artwork: plan.request.artwork?.image,
                             assets: assets).draw()

        guard let image = context.makeImage() else { return nil }
        return PluginSurfaceTexture(image: image,
                                    pointSize: plan.pointSize,
                                    pixelsPerPoint: plan.pixelsPerPoint,
                                    colorSpace: colorSpace,
                                    orientation: .up,
                                    contentSignature: plan.contentSignature)
    }
}
