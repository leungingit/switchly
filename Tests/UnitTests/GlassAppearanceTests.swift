import AppKit
import SwiftUI
import XCTest
@testable import Switchly

final class GlassAppearanceTests: XCTestCase {
    /// 固定旧版数值，防止共享叠层时顺手改变各表面的外观。
    func testExistingSurfaceCoefficientsArePreserved() {
        var material = CrystalMaterial.legacyDefault
        material.topSheenOpacity = 0.31
        material.panelTintCap = 0.42
        material.rimTopOpacity = 0.73

        let panel = GlassAppearance.panel(opacity: 0.45, material: material)
        XCTAssertEqual(panel.washOpacity, 0.615, accuracy: 0.0001)
        XCTAssertEqual(panel.tintOpacity, 0.05292, accuracy: 0.0001)
        XCTAssertEqual(panel.topSheenOpacity, 0.31, accuracy: 0.0001)
        XCTAssertEqual(panel.rimTopOpacity, 0.73)

        let preferences = GlassAppearance.window(opacity: 0.45, material: material, style: .preferences)
        XCTAssertEqual(preferences.tintOpacity, 0.04158, accuracy: 0.0001)
        XCTAssertEqual(preferences.topSheenOpacity, 0.05859, accuracy: 0.0001)
        XCTAssertEqual(preferences.middleSheenOpacity, 0.04)
        XCTAssertNil(preferences.rimTopOpacity)

        for style in [WindowGlassStyle.workspace, .statistics] {
            let window = GlassAppearance.window(opacity: 0.45, material: material, style: style)
            XCTAssertEqual(window.tintOpacity, 0.0336, accuracy: 0.0001)
            XCTAssertEqual(window.topSheenOpacity, 0.1302, accuracy: 0.0001)
            XCTAssertNil(window.rimTopOpacity)
        }
        XCTAssertNil(GlassAppearance.window(opacity: 0.45, material: material, style: .statistics).middleSheenOpacity)
    }

    func testZeroWashRemovesAllBackgroundLayers() {
        let material = CrystalMaterial.legacyDefault
        let appearances = [GlassAppearance.panel(opacity: 0, material: material)]
            + [WindowGlassStyle.preferences, .workspace, .statistics].map {
                GlassAppearance.window(opacity: 0, material: material, style: $0)
            }
        for appearance in appearances {
            XCTAssertEqual(appearance.washOpacity, 0)
            XCTAssertEqual(appearance.tintOpacity, 0)
            XCTAssertEqual(appearance.topSheenOpacity, 0)
            XCTAssertNil(appearance.middleSheenOpacity)
            XCTAssertNil(appearance.rimTopOpacity)
        }
    }

    func testZeroSheenSurvivesClampingAndHasNoMiddleHighlight() throws {
        var material = CrystalMaterial.legacyDefault
        material.topSheenOpacity = 0
        let decoded = try JSONDecoder().decode(CrystalMaterial.self, from: JSONEncoder().encode(material)).clamped()
        XCTAssertEqual(decoded.topSheenOpacity, 0)
        let panel = GlassAppearance.panel(opacity: 0.3, material: decoded)
        XCTAssertEqual(panel.topSheenOpacity, 0)
        XCTAssertEqual(panel.middleSheenOpacity, 0)
        for style in [WindowGlassStyle.preferences, .workspace, .statistics] {
            let appearance = GlassAppearance.window(opacity: 0.7, material: decoded, style: style)
            XCTAssertEqual(appearance.topSheenOpacity, 0)
            XCTAssertEqual(appearance.middleSheenOpacity ?? 0, 0)
        }
    }

    /// 无面板只作用于浮动面板，不能移除三个普通窗口自己的模糊层。
    @MainActor
    func testEachStandardWindowOwnsItsBackgroundInNoPanelMode() throws {
        var material = CrystalMaterial.legacyDefault
        material.panelMaterial = .clear
        let styles: [WindowGlassStyle] = [.preferences, .workspace, .statistics]
        var windows: [NSWindow] = []
        var effects: [NSVisualEffectView] = []
        defer { windows.forEach { $0.contentView = nil } }

        for style in styles {
            let host = NSHostingView(rootView: WindowGlassSurface(opacity: 0.7, material: material, style: style))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            windows.append(window)

            let matches = visualEffects(in: host)
            XCTAssertEqual(matches.count, 1)
            let effect = try XCTUnwrap(matches.first)
            XCTAssertEqual(effect.blendingMode, .behindWindow)
            XCTAssertEqual(effect.material, .popover)
            XCTAssertEqual(effect.alphaValue, 0.79, accuracy: 0.0001)
            effects.append(effect)
        }
        XCTAssertFalse(effects[0] === effects[1])
        XCTAssertFalse(effects[1] === effects[2])
    }

    /// 滑块更新必须到达实际 AppKit 背景视图，不能只改变示意叠层。
    @MainActor
    func testWindowWashUpdatesActualBackgroundView() throws {
        let material = CrystalMaterial.legacyDefault
        let host = NSHostingView(rootView: WindowGlassSurface(opacity: 0, material: material, style: .preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(visualEffects(in: host).first).alphaValue, 0, accuracy: 0.0001)

        host.rootView = WindowGlassSurface(opacity: 1, material: material, style: .preferences)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(visualEffects(in: host).first).alphaValue, 1, accuracy: 0.0001)
    }

    @MainActor
    private func visualEffects(in view: NSView) -> [NSVisualEffectView] {
        (view as? NSVisualEffectView).map { [$0] } ?? view.subviews.flatMap { visualEffects(in: $0) }
    }
}
