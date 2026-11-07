//
//  PluginSurfaceTexture.swift
//  Switchly
//
//  One immutable surface texture owned by the scene that displays it. The
//  image is sRGB, top-left origin and encoded with `.up` orientation, so the
//  SceneKit material must not apply a second vertical flip.
//

import AppKit
import CoreGraphics
import ImageIO

struct PluginSurfaceTexture {
    /// Immutable bitmap in sRGB. Row 0 is the top of the surface.
    let image: CGImage
    /// Logical size in points used for layout and material sizing.
    let pointSize: CGSize
    /// Effective density after the 1024 px edge clamp.
    let pixelsPerPoint: CGFloat
    let colorSpace: CGColorSpace
    /// Always `.up`; drawing already bakes the orientation into the bitmap.
    let orientation: CGImagePropertyOrientation
    /// Identity of the content that produced this texture.
    let contentSignature: String

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    /// AppKit view of the same bitmap for previews and NSImage-based storage.
    var nsImage: NSImage {
        NSImage(cgImage: image, size: pointSize)
    }

    init(image: CGImage,
         pointSize: CGSize,
         pixelsPerPoint: CGFloat,
         colorSpace: CGColorSpace,
         orientation: CGImagePropertyOrientation,
         contentSignature: String) {
        self.image = image
        self.pointSize = pointSize
        self.pixelsPerPoint = pixelsPerPoint
        self.colorSpace = colorSpace
        self.orientation = orientation
        self.contentSignature = contentSignature
    }
}
