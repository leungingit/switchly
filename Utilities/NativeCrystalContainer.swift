import AppKit
import SwiftUI

/// Embed the actual controls in AppKit's public glass content container.
/// The hosting view is retained on updates so focus and control state survive drags.
@available(macOS 26.0, *)
struct NativeCrystalContainer<Content: View>: NSViewRepresentable {
    let content: Content
    let density: Double
    let material: CrystalMaterial
    let cornerRadius: CGFloat

    final class Coordinator {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        init() { host.sizingOptions = [] }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.contentView = context.coordinator.host.view
        updateNSView(glass, context: context)
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        glass.style = .clear
        glass.cornerRadius = cornerRadius
        // The theme is inherited. Never override just the backing's appearance.
        glass.appearance = nil
        glass.tintColor = nil // Colour is composed once in the shared content surface.
        context.coordinator.host.rootView = hostedContent(context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSGlassEffectView, context: Context) -> CGSize? {
        if let width = proposal.width, let height = proposal.height {
            return CGSize(width: max(width, 0), height: max(height, 0))
        }
        // Ask SwiftUI for content dimensions only when needed. Reading AppKit
        // fittingSize during glass layout re-enters the same layout pass.
        return context.coordinator.host.sizeThatFits(in: CGSize(
            width: proposal.width ?? .greatestFiniteMagnitude,
            height: proposal.height ?? .greatestFiniteMagnitude))
    }

    private func hostedContent(_ context: Context) -> AnyView {
        let appearance = GlassAppearance.panel(opacity: density, material: material)
        return AnyView(content
            .background(
                ZStack {
                    // Density adds a theme-relative reading surface, without fading the controls.
                    Color(nsColor: .windowBackgroundColor).opacity(appearance.washOpacity * DesignTokens.Glass.maximumNativeReadingOpacity)
                    appearance.tintColor.opacity(appearance.tintOpacity)
                }
            )
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.locale, context.environment.locale)
            .environment(\.isEnabled, context.environment.isEnabled))
    }
}

struct WindowCrystalModifier: ViewModifier {
    let density: Double
    let material: CrystalMaterial
    let style: WindowGlassStyle

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), material.glassStyle == .transparent {
            NativeCrystalContainer(content: content, density: density, material: material,
                                   cornerRadius: DesignTokens.Radius.panel)
                .ignoresSafeArea()
        } else {
            content.background(WindowGlassSurface(opacity: density, material: material, style: style).ignoresSafeArea())
        }
    }
}
