import XCTest
@testable import Switchly

final class Scene3DPointerClassifierTests: XCTestCase {
    func testPointerBelowThresholdIsClickAtDownPoint() {
        var classifier = Scene3DPointerClassifier()
        classifier.down(at: CGPoint(x: 10, y: 10))
        classifier.moved(to: CGPoint(x: 13, y: 10))
        let outcome = classifier.up(at: CGPoint(x: 13, y: 10))
        XCTAssertEqual(outcome, .click(CGPoint(x: 10, y: 10)))
    }

    func testPointerAtThresholdBecomesDrag() {
        var classifier = Scene3DPointerClassifier()
        classifier.down(at: .zero)
        XCTAssertTrue(classifier.moved(to: CGPoint(x: Scene3DPointerClassifier.dragThreshold, y: 0)))
        let outcome = classifier.up(at: CGPoint(x: Scene3DPointerClassifier.dragThreshold, y: 0))
        XCTAssertEqual(outcome, .drag)
    }

    func testPointerUpFarFromDownIsDragEvenWithoutMovedEvents() {
        var classifier = Scene3DPointerClassifier()
        classifier.down(at: .zero)
        let outcome = classifier.up(at: CGPoint(x: 40, y: 30))
        XCTAssertEqual(outcome, .drag)
    }

    func testDiagonalDistanceUsesEuclideanLength() {
        var below = Scene3DPointerClassifier()
        below.down(at: .zero)
        XCTAssertFalse(below.moved(to: CGPoint(x: 2, y: 2))) // 2.83 pt

        var above = Scene3DPointerClassifier()
        above.down(at: .zero)
        XCTAssertTrue(above.moved(to: CGPoint(x: 3, y: 3))) // 4.24 pt
    }

    func testCancelClearsGesture() {
        var classifier = Scene3DPointerClassifier()
        classifier.down(at: .zero)
        XCTAssertTrue(classifier.cancel())
        XCTAssertFalse(classifier.isDown)
        XCTAssertEqual(classifier.up(at: CGPoint(x: 100, y: 100)), .none)
    }
}
