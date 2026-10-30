//
//  PluginOverlayView.swift
//  Switchly
//
//  Draws a validated PluginUINode tree with native controls. Plugins never
//  supply colors or point sizes: every metric comes from DesignTokens and
//  every surface from GlassEffect, so overlays follow theme, glass settings
//  and Reduce Motion like the rest of the panel. Hover / press / focus are
//  drawn locally without a JS round trip.
//

import AppKit
import SwiftUI

struct PluginOverlayView: View {
    let node: PluginUINode
    let material: CrystalMaterial
    let isGlassActive: Bool
    /// Host-fetched cover for `image(source: {artwork})`.
    var artwork: NSImage? = nil
    /// Where `scene` sprite assets live (the owning plugin's directory).
    var assetDirectory: URL? = nil
    let onAction: (String, Double?) -> Void

    var body: some View {
        render(node)
    }

    private func render(_ node: PluginUINode) -> AnyView {
        switch node {
        case .hstack(let children, let spacing, let align):
            return AnyView(HStack(alignment: verticalAlignment(align), spacing: points(spacing)) {
                ForEach(Array(children.enumerated()), id: \.offset) { render($0.element) }
            })
        case .vstack(let children, let spacing, let align):
            return AnyView(VStack(alignment: horizontalAlignment(align), spacing: points(spacing)) {
                ForEach(Array(children.enumerated()), id: \.offset) { render($0.element) }
            })
        case .zstack(let children):
            // Cover scenes are backdrops: behind the rest, never sizing it.
            let backdrops = children.filter { if case .scene(let s) = $0, s.fit == .cover { return true } else { return false } }
            let content = children.filter { child in !backdrops.contains(child) }
            return AnyView(ZStack {
                ForEach(Array(content.enumerated()), id: \.offset) { render($0.element) }
            }
            .background(ZStack {
                ForEach(Array(backdrops.enumerated()), id: \.offset) { render($0.element) }
            }))
        case .scene(let scene):
            return AnyView(PluginSceneView(scene: scene, assetDirectory: assetDirectory) { onAction($0, $1) })
        case .spacer:
            return AnyView(Spacer(minLength: 0))
        case .surface(let children, let surfaceMaterial):
            let content = VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(children.enumerated()), id: \.offset) { render($0.element) }
            }
            .padding(DesignTokens.Spacing.xs)
            return AnyView(content.liquidGlass(
                isActive: surfaceMaterial == .glass && isGlassActive,
                opacity: 0.55,
                cornerRadius: DesignTokens.Radius.control,
                material: material
            ))
        case .screen(let children):
            let radius = DesignTokens.Radius.control
            return AnyView(VStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(children.enumerated()), id: \.offset) { render($0.element) }
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.primary.opacity(0.4), lineWidth: DesignTokens.Plugin.screenBorder)))
        case .wheel(let children):
            return AnyView(PluginWheel(items: children.map { render($0) }))
        case .button(let id, let symbol, let label, let size, let variant, let enabled, let selected):
            return AnyView(PluginSymbolButton(symbol: symbol, label: label, size: size,
                                              prominent: variant == .prominent, selected: selected) {
                onAction(id, nil)
            }
            .disabled(!enabled))
        case .toggle(let id, let symbolOn, let symbolOff, let isOn, let label):
            return AnyView(PluginToggleButton(isOn: isOn, symbolOn: symbolOn, symbolOff: symbolOff, label: label) {
                onAction(id, $0 ? 1 : 0)
            })
        case .slider(let id, let value, let label, let step):
            return AnyView(PluginSlider(value: value, step: step, label: label) { onAction(id, $0) })
        case .text(let value, let style, let lines):
            return AnyView(Text(value)
                .font(font(style))
                .foregroundColor(style == .caption ? .secondary : .primary)
                .lineLimit(lines ?? 1)
                .truncationMode(.tail))
        case .marquee(let value):
            return AnyView(PluginMarquee(value: value))
        case .progress(let value, let style, _):
            if style == .circular {
                return AnyView(ProgressView(value: value).progressViewStyle(.circular).controlSize(.small))
            }
            return AnyView(ProgressView(value: value).progressViewStyle(.linear).controlSize(.small)
                .accessibilityValue(Text("\(Int(value * 100))%")))
        case .image(let source, let size, let corner):
            return AnyView(PluginImage(source: source, size: size, corner: corner, artwork: artwork))
        case .badge(let value, let tone):
            return AnyView(Text(value)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, DesignTokens.Spacing.xs)
                .padding(.vertical, 1)
                .foregroundColor(tone == .neutral ? .primary : .white)
                .background(Capsule().fill(badgeFill(tone))))
        }
    }

    private func points(_ spacing: PluginSpacing?) -> CGFloat {
        switch spacing ?? .s {
        case .xs: return DesignTokens.Spacing.xs
        case .s: return DesignTokens.Spacing.sm
        case .m: return DesignTokens.Spacing.md
        }
    }

    private func verticalAlignment(_ align: PluginAlignment?) -> VerticalAlignment {
        switch align {
        case .leading: return .top
        case .trailing: return .bottom
        default: return .center
        }
    }

    private func horizontalAlignment(_ align: PluginAlignment?) -> HorizontalAlignment {
        switch align {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func font(_ style: PluginTextStyle) -> Font {
        switch style {
        case .title: return .headline
        case .body: return .caption.weight(.medium)
        case .caption: return .caption2
        }
    }

    private func badgeFill(_ tone: PluginBadgeTone) -> Color {
        switch tone {
        case .neutral: return Color(nsColor: .quaternaryLabelColor)
        case .accent: return .accentColor
        case .warning: return Color(nsColor: .systemOrange)
        }
    }
}

// MARK: - Controls

enum PluginMetrics {
    static func control(_ size: PluginControlSize) -> CGFloat {
        switch size {
        case .s: return DesignTokens.Plugin.controlSmall
        case .m: return DesignTokens.Plugin.controlMedium
        case .l: return DesignTokens.Plugin.controlLarge
        }
    }

    static func image(_ size: PluginControlSize) -> CGFloat {
        switch size {
        case .s: return DesignTokens.Plugin.imageSmall
        case .m: return DesignTokens.Plugin.imageMedium
        case .l: return DesignTokens.Plugin.imageLarge
        }
    }
}

private struct PluginSymbolButton: View {
    let symbol: String
    let label: String
    let size: PluginControlSize
    let prominent: Bool
    let selected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let side = PluginMetrics.control(size)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: side * 0.45, weight: .semibold))
                .foregroundColor(prominent ? .white : (selected ? .accentColor : .primary))
                .frame(width: side, height: side)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(PluginPressStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: isHovered)
    }

    private var fill: Color {
        if prominent { return Color.accentColor.opacity(isHovered ? 1 : 0.9) }
        return Color.primary.opacity(isHovered ? 0.16 : 0.0001)
    }
}

/// Flips immediately (optimistic), then reports the new state; the next
/// render reconciles it with the plugin's real value.
private struct PluginToggleButton: View {
    let isOn: Bool
    let symbolOn: String
    let symbolOff: String
    let label: String
    let onChange: (Bool) -> Void

    @State private var optimistic: Bool?

    var body: some View {
        let shown = optimistic ?? isOn
        PluginSymbolButton(symbol: shown ? symbolOn : symbolOff, label: label, size: .s,
                           prominent: false, selected: shown) {
            optimistic = !shown
            onChange(!shown)
        }
        .accessibilityAddTraits(shown ? .isSelected : [])
        .onChange(of: isOn) { _ in optimistic = nil }
    }
}

/// Reports only when dragging ends (design doc §3.5.2).
private struct PluginSlider: View {
    let value: Double
    let step: Double?
    let label: String
    let onCommit: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        Slider(value: Binding(get: { dragValue ?? value }, set: { dragValue = $0 }), in: 0...1) { editing in
            guard !editing, let committed = dragValue else { return }
            let snapped = step.map { (committed / $0).rounded() * $0 } ?? committed
            onCommit(min(max(snapped, 0), 1))
            dragValue = nil
        }
        .controlSize(.mini)
        .accessibilityLabel(Text(label))
    }
}

private struct PluginImage: View {
    let source: PluginImageSource
    let size: PluginControlSize
    let corner: PluginCorner?
    let artwork: NSImage?

    var body: some View {
        let side = PluginMetrics.image(size)
        let radius = corner == .m ? DesignTokens.Radius.thumbnail : DesignTokens.Radius.chip
        Group {
            switch source {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: side * 0.6))
            case .artwork where artwork != nil:
                Image(nsImage: artwork!)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
            case .artwork, .pluginAsset:
                // No cover (or bundled assets, not wired yet): a neutral
                // placeholder keeps the layout stable.
                Image(systemName: "music.note").font(.system(size: side * 0.45, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: side, height: side)
                    .background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.08)))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Scrolls text that overflows its width in a seamless loop, resting at the
/// start of every pass. Fits or Reduce Motion: plain tail truncation.
private struct PluginMarquee: View {
    let value: String

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let gap = DesignTokens.Spacing.xl
    private var font: Font { .callout.weight(.semibold) }
    private var scrolls: Bool { textWidth > boxWidth + 1 && !MotionTokens.reduceMotion }

    var body: some View {
        // The hidden line fixes height and reports the box width.
        Text(value).font(font).lineLimit(1).opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in Color.clear.onAppear { boxWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { boxWidth = $0 } })
            .overlay(alignment: .leading) {
                if scrolls {
                    HStack(spacing: gap) {
                        Text(value).font(font).fixedSize()
                        Text(value).font(font).fixedSize()
                    }
                    .offset(x: offset)
                    .id(value)
                    .onAppear(perform: run)
                } else {
                    Text(value).font(font).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .clipped()
            .background(Text(value).font(font).fixedSize().hidden()
                .background(GeometryReader { proxy in Color.clear.onAppear { textWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { textWidth = $0 } }))
            .help(value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(value))
    }

    private func run() {
        offset = 0
        let distance = textWidth + gap
        withAnimation(.linear(duration: Double(distance / MotionTokens.marqueeSpeed))
            .delay(MotionTokens.marqueePause)
            .repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}

private struct PluginPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(MotionTokens.animated(MotionTokens.microSpring), value: configuration.isPressed)
    }
}

/// Circular dial: items sit at the four compass points of the ring, the fifth
/// in the centre disc.
private struct PluginWheel: View {
    let items: [AnyView]

    var body: some View {
        let d = DesignTokens.Plugin.wheelDiameter
        let c = DesignTokens.Plugin.wheelCenter
        let reach = (d + c) / 4
        ZStack {
            Circle().fill(Color.primary.opacity(0.07))
            Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: DesignTokens.hairline)
            Circle().fill(Color.primary.opacity(0.08)).frame(width: c, height: c)
            items[0].offset(y: -reach)
            items[1].offset(x: -reach)
            items[2].offset(x: reach)
            items[3].offset(y: reach)
            items[4]
        }
        .frame(width: d, height: d)
    }
}
