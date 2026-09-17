//
//  GlassEffect.swift
//  Switchly
//
//  Unified Liquid Glass wrapper with macOS 26+ native API
//  and graceful fallback to material blur on older systems.
//

import SwiftUI
import AppKit

// MARK: - GlassEffectModifier

/// A ViewModifier that applies Liquid Glass styling to individual views.
///
/// On macOS 26+ it uses the native `.glassEffect()` API with optional tint,
/// interactivity, and shape. On older systems it falls back to
/// `.ultraThinMaterial` with a color overlay for a similar translucent look.
struct GlassEffectModifier: ViewModifier {
    /// Whether the glass effect is active. When `false`, falls back to the
    /// original solid color background defined by `fallbackColor`.
    let isActive: Bool

    /// Base opacity for the color overlay (0...1). Maps to the tint intensity
    /// on macOS 26+ and the overlay alpha on older systems.
    let opacity: Double

    /// Corner radius for the glass shape.
    let cornerRadius: CGFloat

    /// Optional tint color. `nil` uses the system window background color.
    let tintColor: Color?

    /// Whether the glass should respond to pointer interactions.
    let interactive: Bool

    /// Fallback solid color used when `isActive` is `false`.
    let fallbackColor: Color

    init(
        isActive: Bool,
        opacity: Double = 0.30,
        cornerRadius: CGFloat = 8,
        tintColor: Color? = nil,
        interactive: Bool = false,
        fallbackColor: Color = Color(nsColor: .controlBackgroundColor)
    ) {
        self.isActive = isActive
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.interactive = interactive
        self.fallbackColor = fallbackColor
    }

    func body(content: Content) -> some View {
        if isActive {
            if #available(macOS 26, *) {
                nativeGlass(content)
            } else {
                fallbackGlass(content)
            }
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fallbackColor)
                )
        }
    }

    // MARK: - Native (macOS 26+)

    @available(macOS 26, *)
    @ViewBuilder
    private func nativeGlass(_ content: Content) -> some View {
        let tint = resolvedTint.opacity(opacity)
        if interactive {
            content
                .glassEffect(
                    .regular.tint(tint).interactive(),
                    in: .rect(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .glassEffect(
                    .regular.tint(tint),
                    in: .rect(cornerRadius: cornerRadius, style: .continuous)
                )
        }
    }

    @available(macOS 26, *)
    private var resolvedTint: Color {
        tintColor ?? Color(nsColor: .windowBackgroundColor)
    }

    // MARK: - Fallback (macOS 12-15)

    @ViewBuilder
    private func fallbackGlass(_ content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(overlayColor.opacity(opacity))
                }
            )
    }

    private var overlayColor: Color {
        tintColor ?? Color(nsColor: .windowBackgroundColor)
    }
}

// MARK: - View Extension

extension View {
    /// Applies Liquid Glass styling with automatic API selection.
    ///
    /// - Parameters:
    ///   - isActive: Whether glass is enabled (maps to `enableBackgroundBlur`).
    ///   - opacity: Overlay/tint opacity (0...1).
    ///   - cornerRadius: Corner radius of the glass shape.
    ///   - tintColor: Optional tint color (defaults to window background).
    ///   - interactive: Whether the glass responds to pointer interactions.
    ///   - fallbackColor: Solid color when glass is disabled.
    func liquidGlass(
        isActive: Bool = true,
        opacity: Double = 0.30,
        cornerRadius: CGFloat = 8,
        tintColor: Color? = nil,
        interactive: Bool = false,
        fallbackColor: Color = Color(nsColor: .controlBackgroundColor)
    ) -> some View {
        modifier(
            GlassEffectModifier(
                isActive: isActive,
                opacity: opacity,
                cornerRadius: cornerRadius,
                tintColor: tintColor,
                interactive: interactive,
                fallbackColor: fallbackColor
            )
        )
    }

    /// Solid surface for cards that sit inside a glass panel.
    ///
    /// Cards intentionally do **not** carry their own material:
    /// - On the macOS 12–15 fallback path every `.ultraThinMaterial` fill is
    ///   its own `NSVisualEffectView`, so a 50-card grid meant 50+ live blur
    ///   views — the single most expensive thing a card grid can do.
    /// - On macOS 26+ native glass, glass-on-glass stacks read muddy and
    ///   cost contrast on the card's text and thumbnail.
    ///
    /// The panel already provides the blur; a solid (optionally translucent)
    /// fill on top keeps content crisp and lets the blur show through where
    /// it matters. This is also the Liquid Glass design language: glass
    /// containers hold solid content.
    func cardSurface(
        fill: Color,
        cornerRadius: CGFloat = DesignTokens.Radius.card
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
    }

    /// Panel-level glass background for floating NSPanel containers.
    ///
    /// Uses NSVisualEffectView behind-window blur + glass-style tint overlay
    /// instead of `.glassEffect()`, which does not render correctly on
    /// borderless NSPanel + NSHostingView (produces gray square corners).
    func panelGlass(
        isActive: Bool,
        opacity: Double,
        cornerRadius: CGFloat,
        tintColor: Color? = nil
    ) -> some View {
        modifier(
            PanelGlassModifier(
                isActive: isActive,
                opacity: opacity,
                cornerRadius: cornerRadius,
                tintColor: tintColor
            )
        )
    }
}

// MARK: - Panel Corner Radius

/// Unified corner radius for all floating panels (preview, dock preview, workspace bar).
/// Matches the visual curvature of standard macOS windows (preferences, workspaces).
enum GlassPanelCorner {
    /// Panel-level corner radius — visible outer curve of the floating panel.
    static let radius: CGFloat = 22
}

// MARK: - PanelGlassModifier

/// A ViewModifier for floating `NSPanel` containers.
///
/// `.glassEffect()` does not work correctly on `NSPanel` + `NSHostingView`:
/// the glass material cannot sample the desktop background through a
/// borderless, clear-background panel and degenerates into a gray rectangle
/// that ignores `.clipShape()`. Instead, we use `NSVisualEffectView` with
/// `.behindWindow` blending plus a glass-style tint overlay that simulates
/// Liquid Glass light refraction.
///
/// **Key fix for gray square corners:** The `NSVisualEffectView` itself is
/// given the same corner radius and `masksToBounds`, so the blur region is
/// rounded before any SwiftUI clipping is applied. This prevents the
/// rectangular visual effect view from showing through the transparent
/// corners of the `NSPanel`.
struct PanelGlassModifier: ViewModifier {
    let isActive: Bool
    let opacity: Double
    let cornerRadius: CGFloat
    let tintColor: Color?

    func body(content: Content) -> some View {
        if isActive {
            content.background(panelBackground)
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        ZStack {
            // Base: NSVisualEffectView provides behind-window blur.
            // It is masked to the panel corner radius so it never draws
            // outside the rounded bounds.
            GlassBackground(material: .hudWindow, cornerRadius: cornerRadius)

            // Glass-style tint overlay: simulates Liquid Glass translucency
            // by layering a color with light gradient refraction.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(resolvedTint.opacity(opacity * 0.6))

            // Subtle top-edge highlight to simulate glass light refraction
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        }
    }

    private var resolvedTint: Color {
        tintColor ?? Color(nsColor: .windowBackgroundColor)
    }
}

// MARK: - GlassBackground (NSVisualEffectView)

/// An `NSViewRepresentable` that wraps `NSVisualEffectView` for behind-window
/// blur. Used for panel-level backgrounds on all macOS versions.
///
/// The wrapped view is masked to the supplied `cornerRadius` so the blur
/// region follows the panel's rounded shape and never leaks gray square
/// corners through the transparent `NSPanel` background.
struct GlassBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let cornerRadius: CGFloat

    init(material: NSVisualEffectView.Material = .hudWindow, cornerRadius: CGFloat = 0) {
        self.material = material
        self.cornerRadius = cornerRadius
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
    }
}

// MARK: - GlassPreviewCard

/// A live preview card that shows what the glass effect looks like with the
/// current opacity setting. Designed to be placed in the settings panel next
/// to the opacity slider so users can see changes in real time.
struct GlassPreviewCard: View {
    let opacity: Double
    let cornerRadius: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            // Simulated window content
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 20)
                    .overlay(
                        HStack(spacing: 4) {
                            Circle().fill(.red).frame(width: 6, height: 6)
                            Circle().fill(.yellow).frame(width: 6, height: 6)
                            Circle().fill(.green).frame(width: 6, height: 6)
                        }
                        .padding(.leading, 6),
                        alignment: .leading
                    )

                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 40, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(nsColor: .textColor).opacity(0.4))
                            .frame(height: 5)
                            .frame(width: 60)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(nsColor: .textColor).opacity(0.2))
                            .frame(height: 4)
                            .frame(width: 45)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .frame(width: 160, height: 72)
            .background(
                ZStack {
                    // Simulated desktop background
                    LinearGradient(
                        colors: [.blue.opacity(0.4), .purple.opacity(0.3), .pink.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            // Glass layer on top
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.85)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(opacity * 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)

            Text("\(Int(opacity * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        // Track the opacity slider with an interactive spring so the live
        // preview trails the finger smoothly instead of stepping.
        .animation(MotionTokens.interactiveSpring, value: opacity)
    }
}
