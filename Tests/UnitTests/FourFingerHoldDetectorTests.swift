//
//  FourFingerHoldDetectorTests.swift
//  SwitchlyTests
//
//  Synthetic frames for the "four fingers resting" recogniser.
//

import XCTest
import CoreGraphics
@testable import Switchly

final class FourFingerHoldDetectorTests: XCTestCase {

    private func feed(
        _ detector: inout FourFingerHoldDetector,
        fingers: Int,
        from start: TimeInterval,
        to end: TimeInterval,
        at point: CGPoint = CGPoint(x: 50, y: 40)
    ) -> [FourFingerHoldEvent] {
        var events: [FourFingerHoldEvent] = []
        var time = start
        while time <= end {
            if let event = detector.process(fingers: fingers, centroidMM: point, timestamp: time) {
                events.append(event)
            }
            time += 0.01
        }
        return events
    }

    func testStillHoldBeginsAfterOneSecondAndEndsOnLift() {
        var detector = FourFingerHoldDetector()
        XCTAssertTrue(feed(&detector, fingers: 4, from: 0, to: 0.95).isEmpty)
        XCTAssertEqual(feed(&detector, fingers: 4, from: 0.96, to: 1.5), [.began])
        XCTAssertEqual(feed(&detector, fingers: 0, from: 1.51, to: 1.52), [.ended])
    }

    func testDriftBeforeTheDurationCancelsUntilLift() {
        var detector = FourFingerHoldDetector()
        _ = feed(&detector, fingers: 4, from: 0, to: 0.5)
        _ = feed(&detector, fingers: 4, from: 0.51, to: 0.6, at: CGPoint(x: 60, y: 40))
        XCTAssertTrue(feed(&detector, fingers: 4, from: 0.61, to: 2.0, at: CGPoint(x: 50, y: 40)).isEmpty)
        // A fresh touch can hold again.
        _ = feed(&detector, fingers: 0, from: 2.1, to: 2.2)
        XCTAssertEqual(feed(&detector, fingers: 4, from: 3.0, to: 4.1), [.began])
    }

    func testFifthFingerCancelsTheHold() {
        var detector = FourFingerHoldDetector()
        _ = feed(&detector, fingers: 4, from: 0, to: 0.5)
        _ = feed(&detector, fingers: 5, from: 0.51, to: 0.6)
        XCTAssertTrue(feed(&detector, fingers: 4, from: 0.61, to: 2.0).isEmpty)
    }

    func testWobbleAfterTheHoldBeganDoesNotEndIt() {
        var detector = FourFingerHoldDetector()
        XCTAssertEqual(feed(&detector, fingers: 4, from: 0, to: 1.1), [.began])
        let wobble = feed(&detector, fingers: 4, from: 1.11, to: 1.5, at: CGPoint(x: 70, y: 40))
        XCTAssertTrue(wobble.isEmpty)
        XCTAssertEqual(feed(&detector, fingers: 0, from: 1.6, to: 1.61), [.ended])
    }

    func testShortDropoutKeepsTheSession() {
        var detector = FourFingerHoldDetector()
        _ = feed(&detector, fingers: 4, from: 0, to: 0.5)
        _ = feed(&detector, fingers: 3, from: 0.51, to: 0.55)
        XCTAssertEqual(feed(&detector, fingers: 4, from: 0.56, to: 1.2), [.began])
    }

    func testThreeFingersNeverStartAHold() {
        var detector = FourFingerHoldDetector()
        XCTAssertTrue(feed(&detector, fingers: 3, from: 0, to: 3).isEmpty)
    }
}
