//
//  SettingsServiceTests.swift
//  SwitchlyTests
//
//  Unit tests for SettingsService
//

import XCTest
@testable import Switchly

final class SettingsServiceTests: XCTestCase {
    var settingsService: SettingsService!
    private let suiteName = "com.switchly.tests.SettingsServiceTests"
    
    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        settingsService = SettingsService(defaults: defaults)
    }
    
    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }
    
    func testLoadDefaultSettings() {
        let settings = settingsService.loadSettings()
        XCTAssertEqual(settings, AppSettings.default)
    }
    
    func testSaveAndLoadSettings() {
        var settings = AppSettings.default
        settings.launchAtLogin = true
        settings.thumbnailSize = .large
        
        do {
            try settingsService.saveSettings(settings)
            let loadedSettings = settingsService.loadSettings()
            XCTAssertEqual(loadedSettings.launchAtLogin, true)
            XCTAssertEqual(loadedSettings.thumbnailSize, .large)
        } catch {
            XCTFail("Save failed: \(error)")
        }
    }
    
    /// The decoded-settings cache must never serve a stale value after a
    /// save: `loadSettings` sits on hot paths (monitor ticks, card captures)
    /// and observers read settings immediately after the change notification.
    func testCacheReflectsSavesImmediately() {
        var settings = AppSettings.default
        settings.thumbnailSize = .small
        try? settingsService.saveSettings(settings)
        XCTAssertEqual(settingsService.loadSettings().thumbnailSize, .small)
        
        settings.thumbnailSize = .large
        try? settingsService.saveSettings(settings)
        XCTAssertEqual(settingsService.loadSettings().thumbnailSize, .large)
    }
    
    /// The cache is per-instance: a fresh service (new app launch) still reads
    /// what was persisted, not another instance's memory.
    func testFreshInstanceStillReadsWhatWasPersisted() {
        var settings = AppSettings.default
        settings.launchAtLogin = true
        try? settingsService.saveSettings(settings)
        
        let freshDefaults = UserDefaults(suiteName: suiteName)!
        let freshService = SettingsService(defaults: freshDefaults)
        XCTAssertTrue(freshService.loadSettings().launchAtLogin)
    }
    func testSharedAppearanceSurvivesFreshService() throws {
        var settings = AppSettings.default
        settings.theme = .dark
        settings.crystalMaterial.glassStyle = .transparent
        settings.crystalMaterial.sharedDensity = 0.12
        settings.crystalMaterial.cardOpacity = 0
        settings.crystalMaterial.panelTintCap = 0
        try settingsService.saveSettings(settings)
        let fresh = SettingsService(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(fresh.loadSettings(), settings)
        XCTAssertEqual(fresh.loadSettings().panelGlassDensity, 0.12)
        XCTAssertEqual(fresh.loadSettings().windowGlassDensity, 0.12)
    }


    /// The desktop grid axes ride the existing settings blob: saving them
    /// persists every field, posts the one change notification the running
    /// consumers already observe, and a fresh instance reads them back.
    func testGridSettingsPersistAndNotify() {
        var settings = AppSettings.default
        settings.gridEnabled = true
        settings.gridStyle = .b
        settings.gridBackground = .white

        let notified = expectation(forNotification: .settingsDidChange, object: nil)
        XCTAssertNoThrow(try settingsService.saveSettings(settings))
        wait(for: [notified], timeout: 1)

        let freshDefaults = UserDefaults(suiteName: suiteName)!
        let freshService = SettingsService(defaults: freshDefaults)
        let loaded = freshService.loadSettings()
        XCTAssertTrue(loaded.gridEnabled)
        XCTAssertEqual(loaded.gridStyle, .b)
        XCTAssertEqual(loaded.gridBackground, .white)
    }
}
