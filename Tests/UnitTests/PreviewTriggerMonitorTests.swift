//
//  PreviewTriggerMonitorTests.swift
//  SwitchlyTests
//
//  Headless tests for the pointer-trigger pieces that are pure functions:
//  the shake classifier (zig-zag detection) and the hotspot zone geometry.
//  The monitor itself is wired to NSEvent and PreviewPanel, so it is covered
//  by these through its inputs rather than by faking the window server.
//

import XCTest
@testable import Switchly

final class PreviewTriggerMonitorTests: XCTestCase {

    // MARK: ShakeGestureClassifier

    /// Three fast reversals of enough amplitude: the gesture fires. The
    /// first leg only establishes the direction (from rest), so a full
    /// gesture is five legs.
    func testShakeFiresOnThreeReversals() {
        var classifier = ShakeGestureClassifier(window: 0.7,
                                                reversalAmplitude: 30,
                                                reversalsToTrigger: 3)
        var time: TimeInterval = 0
        var x: CGFloat = 500
        var fired = false

        // right (establishes), then left, right, left, right -- each leg
        // >= the amplitude
        for delta in [CGFloat(40), -40, 40, -40, 40] {
            x += delta
            time += 0.05
            fired = classifier.add(location: NSPoint(x: x, y: 300), time: time)
        }

        XCTAssertTrue(fired, "a deliberate zig-zag must trigger")
    }

    /// Vertical wiggles are shakes too -- the dominant axis wins.
    func testShakeFiresOnVerticalWiggle() {
        var classifier = ShakeGestureClassifier(window: 0.7,
                                                reversalAmplitude: 30,
                                                reversalsToTrigger: 3)
        var time: TimeInterval = 0
        var y: CGFloat = 300
        var fired = false

        for delta in [CGFloat(45), -45, 45, -45, 45] {
            y += delta
            time += 0.06
            fired = classifier.add(location: NSPoint(x: 500, y: y), time: time)
        }

        XCTAssertTrue(fired)
    }

    /// Sustained travel in one direction has no reversals and never fires.
    func testFastSingleDirectionTravelDoesNotFire() {
        var classifier = ShakeGestureClassifier(window: 0.7,
                                                reversalAmplitude: 30,
                                                reversalsToTrigger: 3)
        var x: CGFloat = 100

        for index in 0..<30 {
            x += 35
            XCTAssertFalse(classifier.add(location: NSPoint(x: x, y: 300),
                                          time: TimeInterval(index) * 0.02),
                           "one-direction flings must not trigger (at step \(index))")
        }
    }

    /// Sub-amplitude jitter (hand tremor, precise pointing) never
    /// establishes a direction, so it cannot accumulate reversals.
    func testSubAmplitudeJitterDoesNotFire() {
        var classifier = ShakeGestureClassifier(window: 0.7,
                                                reversalAmplitude: 30,
                                                reversalsToTrigger: 3)
        var time: TimeInterval = 0

        for index in 0..<100 {
            let x = 500 + CGFloat(index % 2 == 0 ? 10 : -10)
            time += 0.01
            XCTAssertFalse(classifier.add(location: NSPoint(x: x, y: 300), time: time),
                           "jitter must not trigger (at step \(index))")
        }
    }

    /// Reversals older than the window do not count toward the gesture, so
    /// three slow wiggles spread over seconds stay silent.
    func testReversalsOutsideTheWindowDoNotCombine() {
        var classifier = ShakeGestureClassifier(window: 0.7,
                                                reversalAmplitude: 30,
                                                reversalsToTrigger: 3)
        var time: TimeInterval = 0
        var x: CGFloat = 500

        // One wiggle now, one after 1s, one after 2s -- each pair of
        // reversals is long gone by the time the next lands.
        for _ in 0..<6 {
            x += 40
            time += 0.1
            classifier.add(location: NSPoint(x: x, y: 300), time: time)
            x -= 40
            time += 1.0
            let fired = classifier.add(location: NSPoint(x: x, y: 300), time: time)
            XCTAssertFalse(fired, "isolated wiggles must not trigger")
        }
    }

    /// After a trigger the state is spent: the residual movement of the same
    /// gesture cannot immediately re-trigger. The monitor also applies a
    /// cooldown; the reset here is what keeps the classifier itself honest.
    func testClassifierResetClearsState() {
        var classifier = ShakeGestureClassifier(window: 0.7,
                                                reversalAmplitude: 30,
                                                reversalsToTrigger: 3)
        var time: TimeInterval = 0
        var x: CGFloat = 500
        var fired = false
        for delta in [CGFloat(40), -40, 40, -40, 40] {
            x += delta
            time += 0.05
            fired = classifier.add(location: NSPoint(x: x, y: 300), time: time)
        }
        XCTAssertTrue(fired)

        classifier.reset()
        var firedAgain = false
        for delta in [CGFloat(40), -40, 40] {
            x += delta
            time += 0.05
            firedAgain = classifier.add(location: NSPoint(x: x, y: 300), time: time)
        }
        XCTAssertFalse(firedAgain, "after a reset the gesture must start from zero")
    }

    // MARK: PreviewHotspotZone

    private let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testTopEdgeZoneCoversTheMiddleStretchOfTheTop() {
        let zone = PreviewHotspotZone.zone(screenFrame: screenFrame, edge: .top)
        // Middle of the top edge, within the 8pt depth.
        XCTAssertTrue(zone.contains(NSPoint(x: 720, y: 899)))
        XCTAssertTrue(zone.contains(NSPoint(x: 720, y: 893)))
        // The middle band spans 40% of the width: [432, 1008) on a 1440pt screen.
        XCTAssertTrue(zone.contains(NSPoint(x: 500, y: 899)))
        XCTAssertTrue(zone.contains(NSPoint(x: 1007, y: 899)))
        XCTAssertFalse(zone.contains(NSPoint(x: 431, y: 899)),
                       "the corners must stay free for the menu bar and hot corners")
        XCTAssertFalse(zone.contains(NSPoint(x: 1009, y: 899)))
        // Depth cutoff: below 8pt from the edge is not the hotspot.
        XCTAssertFalse(zone.contains(NSPoint(x: 720, y: 880)))
    }

    func testLeftEdgeZoneCoversTheMiddleStretchOfTheLeft() {
        let zone = PreviewHotspotZone.zone(screenFrame: screenFrame, edge: .left)
        XCTAssertTrue(zone.contains(NSPoint(x: 1, y: 450)))
        XCTAssertTrue(zone.contains(NSPoint(x: 7, y: 450)))
        // The band spans 40% of the height, centered vertically.
        XCTAssertTrue(zone.contains(NSPoint(x: 1, y: 629)))
        XCTAssertFalse(zone.contains(NSPoint(x: 1, y: 100)),
                       "the ends of the edge must stay free")
        XCTAssertFalse(zone.contains(NSPoint(x: 40, y: 450)),
                       "only the strip against the edge is the hotspot")
    }

    func testRightEdgeZoneCoversTheMiddleStretchOfTheRight() {
        let zone = PreviewHotspotZone.zone(screenFrame: screenFrame, edge: .right)
        XCTAssertTrue(zone.contains(NSPoint(x: 1439, y: 450)))
        XCTAssertTrue(zone.contains(NSPoint(x: 1433, y: 450)))
        XCTAssertFalse(zone.contains(NSPoint(x: 1400, y: 450)))
        XCTAssertFalse(zone.contains(NSPoint(x: 1439, y: 880)))
    }

    /// A cursor slammed into the bezel reports the exact edge coordinate;
    /// the zone must still contain it.
    func testExactEdgeCoordinatesAreInsideTheZone() {
        XCTAssertTrue(PreviewHotspotZone.contains(NSPoint(x: 720, y: 900),
                                                  screenFrames: [screenFrame],
                                                  edge: .top))
        XCTAssertTrue(PreviewHotspotZone.contains(NSPoint(x: 0, y: 450),
                                                  screenFrames: [screenFrame],
                                                  edge: .left))
        XCTAssertTrue(PreviewHotspotZone.contains(NSPoint(x: 1440, y: 450),
                                                  screenFrames: [screenFrame],
                                                  edge: .right))
    }

    /// contains() walks every screen, so each display carries its own zone.
    func testContainsChecksEveryScreen() {
        let screens = [screenFrame,
                       CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        XCTAssertTrue(PreviewHotspotZone.contains(NSPoint(x: 720, y: 900),
                                                  screenFrames: screens,
                                                  edge: .top))
        XCTAssertTrue(PreviewHotspotZone.contains(NSPoint(x: 2400, y: 1080),
                                                  screenFrames: screens,
                                                  edge: .top))
    }
}
