import AppKit
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) -> CGImage {
    let dimension = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create bitmap context")
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    let cornerRadius = dimension * 0.22

    context.saveGState()
    context.addPath(roundedRect(bounds.insetBy(dx: dimension * 0.035, dy: dimension * 0.035), radius: cornerRadius))
    context.clip()

    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.20, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.58, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.27, green: 0.78, blue: 0.64, alpha: 1).cgColor
        ] as CFArray,
        locations: [0, 0.58, 1]
    )
    if let background {
        context.drawLinearGradient(background, start: CGPoint(x: 0, y: dimension), end: CGPoint(x: dimension, y: 0), options: [])
    }

    context.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.08).cgColor)
    context.fillEllipse(in: CGRect(x: dimension * 0.56, y: dimension * 0.58, width: dimension * 0.42, height: dimension * 0.42))
    context.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.14).cgColor)
    context.fillEllipse(in: CGRect(x: -dimension * 0.12, y: -dimension * 0.08, width: dimension * 0.48, height: dimension * 0.48))
    context.restoreGState()

    context.setShadow(offset: CGSize(width: 0, height: -dimension * 0.025), blur: dimension * 0.035, color: NSColor.black.withAlphaComponent(0.28).cgColor)

    let windowRects = [
        CGRect(x: dimension * 0.20, y: dimension * 0.44, width: dimension * 0.52, height: dimension * 0.34),
        CGRect(x: dimension * 0.28, y: dimension * 0.34, width: dimension * 0.52, height: dimension * 0.34),
        CGRect(x: dimension * 0.22, y: dimension * 0.24, width: dimension * 0.58, height: dimension * 0.38)
    ]

    for (index, rect) in windowRects.enumerated() {
        let radius = dimension * 0.055
        let alpha = index == 2 ? 0.96 : 0.72
        context.setFillColor(NSColor(calibratedWhite: 1, alpha: alpha).cgColor)
        context.addPath(roundedRect(rect, radius: radius))
        context.fillPath()

        context.setFillColor(NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.25, alpha: index == 2 ? 0.12 : 0.10).cgColor)
        let titleBar = CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.22, width: rect.width, height: rect.height * 0.22)
        context.addPath(roundedRect(titleBar, radius: radius))
        context.fillPath()

        context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.45).cgColor)
        context.setLineWidth(max(1, dimension * 0.008))
        context.addPath(roundedRect(rect.insetBy(dx: dimension * 0.003, dy: dimension * 0.003), radius: radius))
        context.strokePath()
    }

    context.setShadow(offset: CGSize(width: 0, height: -dimension * 0.012), blur: dimension * 0.018, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: dimension * 0.55, y: dimension * 0.74))
    bolt.addLine(to: CGPoint(x: dimension * 0.40, y: dimension * 0.48))
    bolt.addLine(to: CGPoint(x: dimension * 0.53, y: dimension * 0.48))
    bolt.addLine(to: CGPoint(x: dimension * 0.46, y: dimension * 0.26))
    bolt.addLine(to: CGPoint(x: dimension * 0.67, y: dimension * 0.57))
    bolt.addLine(to: CGPoint(x: dimension * 0.54, y: dimension * 0.57))
    bolt.closeSubpath()

    let boltGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 1.00, green: 0.92, blue: 0.35, alpha: 1).cgColor,
            NSColor(calibratedRed: 1.00, green: 0.56, blue: 0.16, alpha: 1).cgColor
        ] as CFArray,
        locations: [0, 1]
    )
    context.saveGState()
    context.addPath(bolt)
    context.clip()
    if let boltGradient {
        context.drawLinearGradient(boltGradient, start: CGPoint(x: dimension * 0.42, y: dimension * 0.75), end: CGPoint(x: dimension * 0.67, y: dimension * 0.25), options: [])
    }
    context.restoreGState()

    context.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
    context.setLineWidth(max(1, dimension * 0.012))
    context.addPath(bolt)
    context.strokePath()

    guard let cgImage = context.makeImage() else {
        fatalError("Failed to create app icon image")
    }
    return cgImage
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "IconGeneration", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) {
        throw NSError(domain: "IconGeneration", code: 2)
    }
}

for size in sizes {
    let image = drawIcon(size: size)
    try writePNG(image, to: outputDirectory.appendingPathComponent("AppIcon-\(size).png"))
}
