//
//  SystemGestureInterceptorTests.swift
//  SwitchlyTests
//

import XCTest
@testable import Switchly

final class SystemGestureInterceptorTests: XCTestCase {
    func testSwipesAreSuppressed() {
        XCTAssertTrue(SystemGestureInterceptor.shouldSuppress(gestureKind: 1))
        XCTAssertTrue(SystemGestureInterceptor.shouldSuppress(gestureKind: 2))
    }

    func testPinchAndSpreadPassThrough() {
        XCTAssertFalse(SystemGestureInterceptor.shouldSuppress(gestureKind: 3))
        XCTAssertFalse(SystemGestureInterceptor.shouldSuppress(gestureKind: 0))
    }
}
