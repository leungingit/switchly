//
//  WindowInfoTests.swift
//  SwitchlyTests
//
//  Unit tests for WindowInfo model
//

import XCTest
import CoreGraphics
@testable import Switchly

final class WindowInfoTests: XCTestCase {
    func testOffSpaceWindowIsNotMinimizedAndStateSurvivesCoding() throws {
        let window = WindowInfo(id: 12, ownerPID: 34, ownerName: "App", windowTitle: "Other desktop",
                                bounds: .zero, isOnCurrentSpace: false, windowNumber: 12,
                                isMinimized: false, isHidden: true, isOnOtherSpace: true)
        let decoded = try JSONDecoder().decode(WindowInfo.self, from: JSONEncoder().encode(window))
        XCTAssertFalse(decoded.isMinimized)
        XCTAssertFalse(decoded.canPerformWindowActions)
        XCTAssertEqual(decoded.statusLocalizationKey, "Window is hidden")
        XCTAssertTrue(decoded.isHidden)
        XCTAssertTrue(decoded.isOnOtherSpace)
        XCTAssertFalse(decoded.isOnCurrentSpace)
    }

    func testLegacyOffscreenWindowDecodesWithPreviousMinimizedMeaning() throws {
        let window = WindowInfo(id: 12, ownerPID: 34, ownerName: "App", windowTitle: "Legacy",
                                bounds: .zero, isOnCurrentSpace: false, windowNumber: 12)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(window)) as? [String: Any])
        for key in ["isMinimized", "isHidden", "isOnOtherSpace"] { data.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(WindowInfo.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertTrue(decoded.isMinimized)
        XCTAssertFalse(decoded.isOnOtherSpace)
    }

    func testWindowInfoInitialization() {
        let windowID: CGWindowID = 123
        let ownerPID: pid_t = 456
        let ownerName = "Test App"
        let windowTitle = "Test Window"
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let isOnCurrentSpace = true
        let windowNumber = 123
        
        let window = WindowInfo(
            id: windowID,
            ownerPID: ownerPID,
            ownerName: ownerName,
            windowTitle: windowTitle,
            bounds: bounds,
            isOnCurrentSpace: isOnCurrentSpace,
            windowNumber: windowNumber
        )
        
        XCTAssertEqual(window.id, windowID)
        XCTAssertEqual(window.ownerPID, ownerPID)
        XCTAssertEqual(window.ownerName, ownerName)
        XCTAssertEqual(window.windowTitle, windowTitle)
        XCTAssertEqual(window.bounds, bounds)
        XCTAssertEqual(window.isOnCurrentSpace, isOnCurrentSpace)
        XCTAssertEqual(window.windowNumber, windowNumber)
    }
    
    func testDisplayName() {
        let windowWithTitle = WindowInfo(
            id: 1,
            ownerPID: 456,
            ownerName: "Test App",
            windowTitle: "Test Window",
            bounds: .zero,
            isOnCurrentSpace: true,
            windowNumber: 1
        )
        
        let windowWithoutTitle = WindowInfo(
            id: 2,
            ownerPID: 456,
            ownerName: "Test App",
            windowTitle: "",
            bounds: .zero,
            isOnCurrentSpace: true,
            windowNumber: 2
        )
        
        XCTAssertEqual(windowWithTitle.displayName, "Test Window")
        XCTAssertEqual(windowWithoutTitle.displayName, "Test App")
    }
    
    func testWindowInfoEquality() {
        let window1 = WindowInfo(
            id: 1,
            ownerPID: 456,
            ownerName: "App 1",
            windowTitle: "Window 1",
            bounds: .zero,
            isOnCurrentSpace: true,
            windowNumber: 1
        )
        
        let window2 = WindowInfo(
            id: 1,
            ownerPID: 789,
            ownerName: "App 2",
            windowTitle: "Window 2",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            isOnCurrentSpace: false,
            windowNumber: 2
        )
        
        let window3 = WindowInfo(
            id: 2,
            ownerPID: 456,
            ownerName: "App 1",
            windowTitle: "Window 1",
            bounds: .zero,
            isOnCurrentSpace: true,
            windowNumber: 1
        )
        
        XCTAssertEqual(window1, window2)
        XCTAssertNotEqual(window1, window3)
    }
    
    func testWindowInfoHashable() {
        let window1 = WindowInfo(
            id: 1,
            ownerPID: 456,
            ownerName: "Test",
            windowTitle: "",
            bounds: .zero,
            isOnCurrentSpace: true,
            windowNumber: 1
        )
        
        let window2 = WindowInfo(
            id: 1,
            ownerPID: 456,
            ownerName: "Test",
            windowTitle: "",
            bounds: .zero,
            isOnCurrentSpace: true,
            windowNumber: 1
        )
        
        var set = Set<WindowInfo>()
        set.insert(window1)
        set.insert(window2)
        
        XCTAssertEqual(set.count, 1)
    }
}
