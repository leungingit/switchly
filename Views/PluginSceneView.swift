//
//  PluginSceneView.swift
//  Switchly
//
//  Plays a PluginScene. The timeline runs at the scene's fps only while
//  something is still changing (or hovered): once the scene has settled, or
//  under Reduce Motion, it is drawn once and the timer stops. Hover and clicks
//  are hit-tested locally against the layers that declare `hit`, so a hover
//  never round-trips through JS.
//

import AppKit
import SwiftUI

struct PluginSceneView: View {
    let scene: PluginScene
    let assetDirectory: URL?
    let onAction: (String, Double?) -> Void

    @State private var hoverID: String?
    @State private var previousHoverID: String?
    @State private var hoverChangedAt = Date.distantPast
    @State private var settled = false
    @State private var settleTask: Task<Void, Never>?
    @State private var assets = SceneAssets(directory: nil)

    private static let hoverFade = 0.15

    var body: some View {
        let reduce = MotionTokens.reduceMotion
        let running = !reduce && !settled
        GeometryReader { geo in
            let k = scale(for: geo.size)
            let origin = CGPoint(x: (geo.size.width - CGFloat(scene.width) * k) / 2,
                                 y: scene.fit == .cover ? (geo.size.height - CGFloat(scene.height) * k) / 2 : 0)
            ZStack {
                TimelineView(.animation(minimumInterval: 1 / scene.fps, paused: !running && !isHoverAnimating)) { context in
                    Canvas { ctx, _ in
                        var c = ctx
                        c.translateBy(x: origin.x, y: origin.y)
                        c.scaleBy(x: k, y: k)
                        SceneDrawing(scene: scene, t: scene.time(now: context.date.timeIntervalSince1970, reduceMotion: reduce),
                                     still: reduce, hover: hoverFactors(at: context.date), assets: assets)
                            .draw(into: c)
                    }
                }
                if scene.fit == .width, !scene.hits.isEmpty {
                    SceneInputView(onMove: { setHover(at: $0, origin: origin, k: k) },
                                   onClick: { click(at: $0, origin: origin, k: k) })
                    accessibilityRegions(origin: origin, k: k)
                }
            }
            // A cover scene is the plugin card's backdrop: clip it to the
            // card's corner radius so its colour wash ends in the card's
            // shape instead of a square.
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous))
        }
        .aspectRatio(scene.fit == .width ? CGFloat(scene.width / scene.height) : nil, contentMode: .fit)
        .frame(maxWidth: scene.fit == .width ? CGFloat(scene.width) * 1.3 : .infinity)
        .allowsHitTesting(scene.fit == .width && !scene.hits.isEmpty)
        .onAppear {
            assets = SceneAssets(directory: assetDirectory)
            armSettleTimer()
        }
        .onChange(of: scene) { _ in armSettleTimer() }
        .onDisappear { settleTask?.cancel() }
    }

    private func scale(for size: CGSize) -> CGFloat {
        let kw = size.width / CGFloat(scene.width), kh = size.height / CGFloat(scene.height)
        return scene.fit == .cover ? max(kw, kh) : kw
    }

    // MARK: - Settling

    /// Stops the timeline shortly after the last animation ends.
    private func armSettleTimer() {
        settleTask?.cancel()
        settled = false
        guard let end = scene.settledAt else { return }
        let remaining = end - (Date().timeIntervalSince1970 - scene.epoch) + 0.3
        settleTask = Task { @MainActor in
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            if !Task.isCancelled { settled = true }
        }
    }

    // MARK: - Hover and clicks

    private var isHoverAnimating: Bool { Date().timeIntervalSince(hoverChangedAt) < Self.hoverFade + 0.1 }

    private func hoverFactors(at date: Date) -> [String: Double] {
        let progress = SceneMath.ease(.inOut, date.timeIntervalSince(hoverChangedAt) / Self.hoverFade)
        var result: [String: Double] = [:]
        if let previousHoverID { result[previousHoverID] = 1 - progress }
        if let hoverID { result[hoverID] = progress }
        return result
    }

    private func regions(origin: CGPoint, k: CGFloat) -> [SceneDrawing.HitRegion] {
        let t = scene.time(now: Date().timeIntervalSince1970, reduceMotion: MotionTokens.reduceMotion)
        return SceneDrawing.hitRegions(in: scene, at: t, still: MotionTokens.reduceMotion)
    }

    private func hit(at point: CGPoint, origin: CGPoint, k: CGFloat) -> SceneHit? {
        let local = CGPoint(x: (point.x - origin.x) / k, y: (point.y - origin.y) / k)
        // Later layers draw on top, so they win.
        return regions(origin: origin, k: k).last { $0.rect.contains(local) }?.hit
    }

    private func setHover(at point: CGPoint?, origin: CGPoint, k: CGFloat) {
        let id = point.flatMap { hit(at: $0, origin: origin, k: k)?.id }
        guard id != hoverID else { return }
        previousHoverID = hoverID
        hoverID = id
        hoverChangedAt = Date()
        settled = false
        armSettleTimer()
        if id != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    private func click(at point: CGPoint, origin: CGPoint, k: CGFloat) {
        guard let hit = hit(at: point, origin: origin, k: k) else { return }
        onAction(hit.id, nil)
    }

    private func accessibilityRegions(origin: CGPoint, k: CGFloat) -> some View {
        ZStack {
            ForEach(regions(origin: origin, k: k), id: \.hit.id) { region in
                Color.clear
                    .frame(width: region.rect.width * k, height: region.rect.height * k)
                    .position(x: origin.x + region.rect.midX * k, y: origin.y + region.rect.midY * k)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(region.hit.label)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onAction(region.hit.id, nil) }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Reports the pointer (top-left origin) and clicks of its area; the system
/// SwiftUI hover API only says in / out and is unavailable below macOS 13.
private struct SceneInputView: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> InputNSView {
        let view = InputNSView()
        view.onMove = onMove
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: InputNSView, context: Context) {
        view.onMove = onMove
        view.onClick = onClick
    }

    final class InputNSView: NSView {
        var onMove: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint) -> Void = { _ in }
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) { onMove(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onMove(nil) }
        override func mouseDown(with event: NSEvent) { onClick(convert(event.locationInWindow, from: nil)) }
    }
}
