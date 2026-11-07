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
        GeometryReader { proxy in
            content
                .onAppear {
                    controller.updateActionSink(onAction)
                    controller.updateSlotSize(proxy.size)
                    controller.start()
                }
                .onChange(of: proxy.size) { controller.updateSlotSize($0) }
                .onDisappear { controller.stop() }
                .onChange(of: configuration) { _ in
                    controller.updateActionSink(onAction)
                    controller.configure(
                        descriptor: descriptor,
                        pluginID: pluginID,
                        assetDirectory: assetDirectory,
                        artwork: artwork,
                        palette: palette
                    )
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(descriptor.key))
    }

    private var configuration: PluginScene3DViewConfiguration {
        PluginScene3DViewConfiguration(
            descriptor: descriptor,
            pluginID: pluginID,
            assetDirectory: assetDirectory,
            artworkToken: artwork?.token,
            palette: palette
        )
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .ready:
            PluginScene3DHostView(controller: controller, onAction: onAction)
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
