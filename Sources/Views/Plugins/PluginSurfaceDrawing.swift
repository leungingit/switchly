//
//  PluginSurfaceDrawing.swift
//  Switchly
//
//  Core Graphics drawing for restricted dynamic surfaces. The drawing language
//  mirrors `PluginOverlayView` semantics: the same fonts, the same secondary
//  caption color, the same image sizes/corner radii, the same stack spacing and
//  the same badge capsule. Progress is drawn by hand because SwiftUI's
//  `ImageRenderer` and system `ProgressView` do not agree pixel-for-pixel.
//  Content outside the §9.4 allowlist is rejected by the renderer before it
//  reaches this type, so forbidden cases draw nothing.
//
//  Coordinates inside this type are top-left points. The rasterizer installs
//  that transform once; text and images add a local vertical flip because
//  Core Text and CGImage drawing expect a bottom-left user space.
//

import AppKit
import CoreGraphics
import CoreText

struct PluginSurfaceDrawing {
    private let context: CGContext
    private let plan: PluginSurfaceRasterPlan
    private let artwork: CGImage?
    private let assets: SceneAssets

    private var palette: PluginSurfacePalette { plan.request.palette }
    private var pointSize: CGSize { plan.pointSize }

    private let linearProgressHeight: CGFloat = 4
    private let circularProgressLine: CGFloat = 2

    init(context: CGContext,
         plan: PluginSurfaceRasterPlan,
         artwork: CGImage?,
         assets: SceneAssets) {
        self.context = context
        self.plan = plan
        self.artwork = artwork
        self.assets = assets
    }

    func draw() {
        context.saveGState()
        // The bitmap has a top-left origin; convert points (x right, y down)
        // into the bitmap's pixel space.
        context.translateBy(x: 0, y: plan.pixelSize.height)
        context.scaleBy(x: plan.pixelsPerPoint, y: -plan.pixelsPerPoint)
        context.clip(to: CGRect(origin: .zero, size: pointSize))
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        let rootSize = measure(plan.request.content, maxWidth: pointSize.width)
        let rect = CGRect(x: (pointSize.width - rootSize.width) / 2,
                          y: (pointSize.height - rootSize.height) / 2,
                          width: rootSize.width,
                          height: rootSize.height)
        draw(plan.request.content, in: rect)
        context.restoreGState()
    }

    // MARK: - Measurement

    private func measure(_ node: PluginUINode, maxWidth: CGFloat) -> CGSize {
        let width = max(0, maxWidth)
        switch node {
        case .hstack(let children, let spacing, _):
            let layout = hstackLayout(children, spacing: spacing, maxWidth: width)
            return CGSize(width: min(width, layout.width), height: layout.height)
        case .vstack(let children, let spacing, _):
            return vstackSize(children, spacing: spacing, maxWidth: width)
        case .zstack(let children):
            let sizes = children.map { measure($0, maxWidth: width) }
            return CGSize(width: sizes.map(\.width).max() ?? 0,
                          height: sizes.map(\.height).max() ?? 0)
        case .spacer:
            return .zero
        case .text(let value, let style, let lines):
            return textSize(value, attributes: textAttributes(style, lines: lines), maxWidth: width)
        case .progress(_, let style, _):
            return style == .linear
                ? CGSize(width: width, height: linearProgressHeight)
                : CGSize(width: DesignTokens.Plugin.controlSmall, height: DesignTokens.Plugin.controlSmall)
        case .image(_, let size, _):
            let side = PluginMetrics.image(size)
            return CGSize(width: side, height: side)
        case .marquee(let value):
            return textSize(value, attributes: marqueeAttributes, maxWidth: width)
        case .badge(let value, let tone):
            return badgeSize(value, tone: tone, maxWidth: width)
        case .surface, .button, .toggle, .slider, .wheel, .screen, .scene, .scene3d:
            // Forbidden by §9.4; the renderer rejects the whole request before
            // drawing, so these branches only keep the switch exhaustive.
            return .zero
        }
    }

    private func vstackSize(_ children: [PluginUINode], spacing: PluginSpacing?, maxWidth: CGFloat) -> CGSize {
        let sizes = children.map { measure($0, maxWidth: maxWidth) }
        let gap = points(spacing ?? .s)
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.reduce(0) { $0 + $1.height }
            + gap * CGFloat(max(0, children.count - 1))
        return CGSize(width: min(maxWidth, width), height: height)
    }

    private struct HStackLayout {
        let widths: [CGFloat]
        let height: CGFloat
        let gap: CGFloat
        let width: CGFloat
    }

    private func hstackLayout(_ children: [PluginUINode],
                              spacing: PluginSpacing?,
                              maxWidth: CGFloat) -> HStackLayout {
        let gap = points(spacing ?? .s)
        let count = children.count
        guard count > 0 else { return HStackLayout(widths: [], height: 0, gap: gap, width: 0) }

        let available = max(0, maxWidth - gap * CGFloat(count - 1))
        var widths = [CGFloat](repeating: 0, count: count)
        var flexible: [Int] = []
        for (index, child) in children.enumerated() {
            if expandsHorizontally(child) {
                flexible.append(index)
            } else {
                widths[index] = measure(child, maxWidth: available).width
            }
        }

        let fixed = widths.reduce(0, +)
        let share = flexible.isEmpty ? 0 : max(0, available - fixed) / CGFloat(flexible.count)
        for index in flexible { widths[index] = share }

        let total = min(available, widths.reduce(0, +))
        let height = children.enumerated().map { index, child in
            measure(child, maxWidth: widths[index]).height
        }.max() ?? 0
        return HStackLayout(widths: widths, height: height, gap: gap, width: total)
    }

    private func expandsHorizontally(_ node: PluginUINode) -> Bool {
        switch node {
        case .spacer, .marquee:
            return true
        case .progress(_, .linear, _):
            return true
        case .vstack(let children, _, _), .zstack(let children):
            return children.contains(where: expandsHorizontally)
        case .hstack:
            return false
        case .badge, .text, .progress, .image,
             .surface, .screen, .button, .toggle, .slider, .wheel, .scene, .scene3d:
            return false
        }
    }

    private func points(_ spacing: PluginSpacing) -> CGFloat {
        switch spacing {
        case .xs: return DesignTokens.Spacing.xs
        case .s: return DesignTokens.Spacing.sm
        case .m: return DesignTokens.Spacing.md
        }
    }

    // MARK: - Drawing

    private func draw(_ node: PluginUINode, in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        switch node {
        case .hstack(let children, let spacing, let align):
            drawHStack(children, spacing: spacing, align: align, in: rect)
        case .vstack(let children, let spacing, let align):
            drawVStack(children, spacing: spacing, align: align, in: rect)
        case .zstack(let children):
            drawZStack(children, in: rect)
        case .spacer:
            break
        case .text(let value, let style, let lines):
            drawText(value, attributes: textAttributes(style, lines: lines),
                     in: rect, alignment: .left)
        case .marquee(let value):
            drawText(value, attributes: marqueeAttributes, in: rect, alignment: .left)
        case .progress(let value, let style, _):
            drawProgress(value, style: style, in: rect)
        case .image(let source, let size, let corner):
            drawImage(source, size: size, corner: corner, in: rect)
        case .badge(let value, let tone):
            drawBadge(value, tone: tone, in: rect)
        case .surface, .button, .toggle, .slider, .wheel, .screen, .scene, .scene3d:
            // Forbidden by §9.4. The renderer rejects the whole request before
            // drawing; these branches only keep the switch exhaustive.
            break
        }
    }

    private func drawHStack(_ children: [PluginUINode],
                            spacing: PluginSpacing?,
                            align: PluginAlignment?,
                            in rect: CGRect) {
        let layout = hstackLayout(children, spacing: spacing, maxWidth: rect.width)
        var x = rect.minX
        for (index, child) in children.enumerated() {
            let width = layout.widths[index]
            let height = measure(child, maxWidth: width).height
            let y: CGFloat
            switch align {
            case .leading: y = rect.minY
            case .trailing: y = rect.maxY - height
            default: y = rect.midY - height / 2
            }
            draw(child, in: CGRect(x: x, y: y, width: width, height: height))
            x += width + layout.gap
        }
    }

    private func drawVStack(_ children: [PluginUINode],
                            spacing: PluginSpacing?,
                            align: PluginAlignment?,
                            in rect: CGRect) {
        let gap = points(spacing ?? .s)
        let sizes = children.map { measure($0, maxWidth: rect.width) }
        let contentHeight = sizes.reduce(0) { $0 + $1.height }
            + gap * CGFloat(max(0, children.count - 1))
        let spacers = children.filter { if case .spacer = $0 { return true } else { return false } }.count
        let extra = spacers > 0 ? max(0, rect.height - contentHeight) : 0
        let spacerHeight = spacers > 0 ? extra / CGFloat(spacers) : 0

        var y = rect.minY
        for (index, child) in children.enumerated() {
            let size = sizes[index]
            let height = size.height + (isSpacer(child) ? spacerHeight : 0)
            let x: CGFloat
            switch align {
            case .center: x = rect.midX - size.width / 2
            case .trailing: x = rect.maxX - size.width
            default: x = rect.minX
            }
            draw(child, in: CGRect(x: x, y: y, width: size.width, height: height))
            y += height + gap
        }
    }

    private func isSpacer(_ node: PluginUINode) -> Bool {
        if case .spacer = node { return true }
        return false
    }

    private func drawZStack(_ children: [PluginUINode], in rect: CGRect) {
        for child in children {
            let size = measure(child, maxWidth: rect.width)
            draw(child, in: CGRect(x: rect.midX - size.width / 2,
                                   y: rect.midY - size.height / 2,
                                   width: size.width,
                                   height: size.height))
        }
    }

    // MARK: - Text

    private struct TextAttributes {
        let font: NSFont
        let color: PluginSurfaceColor
        let maxLines: Int
    }

    private func textAttributes(_ style: PluginTextStyle, lines: Int?) -> TextAttributes {
        let font: NSFont
        let color: PluginSurfaceColor
        switch style {
        case .title:
            font = NSFont.preferredFont(forTextStyle: .headline)
            color = palette.text
        case .body:
            let caption = NSFont.preferredFont(forTextStyle: .caption1)
            font = NSFont.systemFont(ofSize: caption.pointSize, weight: .medium)
            color = palette.text
        case .caption:
            font = NSFont.preferredFont(forTextStyle: .caption2)
            color = palette.secondaryText
        }
        return TextAttributes(font: font, color: color, maxLines: min(max(lines ?? 1, 1), 3))
    }

    private var marqueeAttributes: TextAttributes {
        let callout = NSFont.preferredFont(forTextStyle: .callout)
        let font = NSFont.systemFont(ofSize: callout.pointSize, weight: .semibold)
        return TextAttributes(font: font, color: palette.text, maxLines: 1)
    }

    private func lineHeight(_ attributes: TextAttributes) -> CGFloat {
        max(1, ceil(attributes.font.ascender - attributes.font.descender + attributes.font.leading))
    }

    private func attributed(_ value: String,
                            attributes: TextAttributes,
                            alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        paragraph.lineSpacing = 0
        return NSAttributedString(string: value, attributes: [
            .font: attributes.font,
            .foregroundColor: attributes.color.nsColor,
            .paragraphStyle: paragraph
        ])
    }

    private func textSize(_ value: String,
                          attributes: TextAttributes,
                          maxWidth: CGFloat) -> CGSize {
        guard !value.isEmpty else { return CGSize(width: 0, height: lineHeight(attributes)) }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(value, attributes: attributes))
        // Core Text can need more vertical room than `ascender - descender +
        // leading` implies (the 10 pt medium system font needs 13 points while
        // its font metrics add up to 11.78). Measure the real one-line height
        // with Core Text so the layout frame and the drawn frame agree; a frame
        // one point short silently produces a frame with no lines at all.
        let singleLine = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            nil)
        let line = max(1, ceil(singleLine.height))
        let constraint = CGSize(width: max(1, maxWidth),
                                height: line * CGFloat(attributes.maxLines))
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, constraint, &fitRange)
        return CGSize(width: min(max(0, maxWidth), ceil(suggested.width)),
                      height: min(line * CGFloat(attributes.maxLines),
                                  max(line, ceil(suggested.height))))
    }

    private func drawText(_ value: String,
                          attributes: TextAttributes,
                          in rect: CGRect,
                          alignment: NSTextAlignment) {
        guard rect.width > 0, rect.height > 0, !value.isEmpty else { return }
        let attributedString = attributed(value, attributes: attributes, alignment: alignment)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        context.saveGState()
        context.textMatrix = .identity
        // Local bottom-left space for Core Text.
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    // MARK: - Badge

    /// Mirrors the overlay's badge: `caption2.weight(.semibold)`, horizontal
    /// `xs` padding, vertical 1 point, capsule background. Neutral uses the
    /// primary label on a quaternary fill; accent and warning use white text.
    private func badgeAttributes(_ tone: PluginBadgeTone) -> TextAttributes {
        let caption = NSFont.preferredFont(forTextStyle: .caption2)
        let font = NSFont.systemFont(ofSize: caption.pointSize, weight: .semibold)
        let color = tone == .neutral ? palette.text : palette.badgeText
        return TextAttributes(font: font, color: color, maxLines: 1)
    }

    private func badgeSize(_ value: String, tone: PluginBadgeTone, maxWidth: CGFloat) -> CGSize {
        let horizontal = DesignTokens.Spacing.xs * 2
        let innerWidth = max(0, maxWidth - horizontal)
        let text = textSize(value, attributes: badgeAttributes(tone), maxWidth: innerWidth)
        return CGSize(width: min(maxWidth, text.width + horizontal),
                      height: text.height + 2)
    }

    private func drawBadge(_ value: String, tone: PluginBadgeTone, in rect: CGRect) {
        fillRounded(rect, radius: rect.height / 2, color: badgeFill(tone))
        let inner = rect.insetBy(dx: DesignTokens.Spacing.xs, dy: 1)
        guard inner.width > 0, inner.height > 0 else { return }
        drawText(value, attributes: badgeAttributes(tone), in: inner, alignment: .left)
    }

    private func badgeFill(_ tone: PluginBadgeTone) -> PluginSurfaceColor {
        switch tone {
        case .neutral: return palette.badgeNeutralFill
        case .accent: return palette.badgeAccentFill
        case .warning: return palette.badgeWarningFill
        }
    }

    // MARK: - Images

    private func drawImage(_ source: PluginImageSource,
                           size: PluginControlSize,
                           corner: PluginCorner?,
                           in rect: CGRect) {
        let side = PluginMetrics.image(size)
        let radius = corner == .m ? DesignTokens.Radius.thumbnail : DesignTokens.Radius.chip
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        switch source {
        case .symbol(let name):
            drawSymbol(name, pointSize: side * 0.6, weight: .regular,
                       color: palette.text, in: box)
        case .artwork:
            if let artwork {
                drawFilledImage(artwork, in: box, radius: radius)
            } else {
                drawPlaceholder(in: box, radius: radius)
            }
        case .pluginAsset(let name):
            if let image = assets.image(name) {
                drawFilledImage(image, in: box, radius: radius)
            } else {
                drawPlaceholder(in: box, radius: radius)
            }
        }
    }

    private func drawPlaceholder(in rect: CGRect, radius: CGFloat) {
        fillRounded(rect, radius: radius, color: palette.placeholderFill)
        drawSymbol("music.note", pointSize: rect.width * 0.45, weight: .semibold,
                   color: palette.secondaryText, in: rect)
    }

    private func drawFilledImage(_ image: CGImage, in rect: CGRect, radius: CGFloat) {
        guard image.width > 0, image.height > 0 else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
        context.clip()
        // Aspect fill: crop the source around its centre, then draw to the box.
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let sourceSize = CGSize(width: rect.width / scale, height: rect.height / scale)
        let source = CGRect(x: (CGFloat(image.width) - sourceSize.width) / 2,
                            y: (CGFloat(image.height) - sourceSize.height) / 2,
                            width: sourceSize.width, height: sourceSize.height)
        let cropped = image.cropping(to: source.integral) ?? image
        drawUpright(cropped, in: rect)
        context.restoreGState()
    }

    /// Draws a CGImage upright in the top-left surface coordinate system.
    private func drawUpright(_ image: CGImage, in rect: CGRect) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private func drawSymbol(_ name: String,
                            pointSize: CGFloat,
                            weight: NSFont.Weight,
                            color: PluginSurfaceColor,
                            in rect: CGRect) {
        guard pointSize > 0,
              let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.nsColor]))
        let symbol = base.withSymbolConfiguration(configuration) ?? base
        var proposed = CGRect(origin: .zero, size: symbol.size)
        guard let image = symbol.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              image.width > 0, image.height > 0 else { return }

        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = CGRect(x: rect.midX - drawSize.width / 2,
                            y: rect.midY - drawSize.height / 2,
                            width: drawSize.width, height: drawSize.height)
        drawUpright(image, in: target)
    }

    // MARK: - Progress

    private func drawProgress(_ value: Double, style: PluginProgressStyle, in rect: CGRect) {
        let progress = CGFloat(min(max(value, 0), 1))
        switch style {
        case .linear:
            let height = min(linearProgressHeight, rect.height)
            let bar = CGRect(x: rect.minX, y: rect.midY - height / 2,
                             width: rect.width, height: height)
            let radius = height / 2
            fillRounded(bar, radius: radius, color: palette.progressTrack)
            guard progress > 0 else { return }
            let fill = CGRect(x: bar.minX, y: bar.minY,
                              width: max(radius * 2, bar.width * progress), height: bar.height)
            fillRounded(fill, radius: radius, color: palette.progressFill)
        case .circular:
            let side = min(rect.width, rect.height, DesignTokens.Plugin.controlSmall)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = max(0, (side - circularProgressLine) / 2)
            guard radius > 0 else { return }
            context.setStrokeColor(palette.progressTrack.cgColor)
            context.setLineWidth(circularProgressLine)
            context.addArc(center: center, radius: radius,
                           startAngle: 0, endAngle: .pi * 2, clockwise: false)
            context.strokePath()
            guard progress > 0 else { return }
            context.setStrokeColor(palette.progressFill.cgColor)
            context.setLineWidth(circularProgressLine)
            // In the vertically flipped surface space increasing angles run
            // clockwise on screen; start at the top.
            context.addArc(center: center, radius: radius,
                           startAngle: -.pi / 2,
                           endAngle: -.pi / 2 + .pi * 2 * progress,
                           clockwise: false)
            context.strokePath()
        }
    }

    // MARK: - Shapes

    private func fillRounded(_ rect: CGRect, radius: CGFloat, color: PluginSurfaceColor) {
        guard rect.width > 0, rect.height > 0, color.alpha > 0 else { return }
        let r = min(radius, min(rect.width, rect.height) / 2)
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        context.fillPath()
    }

}
