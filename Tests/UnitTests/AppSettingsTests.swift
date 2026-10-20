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
            defaultWorkspaceWindowSortStrategy: .titleAscending
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
        } catch {
            XCTFail("Encoding/Decoding failed: \(error)")
        }
    }

    // MARK: Usage statistics

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
}
