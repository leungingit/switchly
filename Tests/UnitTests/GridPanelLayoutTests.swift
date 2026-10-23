//
//  GridPanelLayoutTests.swift
//  SwitchlyTests
//
//  Multi-display and boundary geometry for the overview and the HUD (T23).
//
//  Everything here is a pure function over fabricated rectangles: a second
//  display, mixed scale, a Dock on the left and a tiny screen all reduce to
//  "which visible frame is the target" and "what frame fits inside it".
//

import XCTest
import CoreGraphics
@testable import Switchly

final class GridPanelLayoutTests: XCTestCase {

    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let secondaryRight = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    private let secondaryAbove = CGRect(x: 0, y: 900, width: 1440, height: 900)
    private let laptopSmall = CGRect(x: 0, y: 0, width: 1152, height: 720)

    // MARK: - Target screen

    func testPointerInsideAScreenPicksThatScreen() {
        XCTAssertEqual(
            GridPanelLayout.screenIndex(containing: CGPoint(x: 200, y: 200), frames: [primary, secondaryRight]),
            0
        )
        XCTAssertEqual(
            GridPanelLayout.screenIndex(containing: CGPoint(x: 2000, y: 400), frames: [primary, secondaryRight]),
            1
        )
    }

    /// The menu bar strip sits above `visibleFrame`, so the pointer is often
    /// outside every frame. The nearest screen must win instead of the primary.
    func testPointerInTheMenuBarStripUsesTheNearestScreen() {
        let index = GridPanelLayout.screenIndex(
            containing: CGPoint(x: 2500, y: 1085),
            frames: [primary, secondaryRight]
        )
        XCTAssertEqual(index, 1)
    }

    /// A negative-origin display (a second screen to the left) must resolve
    /// correctly instead of being treated as "no screen".
    func testNegativeOriginScreenIsFound() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            GridPanelLayout.screenIndex(containing: CGPoint(x: -500, y: 300), frames: [primary, left]),
            1
        )
    }

    func testNoScreensFallsBackToTheGivenIndex() {
        XCTAssertEqual(
            GridPanelLayout.screenIndex(containing: .zero, frames: [], fallback: 0),
            0
        )
    }

    // MARK: - Overview, style C

    func testStyleCFillsTheVisibleFrameOnEveryScreen() {
        for frame in [primary, secondaryRight, secondaryAbove, laptopSmall] {
            XCTAssertEqual(
                GridPanelLayout.overviewFrame(style: .c, visibleFrame: frame),
                frame
            )
        }
    }

    /// Style C must never exceed the visible frame — a full-screen panel that
    /// runs under the menu bar or the Dock is a defect (spec §4).
    func testStyleCNeverExceedsAVisibleFrameWithAMenuBarAndDock() {
        let visible = CGRect(x: 0, y: 60, width: 1440, height: 815) // Dock 60pt, menu bar 25pt
        let frame = GridPanelLayout.overviewFrame(style: .c, visibleFrame: visible)
        XCTAssertEqual(frame, visible)
    }

    // MARK: - Overview, style B

    func testStyleBIsCentredAndCapped() {
        let frame = GridPanelLayout.overviewFrame(
            style: .b,
            visibleFrame: secondaryRight,
            margin: 48
        )
        XCTAssertLessThanOrEqual(frame.width, DesignTokens.Grid.styleBMaxWidth)
        XCTAssertLessThanOrEqual(frame.height, DesignTokens.Grid.styleBMaxHeight)
        XCTAssertEqual(frame.midX, secondaryRight.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, secondaryRight.midY, accuracy: 0.5)
    }

    func testStyleBFitsASmallScreenAndKeepsItsMargin() {
        let frame = GridPanelLayout.overviewFrame(style: .b, visibleFrame: laptopSmall, margin: 48)
        XCTAssertLessThanOrEqual(frame.width, laptopSmall.width - 96 + 0.5)
        XCTAssertLessThanOrEqual(frame.height, laptopSmall.height - 96 + 0.5)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(laptopSmall.contains(frame), "style B must stay inside the visible frame")
    }

    func testStyleBOnASecondDisplayStaysOnThatDisplay() {
        let frame = GridPanelLayout.overviewFrame(style: .b, visibleFrame: secondaryAbove, margin: 48)
        XCTAssertTrue(secondaryAbove.contains(frame))
    }

    func testDegenerateVisibleFrameProducesNoFrame() {
        XCTAssertEqual(
            GridPanelLayout.overviewFrame(style: .b, visibleFrame: .zero),
            .zero
        )
        XCTAssertEqual(
            GridPanelLayout.overviewFrame(style: .c, visibleFrame: .zero),
            .zero
        )
    }

    // MARK: - HUD

    func testHUDSitsAtTheTopCentreAndInsideTheScreen() {
        let frame = GridPanelLayout.hudFrame(
            visibleFrame: primary,
            fittingSize: CGSize(width: 420, height: 96)
        )
        XCTAssertEqual(frame.midX, primary.midX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, primary.maxY - DesignTokens.Spacing.xl * 2, accuracy: 0.5)
        XCTAssertTrue(primary.contains(frame))
    }

    func testHUDIsCappedAtItsIdealWidthOnAWideScreen() {
        let frame = GridPanelLayout.hudFrame(
            visibleFrame: secondaryRight,
            fittingSize: CGSize(width: 5000, height: 96)
        )
        XCTAssertEqual(frame.width, DesignTokens.Grid.HUD.maxWidth, accuracy: 0.5)
        XCTAssertTrue(secondaryRight.contains(frame))
    }

    func testHUDShrinksOnANarrowScreenInsteadOfOverflowing() {
        let narrow = CGRect(x: 0, y: 0, width: 420, height: 600)
        let frame = GridPanelLayout.hudFrame(
            visibleFrame: narrow,
            fittingSize: CGSize(width: 520, height: 96)
        )
        XCTAssertLessThanOrEqual(frame.width, narrow.width - DesignTokens.Spacing.xl * 2 + 0.5)
        XCTAssertTrue(narrow.contains(frame))
    }

    func testHUDFitsOnAShortScreenWithoutNegativeHeight() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 120)
        let frame = GridPanelLayout.hudFrame(
            visibleFrame: short,
            fittingSize: CGSize(width: 420, height: 300)
        )
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertLessThanOrEqual(frame.height, short.height)
    }

    func testHUDOnEveryScreenStaysInsideIt() {
        for visible in [primary, secondaryRight, secondaryAbove, laptopSmall] {
            let frame = GridPanelLayout.hudFrame(
                visibleFrame: visible,
                fittingSize: CGSize(width: 520, height: 120)
            )
            XCTAssertTrue(
                visible.contains(frame),
                "HUD \(frame) left \(visible)"
            )
        }
    }
}
