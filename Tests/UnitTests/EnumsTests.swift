//
//  EnumsTests.swift
//  SwitchlyTests
//
//  Unit tests for enumerations
//

import XCTest
@testable import Switchly

final class EnumsTests: XCTestCase {
    func testPreviewStrategy() {
        XCTAssertEqual(PreviewStrategy.allApplications.displayName, "Preview All Windows")
        XCTAssertEqual(PreviewStrategy.configuredOnly.displayName, "Only Configured Apps")
        
        XCTAssertEqual(PreviewStrategy.allApplications.systemImageName, "square.stack.3d.up")
        XCTAssertEqual(PreviewStrategy.configuredOnly.systemImageName, "target")
    }
    
    func testThumbnailSize() {
        XCTAssertEqual(ThumbnailSize.small.displayName, "Small")
        XCTAssertEqual(ThumbnailSize.medium.displayName, "Medium")
        XCTAssertEqual(ThumbnailSize.large.displayName, "Large")
        
        XCTAssertEqual(ThumbnailSize.small.dimensions.width, 160)
        XCTAssertEqual(ThumbnailSize.small.dimensions.height, 100)
        XCTAssertEqual(ThumbnailSize.medium.dimensions.width, 200)
        XCTAssertEqual(ThumbnailSize.large.dimensions.width, 240)
    }
    
    func testMonitorFrequency() {
        XCTAssertEqual(MonitorFrequency.highPerformance.interval, 1.0)
        XCTAssertEqual(MonitorFrequency.balanced.interval, 2.0)
        XCTAssertEqual(MonitorFrequency.powerSaving.interval, 5.0)
    }
    
    func testNotificationStrategy() {
        XCTAssertEqual(NotificationStrategy.intelligent.displayName, "Intelligent Notifications")
        XCTAssertEqual(NotificationStrategy.all.displayName, "All Notifications")
        XCTAssertEqual(NotificationStrategy.silent.displayName, "Silent Mode")
    }
    
    func testShortcutPrefix() {
        XCTAssertEqual(ShortcutPrefix.commandOption.displayName, "⌘⌥")
        XCTAssertEqual(ShortcutPrefix.commandControl.displayName, "⌘⌃")
        XCTAssertEqual(ShortcutPrefix.controlOption.displayName, "⌃⌥")
        XCTAssertEqual(ShortcutPrefix.commandShift.displayName, "⌘⇧")
        XCTAssertEqual(ShortcutPrefix.commandOptionShift.displayName, "⌘⌥⇧")
    }
}
