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
}
