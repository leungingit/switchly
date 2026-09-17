//
//  AppSettingsTests.swift
//  SwitchlyTests
//
//  Unit tests for AppSettings model
//

import XCTest
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
}
