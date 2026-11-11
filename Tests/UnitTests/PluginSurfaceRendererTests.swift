//
//  PluginSurfaceRendererTests.swift
//  SwitchlyTests
//
//  T04 regression tests for the restricted 2D dynamic surface: content-hash
//  deduplication, redraw on real content changes, the 1024 px clamp, pixel
//  density, upright sRGB output, and empty/long multilingual content.
//

import AppKit
import CoreGraphics
import XCTest
@testable import Switchly

@MainActor
final class PluginSurfaceRendererTests: XCTestCase {
    // MARK: - Cache and redraw

    func testSameContentRendersOnceAndReusesTheTexture() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)
        let first = renderer.texture(for: makeRequest())
        let second = renderer.texture(for: makeRequest())

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(renderer.cachedTextureCount, 1)
        XCTAssertEqual(first?.contentSignature, second?.contentSignature)
        XCTAssertEqual(first?.image.width, second?.image.width)
    }

    func testTextChangeRendersAgainWithANewSignature() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)
        var request = makeRequest()
        let original = renderer.texture(for: request)

        request.content = .vstack(children: [
            .text(value: "Different title", style: .title, lines: 1)
        ], spacing: nil, align: nil)
        let changed = renderer.texture(for: request)

        XCTAssertEqual(fake.callCount, 2)
        XCTAssertNotEqual(original?.contentSignature, changed?.contentSignature)
        XCTAssertNotNil(changed)
    }

    func testProgressValueChangeRendersAgainButRateChangeDoesNot() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)
        var request = makeRequest(progress: 0.25)
        _ = renderer.texture(for: request)

        request.content = progressNode(value: 0.25, rate: 0.1)
        _ = renderer.texture(for: request)
        XCTAssertEqual(fake.callCount, 1, "rate is interpolated by the host, not baked into the surface")

        request.content = progressNode(value: 0.75, rate: 0.1)
        _ = renderer.texture(for: request)
        XCTAssertEqual(fake.callCount, 2)
    }

    func testArtworkTokenChangeRendersAgainEvenWhenTheImageObjectIsReused() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)
        let image = makeStripedImage()
        var request = makeRequest()
        request.artwork = PluginSurfaceArtwork(token: "cover-A", image: image)
        _ = renderer.texture(for: request)

        request.artwork = PluginSurfaceArtwork(token: "cover-B", image: image)
        _ = renderer.texture(for: request)

        XCTAssertEqual(fake.callCount, 2)
    }

    func testLeastRecentlyUsedTextureIsEvicted() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake, cacheCapacity: 1)
        var request = makeRequest()
        _ = renderer.texture(for: request)
        request.content = .text(value: "Second", style: .body, lines: 1)
        _ = renderer.texture(for: request)
        request.content = .text(value: "Third", style: .body, lines: 1)
        _ = renderer.texture(for: request)

        XCTAssertEqual(fake.callCount, 3)
        XCTAssertEqual(renderer.cachedTextureCount, 1)
    }

    // MARK: - Size, density and format

    func testPixelEdgesAreClampedTo1024WhilePreservingAspectRatio() {
        var request = makeRequest()
        request.pointSize = CGSize(width: 1600, height: 900)
        request.pixelsPerPoint = 2
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = renderer.texture(for: request)

        XCTAssertEqual(texture?.image.width, 1024)
        XCTAssertEqual(texture?.image.height, 576)
        XCTAssertEqual(texture?.pixelsPerPoint ?? 0, 0.64, accuracy: 1e-9)
        XCTAssertEqual(texture?.pointSize, request.pointSize)
    }

    func testCallerCannotRaiseThePixelEdgeLimit() {
        var request = makeRequest()
        request.pointSize = CGSize(width: 3000, height: 3000)
        request.pixelsPerPoint = 2
        request.maxPixelEdge = 4096
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = renderer.texture(for: request)

        XCTAssertEqual(texture?.image.width, 1024)
        XCTAssertEqual(texture?.image.height, 1024)
    }

    func testSmallSurfaceUsesTheRequestedBackingScale() {
        var request = makeRequest()
        request.pointSize = CGSize(width: 100, height: 50)
        request.pixelsPerPoint = 2
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = renderer.texture(for: request)

        XCTAssertEqual(texture?.image.width, 200)
        XCTAssertEqual(texture?.image.height, 100)
        XCTAssertEqual(texture?.pixelsPerPoint, 2)
    }

    func testOutputIsUprightSRGBWithPremultipliedAlpha() throws {
        var request = makeRequest()
        request.pointSize = CGSize(width: 100, height: 100)
        request.pixelsPerPoint = 2
        request.palette = opaquePalette()
        request.content = .image(source: .artwork, size: .l, corner: .m)
        request.artwork = PluginSurfaceArtwork(token: "stripes", image: try XCTUnwrap(makeStripedImage()))
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = try XCTUnwrap(renderer.texture(for: request))
        XCTAssertEqual(texture.orientation, .up)
        XCTAssertEqual(texture.colorSpace.name as String?,
                       CGColorSpace(name: CGColorSpace.sRGB)?.name as String?)
        XCTAssertEqual(texture.image.alphaInfo, .premultipliedLast)

        // The fixture's first row is red and the second row is blue. An upright
        // surface must keep red above blue; a double vertical flip would swap
        // the sampled pixels.
        let top = try XCTUnwrap(pixel(texture.image, x: 100, y: 20))
        let bottom = try XCTUnwrap(pixel(texture.image, x: 100, y: 180))
        XCTAssertGreaterThan(top.r, 200)
        XCTAssertLessThan(top.b, 60)
        XCTAssertGreaterThan(bottom.b, 200)
        XCTAssertLessThan(bottom.r, 60)
    }

    // MARK: - Invalid and empty input

    func testInvalidSizesAreRejectedWithoutRasterizing() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)

        var zero = makeRequest()
        zero.pointSize = .zero
        XCTAssertNil(renderer.texture(for: zero))

        var negative = makeRequest()
        negative.pointSize = CGSize(width: -10, height: 10)
        XCTAssertNil(renderer.texture(for: negative))

        var infinite = makeRequest()
        infinite.pointSize = CGSize(width: CGFloat.infinity, height: 10)
        XCTAssertNil(renderer.texture(for: infinite))

        var badDensity = makeRequest()
        badDensity.pixelsPerPoint = 0
        XCTAssertNil(renderer.texture(for: badDensity))

        XCTAssertEqual(fake.callCount, 0)
    }

    func testEmptyTreeProducesAFullyTransparentTexture() throws {
        var request = makeRequest()
        request.pointSize = CGSize(width: 200, height: 120)
        request.palette = opaquePalette()
        request.palette.background = .clear
        request.content = .vstack(children: [], spacing: nil, align: nil)
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = try XCTUnwrap(renderer.texture(for: request))
        let data = try XCTUnwrap(texture.image.dataProvider?.data as Data?)
        XCTAssertEqual(texture.image.width, 400)
        XCTAssertEqual(texture.image.height, 240)
        for y in stride(from: 0, to: texture.image.height, by: 40) {
            let color = try XCTUnwrap(pixel(texture.image, x: 40, y: y))
            XCTAssertEqual(color.a, 0, "empty tree must not paint pixels")
        }
        XCTAssertFalse(data.isEmpty)
    }

    func testEmptyTitleAndZeroProgressStillRender() throws {
        var request = makeRequest()
        request.pointSize = CGSize(width: 300, height: 160)
        request.content = .vstack(children: [
            .text(value: "", style: .caption, lines: 1),
            .progress(value: 0, style: .linear, rate: nil),
            .image(source: .artwork, size: .m, corner: .m)
        ], spacing: .s, align: .center)
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = try XCTUnwrap(renderer.texture(for: request))
        // The empty text has no ink, but the progress track and the missing
        // cover placeholder do.
        let ink = countNonBackgroundPixels(texture.image, background: (255, 255, 255))
        XCTAssertGreaterThan(ink, 0)
    }

    // MARK: - Content edge cases

    func testLongMixedLanguageTitleDrawsVisibleInkAndTruncatesToOneLine() throws {
        var request = makeRequest()
        request.pointSize = CGSize(width: 280, height: 40)
        request.palette = opaquePalette()
        request.content = .text(
            value: "正在播放：鲸娘的真实姿态 — A Very Long Mixed-Language Track Title That Must Truncate",
            style: .title,
            lines: 1)
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = try XCTUnwrap(renderer.texture(for: request))
        let ink = countDarkPixels(texture.image, yRange: 0..<texture.image.height)
        XCTAssertGreaterThan(ink, 20, "Core Text must draw the UTF-8 title")

        // One line remains inside the 40 pt request at 2x: the centred 16 pt
        // line ends around 56 px, so the bottom quarter must stay clean.
        let overflow = countDarkPixels(texture.image, yRange: 60..<texture.image.height)
        XCTAssertEqual(overflow, 0, "a one-line title must not draw a second row")
    }

    func testBodyTextDrawsVisibleInk() throws {
        // Regression: the 10 pt medium body font measures 11.78 pt from its
        // font metrics but Core Text needs a 13 pt line box. A frame clamped to
        // the smaller height contains no lines and silently draws nothing.
        var request = makeRequest()
        request.pointSize = CGSize(width: 260, height: 40)
        request.palette = opaquePalette()
        request.content = .text(
            value: "A Very Long Mixed-Language Track Title",
            style: .body,
            lines: 1)
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = try XCTUnwrap(renderer.texture(for: request))
        let upper = countDarkPixels(texture.image, yRange: 0..<50)
        XCTAssertGreaterThan(upper, 20, "Core Text must draw the body line inside its 13 pt box")
        let lower = countDarkPixels(texture.image, yRange: 60..<texture.image.height)
        XCTAssertEqual(lower, 0, "a one-line body text must not spill below its slot")
    }

    func testMissingArtworkDrawsThePlaceholder() throws {
        var request = makeRequest()
        request.pointSize = CGSize(width: 100, height: 100)
        request.pixelsPerPoint = 1
        request.palette = opaquePalette()
        request.palette.placeholderFill = PluginSurfaceColor(white: 0.2)
        request.content = .image(source: .artwork, size: .l, corner: .m)
        request.artwork = PluginSurfaceArtwork(token: "missing", image: nil)
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = try XCTUnwrap(renderer.texture(for: request))
        // The image is 88 pt centred in 100 pt; (24, 24) is inside the rounded
        // placeholder but outside the centred music-note symbol.
        let corner = try XCTUnwrap(pixel(texture.image, x: 24, y: 24))
        XCTAssertLessThan(corner.r, 100, "placeholder fill should darken the cover area")
    }

    func testCircularProgressRendersWithoutFailure() throws {
        var request = makeRequest()
        request.pointSize = CGSize(width: 80, height: 80)
        request.pixelsPerPoint = 2
        request.palette = opaquePalette()
        request.content = .progress(value: 0.6, style: .circular, rate: nil)
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = try XCTUnwrap(renderer.texture(for: request))
        let ink = countNonBackgroundPixels(texture.image, background: (255, 255, 255))
        XCTAssertGreaterThan(ink, 20)
    }

    // MARK: - §9.4 allowlist

    func testBadgeValueAndToneParticipateInTheSignature() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)
        var request = makeRequest()

        request.content = .badge(value: "NEW", tone: .neutral)
        _ = renderer.texture(for: request)
        request.content = .badge(value: "NEW", tone: .accent)
        _ = renderer.texture(for: request)
        request.content = .badge(value: "OLD", tone: .accent)
        _ = renderer.texture(for: request)

        XCTAssertEqual(fake.callCount, 3, "value and tone both change the pixels")
        XCTAssertEqual(renderer.cachedTextureCount, 3)
    }

    func testBadgeDrawsACapsuleFillWithWhiteText() throws {
        var request = makeRequest()
        request.pointSize = CGSize(width: 160, height: 40)
        request.pixelsPerPoint = 2
        request.palette = opaquePalette()
        request.content = .badge(value: "NEW", tone: .accent)
        let renderer = PluginSurfaceRenderer(rasterizer: CoreGraphicsPluginSurfaceRasterizer())

        let texture = try XCTUnwrap(renderer.texture(for: request))
        let box = try XCTUnwrap(accentBadgeBounds(texture.image))
        XCTAssertGreaterThan(box.width, 20)
        XCTAssertGreaterThan(box.height, 10)
        XCTAssertLessThan(box.width, CGFloat(texture.image.width))

        // A capsule keeps its rounded corner transparent over the white
        // background; its left edge centre is filled with the accent color.
        let corner = try XCTUnwrap(pixel(texture.image, x: Int(box.minX), y: Int(box.minY)))
        XCTAssertGreaterThan(corner.r, 240, "capsule corner must stay background")
        let edge = try XCTUnwrap(pixel(texture.image, x: Int(box.minX) + 2, y: Int(box.midY)))
        XCTAssertGreaterThan(edge.r, 200)
        XCTAssertLessThan(edge.g, 80)

        XCTAssertGreaterThan(countWhitePixelsInside(texture.image, box: box), 10,
                             "the accent badge draws white label text")
    }

    func testForbiddenNodesAreRejectedWithoutRasterizing() throws {
        let scene = try JSONDecoder().decode(
            PluginUINode.self,
            from: Data(#"{"type":"scene","key":"k","epoch":0,"width":100,"height":100,"layers":[{"kind":"group"}]}"#.utf8))
        let forbidden: [PluginUINode] = [
            .surface(children: [.text(value: "Inside", style: .caption, lines: 1)], material: .plain),
            .screen(children: [.text(value: "Inside", style: .caption, lines: 1)]),
            .button(id: "go", symbol: "play.fill", label: "Play", size: .m,
                    variant: .plain, enabled: true, selected: false),
            .toggle(id: "on", symbolOn: "sun.max", symbolOff: "moon", isOn: true, label: "Theme"),
            .slider(id: "volume", value: 0.5, label: "Volume", step: 0.1),
            .wheel(children: [.spacer, .spacer, .spacer, .spacer,
                              .text(value: "OK", style: .caption, lines: 1)]),
            scene
        ]
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)

        for node in forbidden {
            var request = makeRequest()
            request.content = node
            XCTAssertNil(renderer.texture(for: request), "forbidden node must be rejected")
        }
        XCTAssertEqual(fake.callCount, 0)
        XCTAssertEqual(renderer.cachedTextureCount, 0)
    }

    func testNestedForbiddenContentIsRejectedWithoutRasterizing() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)
        var request = makeRequest()
        request.content = .vstack(children: [
            .text(value: "Title", style: .title, lines: 1),
            .zstack(children: [.screen(children: [])])
        ], spacing: .s, align: .leading)

        XCTAssertNil(renderer.texture(for: request))
        XCTAssertEqual(fake.callCount, 0)
    }

    func testEveryAllowlistedNodeTypeRendersOnce() {
        let fake = FakeRasterizer()
        let renderer = PluginSurfaceRenderer(rasterizer: fake)
        var request = makeRequest()
        request.content = .vstack(children: [
            .hstack(children: [
                .text(value: "Now playing", style: .title, lines: 1),
                .spacer,
                .badge(value: "NEW", tone: .accent)
            ], spacing: .s, align: .center),
            .vstack(children: [
                .zstack(children: [
                    .image(source: .symbol("music.note"), size: .s, corner: .s),
                    .progress(value: 0.4, style: .circular, rate: nil)
                ]),
                .progress(value: 0.4, style: .linear, rate: nil),
                .marquee(value: "Artist — Track")
            ], spacing: .xs, align: .leading)
        ], spacing: .m, align: .leading)

        XCTAssertNotNil(renderer.texture(for: request))
        XCTAssertEqual(fake.callCount, 1)
    }

    // MARK: - Helpers

    private func makeRequest(progress: Double = 0.5) -> PluginSurfaceRequest {
        let content: PluginUINode = progress == 0.5
            ? .vstack(children: [
                .text(value: "Now playing", style: .title, lines: 1),
                .text(value: "Artist", style: .caption, lines: 1),
                .progress(value: 0.5, style: .linear, rate: nil)
            ], spacing: .s, align: .leading)
            : progressNode(value: progress, rate: nil)
        return PluginSurfaceRequest(content: content,
                                    pointSize: CGSize(width: 200, height: 80),
                                    pixelsPerPoint: 2,
                                    artwork: nil,
                                    assetDirectory: nil,
                                    palette: opaquePalette(),
                                    maxPixelEdge: PluginSurfaceRequest.defaultMaxPixelEdge)
    }

    private func progressNode(value: Double, rate: Double?) -> PluginUINode {
        .progress(value: value, style: .linear, rate: rate)
    }

    private func opaquePalette() -> PluginSurfacePalette {
        var palette = PluginSurfacePalette()
        palette.background = .white
        palette.text = .black
        palette.secondaryText = PluginSurfaceColor(white: 0.35)
        palette.progressTrack = PluginSurfaceColor(white: 0.8)
        palette.progressFill = PluginSurfaceColor(red: 0.9, green: 0.1, blue: 0.1)
        palette.placeholderFill = PluginSurfaceColor(white: 0.85)
        palette.badgeNeutralFill = PluginSurfaceColor(white: 0.8)
        palette.badgeAccentFill = PluginSurfaceColor(red: 0.9, green: 0.1, blue: 0.1)
        palette.badgeWarningFill = PluginSurfaceColor(red: 0.95, green: 0.5, blue: 0.1)
        palette.badgeText = .white
        return palette
    }

    private func makeStripedImage() -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let bytes: [UInt8] = [
            255, 0, 0, 255, 255, 0, 0, 255,
            0, 0, 255, 255, 0, 0, 255, 255
        ]
        guard let colorSpace,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: 2,
                       height: 2,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: 8,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let cfData = image.dataProvider?.data else { return nil }
        let bytes = [UInt8](cfData as Data)
        let index = y * image.bytesPerRow + x * 4
        guard index + 3 < bytes.count else { return nil }
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }

    private func countNonBackgroundPixels(_ image: CGImage,
                                          background: (UInt8, UInt8, UInt8)) -> Int {
        countPixels(image) { r, g, b in
            abs(Int(r) - Int(background.0)) > 10
                || abs(Int(g) - Int(background.1)) > 10
                || abs(Int(b) - Int(background.2)) > 10
        }
    }

    private func countPixels(_ image: CGImage,
                             matching: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        guard let cfData = image.dataProvider?.data else { return 0 }
        let bytes = [UInt8](cfData as Data)
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = y * image.bytesPerRow + x * 4
                guard index + 3 < bytes.count else { continue }
                if matching(bytes[index], bytes[index + 1], bytes[index + 2]) { count += 1 }
            }
        }
        return count
    }

    private func countDarkPixels(_ image: CGImage, yRange: Range<Int>) -> Int {
        guard let cfData = image.dataProvider?.data else { return 0 }
        let bytes = [UInt8](cfData as Data)
        let lower = max(0, yRange.lowerBound)
        let upper = min(image.height, yRange.upperBound)
        guard lower < upper else { return 0 }
        var count = 0
        for y in lower..<upper {
            for x in 0..<image.width {
                let index = y * image.bytesPerRow + x * 4
                guard index + 3 < bytes.count else { continue }
                if bytes[index] < 100, bytes[index + 1] < 100, bytes[index + 2] < 100 {
                    count += 1
                }
            }
        }
        return count
    }

    private func accentBadgeBounds(_ image: CGImage) -> CGRect? {
        guard let cfData = image.dataProvider?.data else { return nil }
        let bytes = [UInt8](cfData as Data)
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = y * image.bytesPerRow + x * 4
                guard index + 3 < bytes.count else { continue }
                if bytes[index] > 180, bytes[index + 1] < 80, bytes[index + 2] < 80 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func countWhitePixelsInside(_ image: CGImage, box: CGRect) -> Int {
        guard let cfData = image.dataProvider?.data else { return 0 }
        let bytes = [UInt8](cfData as Data)
        var count = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                let index = y * image.bytesPerRow + x * 4
                guard index + 3 < bytes.count else { continue }
                if bytes[index] > 230, bytes[index + 1] > 230, bytes[index + 2] > 230 {
                    count += 1
                }
            }
        }
        return count
    }
}

@MainActor
private final class FakeRasterizer: PluginSurfaceRasterizing {
    private(set) var plans: [PluginSurfaceRasterPlan] = []
    var callCount: Int { plans.count }

    func rasterize(_ plan: PluginSurfaceRasterPlan) -> PluginSurfaceTexture? {
        plans.append(plan)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let context = CGContext(data: nil,
                                      width: 4,
                                      height: 4,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 16,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        return PluginSurfaceTexture(image: image,
                                    pointSize: plan.pointSize,
                                    pixelsPerPoint: plan.pixelsPerPoint,
                                    colorSpace: colorSpace,
                                    orientation: .up,
                                    contentSignature: plan.contentSignature)
    }
}
