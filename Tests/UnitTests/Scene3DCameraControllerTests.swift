import XCTest
@testable import Switchly

final class Scene3DCameraControllerTests: XCTestCase {
    func testPitchClampsToDeclaredLimits() {
        var camera = Scene3DCameraController(
            limits: .init(horizontal: true, vertical: true, pitchMin: -10, pitchMax: 20)
        )
        camera.drag(by: CGVector(dx: 0, dy: -100))
        XCTAssertEqual(camera.pose.pitch, 20)
        camera.drag(by: CGVector(dx: 0, dy: 200))
        XCTAssertEqual(camera.pose.pitch, -10)
    }

    func testReversedPitchLimitsAreNormalised() {
        let limits = Scene3DCameraController.Limits(pitchMin: 30, pitchMax: -30)
        XCTAssertEqual(limits.pitchMin, -30)
        XCTAssertEqual(limits.pitchMax, 30)
    }

    func testDisabledAxesIgnoreTheirDelta() {
        var camera = Scene3DCameraController(limits: .init(horizontal: false, vertical: true))
        XCTAssertFalse(camera.drag(by: CGVector(dx: 10, dy: 0)))
        XCTAssertEqual(camera.pose, .init())

        var verticalOff = Scene3DCameraController(limits: .init(horizontal: true, vertical: false))
        verticalOff.drag(by: CGVector(dx: 10, dy: 10))
        XCTAssertEqual(verticalOff.pose.pitch, 0)
        XCTAssertNotEqual(verticalOff.pose.yaw, 0)
    }

    func testYawWrapsAcrossHalfTurn() {
        var camera = Scene3DCameraController(tuning: .init(degreesPerPoint: 100))
        camera.drag(by: CGVector(dx: 2, dy: 0)) // +200°
        XCTAssertEqual(camera.pose.yaw, -160)
        camera.drag(by: CGVector(dx: -5, dy: 0)) // -500° from -160 → 60
        XCTAssertEqual(camera.pose.yaw, 60)
    }

    func testInertiaMovesThenSettles() {
        var camera = Scene3DCameraController()
        camera.drag(by: CGVector(dx: 10, dy: 0))
        let afterDrag = camera.pose.yaw
        XCTAssertFalse(camera.isSettled)
        XCTAssertTrue(camera.advance(by: 0.016))
        XCTAssertGreaterThan(camera.pose.yaw, afterDrag)

        var frames = 0
        while camera.advance(by: 1.0 / 60) {
            frames += 1
            if frames > 1000 { break }
        }
        XCTAssertTrue(camera.isSettled)
        XCTAssertLessThan(frames, 1000)
    }

    func testReduceMotionDropsInertiaButKeepsDraggedPose() {
        var camera = Scene3DCameraController()
        camera.drag(by: CGVector(dx: 12, dy: 0))
        let draggedPose = camera.pose
        camera.endDrag(reduceMotion: true)
        XCTAssertEqual(camera.pose, draggedPose)
        XCTAssertTrue(camera.isSettled)
        XCTAssertFalse(camera.advance(by: 0.016))
    }

    func testResetReturnsToInitialPose() {
        var camera = Scene3DCameraController(initialPose: .init(yaw: 30, pitch: -12))
        camera.drag(by: CGVector(dx: 40, dy: 20))
        XCTAssertTrue(camera.reset())
        XCTAssertEqual(camera.pose, .init(yaw: 30, pitch: -12))
        XCTAssertTrue(camera.isSettled)
        XCTAssertFalse(camera.reset())
    }

    func testCameraPositionFollowsPose() {
        let front = Scene3DCameraController.Geometry.worldPosition(for: .init(), distance: 4)
        XCTAssertEqual(front.z, 4)
        let right = Scene3DCameraController.Geometry.worldPosition(for: .init(yaw: 90), distance: 4)
        XCTAssertEqual(right.x, 4, accuracy: 0.001)
    }
}
