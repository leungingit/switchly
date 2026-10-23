import XCTest
@testable import Switchly

final class MotionTokensTests: XCTestCase {

    func testGridTraceIsAmbientLoop() {
        XCTAssertEqual(MotionTokens.gridTraceDuration, 2.4)
        XCTAssertGreaterThan(MotionTokens.gridTraceDuration, MotionTokens.workspaceSwitchDuration)
    }

    func testAnimatedFollowsReduceMotion() {
        let result = MotionTokens.animated(.linear(duration: MotionTokens.gridTraceDuration))
        if MotionTokens.reduceMotion {
            XCTAssertNil(result)
        } else {
            XCTAssertNotNil(result)
        }
    }
}
