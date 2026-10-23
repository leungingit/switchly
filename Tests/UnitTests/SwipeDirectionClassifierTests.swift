//
//  SwipeDirectionClassifierTests.swift
//  SwitchlyTests
//
//  Synthetic trajectories for the eight-direction recogniser: directions,
//  diagonal bias, dropout tolerance, cooldown and one-shot sessions.
//  No trackpad and no private framework involved.
//

import XCTest
import CoreGraphics
@testable import Switchly

final class SwipeDirectionClassifierTests: XCTestCase {

    private let start = CGPoint(x: 60, y: 40)

    private func move(_ dx: Double, _ dy: Double) -> CGPoint {
        CGPoint(x: start.x + dx, y: start.y + dy)
    }

    /// Feeds a complete gesture: four fingers at the start, one frame at the
    /// offset, then a lift so the next call starts a fresh session.
    private func swipe(
        _ classifier: inout SwipeDirectionClassifier,
        dx: Double,
        dy: Double,
        at time: TimeInterval = 1.0
    ) -> SwipeEvent? {
        _ = classifier.process(fingers: 4, centroidMM: start, timestamp: time)
        let event = classifier.process(fingers: 4, centroidMM: move(dx, dy), timestamp: time + 0.05)
        _ = classifier.process(fingers: 0, centroidMM: .zero, timestamp: time + 0.10)
        return event
    }

    private func direction(_ dx: Double, _ dy: Double) -> SwipeDirection? {
        var classifier = SwipeDirectionClassifier()
        guard case .fired(let gesture)? = swipe(&classifier, dx: dx, dy: dy) else { return nil }
        return gesture.direction
    }

    // MARK: - Directions

    func testAllEightDirectionsFromSyntheticTrajectories() {
        XCTAssertEqual(direction(20, 0), .right)
        XCTAssertEqual(direction(14, 14), .upRight)
        XCTAssertEqual(direction(0, 20), .up)
        XCTAssertEqual(direction(-14, 14), .upLeft)
        XCTAssertEqual(direction(-20, 0), .left)
        XCTAssertEqual(direction(-14, -14), .downLeft)
        XCTAssertEqual(direction(0, -20), .down)
        XCTAssertEqual(direction(14, -14), .downRight)
    }

    func testSectorBoundariesSplitAtTwentyTwoAndAHalfDegrees() {
        XCTAssertEqual(SwipeDirectionClassifier.direction(forAngleDegrees: 22.4), .right)
        XCTAssertEqual(SwipeDirectionClassifier.direction(forAngleDegrees: 22.6), .upRight)
        XCTAssertEqual(SwipeDirectionClassifier.direction(forAngleDegrees: 337.5), .right)
        XCTAssertEqual(SwipeDirectionClassifier.direction(forAngleDegrees: -1), .right)
        XCTAssertEqual(SwipeDirectionClassifier.direction(forAngleDegrees: 270), .down)
    }

    func testDiagonalBiasWidensDiagonalSectors() {
        // A 5° bias makes the diagonal half-width 27.5° and the axis half-width
        // 17.5°: 20° is axial without the bias and diagonal with it.
        XCTAssertEqual(SwipeDirectionClassifier.direction(forAngleDegrees: 20), .right)
        XCTAssertEqual(
            SwipeDirectionClassifier.direction(forAngleDegrees: 20, diagonalBias: 5),
            .upRight
        )
        XCTAssertEqual(
            SwipeDirectionClassifier.direction(forAngleDegrees: 15, diagonalBias: 5),
            .right
        )
    }

    // MARK: - Threshold

    func testBelowThresholdDoesNotFire() {
        var classifier = SwipeDirectionClassifier()
        XCTAssertNil(swipe(&classifier, dx: 8, dy: 0))
        XCTAssertFalse(classifier.isInSession, "the lift after a short move ends the session")
    }

    func testThreeFingersNeverStartASession() {
        var classifier = SwipeDirectionClassifier()
        XCTAssertNil(classifier.process(fingers: 3, centroidMM: start, timestamp: 1))
        XCTAssertFalse(classifier.isInSession)
    }

    func testSessionFiresOnlyOnce() {
        var classifier = SwipeDirectionClassifier()
        _ = classifier.process(fingers: 4, centroidMM: start, timestamp: 1)
        XCTAssertNotNil(classifier.process(fingers: 4, centroidMM: move(20, 0), timestamp: 1.05))
        XCTAssertNil(
            classifier.process(fingers: 4, centroidMM: move(40, 0), timestamp: 1.10),
            "A single session must not emit a second gesture"
        )
    }

    // MARK: - Dropout and cooldown

    func testShortFingerDropoutIsTolerated() {
        var classifier = SwipeDirectionClassifier()
        _ = classifier.process(fingers: 4, centroidMM: start, timestamp: 1)
        // One frame at three fingers, then back to four within 80 ms.
        XCTAssertNil(classifier.process(fingers: 3, centroidMM: start, timestamp: 1.02))
        XCTAssertTrue(classifier.isInSession)
        guard case .fired(let gesture)? = classifier.process(
            fingers: 4,
            centroidMM: move(20, 0),
            timestamp: 1.04
        ) else {
            return XCTFail("session should survive a short dropout")
        }
        XCTAssertEqual(gesture.direction, .right)
    }

    func testDropoutBeyondEightyMillisecondsEndsTheSession() {
        var classifier = SwipeDirectionClassifier()
        _ = classifier.process(fingers: 4, centroidMM: start, timestamp: 1)
        _ = classifier.process(fingers: 3, centroidMM: start, timestamp: 1.02)
        XCTAssertNil(classifier.process(fingers: 3, centroidMM: start, timestamp: 1.12))
        XCTAssertFalse(classifier.isInSession)
    }

    func testLiftEndsTheSessionImmediately() {
        var classifier = SwipeDirectionClassifier()
        _ = classifier.process(fingers: 4, centroidMM: start, timestamp: 1)
        _ = classifier.process(fingers: 0, centroidMM: .zero, timestamp: 1.03)
        XCTAssertFalse(classifier.isInSession)
    }

    func testCooldownSuppressesTheNextSwipeWithoutExtendingIt() {
        var classifier = SwipeDirectionClassifier()
        guard case .fired? = swipe(&classifier, dx: 20, dy: 0, at: 1.0) else {
            return XCTFail("first swipe should fire")
        }
        // 100 ms later: still cooling down.
        guard case .suppressed(let gesture)? = swipe(&classifier, dx: -20, dy: 0, at: 1.1) else {
            return XCTFail("second swipe inside the cooldown should be reported as suppressed")
        }
        XCTAssertEqual(gesture.direction, .left)

        // 400 ms after the first: the cooldown expired, so it fires again.
        guard case .fired? = swipe(&classifier, dx: 0, dy: 20, at: 1.4) else {
            return XCTFail("swipe after the cooldown should fire")
        }
    }

    func testSuppressedSessionDoesNotRestartTheCooldown() {
        var classifier = SwipeDirectionClassifier()
        guard case .fired? = swipe(&classifier, dx: 20, dy: 0, at: 1.0) else {
            return XCTFail("first swipe should fire")
        }
        guard case .suppressed? = swipe(&classifier, dx: 20, dy: 0, at: 1.2) else {
            return XCTFail("expected suppression")
        }
        // The cooldown from the 1.05 s firing ends at 1.40 s. The suppressed
        // session fired at 1.25 s; had it extended the cooldown it would now
        // run to 1.60 s and this swipe would be suppressed again.
        guard case .fired? = swipe(&classifier, dx: 0, dy: 20, at: 1.45) else {
            return XCTFail("suppressed swipes must not extend the cooldown")
        }
    }

    // MARK: - Geometry

    func testCentroidConversionUsesPhysicalSurfaceSize() {
        let size = CGSize(width: 124.8, height: 76.8)
        let point = SwipeDirectionClassifier.centroidMM(
            normalized: CGPoint(x: 0.5, y: 0.25),
            surfaceSizeMM: size
        )
        XCTAssertEqual(point.x, 62.4, accuracy: 0.001)
        XCTAssertEqual(point.y, 19.2, accuracy: 0.001)
    }

    func testDiagonalStepsMapToGridNeighbours() {
        XCTAssertEqual(SwipeDirection.upRight.columnDelta, 1)
        XCTAssertEqual(SwipeDirection.upRight.rowDelta, -1)
        XCTAssertEqual(SwipeDirection.downLeft.columnDelta, -1)
        XCTAssertEqual(SwipeDirection.downLeft.rowDelta, 1)
        XCTAssertEqual(SwipeDirection.left.columnDelta, -1)
        XCTAssertEqual(SwipeDirection.left.rowDelta, 0)
        XCTAssertEqual(SwipeDirection.up.columnDelta, 0)
        XCTAssertEqual(SwipeDirection.up.rowDelta, -1)
    }

    func testDefaultsMatchTheLedger() {
        XCTAssertEqual(SwipeDefaults.minimumFingers, 4)
        XCTAssertEqual(SwipeDefaults.thresholdMM, 12)
        XCTAssertEqual(SwipeDefaults.dropoutMS, 80)
        XCTAssertEqual(SwipeDefaults.cooldownMS, 350)
    }
}
