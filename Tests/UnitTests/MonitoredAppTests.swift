//
//  MonitoredAppTests.swift
//  SwitchlyTests
//
//  Unit tests for MonitoredApp model
//

import XCTest
@testable import Switchly

final class MonitoredAppTests: XCTestCase {
    func testMonitoredAppInitialization() {
        let bundleID = "com.test.app"
        let appName = "Test App"
        let shortcutKey = "1"
        
        let app = MonitoredApp(
            bundleIdentifier: bundleID,
            appName: appName,
            shortcutKey: shortcutKey,
            isEnabled: true,
            autoSwitchIfSingle: true
        )
        
        XCTAssertEqual(app.bundleIdentifier, bundleID)
        XCTAssertEqual(app.appName, appName)
        XCTAssertEqual(app.shortcutKey, shortcutKey)
        XCTAssertTrue(app.isEnabled)
        XCTAssertTrue(app.autoSwitchIfSingle)
    }
    
    func testMonitoredAppDefaultValues() {
        let app = MonitoredApp(
            bundleIdentifier: "com.test.app",
            appName: "Test App"
        )
        
        XCTAssertEqual(app.shortcutKey, nil)
        XCTAssertTrue(app.isEnabled)
        XCTAssertTrue(app.autoSwitchIfSingle)
    }
    
    func testMonitoredAppCodable() {
        let app = MonitoredApp(
            bundleIdentifier: "com.test.app",
            appName: "Test App",
            shortcutKey: "1",
            isEnabled: false,
            autoSwitchIfSingle: false
        )
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(app)
            
            let decoder = JSONDecoder()
            let decodedApp = try decoder.decode(MonitoredApp.self, from: data)
            
            XCTAssertEqual(decodedApp.bundleIdentifier, app.bundleIdentifier)
            XCTAssertEqual(decodedApp.appName, app.appName)
            XCTAssertEqual(decodedApp.shortcutKey, app.shortcutKey)
            XCTAssertEqual(decodedApp.isEnabled, app.isEnabled)
            XCTAssertEqual(decodedApp.autoSwitchIfSingle, app.autoSwitchIfSingle)
        } catch {
            XCTFail("Encoding/Decoding failed: \(error)")
        }
    }

    func testInferredShortcutKeyUsesFirstAsciiLetter() {
        XCTAssertEqual(PreferencesViewModel.inferredShortcutKey(for: "VSCode", globalShortcutKey: "p"), "v")
        XCTAssertEqual(PreferencesViewModel.inferredShortcutKey(for: " safari", globalShortcutKey: "p"), "s")
    }

    func testInferredShortcutKeySkipsNonAsciiFirstCharacter() {
        XCTAssertNil(PreferencesViewModel.inferredShortcutKey(for: "小红书", globalShortcutKey: "p"))
        XCTAssertNil(PreferencesViewModel.inferredShortcutKey(for: "1Password", globalShortcutKey: "p"))
    }

    func testInferredShortcutKeySkipsGlobalShortcutConflict() {
        XCTAssertNil(PreferencesViewModel.inferredShortcutKey(for: "Preview", globalShortcutKey: "p"))
    }
}
