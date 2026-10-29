//
//  AppSettingsTests.swift
//  SwitchlyTests
//
//  Unit tests for AppSettings model
//

import XCTest
import SwiftUI
import AppKit
@testable import Switchly

final class AppSettingsTests: XCTestCase {
    func testDefaultSettings() {
        let settings = AppSettings.default
        
        XCTAssertEqual(settings.previewStrategy, .configuredOnly)
        XCTAssertEqual(settings.globalShortcutKey, "p")
        XCTAssertEqual(settings.thumbnailSize, .medium)
        XCTAssertTrue(settings.showWindowTitles)
        XCTAssertTrue(settings.enableBackgroundBlur)
        XCTAssertEqual(settings.backgroundBlurOpacity, 0.30)
        XCTAssertEqual(settings.monitorFrequency, .balanced)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.hideMainWindowOnLaunch)
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(settings.theme, .system)
        XCTAssertTrue(settings.workspaces.isEmpty)
        XCTAssertEqual(settings.defaultWorkspaceMissingAppDisplayMode, .hidden)
        XCTAssertEqual(settings.defaultWorkspaceWindowSortStrategy, .titleAscending)
        XCTAssertFalse(settings.previewHotspotEnabled)
        XCTAssertEqual(settings.previewHotspotEdge, .left)
        XCTAssertFalse(settings.previewShakeEnabled)
        XCTAssertEqual(settings.crystalMaterial, .legacyDefault)
        XCTAssertEqual(settings.previewPanelStyle, .classicGrid)
        XCTAssertFalse(settings.gridEnabled)
        XCTAssertEqual(settings.gridStyle, .c)
        XCTAssertEqual(settings.gridBackground, .cream)
        XCTAssertEqual(settings.windowCardBackdrop, .followingSystem)
        XCTAssertEqual(settings.previewSpaceScope, .allSpaces)
    }
    
    func testSettingsCodable() {
        let workspace = Workspace(
            name: "Development",
            shortcutKey: "d",
            appItems: [
                WorkspaceAppItem(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")
            ],
            missingAppDisplayMode: .placeholder,
            windowSortStrategy: .titleAscending
        )

        let settings = AppSettings(
            previewStrategy: .allApplications,
            shortcutPrefix: .commandControl,
            globalShortcutKey: "space",
            monitoredApps: [],
            thumbnailSize: .large,
            showWindowTitles: false,
            refreshInterval: 1.0,
            enableBackgroundBlur: false,
            backgroundBlurOpacity: 0.45,
            previewDisplayMode: .primaryScreen,
            notificationStrategy: .all,
            launchAtLogin: true,
            hideMainWindowOnLaunch: false,
            monitorFrequency: .highPerformance,
            language: .simplifiedChinese,
            theme: .dark,
            workspaces: [workspace],
            defaultWorkspaceMissingAppDisplayMode: .placeholder,
            defaultWorkspaceWindowSortStrategy: .titleAscending,
            previewSpaceScope: .currentSpace
        )
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)
            
            let decoder = JSONDecoder()
            let decodedSettings = try decoder.decode(AppSettings.self, from: data)
            
            XCTAssertEqual(decodedSettings.previewStrategy, settings.previewStrategy)
            XCTAssertEqual(decodedSettings.thumbnailSize, settings.thumbnailSize)
            XCTAssertEqual(decodedSettings.showWindowTitles, settings.showWindowTitles)
            XCTAssertEqual(decodedSettings.backgroundBlurOpacity, settings.backgroundBlurOpacity)
            XCTAssertEqual(decodedSettings.language, settings.language)
            XCTAssertEqual(decodedSettings.theme, settings.theme)
            XCTAssertEqual(decodedSettings.workspaces, [workspace])
            XCTAssertEqual(decodedSettings.defaultWorkspaceMissingAppDisplayMode, .placeholder)
            XCTAssertEqual(decodedSettings.defaultWorkspaceWindowSortStrategy, .titleAscending)
            XCTAssertEqual(decodedSettings.previewSpaceScope, .currentSpace)
        } catch {
            XCTFail("Encoding/Decoding failed: \(error)")
        }
    }

    // MARK: Desktop range

    func testMissingPreviewSpaceScopeFallsBackToAllSpaces() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "previewSpaceScope")
        XCTAssertNil(object["previewSpaceScope"])

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertEqual(decoded.previewSpaceScope, .allSpaces)
    }

    func testPreviewSpaceScopeRoundTrip() throws {
        var settings = AppSettings.default
        settings.previewSpaceScope = .currentSpace

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.previewSpaceScope, .currentSpace)
    }

    // MARK: Usage statistics

    /// Older settings have no logging key: file logging stays off until the user opts in.
    func testMissingFileLoggingKeyDefaultsToOff() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "fileLoggingEnabled")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.fileLoggingEnabled)

        var enabled = AppSettings.default
        enabled.fileLoggingEnabled = true
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(roundTrip.fileLoggingEnabled)
    }

    /// Settings written before the statistics panel existed have none of the
    /// new keys: statistics stay on and the baseline falls back to the
    /// recommended preset instead of failing the whole decode.
    func testMissingUsageStatisticsKeysFallBackToDefaults() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "usageStatisticsEnabled")
        object.removeValue(forKey: "efficiencyBaselinePreset")
        object.removeValue(forKey: "efficiencyBaselineCustom")
        XCTAssertNil(object["usageStatisticsEnabled"])

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertTrue(decoded.usageStatisticsEnabled)
        XCTAssertEqual(decoded.efficiencyBaselinePreset, .standard)
        XCTAssertNil(decoded.efficiencyBaselineCustom)
    }

    func testUsageStatisticsRoundTrip() throws {
        var settings = AppSettings.default
        settings.usageStatisticsEnabled = false
        settings.efficiencyBaselinePreset = .custom
        settings.efficiencyBaselineCustom = .conservative

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.usageStatisticsEnabled)
        XCTAssertEqual(decoded.efficiencyBaselinePreset, .custom)
        XCTAssertEqual(decoded.efficiencyBaselineCustom, .conservative)
    }

    // MARK: Pointer triggers

    /// Settings written before the pointer triggers existed decode with both
    /// triggers off, so an upgrade never starts popping the panel on its own.
    func testMissingPointerTriggerKeysFallBackToDefaults() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "previewHotspotEnabled")
        object.removeValue(forKey: "previewHotspotEdge")
        object.removeValue(forKey: "previewShakeEnabled")
        XCTAssertNil(object["previewHotspotEnabled"])

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertFalse(decoded.previewHotspotEnabled)
        XCTAssertEqual(decoded.previewHotspotEdge, .left)
        XCTAssertFalse(decoded.previewShakeEnabled)
    }

    func testPointerTriggerSettingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.previewHotspotEnabled = true
        settings.previewHotspotEdge = .right
        settings.previewShakeEnabled = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.previewHotspotEnabled)
        XCTAssertEqual(decoded.previewHotspotEdge, .right)
        XCTAssertTrue(decoded.previewShakeEnabled)
    }
    // MARK: - Optical crystal settings (redesign)

    /// A settings file written by the pre-redesign build has neither crystal
    /// key; decoding it must land on the documented defaults instead of
    /// failing, or every upgrade resets the user's other preferences too.
    func testMissingCrystalKeysFallBackToDefaults() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "crystalMaterial")
        object.removeValue(forKey: "previewPanelStyle")
        XCTAssertNil(object["crystalMaterial"])
        XCTAssertNil(object["previewPanelStyle"])

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertEqual(decoded.crystalMaterial, .legacyDefault)
        XCTAssertEqual(decoded.previewPanelStyle, .classicGrid)
    }

    func testCrystalMaterialRoundTrip() throws {
        var settings = AppSettings.default
        settings.crystalMaterial = CrystalMaterial(
            tintColor: Color(red: 0.9, green: 0.2, blue: 0.1),
            topSheenOpacity: 0.31,
            panelTintCap: 0.42,
            rimTopOpacity: 0.73,
            panelMaterial: .clear
        )
        settings.previewPanelStyle = .stage

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.crystalMaterial.topSheenOpacity, 0.31, accuracy: 0.0001)
        XCTAssertEqual(decoded.crystalMaterial.panelTintCap, 0.42, accuracy: 0.0001)
        XCTAssertEqual(decoded.crystalMaterial.rimTopOpacity, 0.73, accuracy: 0.0001)
        XCTAssertEqual(decoded.crystalMaterial.panelMaterial, .clear)
        let rgb = NSColor(decoded.crystalMaterial.tintColor).usingColorSpace(.sRGB) ?? .white
        XCTAssertEqual(Double(rgb.redComponent), 0.9, accuracy: 0.01)
        XCTAssertEqual(decoded.previewPanelStyle, .stage)
    }

    /// A settings file written before the four knobs existed carries one of
    /// the retired presets. Each must expand into the parameters it stood for,
    /// or an upgrade would silently repaint the panel.
    func testRetiredPresetsExpandIntoParameters() throws {
        let quartz = CrystalMaterial.legacy(expandedFrom: "quartz")
        XCTAssertEqual(quartz.topSheenOpacity, 0.20, accuracy: 0.0001)
        XCTAssertEqual(quartz.rimTopOpacity, 0.62, accuracy: 0.0001)
        XCTAssertEqual(quartz.panelTintCap, 1.0, accuracy: 0.0001)
        XCTAssertEqual(quartz.panelMaterial, .glass)

        // "frameless" meant no panel surface at all; that facet now lives on
        // the material switch, so it must land on .clear rather than a wash.
        let frameless = CrystalMaterial.legacy(expandedFrom: "frameless")
        XCTAssertEqual(frameless.panelMaterial, .clear)
        XCTAssertEqual(frameless.topSheenOpacity, 0.24, accuracy: 0.0001)
        XCTAssertEqual(frameless.rimTopOpacity, 0.68, accuracy: 0.0001)

        XCTAssertEqual(CrystalMaterial.legacy(expandedFrom: "ice"), .legacyDefault)
        XCTAssertEqual(CrystalMaterial.legacy(expandedFrom: nil), .legacyDefault)
    }

    /// Decoding a settings blob that still holds only the retired key must
    /// carry it over instead of reverting to the factory defaults.
    func testRetiredPresetKeyIsMigratedOnDecode() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "crystalMaterial")
        object["crystalThemePreset"] = "quartz"

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertEqual(decoded.crystalMaterial.topSheenOpacity, 0.20, accuracy: 0.0001)
        XCTAssertEqual(decoded.crystalMaterial.panelMaterial, .glass)
    }

    /// The settings window and the floating panels must not share one wash
    /// value: tuning the panels used to change the window the user was
    /// reading the slider in.
    func testPreferencesGlassIsIndependentOfPanelGlass() throws {
        var settings = AppSettings.default
        settings.backgroundBlurOpacity = 0.10
        settings.preferencesGlassOpacity = 0.95

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.backgroundBlurOpacity, 0.10, accuracy: 0.0001)
        XCTAssertEqual(decoded.preferencesGlassOpacity, 0.95, accuracy: 0.0001)
    }

    /// A settings file written before the window had its own slider must not
    /// leave the settings window fully transparent.
    func testMissingPreferencesGlassFallsBackToReadableDefault() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "preferencesGlassOpacity")

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertEqual(decoded.preferencesGlassOpacity, 0.70, accuracy: 0.0001)
    }

    /// The sliders are bounded, and a hand-edited settings file must not be
    /// able to push the render outside them.
    func testCrystalMaterialClampsToSliderRanges() {
        let wild = CrystalMaterial(
            tintColor: .white,
            topSheenOpacity: 5,
            panelTintCap: -3,
            rimTopOpacity: 9,
            panelMaterial: .glass
        ).clamped()
        XCTAssertEqual(wild.topSheenOpacity, CrystalMaterial.Range.sheen.upperBound, accuracy: 0.0001)
        XCTAssertEqual(wild.panelTintCap, CrystalMaterial.Range.panelTint.lowerBound, accuracy: 0.0001)
        XCTAssertEqual(wild.rimTopOpacity, CrystalMaterial.Range.rim.upperBound, accuracy: 0.0001)
    }

    /// The panel material switch is the one facet the four numeric knobs
    /// cannot express, so it must keep both cases — a single-case enum would
    /// be a dead control.
    func testPanelMaterialHasBothCases() {
        XCTAssertEqual(CrystalPanelMaterial.allCases, [.glass, .clear])
    }

    /// Every layout case must change the layout it names. A case that draws
    /// like another one is a dead setting (this is how two of them shipped).
    func testPreviewPanelStylesHaveDistinctGeometry() {
        XCTAssertEqual(Set(PreviewPanelStyle.allCases.map(\.cell)).count,
                       PreviewPanelStyle.allCases.count,
                       "two layout styles share the same cell geometry")

        let size = ThumbnailSize.medium
        for style in PreviewPanelStyle.allCases {
            XCTAssertGreaterThan(style.minimumCardWidth(for: size), 0)
            XCTAssertGreaterThan(style.thumbnailHeightScale, 0)
        }
        XCTAssertNotEqual(PreviewPanelStyle.stage.minimumCardWidth(for: size),
                          PreviewPanelStyle.classicGrid.minimumCardWidth(for: size))
        XCTAssertNotEqual(PreviewPanelStyle.stage.thumbnailHeightScale,
                          PreviewPanelStyle.classicGrid.thumbnailHeightScale)
    }
    // MARK: - Thumbnail backdrop

    /// The backdrop of a window thumbnail was a fixed black wash before it
    /// became adjustable. A settings file written back then carries no
    /// backdrop key, and it must decode to the wash that file rendered —
    /// otherwise the upgrade repaints every thumbnail.
    func testMissingThumbnailBackdropFallsBackToLegacyWash() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "thumbnailBackdrop")
        XCTAssertNil(object["thumbnailBackdrop"])

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertEqual(decoded.thumbnailBackdrop, .legacyDefault)
    }

    func testThumbnailBackdropRoundTrip() throws {
        var settings = AppSettings.default
        settings.thumbnailBackdrop = ThumbnailBackdrop(
            tintColor: Color(red: 0.1, green: 0.4, blue: 0.8),
            opacity: 0.33
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.thumbnailBackdrop.opacity, 0.33, accuracy: 0.0001)
        let rgb = NSColor(decoded.thumbnailBackdrop.tintColor).usingColorSpace(.sRGB) ?? .black
        XCTAssertEqual(Double(rgb.redComponent), 0.1, accuracy: 0.01)
        XCTAssertEqual(Double(rgb.greenComponent), 0.4, accuracy: 0.01)
        XCTAssertEqual(Double(rgb.blueComponent), 0.8, accuracy: 0.01)
    }

    /// A hand-edited settings file can carry an opacity outside the slider's
    /// range; decoding must clamp it, not carry it into the drawing code.
    func testThumbnailBackdropClampsToSliderRange() {
        let tooStrong = ThumbnailBackdrop(tintColor: .black, opacity: 4.0).clamped()
        XCTAssertEqual(tooStrong.opacity, ThumbnailBackdrop.Range.opacity.upperBound, accuracy: 0.0001)

        let tooFaint = ThumbnailBackdrop(tintColor: .black, opacity: -2.0).clamped()
        XCTAssertEqual(tooFaint.opacity, ThumbnailBackdrop.Range.opacity.lowerBound, accuracy: 0.0001)
    }

    /// The same stored strength reaches the matte regardless of panel style.
    /// In particular the upper endpoint must not be silently scaled to 22.5%.
    func testThumbnailBackdropUsesRequestedStrength() {
        for opacity in [0.0, 0.16, ThumbnailBackdrop.Range.opacity.upperBound] {
            let backdrop = ThumbnailBackdrop(tintColor: .black, opacity: opacity)
            let colour = NSColor(backdrop.resolvedColor()).usingColorSpace(.sRGB)
            XCTAssertEqual(Double(colour?.alphaComponent ?? -1), opacity, accuracy: 0.001)
        }
    }
    // MARK: - Thumbnail backdrop in the drawing code

    /// The backdrop is a drawing decision, not just a stored number: the wash
    /// behind a thumbnail must actually be the colour the user picked. This
    /// renders the real drawing expression offscreen and reads the pixels
    /// back, so a change in how the wash is resolved cannot pass unnoticed.
    func testThumbnailBackdropColourReachesTheRenderedPixels() throws {
        let backdrop = ThumbnailBackdrop(tintColor: Color(red: 1.0, green: 0.0, blue: 0.0),
                                         opacity: 0.6)

        // The exact expression the three preview surfaces draw.
        let wash = backdrop.resolvedColor()

        // Render it over an opaque white sheet: the resulting pixel is the
        // wash composited on white, so a red wash must read as pink, not as
        // the pure colour and not as white.
        let host = NSHostingView(rootView: Color.white.overlay(wash))
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("cannot create a bitmap rep")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let pixel = rep.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB) else {
            XCTFail("cannot read the rendered pixel")
            return
        }

        // A red wash at 0.6 over white: the red channel stays saturated, and
        // green and blue keep only the part of the white that shows through.
        // The exact figure depends on the colour space SwiftUI composites in
        // (it is a linear-light blend, not the naive sRGB 0.4), so the
        // assertion checks the shape of the result rather than a magic number:
        // the tint is unmistakably red, and it is clearly not the white it
        // was painted over.
        XCTAssertGreaterThan(Double(pixel.redComponent), 0.95)
        XCTAssertLessThan(Double(pixel.greenComponent), 0.75)
        XCTAssertLessThan(Double(pixel.blueComponent), 0.75)
        XCTAssertEqual(Double(pixel.greenComponent), Double(pixel.blueComponent), accuracy: 0.05)
    }

    // MARK: - Desktop grid

    /// A settings file written before the desktop grid existed has none of
    func testHoldLocateDefaultsOnForOldData() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "gridHoldLocateEnabled")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: stripped).gridHoldLocateEnabled)
    }

    func testGridLayoutRoundTripsAndOldDataDefaultsToIdentity() throws {
        var settings = AppSettings.default
        settings.gridLayouts = ["A": [5, 2, 3, 4, 1, 6, 7, 8, 9]]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).gridLayouts, settings.gridLayouts)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "gridLayouts")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: stripped).gridLayouts, [:])
    }

    /// its keys: the grid must decode as off, style C and the cream wall, and
    /// the existing theme must still be read.
    func testMissingDesktopGridKeysFallBackToDefaults() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "gridEnabled")
        object.removeValue(forKey: "gridStyle")
        object.removeValue(forKey: "gridBackground")
        object["theme"] = "dark"
        XCTAssertNil(object["gridEnabled"])
        XCTAssertNil(object["gridStyle"])
        XCTAssertNil(object["gridBackground"])

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertFalse(decoded.gridEnabled)
        XCTAssertEqual(decoded.gridStyle, .c)
        XCTAssertEqual(decoded.gridBackground, .cream)
        XCTAssertEqual(decoded.theme, .dark)
    }

    func testDesktopGridSettingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.gridEnabled = true
        settings.gridStyle = .b
        settings.gridBackground = .white
        settings.theme = .light

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.gridEnabled)
        XCTAssertEqual(decoded.gridStyle, .b)
        XCTAssertEqual(decoded.gridBackground, .white)
        XCTAssertEqual(decoded.theme, .light)
    }

    /// A hand-edited settings file can carry a style or background this build
    /// does not know. Each falls back to its default without resetting the
    /// rest of the settings.
    func testUnknownDesktopGridValuesFallBackAndKeepOtherFields() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["gridEnabled"] = true
        object["gridStyle"] = "perspective"
        object["gridBackground"] = "graphite"
        object["theme"] = "light"

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertTrue(decoded.gridEnabled)
        XCTAssertEqual(decoded.gridStyle, .c)
        XCTAssertEqual(decoded.gridBackground, .cream)
        XCTAssertEqual(decoded.theme, .light)
    }

    // MARK: - Window card background

    /// The card behind a window thumbnail followed the system surface colour
    /// before it became adjustable. Storage written then has no key for it, and
    /// must keep following the system colour: freezing the light appearance's
    /// white into a stored value would break the dark appearance on upgrade.
    func testMissingWindowCardBackdropStaysOnSystemColour() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "windowCardBackdrop")
        XCTAssertNil(object["windowCardBackdrop"])

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)
        XCTAssertNil(decoded.windowCardBackdrop.tintColor)
        XCTAssertEqual(decoded.windowCardBackdrop, .followingSystem)
    }

    func testWindowCardBackdropRoundTrip() throws {
        var settings = AppSettings.default
        settings.windowCardBackdrop = WindowCardBackdrop(
            tintColor: Color(red: 0.12, green: 0.45, blue: 0.78)
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let decodedColor = try XCTUnwrap(decoded.windowCardBackdrop.tintColor)
        let rgb = try XCTUnwrap(NSColor(decodedColor).usingColorSpace(.sRGB))
        XCTAssertEqual(Double(rgb.redComponent), 0.12, accuracy: 0.01)
        XCTAssertEqual(Double(rgb.greenComponent), 0.45, accuracy: 0.01)
        XCTAssertEqual(Double(rgb.blueComponent), 0.78, accuracy: 0.01)
    }

    /// The unset value is not a stored white: it resolves the semantic system
    /// surface at draw time, so the light and dark appearances each get their
    /// own colour.
    func testWindowCardBackdropResolvesSystemSurfaceWhenUnset() throws {
        let resolved = try XCTUnwrap(
            NSColor(WindowCardBackdrop.followingSystem.resolvedColor()).usingColorSpace(.sRGB)
        )
        let system = try XCTUnwrap(NSColor.controlBackgroundColor.usingColorSpace(.sRGB))
        XCTAssertEqual(Double(resolved.redComponent), Double(system.redComponent), accuracy: 0.001)
        XCTAssertEqual(Double(resolved.greenComponent), Double(system.greenComponent), accuracy: 0.001)
        XCTAssertEqual(Double(resolved.blueComponent), Double(system.blueComponent), accuracy: 0.001)
    }

    /// The colour is a drawing decision, not just a stored value: the resting
    /// card fill the three preview surfaces share must actually render the
    /// picked colour. This samples the real drawing expression offscreen.
    func testWindowCardBackgroundReachesTheRenderedPixels() throws {
        var settings = AppSettings.default
        settings.windowCardBackdrop = WindowCardBackdrop(
            tintColor: Color(red: 1.0, green: 0.0, blue: 0.0)
        )

        // Opaque cards use a separation of 1 (glass off); the same expression
        // scales by the material's cardOpacity under glass.
        let fill = settings.windowCardFill(opacity: 1)
        let host = NSHostingView(rootView: Color.white.overlay(fill))
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("cannot create a bitmap rep")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let pixel = rep.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB) else {
            XCTFail("cannot read the rendered pixel")
            return
        }

        // SwiftUI composites in a linear-light display space, so pure sRGB red
        // does not land on zero in the other channels; the assertion checks the
        // shape (unmistakably red, nowhere near the white it replaced).
        XCTAssertGreaterThan(Double(pixel.redComponent), 0.90)
        XCTAssertLessThan(Double(pixel.greenComponent), 0.30)
        XCTAssertLessThan(Double(pixel.blueComponent), 0.30)
    }

    /// Text on the card must stay legible whichever colour the user picks: a
    /// dark backing flips the card's semantic colours to the dark scheme and a
    /// light one keeps the light scheme. Following the system colour stores no
    /// scheme — the panel's own already matches that surface.
    func testWindowCardBackdropChoosesContrastingTextScheme() {
        XCTAssertNil(WindowCardBackdrop.followingSystem.textColorScheme)
        XCTAssertEqual(WindowCardBackdrop(tintColor: Color(red: 0.05, green: 0.10, blue: 0.15)).textColorScheme, .dark)
        XCTAssertEqual(WindowCardBackdrop(tintColor: Color(red: 0.95, green: 0.96, blue: 0.90)).textColorScheme, .light)
    }

    /// Card separation still scales the chosen colour, so the existing glass
    /// density slider keeps its meaning instead of being overridden.
    func testWindowCardFillKeepsCardSeparation() throws {
        var settings = AppSettings.default
        settings.windowCardBackdrop = WindowCardBackdrop(
            tintColor: Color(red: 0.0, green: 0.0, blue: 0.0)
        )

        let fill = try XCTUnwrap(NSColor(settings.windowCardFill(opacity: 0.4)).usingColorSpace(.sRGB))
        XCTAssertEqual(Double(fill.alphaComponent), 0.4, accuracy: 0.001)
    }
}
