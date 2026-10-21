//
//  GlassEffect.swift
//  Switchly
//
//  Shared glass parameters and legacy frosted surfaces (macOS 12+).
//  Native transparent content containers live in NativeCrystalContainer.swift.
//

import SwiftUI
import AppKit

// MARK: - GlassEffectModifier

/// A ViewModifier that applies Liquid Glass / Optical Crystal styling to individual views.
struct GlassEffectModifier: ViewModifier {
    let isActive: Bool
    let opacity: Double
    let cornerRadius: CGFloat
    let tintColor: Color?
    let interactive: Bool
    let fallbackColor: Color
    let material: CrystalMaterial

    init(
        isActive: Bool,
        opacity: Double = 0.22,
        cornerRadius: CGFloat = DesignTokens.Radius.control,
        tintColor: Color? = nil,
        interactive: Bool = false,
        fallbackColor: Color = Color(nsColor: .controlBackgroundColor),
        material: CrystalMaterial = .legacyDefault
    ) {
        self.isActive = isActive
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.interactive = interactive
        self.fallbackColor = fallbackColor
        self.material = material
    }

    func body(content: Content) -> some View {
        if isActive {
            // Controls reuse the panel's backdrop; no nested blur sampler.
            fallbackGlass(content)
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fallbackColor)
                )
        }
    }

    // MARK: - Crystal glass

    @ViewBuilder
    private func fallbackGlass(_ content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.crystalSurfaceBase.opacity(material.cardOpacity))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    overlayColor.opacity(opacity * material.panelTintCap * DesignTokens.Glass.maximumTintOpacity),
                                    overlayColor.opacity(opacity * material.panelTintCap * DesignTokens.Glass.maximumTintOpacity * 0.25)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .crystalSpecularRim(cornerRadius: cornerRadius, material: material)
    }

    private var overlayColor: Color {
        tintColor ?? material.tintColor
    }
}

// MARK: - View Extension

extension View {
    /// Applies Optical Crystal / Liquid Glass styling with automatic API selection.
    func liquidGlass(
        isActive: Bool = true,
        opacity: Double = 0.22,
        cornerRadius: CGFloat = DesignTokens.Radius.control,
        tintColor: Color? = nil,
        interactive: Bool = false,
        fallbackColor: Color = Color(nsColor: .controlBackgroundColor),
        material: CrystalMaterial = .legacyDefault
    ) -> some View {
        modifier(
            GlassEffectModifier(
                isActive: isActive,
                opacity: opacity,
                cornerRadius: cornerRadius,
                tintColor: tintColor,
                interactive: interactive,
                fallbackColor: fallbackColor,
                material: material
            )
        )
    }

    /// Translucent crystal surface for cards that sit inside a glass panel.
    ///
    /// Preserves the zero-extra-NSVisualEffectView performance guarantee:
    /// instead of a flat opaque controlBackgroundColor that blocks the panel's
    /// backdrop blur, it layers a top-to-bottom optical sheen gradient over the
    /// supplied translucent fill so the underlying desktop blur shines through
    /// like a cut crystal lens.
    ///
    /// Callers pass a *semantic* base
    /// (`Color(nsColor: .controlBackgroundColor).opacity(…)`), never a fixed
    /// light tint: the base follows the window appearance, so the resting card
    /// matches the desktop (dark surface on a dark desktop) and light/dark
    /// label text keeps its contrast. The crystal identity is the preset sheen
    /// plus the specular rim layered above it, not the base colour.
    func cardSurface(
        fill: Color,
        cornerRadius: CGFloat = DesignTokens.Radius.card,
        material: CrystalMaterial = .legacyDefault,
        isSelected: Bool = false
    ) -> some View {
        background(
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)

                // A neutral reflection, independent of the tint colour and strength.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.crystalSheenLuminance(material).opacity(material.glassStyle == .frosted && material.topSheenOpacity > 0 ? (isSelected ? material.topSheenOpacity + 0.08 : material.topSheenOpacity) : 0),
                                Color.crystalSheenLuminance(material).opacity(material.glassStyle == .frosted ? material.topSheenOpacity * 0.25 : 0),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
    }

    /// White optical reflection around the entire perimeter. Selection keeps
    /// its separate accent outline; a resting highlight never turns into dark ink.
    func crystalSpecularRim(
        cornerRadius: CGFloat = DesignTokens.Radius.card,
        material: CrystalMaterial = .legacyDefault,
        isHighlighted: Bool = false,
        lineWidth: CGFloat = DesignTokens.hairline
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: isHighlighted
                            ? [.white.opacity(0.88), Color.accentColor.opacity(0.75), .white.opacity(0.32)]
                            : GlassRim.opacities(strength: material.glassStyle == .frosted ? material.rimTopOpacity : 0)
                                .map { Color.white.opacity($0) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHighlighted ? 1.25 : lineWidth
                )
        )
    }

    /// Panel-level optical crystal background for floating NSPanel containers.
    func panelGlass(
        isActive: Bool,
        opacity: Double,
        cornerRadius: CGFloat,
        tintColor: Color? = nil,
        material: CrystalMaterial = .legacyDefault
    ) -> some View {
        modifier(
            PanelGlassModifier(
                isActive: isActive,
                opacity: opacity,
                cornerRadius: cornerRadius,
                tintColor: tintColor,
                material: material
            )
        )
    }
}

// MARK: - Appearance-aware crystal tokens

extension Color {
    /// Neutral optical highlight; never a graphite wash in light appearance.
    static var crystalSheenTop: Color { .white }

    /// Solid resting fill for crystal cards. Semantic on purpose — it tracks
    /// the window appearance so the desktop shows through the panel and the
    /// label text on top of the card keeps working.
    static var crystalSurfaceBase: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    /// Secondary text follows the same appearance as titles and controls.
    /// The wallpaper is not measured here, so do not infer contrast from a translucent fill.
    static func crystalSecondary(on surface: Color) -> Color {
        // Theme-relative ink; a translucent fill cannot reveal the wallpaper's luminance.
        Color(nsColor: .secondaryLabelColor)
    }

    /// Neutral reflection independent of the text theme and tint colour.
    static func crystalSheenLuminance(_ material: CrystalMaterial) -> Color { .white }

    /// Semantic resting base for the light labels and hairlines that sit
    /// directly on the crystal panel (not inside a card).
    static var crystalPanelHairline: Color {
        appearanceAware(dark: .white, light: crystalGraphite)
    }

    /// Ambient resting base for crystal chips and skeletons.
    static var crystalChipBase: Color {
        appearanceAware(dark: .white, light: crystalGraphite)
    }

    /// Graphite used wherever a dark window would have supplied white.
    static let crystalGraphite = Color(red: 0.10, green: 0.11, blue: 0.13)

    /// A colour that resolves against the **view's own** appearance.
    ///
    /// Reading `NSApplication.shared.effectiveAppearance` once at construction
    /// looked equivalent but is not: it answers for the app, not for the view
    /// rendering the pixels, and under a headless render it always answers
    /// "aqua" — which collapsed all three presets to the light branch and made
    /// them look identical. `NSColor(name:dynamicProvider:)` is handed the
    /// effective appearance of the view drawing it, so on-screen windows,
    /// per-window overrides and offscreen snapshots all agree.
    static func appearanceAware(dark: Color, light: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - Panel Corner Radius

/// Unified corner radius for all floating panels (preview, dock preview, workspace bar).
/// Uses 28pt continuous curvature inspired by visionOS spatial crystal panels.
enum GlassPanelCorner {
    static let radius: CGFloat = 28
}

// MARK: - PanelGlassModifier

/// A ViewModifier for floating NSPanel containers with optical crystal translucency.
struct PanelGlassModifier: ViewModifier {
    let isActive: Bool
    let opacity: Double
    let cornerRadius: CGFloat
    let tintColor: Color?
    var material: CrystalMaterial = .legacyDefault

    func body(content: Content) -> some View {
        if material.panelMaterial == .clear {
            content
        } else if material.glassStyle == .opaque || !isActive {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *), material.glassStyle != .opaque {
            NativeCrystalContainer(content: content, density: opacity,
                                   material: material, cornerRadius: cornerRadius)
        } else {
            content.background(panelBackground)
        }
    }

    private var panelBackground: some View {
        // 面板和材质示意共用叠层；示意图透出设置窗口背景，不代表独立 wash。
        PanelGlassSurface(
            isActive: isActive,
            opacity: opacity,
            cornerRadius: cornerRadius,
            material: material,
            tintColor: tintColor
        )
    }
}

// MARK: - PanelGlassSurface

/// 浮动面板的结构开关；普通窗口不继承面板的关闭模糊或无面板状态。
/// `drawsVibrancy: false` 仅用于已有背景的材质示意，不能代替独立窗口的模糊底层。
struct PanelGlassSurface<Backdrop: View>: View {
    /// `enableBackgroundBlur`. When false the panel is opaque, not glass.
    let isActive: Bool
    /// Raw `backgroundBlurOpacity` (the slider), not the mapped wash:
    /// `GlassWash` maps it for layer 1 and layer 2 scales with it directly.
    let opacity: Double
    let cornerRadius: CGFloat
    let material: CrystalMaterial
    var tintColor: Color?
    /// Draw layer 1. False when the surface already stands on live glass.
    var drawsVibrancy: Bool = true
    private let backdrop: Backdrop

    /// A vibrancy surface draws its own backdrop, so this overload leaves the
    /// call site without a closure — and without a type to infer for it.
    init(
        isActive: Bool,
        opacity: Double,
        cornerRadius: CGFloat,
        material: CrystalMaterial,
        tintColor: Color? = nil
    ) where Backdrop == EmptyView {
        self.init(
            isActive: isActive,
            opacity: opacity,
            cornerRadius: cornerRadius,
            material: material,
            tintColor: tintColor,
            drawsVibrancy: true,
            backdrop: { EmptyView() }
        )
    }

    init(
        isActive: Bool,
        opacity: Double,
        cornerRadius: CGFloat,
        material: CrystalMaterial,
        tintColor: Color? = nil,
        drawsVibrancy: Bool = true,
        @ViewBuilder backdrop: () -> Backdrop
    ) {
        self.isActive = isActive
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.material = material
        self.tintColor = tintColor
        self.drawsVibrancy = drawsVibrancy
        self.backdrop = backdrop()
    }

    var body: some View {
        ZStack {
            if !isActive {
                Color(nsColor: .windowBackgroundColor)
            } else if material.panelMaterial == .clear {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.015))
            } else {
                GlassSurface(
                    appearance: .panel(opacity: opacity, material: material, tintColor: tintColor),
                    cornerRadius: cornerRadius,
                    drawsVibrancy: drawsVibrancy
                ) {
                    backdrop
                }
            }
        }
    }
}

/// Standard-window roles share one parameter resolver.
enum WindowGlassStyle {
    case preferences
    case workspace
    case statistics
}

/// 解析后的绘制参数，不持久化，也不引入新的用户设置。
struct GlassAppearance {
    let washOpacity: Double
    let tintColor: Color
    let tintOpacity: Double
    let topSheenOpacity: Double
    let middleSheenOpacity: Double?
    let rimTopOpacity: Double?

    static func panel(opacity: Double, material: CrystalMaterial, tintColor: Color? = nil) -> GlassAppearance {
        resolved(opacity: opacity, material: material, tintColor: tintColor)
    }

    static func window(opacity: Double, material: CrystalMaterial, style: WindowGlassStyle) -> GlassAppearance {
        resolved(opacity: opacity, material: material)
    }

    private static func resolved(opacity: Double, material: CrystalMaterial, tintColor: Color? = nil) -> GlassAppearance {
        let density = GlassWash.opacity(for: opacity)
        let material = material.clamped()
        return GlassAppearance(
            washOpacity: density,
            tintColor: tintColor ?? material.tintColor,
            tintOpacity: material.panelTintCap * DesignTokens.Glass.maximumTintOpacity,
            topSheenOpacity: material.glassStyle == .frosted ? material.topSheenOpacity : 0,
            middleSheenOpacity: nil,
            rimTopOpacity: material.glassStyle == .frosted ? material.rimTopOpacity : 0
        )
    }

}

/// 每个普通窗口创建自己的背景模糊层，不采样另一个窗口的玻璃。
struct WindowGlassSurface: View {
    let opacity: Double
    let material: CrystalMaterial
    let style: WindowGlassStyle

    var body: some View {
        if material.glassStyle == .opaque {
            Color(nsColor: .windowBackgroundColor)
        } else {
            GlassSurface(
                appearance: .window(opacity: opacity, material: material, style: style),
                cornerRadius: 0,
                drawsVibrancy: true
            ) { EmptyView() }
        }
    }

}

/// 统一的背景模糊、染色、光泽和可选描边叠层。
private struct GlassSurface<Backdrop: View>: View {
    let appearance: GlassAppearance
    let cornerRadius: CGFloat
    let drawsVibrancy: Bool
    @ViewBuilder var backdrop: () -> Backdrop

    var body: some View {
        ZStack {
            if drawsVibrancy {
                GlassBackground(
                    material: .popover,
                    cornerRadius: cornerRadius,
                    washOpacity: appearance.washOpacity
                )
            } else {
                backdrop()
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(appearance.tintColor.opacity(appearance.tintOpacity))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: sheenColors, startPoint: .top, endPoint: .bottom))

            if let rim = appearance.rimTopOpacity {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: GlassRim.opacities(strength: rim).map { Color.white.opacity($0) },
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: DesignTokens.hairline
                    )
            }
        }
    }

    private var sheenColors: [Color] {
        var colors = [Color.crystalSheenTop.opacity(appearance.topSheenOpacity)]
        if let middle = appearance.middleSheenOpacity {
            colors.append(Color.crystalPanelHairline.opacity(middle))
        }
        colors.append(.clear)
        return colors
    }
}

// MARK: - GlassBackground (NSVisualEffectView)

struct GlassBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let cornerRadius: CGFloat
    /// Backdrop alpha only. Density does not fade text or change tint/highlights.
    var washOpacity: Double = 1

    init(material: NSVisualEffectView.Material = .popover, cornerRadius: CGFloat = 0, washOpacity: Double = 1) {
        self.material = material
        self.cornerRadius = cornerRadius
        self.washOpacity = washOpacity
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.appearance = nil // Retired baseTone is decoded only; theme owns all surfaces.
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.alphaValue = washOpacity
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.appearance = nil // Retired baseTone is decoded only; theme owns all surfaces.
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.alphaValue = washOpacity
    }
}

// MARK: - GlassWash

/// Density maps directly to the legacy backdrop alpha, without a hidden floor.
enum GlassWash {
    static func opacity(for slider: Double) -> Double {
        let clamped = min(max(slider, 0), 1)
        return clamped
    }
}

/// Nonzero around all four edges, with a brighter upper lip. Zero removes
/// only our added reflection, never the operating system's own glass rim.
enum GlassRim {
    static func opacities(strength: Double) -> [Double] {
        let strength = min(max(strength, 0), 1)
        return [strength, strength * 0.55, strength * 0.45, strength * 0.7]
    }
}
