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

    // MARK: - Spin

    func testSpinTurnsOneFullRevolutionThenSettles() {
        var camera = Scene3DCameraController(initialPose: .init(yaw: -20, pitch: -8))
        XCTAssertTrue(camera.beginSpin(.right, degrees: 360, duration: 1))
        XCTAssertFalse(camera.isSettled)

        // 中途确实在转动。
        camera.advance(by: 0.25)
        XCTAssertNotEqual(camera.pose.yaw, -20)

        // 走完整个时长后回到起点并稳定，俯仰角不受影响。
        for _ in 0..<10 { camera.advance(by: 0.1) }
        XCTAssertTrue(camera.isSettled)
        XCTAssertEqual(camera.pose.yaw, -20, accuracy: 1e-6)
        XCTAssertEqual(camera.pose.pitch, -8)
    }

    func testSpinLeftAndRightMoveInOppositeDirections() {
        var right = Scene3DCameraController()
        var left = Scene3DCameraController()
        right.beginSpin(.right, degrees: 90, duration: 1)
        left.beginSpin(.left, degrees: 90, duration: 1)
        right.advance(by: 1)
        left.advance(by: 1)
        XCTAssertEqual(right.pose.yaw, 90, accuracy: 1e-6)
        XCTAssertEqual(left.pose.yaw, -90, accuracy: 1e-6)
    }

    func testSpinIsIgnoredWhenHorizontalRotationIsDisabled() {
        var camera = Scene3DCameraController(limits: .init(horizontal: false, vertical: true))
        XCTAssertFalse(camera.beginSpin(.right))
        XCTAssertFalse(camera.turn(.right))
        XCTAssertTrue(camera.isSettled)
        XCTAssertEqual(camera.pose.yaw, 0)
    }

    func testStopInertiaCancelsSpinAndKeepsCurrentPose() {
        var camera = Scene3DCameraController()
        camera.beginSpin(.right, degrees: 360, duration: 1)
        camera.advance(by: 0.3)
        let yaw = camera.pose.yaw
        camera.stopInertia()
        XCTAssertTrue(camera.isSettled)
        XCTAssertEqual(camera.pose.yaw, yaw)
    }

    func testTurnJumpsWithoutAnimation() {
        var camera = Scene3DCameraController()
        XCTAssertTrue(camera.turn(.right))
        XCTAssertEqual(camera.pose.yaw, 90)
        XCTAssertTrue(camera.isSettled)
    }
}
