//
//  SwitchlyUITests.swift
//  SwitchlyUITests
//
//  Minimal UI test target smoke test.
//

import XCTest

final class SwitchlyUITests: XCTestCase {
    func testApplicationLaunches() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.exists)
    }
}
