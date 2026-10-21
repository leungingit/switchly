import AppKit
import SwiftUI
import XCTest
@testable import Switchly

final class GlassAppearanceTests: XCTestCase {
    func testRemoveGlassOverlaysPreservesMaterialAndRoundTrips() throws {
        for style in [GlassStyle.transparent, .frosted] {
            var settings = AppSettings.default
            settings.theme = .dark
            settings.crystalMaterial.glassStyle = style
            settings.crystalMaterial.cardOpacity = 0.25
            settings.removeGlassOverlays()
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored.panelGlassDensity, 0)
            XCTAssertEqual(restored.windowGlassDensity, 0)
            XCTAssertEqual(restored.backgroundBlurOpacity, 0)
            XCTAssertEqual(restored.preferencesGlassOpacity, 0)
            let appearance = GlassAppearance.panel(opacity: restored.panelGlassDensity, material: restored.crystalMaterial)
            XCTAssertEqual(appearance.tintOpacity, 0)
            XCTAssertEqual(appearance.topSheenOpacity, 0)
            XCTAssertEqual(appearance.rimTopOpacity, 0)
            XCTAssertEqual(restored.crystalMaterial.glassStyle, style)
            XCTAssertEqual(restored.crystalMaterial.cardOpacity, 0.25)
            XCTAssertEqual(restored.theme, .dark)
        }
    }

    func testEverySurfaceUsesTheSameIndependentControls() {
        var material = CrystalMaterial.legacyDefault
        material.topSheenOpacity = 0.31
        material.panelTintCap = 0.42
        material.rimTopOpacity = 0.73
        let panel = GlassAppearance.panel(opacity: 0.45, material: material)
        XCTAssertEqual(panel.washOpacity, 0.45, accuracy: 0.0001)
        for style in [WindowGlassStyle.preferences, .workspace, .statistics] {
            let window = GlassAppearance.window(opacity: 0.45, material: material, style: style)
            XCTAssertEqual(window.washOpacity, panel.washOpacity)
            XCTAssertEqual(window.tintOpacity, panel.tintOpacity)
            XCTAssertEqual(window.topSheenOpacity, panel.topSheenOpacity)
            XCTAssertEqual(window.rimTopOpacity, panel.rimTopOpacity)
        }
        let before = panel
        material.panelTintCap = 0
        let after = GlassAppearance.panel(opacity: 0.45, material: material)
        XCTAssertEqual(after.tintOpacity, 0)
        XCTAssertEqual(after.washOpacity, before.washOpacity)
        XCTAssertEqual(after.topSheenOpacity, before.topSheenOpacity)
        XCTAssertEqual(after.rimTopOpacity, before.rimTopOpacity)
    }

    func testZeroValuesRemoveTheirOwnLayersAndDensityHasNoFloor() throws {
        var material = CrystalMaterial.legacyDefault
        material.panelTintCap = 0
        material.topSheenOpacity = 0
        material.rimTopOpacity = 0
        let decoded = try JSONDecoder().decode(CrystalMaterial.self, from: JSONEncoder().encode(material)).clamped()
        for density in [0.0, 0.001, 0.5, 1] {
            let appearance = GlassAppearance.panel(opacity: density, material: decoded)
            XCTAssertEqual(appearance.washOpacity, density)
            XCTAssertEqual(appearance.tintOpacity, 0)
            XCTAssertEqual(appearance.topSheenOpacity, 0)
            XCTAssertNil(appearance.middleSheenOpacity)
            XCTAssertEqual(appearance.rimTopOpacity, 0)
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
            XCTAssertEqual(effect.alphaValue, 0.7, accuracy: 0.0001)
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

    func testBaseToneCompatibilityAndRoundTrip() throws {
        let old = try JSONDecoder().decode(CrystalMaterial.self, from: Data("{}".utf8))
        XCTAssertEqual(old.baseTone, .automatic)
        for tone in GlassBaseTone.allCases {
            var settings = AppSettings.default
            settings.crystalMaterial.baseTone = tone
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(decoded.crystalMaterial.baseTone, tone)
        }
    }

    /// Check the real AppKit view, including clearing the explicit appearance.
    @MainActor
    func testBaseToneUpdatesAndRestoresInheritedAppearance() throws {
        var material = CrystalMaterial.legacyDefault
        let host = NSHostingView(rootView: WindowGlassSurface(opacity: 0.5, material: material, style: .preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil }
        for tone in [GlassBaseTone.light, .dark, .automatic] {
            material.baseTone = tone
            host.rootView = WindowGlassSurface(opacity: 0.5, material: material, style: .preferences)
            host.layoutSubtreeIfNeeded()
            let effect = try XCTUnwrap(visualEffects(in: host).first)
            XCTAssertNil(effect.appearance, "Retired backing tone must not override the text theme")
            XCTAssertEqual(window.appearance?.name, .darkAqua)
        }
    }

    func testLegacyDensitiesArePreservedUntilSharedControlIsUsed() throws {
        var settings = AppSettings.default
        settings.backgroundBlurOpacity = 0.25
        settings.preferencesGlassOpacity = 0.75
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertNil(old.crystalMaterial.sharedDensity)
        XCTAssertEqual(old.panelGlassDensity, 0.25)
        XCTAssertEqual(old.windowGlassDensity, 0.75)
        settings.crystalMaterial.sharedDensity = 0.2
        settings.crystalMaterial.glassStyle = .transparent
        let updated = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(updated.panelGlassDensity, 0.2)
        XCTAssertEqual(updated.windowGlassDensity, 0.2)
        XCTAssertEqual(updated.backgroundBlurOpacity, 0.25)
        XCTAssertEqual(updated.preferencesGlassOpacity, 0.75)
        XCTAssertEqual(updated.crystalMaterial.glassStyle, .transparent)
    }

    @MainActor
    func testNativeGlassOwnsRealContentAndUpdatesWithoutReplacingHost() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires native glass") }
        var material = CrystalMaterial.legacyDefault
        material.glassStyle = .transparent
        let host = NSHostingView(rootView: NativeCrystalContainer(content: Text("Focusable content"), density: 0.2,
                                                                material: material, cornerRadius: 28))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func glass(in view: NSView) -> NSGlassEffectView? {
            if let view = view as? NSGlassEffectView { return view }
            return view.subviews.compactMap { glass(in: $0) }.first
        }
        let effect = try XCTUnwrap(glass(in: host))
        let content = try XCTUnwrap(effect.contentView)
        XCTAssertTrue(content is NSHostingView<AnyView>)
        XCTAssertEqual(effect.style, .clear)
        XCTAssertEqual(effect.alphaValue, 1, "The text must not fade with density")
        XCTAssertEqual(effect.cornerRadius, 28)
        material.glassStyle = .frosted
        host.rootView = NativeCrystalContainer(content: Text("Updated content"), density: 0.8,
                                              material: material, cornerRadius: 20)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(effect.style, .regular)
        XCTAssertTrue(effect.contentView === content)
        XCTAssertEqual(effect.cornerRadius, 20)
        XCTAssertEqual(effect.alphaValue, 1)
    }

    @MainActor
    func testThemeAppliesToExistingWindowsAndRestoresSystemInheritance() {
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSView()
        defer { window.contentView = nil }
        for theme in [AppTheme.light, .dark, .system] {
            ThemeApplier.apply(theme)
            if theme == .system {
                XCTAssertNil(NSApp.appearance)
                XCTAssertNil(window.appearance)
                XCTAssertNil(window.contentView?.appearance)
            } else {
                let name: NSAppearance.Name = theme == .light ? .aqua : .darkAqua
                XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
                XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
            }
        }
    }

    func testTransparentFallbackDoesNotRetainHiddenFrostedHighlights() {
        var material = CrystalMaterial.legacyDefault
        material.glassStyle = .transparent
        let resolved = GlassAppearance.panel(opacity: 0.5, material: material)
        XCTAssertEqual(resolved.topSheenOpacity, 0)
        XCTAssertEqual(resolved.rimTopOpacity, 0)
    }

    @MainActor
    func testAddedRimCoversEveryEdgeWithoutAnInvisibleHalf() {
        XCTAssertTrue(GlassRim.opacities(strength: 0).allSatisfy { $0 == 0 })
        for value in [0.01, 0.57, 1] {
            let stops = GlassRim.opacities(strength: value)
            XCTAssertTrue(stops.allSatisfy { $0 > 0 && $0 <= 1 })
            XCTAssertGreaterThanOrEqual(stops.min() ?? 0, value * 0.4)
        }
    }

    private func visualEffects(in view: NSView) -> [NSVisualEffectView] {
        (view as? NSVisualEffectView).map { [$0] } ?? view.subviews.flatMap { visualEffects(in: $0) }
    }
}
