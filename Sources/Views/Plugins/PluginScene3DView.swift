//
//  PluginScene3DView.swift
//  Switchly
//
//  T06: SwiftUI wrapper for the generic scene3d component. It owns nothing
//  business-related: the controller owns lifecycle and scene state, this file
//  only supplies an SCNView host, translates AppKit mouse coordinates, and
//  shows the plugin fallback when the declaration cannot be rendered.
//
//  Reached from `PluginOverlayView` for `scene3d` nodes. Plugins opt in via
//  `ctx.uiFeatures.scene3d`; otherwise they return their 2D tree.
//

import AppKit
import SceneKit
import SwiftUI

/// SCNView host. Keeps rendering on demand (no continuous loop) and forwards
/// pointer events in top-left coordinates to the controller/T05 input session.
/// The hit-test adapter expects AppKit's bottom-left view coordinates, so the
/// flip happens here and nowhere else.
@MainActor
final class PluginScene3DPointerView: SCNView, PluginScene3DSceneHosting {
    weak var controller: PluginScene3DController?
    private lazy var hitAdapter = Scene3DHitTestAdapter(view: self)

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        wantsLayer = true
        backgroundColor = .clear
        scene = nil
        autoenablesDefaultLighting = false
        allowsCameraControl = false
        isPlaying = false
        rendersContinuously = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        backgroundColor = .clear
        scene = nil
        autoenablesDefaultLighting = false
        allowsCameraControl = false
        isPlaying = false
        rendersContinuously = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
    }

    // MARK: - PluginScene3DSceneHosting

    func mountScene(_ scene: SCNScene?) {
        self.scene = scene
        if scene == nil {
            // Drop the last reference before teardown completes.
            needsDisplay = true
        }
    }

    func refreshDisplay() {
        needsDisplay = true
    }

    func hitCandidates(at point: CGPoint) -> [Scene3DHitRouter.Candidate] {
        hitAdapter.hitCandidates(at: appKitPoint(fromTopLeft: point))
    }

    // MARK: - Pointer

    /// The Dock preview panel is not key when the pointer enters it; the very
    /// first click must reach the model instead of only activating the panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.pointerDown(at: topLeftPoint(from: event))
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.pointerDragged(to: topLeftPoint(from: event))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.pointerUp(at: topLeftPoint(from: event))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.pointerCancelled()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            controller?.pointerCancelled()
        }
        reportAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reportAppearance()
    }

    private func reportAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        controller?.updateHostAppearance(dark: dark)
    }

    private func topLeftPoint(from event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func appKitPoint(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: bounds.height - point.y)
    }
}

/// Everything the controller is configured from. SwiftUI must reconfigure when
/// any of these change, not only the decoded descriptor: a slot can be reused
/// for another plugin, asset directory, artwork token or palette while the
/// `@StateObject` controller survives.
struct PluginScene3DViewConfiguration: Equatable {
    var descriptor: PluginScene3DDescriptor
    var pluginID: String
    var assetDirectory: URL
    var artworkToken: String?
    var palette: PluginSurfacePalette
    var artwork: PluginSurfaceArtwork? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.descriptor == rhs.descriptor && lhs.pluginID == rhs.pluginID
            && lhs.assetDirectory == rhs.assetDirectory
            && lhs.artworkToken == rhs.artworkToken && lhs.palette == rhs.palette
    }
}

/// Bridges the AppKit host into SwiftUI. Re-attaching is idempotent and
/// dismantling detaches so a hidden/reused view cannot keep a stale scene.
private struct PluginScene3DHostView: NSViewRepresentable {
    let controller: PluginScene3DController
    let onAction: (String, Double?) -> Void

    func makeNSView(context: Context) -> PluginScene3DPointerView {
        let view = PluginScene3DPointerView(frame: .zero)
        view.controller = controller
        controller.updateActionSink(onAction)
        controller.attach(host: view)
        return view
    }

    func updateNSView(_ nsView: PluginScene3DPointerView, context: Context) {
        // The representable can be reused with another controller; detach the
        // old one before the new controller mounts into the same SCNView.
        if let previous = nsView.controller, previous !== controller {
            previous.detach(host: nsView)
        }
        nsView.controller = controller
        controller.updateActionSink(onAction)

        if let scene = controller.instance?.scene {
            if nsView.scene !== scene {
                controller.attach(host: nsView)
            }
        } else if nsView.scene != nil {
            // The controller no longer owns a scene (teardown happened before
            // SwiftUI removed the host); never leave the old scene mounted.
            nsView.mountScene(nil)
        }
    }

    static func dismantleNSView(_ nsView: PluginScene3DPointerView, coordinator: ()) {
        nsView.controller?.detach(host: nsView)
    }
}

struct PluginScene3DView: View {
    let descriptor: PluginScene3DDescriptor
    let pluginID: String
    let assetDirectory: URL
    var artwork: PluginSurfaceArtwork? = nil
    var palette: PluginSurfacePalette = .system()
    let material: CrystalMaterial
    let isGlassActive: Bool
    let onAction: (String, Double?) -> Void

    @StateObject private var controller: PluginScene3DController
    @State private var loveBurst = false

    init(descriptor: PluginScene3DDescriptor,
         pluginID: String,
         assetDirectory: URL,
         artwork: PluginSurfaceArtwork? = nil,
         palette: PluginSurfacePalette = .system(),
         material: CrystalMaterial,
         isGlassActive: Bool,
         rasterizerFactory: @escaping @MainActor () -> PluginSurfaceRasterizing,
         onAction: @escaping (String, Double?) -> Void) {
        self.descriptor = descriptor
        self.pluginID = pluginID
        self.assetDirectory = assetDirectory
        self.artwork = artwork
        self.palette = palette
        self.material = material
        self.isGlassActive = isGlassActive
        self.onAction = onAction

        _controller = StateObject(wrappedValue: PluginScene3DController(
            descriptor: descriptor,
            pluginID: pluginID,
            assetDirectory: assetDirectory,
            artwork: artwork,
            palette: palette,
            rasterizerFactory: rasterizerFactory,
            actionSink: onAction
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                content
                    .overlay(alignment: .center) {
                        if loveBurst {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.pink)
                                .shadow(color: .pink.opacity(0.5), radius: 8)
                                .offset(y: -34)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .transition(.scale(scale: 0.45).combined(with: .opacity))
                        }
                    }
                    .onAppear {
                        controller.updateActionSink(handleAction)
                        controller.updateSlotSize(proxy.size)
                        controller.start()
                    }
                    .onChange(of: proxy.size) { controller.updateSlotSize($0) }
                    .onDisappear { controller.stop() }
                    .onChange(of: configuration) { updated in
                        controller.updateActionSink(handleAction)
                        controller.configure(
                            descriptor: updated.descriptor,
                            pluginID: updated.pluginID,
                            assetDirectory: updated.assetDirectory,
                            artwork: updated.artwork,
                            palette: updated.palette
                        )
                    }
            }
            turnControls
                .frame(height: PluginScene3DViewport.controlBarHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(descriptor.key))
    }

    private func handleAction(_ id: String, _ value: Double?) {
        onAction(id, value)
        guard id == "love", !MotionTokens.reduceMotion else { return }
        loveBurst = false
        withAnimation(.easeOut(duration: 0.22)) { loveBurst = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            withAnimation(.easeIn(duration: 0.2)) { loveBurst = false }
        }
    }

    /// Two buttons that spin the model a full turn left / right. Dragging the
    /// model needs the pointer to travel across a small panel, and leaving the
    /// panel dismisses it; these let users inspect every side without moving.
    @ViewBuilder
    private var turnControls: some View {
        if case .ready = controller.state, descriptor.rotate.horizontal {
            HStack(spacing: DesignTokens.Spacing.md) {
                PluginSymbolButton(symbol: "arrow.counterclockwise",
                                   label: NSLocalizedString("Rotate left", comment: "Spin the 3D model a full turn to the left"),
                                   size: .m, prominent: false, selected: false) {
                    controller.spin(.left)
                }
                PluginSymbolButton(symbol: "arrow.clockwise",
                                   label: NSLocalizedString("Rotate right", comment: "Spin the 3D model a full turn to the right"),
                                   size: .m, prominent: false, selected: false) {
                    controller.spin(.right)
                }
            }
        } else {
            Color.clear
        }
    }

    private var configuration: PluginScene3DViewConfiguration {
        PluginScene3DViewConfiguration(
            descriptor: descriptor,
            pluginID: pluginID,
            assetDirectory: assetDirectory,
            artworkToken: artwork?.token,
            palette: palette,
            artwork: artwork
        )
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .ready:
            PluginScene3DHostView(controller: controller, onAction: handleAction)
        case .idle, .loading, .fallback:
            fallbackView
        }
    }

    private var fallbackView: some View {
        PluginOverlayView(node: descriptor.fallback,
                          material: material,
                          isGlassActive: isGlassActive,
                          artwork: artwork?.image.map {
                              NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                          },
                          assetDirectory: assetDirectory,
                          onAction: onAction)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
