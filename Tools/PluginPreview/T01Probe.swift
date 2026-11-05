import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI

private enum ProbeMode: String {
    case offscreen
    case plain
    case glass
}

private struct ProbeOptions {
    let mode: ProbeMode
    let outputDirectory: URL

    init(arguments: [String]) throws {
        guard let rawMode = arguments.first, let mode = ProbeMode(rawValue: rawMode) else {
            throw ProbeError.usage("expected one of: offscreen, plain, glass")
        }
        guard let outIndex = arguments.firstIndex(of: "--out"), arguments.indices.contains(outIndex + 1) else {
            throw ProbeError.usage("missing --out <directory>")
        }
        self.mode = mode
        outputDirectory = URL(fileURLWithPath: arguments[outIndex + 1], isDirectory: true)
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let message): return "usage: T01Probe <offscreen|plain|glass> --out <directory>: \(message)"
        case .failed(let message): return message
        }
    }
}

private struct PixelStats {
    let width: Int
    let height: Int
    let opaquePixels: Int
    let transparentPixels: Int
    let variedPixels: Int
    let redPixels: Int
    let yellowPixels: Int
    let cyanPixels: Int

    var description: String {
        "width=\(width) height=\(height) opaque=\(opaquePixels) transparent=\(transparentPixels) varied=\(variedPixels) red=\(redPixels) yellow=\(yellowPixels) cyan=\(cyanPixels)"
    }
}

@main
private struct T01Probe {
    @MainActor
    static func main() {
        do {
            let options = try ProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
            printEnvironment(mode: options.mode, outputDirectory: options.outputDirectory)

            let fixtures = try ProbeFixtures.make(in: options.outputDirectory.appendingPathComponent("fixtures", isDirectory: true))
            switch options.mode {
            case .offscreen:
                try renderOffscreen(fixtures: fixtures, outputDirectory: options.outputDirectory)
            case .plain, .glass:
                try runWindow(mode: options.mode, fixtures: fixtures, outputDirectory: options.outputDirectory)
            }
        } catch {
            fputs("T01 probe failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func printEnvironment(mode: ProbeMode, outputDirectory: URL) {
        let app = NSApplication.shared
        let screen = NSScreen.main
        print("probe_mode=\(mode.rawValue)")
        print("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("architecture=\(currentArchitecture())")
        print("bundle=\(Bundle.main.bundlePath)")
        print("gui_screens=\(NSScreen.screens.count)")
        print("main_screen=\(screen.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)" } ?? "none")")
        print("screen_capture_preflight=\(CGPreflightScreenCaptureAccess())")
        print("reduce_motion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
        print("appearance=\(app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown")")
        print("output=\(outputDirectory.path)")
    }

    @MainActor
    private static func runWindow(mode: ProbeMode, fixtures: ProbeFixtures, outputDirectory: URL) throws {
        let app = NSApplication.shared
        let background = CommandLine.arguments.contains("--background")
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        app.finishLaunching()

        let root = ProbeContent(mode: mode, fixtures: fixtures)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.level = background ? .normal : .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = host

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2
            ))
        }
        let cover = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .blue
        cover.isOpaque = true
        cover.level = .floating
        defer { cover.orderOut(nil); window.orderOut(nil) }
        if background {
            window.orderBack(nil)
            cover.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        window.displayIfNeeded()
        CATransaction.flush()

        if background {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore else {
                throw ProbeError.failed("foreground changed during background capture")
            }
            print("background_frontmost_during=unchanged")
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
                  let coverIndex = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == cover.windowNumber }),
                  let targetIndex = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }),
                  coverIndex < targetIndex, cover.frame.contains(window.frame) else {
                throw ProbeError.failed("target is not fully occluded")
            }
            print("background_occlusion=PASS")
        }
        let screenshot = outputDirectory.appendingPathComponent("\(mode.rawValue)-window.png")
        try captureWindow(window, to: screenshot)
        let stats = try imageStats(at: screenshot)
        print("screenshot=\(screenshot.path)")
        print("screenshot_stats=\(stats.description)")
        guard stats.width > 400, stats.height > 400, stats.variedPixels > 1_000 else {
            throw ProbeError.failed("window screenshot is empty or visually uniform")
        }
        guard stats.redPixels > 100, stats.yellowPixels > 100 else {
            throw ProbeError.failed("window screenshot does not contain the real control artwork")
        }
        guard stats.cyanPixels > 100 else {
            throw ProbeError.failed("window screenshot does not contain the Scene image fixture")
        }
        if background {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore else {
                throw ProbeError.failed("foreground changed after capture")
            }
            print("background_frontmost_after=unchanged")
        }
        print("window_capture=PASS")
        window.orderOut(nil)
        window.contentView = nil
    }

    @MainActor
    private static func renderOffscreen(fixtures: ProbeFixtures, outputDirectory: URL) throws {
        guard #available(macOS 13.0, *) else {
            print("offscreen_renderer=UNSUPPORTED reason=macOS<13")
            return
        }
        let root = ProbeContent(mode: .plain, fixtures: fixtures)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ProbeError.failed("ImageRenderer produced no bitmap")
        }
        let screenshot = outputDirectory.appendingPathComponent("offscreen-imagerenderer.png")
        try png.write(to: screenshot)
        let stats = try imageStats(at: screenshot)
        print("screenshot=\(screenshot.path)")
        print("screenshot_stats=\(stats.description)")
        guard stats.width > 400, stats.height > 400, stats.variedPixels > 1_000 else {
            throw ProbeError.failed("ImageRenderer bitmap is empty or visually uniform")
        }
        let artworkPass = stats.redPixels > 100 && stats.yellowPixels > 100
        let sceneImagePass = stats.cyanPixels > 100
        print("offscreen_artwork=\(artworkPass ? "PASS" : "FAIL")")
        print("offscreen_scene_image=\(sceneImagePass ? "PASS" : "FAIL")")
        if !artworkPass || !sceneImagePass {
            throw ProbeError.failed("ImageRenderer omitted one or more shared SwiftUI/Canvas layers")
        }
        print("offscreen_renderer=PASS")
    }

    @MainActor
    private static func captureWindow(_ window: NSWindow, to url: URL) throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ProbeError.failed("screen capture permission is unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path),
              (try? Data(contentsOf: url).isEmpty) == false else {
            throw ProbeError.failed("screencapture failed status=\(process.terminationStatus) stderr=\(errorText)")
        }
        if !errorText.isEmpty {
            print("screencapture_stderr=\(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

private struct ProbeFixtures {
    let artwork: NSImage
    let assetDirectory: URL
    let controls: PluginUINode
    let images: PluginUINode
    let scene: PluginScene

    static func make(in directory: URL) throws -> ProbeFixtures {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artworkURL = directory.appendingPathComponent("artwork.png")
        let assetURL = directory.appendingPathComponent("plugin-asset.png")
        let sceneImageURL = directory.appendingPathComponent("scene-image.png")
        try writeArtworkPNG(to: artworkURL)
        try writeAssetPNG(to: assetURL)
        try writeSceneImagePNG(to: sceneImageURL)
        guard let artwork = NSImage(contentsOf: artworkURL) else {
            throw ProbeError.failed("could not load generated artwork")
        }

        let controls = PluginUINode.vstack(children: [
            .text(value: "通用控件 · Shared Renderer", style: .title, lines: 1),
            .surface(children: [
                .hstack(children: [
                    .image(source: .artwork, size: .l, corner: .m),
                    .vstack(children: [
                        .text(value: "Now playing", style: .caption, lines: 1),
                        .text(value: "真实 artwork 与原生控件", style: .body, lines: 1),
                        .progress(value: 0.64, style: .linear, rate: nil)
                    ], spacing: .xs, align: .leading)
                ], spacing: .m, align: .center)
            ], material: .glass),
            .hstack(children: [
                .button(id: "previous", symbol: "backward.fill", label: "上一首", size: .m,
                        variant: .plain, enabled: true, selected: false),
                .button(id: "play", symbol: "play.fill", label: "播放", size: .l,
                        variant: .prominent, enabled: true, selected: false),
                .button(id: "next", symbol: "forward.fill", label: "下一首", size: .m,
                        variant: .plain, enabled: true, selected: false),
                .toggle(id: "favorite", symbolOn: "heart.fill", symbolOff: "heart",
                        isOn: true, label: "收藏")
            ], spacing: .m, align: .center),
            .slider(id: "volume", value: 0.42, label: "音量", step: 0.05),
            .hstack(children: [
                .badge(value: "NATIVE", tone: .accent),
                .text(value: "button / toggle / slider / progress", style: .caption, lines: 1)
            ], spacing: .s, align: .center)
        ], spacing: .m, align: .leading)

        let images = PluginUINode.hstack(children: [
            .image(source: .artwork, size: .l, corner: .m),
            .image(source: .pluginAsset("plugin-asset.png"), size: .l, corner: .m),
            .vstack(children: [
                .text(value: "真实图片", style: .title, lines: 1),
                .text(value: "artwork + plugin asset，经共享资产预算解码", style: .caption, lines: 2)
            ], spacing: .xs, align: .leading)
        ], spacing: .m, align: .center)

        let sceneJSON = #"""
        {
          "key": "t01-scene",
          "epoch": 0,
          "width": 360,
          "height": 120,
          "fps": 30,
          "fit": "width",
          "layers": [
            {
              "kind": "rect", "x": 180, "y": 60, "w": 348, "h": 112, "radius": 14,
              "fill": {"linear": {"colors": ["#18283D", "#4E2B67"], "from": [0, 0], "to": [1, 1]}},
              "stroke": {"color": "#FFFFFF40", "width": 1}
            },
            {"kind": "image", "x": 90, "y": 60, "w": 82, "h": 82, "image": "scene-image.png"},
            {
              "kind": "ellipse", "x": 274, "y": 48, "w": 42, "h": 42, "fill": "#53D8FF",
              "osc": [{"prop": "scale", "amp": 0.08, "freq": 1.2}]
            },
            {
              "kind": "text", "x": 274, "y": 90, "w": 150, "text": "Scene · 共享 Canvas",
              "fill": "$label", "size": 15, "weight": "semibold"
            }
          ]
        }
        """#
        let scene = try JSONDecoder().decode(PluginScene.self, from: Data(sceneJSON.utf8))
        return ProbeFixtures(artwork: artwork, assetDirectory: directory,
                             controls: controls, images: images, scene: scene)
    }

    private static func writeArtworkPNG(to url: URL) throws {
        try writePNG(to: url, width: 96, height: 96) { x, y in
            let dx = Double(x) - 47.5, dy = Double(y) - 47.5
            if dx * dx + dy * dy < 15 * 15 {
                return (255, 255, 255, 255)
            }
            if x < 48 && y < 48 { return (240, 42, 62, 255) }
            if x >= 48 && y < 48 { return (255, 203, 55, 255) }
            if x < 48 { return (45, 196, 125, 255) }
            return (58, 116, 255, 255)
        }
    }

    private static func writeAssetPNG(to url: URL) throws {
        try writePNG(to: url, width: 96, height: 96) { x, y in
            let stripe = (x + y) / 10 % 2 == 0
            if stripe { return (255, 205, 35, 255) }
            return (238, 42, 67, 255)
        }
    }

    private static func writeSceneImagePNG(to url: URL) throws {
        try writePNG(to: url, width: 120, height: 96) { x, y in
            let ring = (x - 60) * (x - 60) + (y - 48) * (y - 48)
            if ring < 14 * 14 { return (255, 255, 255, 255) }
            if x + y < 120 { return (45, 221, 255, 255) }
            return (186, 75, 255, 255)
        }
    }

    private static func writePNG(
        to url: URL,
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let bytes = rep.bitmapData else {
            throw ProbeError.failed("could not allocate fixture bitmap")
        }
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let offset = y * rep.bytesPerRow + x * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = color.3
            }
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ProbeError.failed("could not encode fixture PNG")
        }
        try data.write(to: url)
    }
}

private struct ProbeContent: View {
    let mode: ProbeMode
    let fixtures: ProbeFixtures

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .fill(mode == .glass ? Color.clear : Color(nsColor: .windowBackgroundColor))
                .panelGlass(
                    isActive: mode == .glass,
                    opacity: 0.72,
                    cornerRadius: DesignTokens.Radius.panel,
                    material: .legacyDefault
                )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switchly Plugin Preview · T01")
                            .font(.title3.weight(.semibold))
                        Text("独立进程 · 共享 Renderer · 合成 fixture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(mode == .glass ? "GLASS WINDOW" : "PLAIN RENDER")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }

                section("CONTROLS") {
                    PluginOverlayView(
                        node: fixtures.controls,
                        material: .legacyDefault,
                        isGlassActive: mode == .glass,
                        artwork: fixtures.artwork,
                        assetDirectory: fixtures.assetDirectory,
                        onAction: { id, value in print("fixture_action=\(id) value=\(String(describing: value))") }
                    )
                }

                section("SCENE") {
                    PluginSceneView(scene: fixtures.scene, assetDirectory: fixtures.assetDirectory) { id, value in
                        print("scene_action=\(id) value=\(String(describing: value))")
                    }
                    .frame(height: 128)
                }

                section("IMAGES") {
                    PluginOverlayView(
                        node: fixtures.images,
                        material: .legacyDefault,
                        isGlassActive: mode == .glass,
                        artwork: fixtures.artwork,
                        assetDirectory: fixtures.assetDirectory,
                        onAction: { _, _ in }
                    )
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 760)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .strokeBorder(Color.white.opacity(mode == .glass ? 0.16 : 0.08), lineWidth: 0.5)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            content()
                .padding(DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                        .fill(Color.white.opacity(mode == .glass ? 0.055 : 0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}

private func imageStats(at url: URL) throws -> PixelStats {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ProbeError.failed("could not decode screenshot \(url.path)")
    }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw ProbeError.failed("could not rasterize screenshot") }

    var opaque = 0, transparent = 0, varied = 0, red = 0, yellow = 0, cyan = 0
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2]), a = Int(bytes[offset + 3])
        if a > 240 { opaque += 1 } else if a < 15 { transparent += 1 }
        let spread = max(r, max(g, b)) - min(r, min(g, b))
        if a > 180 && spread > 45 { varied += 1 }
        if r > 165 && g < 125 && b < 145 && spread > 60 { red += 1 }
        if r > 145 && g > 130 && b < 125 && spread > 55 { yellow += 1 }
        if r < 125 && g > 115 && b > 145 && spread > 55 { cyan += 1 }
    }
    return PixelStats(width: width, height: height, opaquePixels: opaque, transparentPixels: transparent,
                      variedPixels: varied, redPixels: red, yellowPixels: yellow, cyanPixels: cyan)
}

private func currentArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
