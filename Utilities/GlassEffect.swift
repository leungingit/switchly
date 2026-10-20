//
//  GlassEffect.swift
//  Switchly
//
//  Unified Optical Crystal glass wrapper: visionOS-inspired top-to-bottom
//  luminance gradient, 135° specular bevel rim, and one implementation for
//  every supported macOS release (12+).
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
            // Crystal glass (tint + optical gradient + specular rim) is the one
            // implementation on every supported release. There is deliberately
            // no `.glassEffect()` branch: that API is absent from the macOS 26/27
            // SwiftUI interface this project builds against, so the old branch
            // was compiled only as unexecutable code and could never be vetted.
            // If a future SDK ships it, add a branch here and re-run
            // work/qa before claiming native Liquid Glass support.
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
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    overlayColor.opacity(max(opacity * 0.65, material.topSheenOpacity)),
                                    overlayColor.opacity(opacity * 0.18)
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

                // Top-to-bottom optical crystal luminance gradient (visionOS reference I01).
                // The sheen is the preset's own hue: a single global white
                // luminance at 18–24 % is ~9:1 heavier than the preset tint, so
                // it used to flatten every preset into the same grey card. Here
                // the tint sits on top of a much lighter luminance base, which
                // is what makes "ice is blue, quartz is amber" actually read.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.crystalSheenLuminance(material).opacity(material.topSheenOpacity > 0 ? (isSelected ? material.topSheenOpacity + 0.08 : material.topSheenOpacity) : 0),
                                Color.crystalSheenLuminance(material).opacity(material.topSheenOpacity > 0 ? 0.06 : 0),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
    }

    /// 135° diagonal specular bevel rim highlight (0.5pt–0.75pt) that gives
    /// panels, pills, and cards a crisp cut-crystal edge.
    ///
    /// The rim reads as light catching a bevel, so it is drawn in the ambient
    /// label polarity (`crystalRimBase`): white on a dark window, a deep
    /// graphite trace on a light one, where a 0.57-alpha white stroke would be
    /// invisible against the light panel behind it.
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
                            ? [
                                Color.crystalRimBase.opacity(0.88),
                                Color.accentColor.opacity(0.75),
                                Color.crystalRimBase.opacity(0.32)
                            ]
                            : [
                                Color.crystalRimBase.opacity(material.rimTopOpacity),
                                Color.crystalRimBase.opacity(0.18),
                                Color.crystalRimBase.opacity(0.06),
                                Color.crystalRimBase.opacity(0.22)
                            ],
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
    /// Base colour of the top-to-bottom crystal sheen.
    ///
    /// The sheen is *light*: on a dark window it is the cool tint itself, but
    /// the same tint drawn at 0.18–0.24 alpha over a light background paints a
    /// near-white wash that swallows dark label text. In light mode the sheen
    /// therefore takes the label polarity (graphite), which produces the same
    /// "material catches the light near its top edge" reading without erasing
    /// contrast.
    ///
    /// Resolved against the drawing view's own appearance (see
    /// `appearanceAware`), not `NSApp.effectiveAppearance` — the app-level
    /// answer is wrong for per-window theme overrides and for offscreen renders.
    static var crystalSheenTop: Color {
        appearanceAware(dark: .white, light: crystalGraphite)
    }

    /// Ambient (un-tinted) base for specular rims: white on dark, graphite on light.
    static var crystalRimBase: Color {
        appearanceAware(dark: .white, light: crystalGraphite)
    }

    /// Solid resting fill for crystal cards. Semantic on purpose — it tracks
    /// the window appearance so the desktop shows through the panel and the
    /// label text on top of the card keeps working.
    static var crystalSurfaceBase: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    /// Secondary text (metadata, title-row details) drawn on crystal.
    ///
    /// `Color.secondary` resolves to `secondaryLabelColor`, which only knows the
    /// *window's* appearance. The crystal panel is the one surface in the app
    /// whose luminance the wallpaper can drag the other way, so on a dark
    /// desktop a light wash lifted the card to L≈0.09 and semantic secondary
    /// text fell to ~2.6:1 (work/qa/report.md §4). This token measures the
    /// surface it is drawn on and takes 80 % of the ink polarity that surface
    /// needs — the same construction as `secondaryLabelColor`, but relative to
    /// the pixel behind it. Measured worst case over the fill/sheen band:
    /// 4.64:1 (no panel), 5.82:1 (low tint), 6.26:1 (full tint).
    static func crystalSecondary(on surface: Color) -> Color {
        // A 6–28 % fill over glass approaches the window colour, so flattening
        // the fill against it is the right proxy for the card's luminance.
        let flattened = crystalSurfaceBase.opaqueOver(surface)
        return Color(nsColor: NSColor(name: nil) { appearance in
            // Resolve under a dark appearance so a dynamic base
            // (controlBackgroundColor & co.) yields the dark-end colour a
            // crystal card actually shows, whatever the calling context.
            let reference = NSAppearance(named: .darkAqua) ?? appearance
            let resolved = NSColor(surface).withAlphaComponent(1)
            var luminance = 0.5
            reference.performAsCurrentDrawingAppearance {
                guard let rgb = resolved.usingColorSpace(.sRGB) else { return }
                luminance = 0.2126 * Self.linear(rgb.redComponent)
                    + 0.7152 * Self.linear(rgb.greenComponent)
                    + 0.0722 * Self.linear(rgb.blueComponent)
            }
            let ink: CGFloat = luminance > 0.5 ? 0 : 1
            return NSColor(srgbRed: ink, green: ink, blue: ink, alpha: 0.8)
        })
    }

    /// Composites `self` at its alpha over `backdrop` and returns the result
    /// fully opaque, so a fill over glass can be measured as one colour.
    private func opaqueOver(_ backdrop: Color) -> Color {
        let fill = self
        return Color(nsColor: NSColor(name: nil) { appearance in
            let reference = NSAppearance(named: .darkAqua) ?? appearance
            var result = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            reference.performAsCurrentDrawingAppearance {
                guard let fg = NSColor(fill).usingColorSpace(.sRGB),
                      let bg = NSColor(backdrop).usingColorSpace(.sRGB) else { return }
                let a = fg.alphaComponent
                result = NSColor(srgbRed: fg.redComponent * a + bg.redComponent * (1 - a),
                                 green: fg.greenComponent * a + bg.greenComponent * (1 - a),
                                 blue: fg.blueComponent * a + bg.blueComponent * (1 - a),
                                 alpha: 1)
            }
            return result
        })
    }

    private static func linear(_ channel: CGFloat) -> Double {
        let c = Double(channel)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Preset-tinted luminance sheen for cards.
    ///
    /// On a dark window the sheen is a light *and* tinted wash, so it carries
    /// both the optical gradient and the preset's identity. On a light window
    /// the same treatment would erase the surface's contrast, so the sheen
    /// falls back to a faint neutral trace and the card keeps its semantic base.
    static func crystalSheenLuminance(_ material: CrystalMaterial) -> Color {
        appearanceAware(dark: material.tintColor, light: crystalGraphite)
    }

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
        if isActive {
            if material.panelMaterial == .clear {
                // No-panel mode: dissolves the outer box so cards float
                // directly on the desktop. This is the one facet the four
                // numeric parameters cannot express — it removes the glass
                // surface itself rather than recolouring it.
                content.background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.015))
                )
            } else {
                content.background(panelBackground)
            }
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
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

/// The resting fill every crystal card shares.
///
/// `PreviewPanel.cardFillOpacity`, `WorkspaceBarPanel` and `DockPreviewView`
/// each spell this formula out today; the preview card reads it from here so
/// its miniature cards carry the panel's fill, not a lookalike.
enum CrystalCardFill {
    static func opacity(_ slider: Double) -> Double {
        min(max(slider * 0.35 + 0.04, 0.06), 0.28)
    }
}

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

/// 普通窗口仍保留各自的染色和光泽公式；本次只统一叠层及 wash 控制入口。
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
        if opacity <= 0 { return transparent(tintColor: tintColor ?? material.tintColor) }
        return GlassAppearance(
            washOpacity: GlassWash.opacity(for: opacity),
            tintColor: tintColor ?? material.tintColor,
            tintOpacity: min(max(opacity * 0.28, 0.04), 0.36) * material.panelTintCap,
            topSheenOpacity: material.topSheenOpacity,
            middleSheenOpacity: material.topSheenOpacity > 0 ? 0.05 : 0,
            rimTopOpacity: material.rimTopOpacity
        )
    }

    static func window(opacity: Double, material: CrystalMaterial, style: WindowGlassStyle) -> GlassAppearance {
        if opacity <= 0 { return transparent(tintColor: material.tintColor) }
        let isPreferences = style == .preferences
        return GlassAppearance(
            washOpacity: GlassWash.opacity(for: opacity),
            tintColor: material.tintColor,
            tintOpacity: (isPreferences ? min(max(opacity * 0.22, 0.04), 0.28) : 0.08) * material.panelTintCap,
            topSheenOpacity: material.topSheenOpacity * material.panelTintCap * (isPreferences ? opacity : 1),
            middleSheenOpacity: style == .statistics ? nil : (material.topSheenOpacity > 0 ? 0.04 : 0),
            rimTopOpacity: nil
        )
    }

    /// 零值关闭所有背景叠层，避免染色或固定渐变残留。
    private static func transparent(tintColor: Color) -> GlassAppearance {
        GlassAppearance(washOpacity: 0, tintColor: tintColor, tintOpacity: 0,
                        topSheenOpacity: 0, middleSheenOpacity: nil, rimTopOpacity: nil)
    }
}

/// 每个普通窗口创建自己的背景模糊层，不采样另一个窗口的玻璃。
struct WindowGlassSurface: View {
    let opacity: Double
    let material: CrystalMaterial
    let style: WindowGlassStyle

    var body: some View {
        GlassSurface(
            appearance: .window(opacity: opacity, material: material, style: style),
            cornerRadius: 0,
            drawsVibrancy: true
        ) {
            EmptyView()
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
                        LinearGradient(
                            colors: [
                                Color.crystalRimBase.opacity(rim),
                                Color.crystalRimBase.opacity(0.20),
                                Color.crystalRimBase.opacity(0.06),
                                Color.crystalRimBase.opacity(0.24)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
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
    /// 整个 NSVisualEffectView 的 alpha，包括其背景模糊和材质效果。
    /// 滑块为零时关闭背景；非零值沿用原来的映射。
    var washOpacity: Double = 1

    init(material: NSVisualEffectView.Material = .popover, cornerRadius: CGFloat = 0, washOpacity: Double = 1) {
        self.material = material
        self.cornerRadius = cornerRadius
        self.washOpacity = washOpacity
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
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

/// 零值允许全透明；非零值保持已有外观，避免改动用户当前设置。
enum GlassWash {
    static func opacity(for slider: Double) -> Double {
        let clamped = min(max(slider, 0), 1)
        return clamped == 0 ? 0 : 0.30 + 0.70 * clamped
    }
}

// MARK: - GlassPreviewCard

/// 设置中的材质示意：复用面板叠层，但底层来自当前窗口。
/// 因此只能展示染色、光泽和布局，不能准确预览独立面板的背景 wash。
struct GlassPreviewCard: View {
    let opacity: Double
    let cornerRadius: CGFloat
    var material: CrystalMaterial = .legacyDefault
    var panelStyle: PreviewPanelStyle = .classicGrid
    /// Draw the surrounding window glass instead of a simulated wall.
    var sampleOfPanelGlass: Bool = false
    /// Localizer for the card's captions. Defaults to identity, so the card
    /// keeps no dependency on the language model in `Models`.
    var localize: (String) -> String = { $0 }

    var body: some View {
        VStack(spacing: 6) {
            PanelGlassSurface(
                // The card previews the glass panel itself, so `isActive` is
                // true; the slider only reaches it through `opacity`.
                isActive: true,
                opacity: opacity,
                cornerRadius: cornerRadius,
                material: material,
                tintColor: material.tintColor,
                // 材质示意沿用当前窗口背景，不再创建自己的模糊底层。
                drawsVibrancy: !sampleOfPanelGlass
            ) {
                if sampleOfPanelGlass {
                    // Layer 1 already sits under the card: the window's glass.
                    Color.clear
                } else {
                    // Legacy preview wall: a stand-in for the desktop, for
                    // surfaces that are not drawn over the settings window.
                    LinearGradient(
                        colors: [
                            Color(red: 0.24, green: 0.50, blue: 0.96).opacity(0.65),
                            Color(red: 0.68, green: 0.34, blue: 0.88).opacity(0.55),
                            Color(red: 0.18, green: 0.78, blue: 0.86).opacity(0.50)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(width: 220, height: 110)
            .overlay(panelChrome)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .crystalSpecularRim(cornerRadius: cornerRadius, material: material, lineWidth: 0.75)
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)

            Text("\(localize("Glass panel")) · \(Int(opacity * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)

            // 明确说明示意图的背景来源和 wash 预览限制。
            Text(localize(sampleOfPanelGlass
                          ? "Material sample uses this window's background; it does not preview an independent panel wash."
                          : "Simulated wallpaper background, not the app's own colours"))
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.75))
                .frame(width: 220)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: opacity)
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: material)
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: panelStyle)
    }

    private var isGlass: Bool { material.panelMaterial != .clear }

    /// The panel's chrome, shrunk into the card: header (title + search pill)
    /// over the section hairline, then the card grid. Every treatment is the
    /// one PreviewPanel draws, at the panel's own alphas — nothing here is a
    /// colour picked to look right next to it.
    private var panelChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Switchly")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 2)

                // PreviewPanel.searchBar, at the same liquidGlass and alphas.
                HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 22, height: 1.5)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .liquidGlass(
                    isActive: isGlass,
                    // PreviewPanel.controlOpacity
                    opacity: min(max(opacity + 0.16, 0), 1),
                    cornerRadius: DesignTokens.Radius.pill,
                    tintColor: material.tintColor,
                    interactive: true,
                    fallbackColor: Color(nsColor: .textBackgroundColor),
                    material: material
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.pill, style: .continuous)
                        .strokeBorder(Color.crystalPanelHairline.opacity(0.42),
                                      lineWidth: DesignTokens.hairline)
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(sectionBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.crystalPanelHairline.opacity(isGlass ? 0.22 : 0.08),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: DesignTokens.hairline)
            }

            HStack(spacing: 7) {
                if panelStyle == .stage {
                    miniOrnamentRail
                }

                HStack(spacing: 6) {
                    miniWindowCard(isSelected: true)
                    miniWindowCard(isSelected: false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(sectionBackground)
        }
    }

    /// PreviewPanel.spatialOrnamentRail, shrunk: a pill of two circular style
    /// buttons inside liquidGlass.
    private var miniOrnamentRail: some View {
        VStack(spacing: 6) {
            ForEach(PreviewPanelStyle.allCases, id: \.self) { style in
                let isCurrent = style == panelStyle
                Circle()
                    .fill(isCurrent ? Color.accentColor.opacity(0.55) : Color.crystalPanelHairline.opacity(0.08))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.crystalPanelHairline.opacity(isCurrent ? 0.85 : 0.24),
                                          lineWidth: DesignTokens.hairline)
                    )
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .liquidGlass(
            isActive: isGlass,
            opacity: 0.18,
            cornerRadius: DesignTokens.Radius.pill,
            material: material
        )
    }

    /// PreviewPanel's grid card: `crystalSurfaceBase` at the same
    /// `cardFillOpacity`, inside the same `cardSurface` sheen, edged by the
    /// same `crystalSpecularRim`. Two cards preview the resting and the
    /// selected fill side by side.
    private func miniWindowCard(isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // PreviewPanel.thumbnailContainer's backing.
            RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail * 0.6, style: .continuous)
                .fill(Color.black.opacity(isGlass ? 0.16 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail * 0.6, style: .continuous)
                        .strokeBorder(Color.crystalPanelHairline.opacity(0.18),
                                      lineWidth: DesignTokens.hairline)
                )
                .frame(height: 26)

            HStack(spacing: 3) {
                // PreviewPanel.titleAppIcon's chip.
                RoundedRectangle(cornerRadius: DesignTokens.Radius.chip * 0.6, style: .continuous)
                    .fill(Color.crystalPanelHairline.opacity(0.16))
                    .frame(width: 9, height: 9)

                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 26, height: 2.5)

                Spacer(minLength: 0)
            }

            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 34, height: 2)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // PreviewPanel.cardFill: accent when selected, semantic base at rest.
        .cardSurface(
            fill: isSelected
                ? Color.accentColor.opacity(isGlass ? 0.12 : 0.06)
                : Color.crystalSurfaceBase.opacity(CrystalCardFill.opacity(opacity)),
            cornerRadius: DesignTokens.Radius.card * 0.6,
            material: material
        )
        .crystalSpecularRim(
            cornerRadius: DesignTokens.Radius.card * 0.6,
            material: material,
            isHighlighted: isSelected
        )
    }

    /// PreviewPanel.sectionBackground: a 2 % hairline wash separates the zones
    /// on glass; without the glass the panel is opaque.
    private var sectionBackground: Color {
        isGlass ? Color.crystalSheenTop.opacity(0.02) : Color(nsColor: .controlBackgroundColor)
    }
}