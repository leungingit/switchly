//
//  WindowMatchRulesTests.swift
//  SwitchlyTests
//
//  Unit tests for the window matching rules used by the switch pipeline.
//
//  These cover the policy that fixes the multi-window switch failure: titles
//  from the Accessibility API and from CoreGraphics are compared with a
//  tolerance for the product/profile suffix apps append, and geometrically
//  identical windows are told apart by z-order correlation instead of by score.
//

import XCTest
import CoreGraphics
@testable import Switchly

final class WindowTitleRulesTests: XCTestCase {

    func testNormalizationTrimsAndLowercases() {
        XCTAssertEqual(WindowTitleRules.normalized("  Hello World  "), "hello world")
        XCTAssertEqual(WindowTitleRules.normalized(""), "")
    }

    func testIdenticalTitlesMatchExactly() {
        XCTAssertEqual(
            WindowTitleRules.matchStrength(axTitle: "Untitled5.ipynb - JupyterLab", cgTitle: "Untitled5.ipynb - JupyterLab"),
            2
        )
        XCTAssertEqual(
            WindowTitleRules.matchStrength(axTitle: "  Viser ", cgTitle: "viser"),
            2
        )
    }

    /// The measured Chrome shape: CG reports the bare tab title, AX appends the
    /// product and profile name.
    func testAccessibilityTitleWithProductSuffixMatches() {
        XCTAssertEqual(
            WindowTitleRules.matchStrength(axTitle: "新标签页 - Google Chrome - alice", cgTitle: "新标签页"),
            1
        )
        XCTAssertEqual(
            WindowTitleRules.matchStrength(axTitle: "Recover Your Apple Account - Apple - Google Chrome - 风起", cgTitle: "Recover Your Apple Account - Apple"),
            1
        )
    }

    func testSuffixMatchAlsoWorksInTheOtherDirection() {
        XCTAssertEqual(
            WindowTitleRules.matchStrength(axTitle: "新标签页", cgTitle: "新标签页 - Google Chrome - alice"),
            1
        )
    }

    /// A shared prefix alone must never be treated as agreement, otherwise a
    /// title-only candidate could win against the correct window.
    func testSharedPrefixWithoutBoundaryDoesNotMatch() {
        XCTAssertEqual(WindowTitleRules.matchStrength(axTitle: "DamageControl", cgTitle: "Damage"), 0)
        XCTAssertEqual(WindowTitleRules.matchStrength(axTitle: "Project - notes", cgTitle: "Project"), 1)
    }

    func testEmptyOrUnrelatedTitlesDoNotMatch() {
        XCTAssertEqual(WindowTitleRules.matchStrength(axTitle: "", cgTitle: "新标签页"), 0)
        XCTAssertEqual(WindowTitleRules.matchStrength(axTitle: "新标签页", cgTitle: ""), 0)
        XCTAssertEqual(WindowTitleRules.matchStrength(axTitle: "", cgTitle: ""), 0)
        XCTAssertEqual(WindowTitleRules.matchStrength(axTitle: "Viser", cgTitle: "Download History"), 0)
    }

    func testExactMatchOutranksSuffixMatch() {
        let exact = WindowTitleRules.score(axTitle: "新标签页", cgTitle: "新标签页")
        let suffix = WindowTitleRules.score(axTitle: "新标签页 - Google Chrome - alice", cgTitle: "新标签页")
        XCTAssertEqual(exact, 40)
        XCTAssertEqual(suffix, 30)
        XCTAssertGreaterThan(exact, suffix)
        XCTAssertEqual(WindowTitleRules.score(axTitle: "Viser", cgTitle: "Downloads"), 0)
    }
}

final class WindowGeometryRulesTests: XCTestCase {

    private let maximized = CGRect(x: 0, y: 0, width: 1920, height: 1050)

    func testSameSizeWithinTolerance() {
        XCTAssertTrue(WindowGeometryRules.isSameSize(maximized, CGRect(x: 0, y: 0, width: 1922, height: 1052)))
        XCTAssertFalse(WindowGeometryRules.isSameSize(maximized, CGRect(x: 0, y: 0, width: 1930, height: 1050)))
    }

    func testSamePositionWithinTolerance() {
        XCTAssertTrue(WindowGeometryRules.isSamePosition(maximized, CGRect(x: 5, y: 5, width: 1920, height: 1050)))
        XCTAssertFalse(WindowGeometryRules.isSamePosition(maximized, CGRect(x: 40, y: 0, width: 1920, height: 1050)))
    }

    /// Geometry classes identify the genuinely ambiguous case: two maximized
    /// windows of one app, which no title or geometry score can separate.
    func testSameClassRequiresBothSizeAndPosition() {
        XCTAssertTrue(WindowGeometryRules.isSameClass(maximized, CGRect(x: 1, y: 1, width: 1921, height: 1051)))
        XCTAssertFalse(WindowGeometryRules.isSameClass(maximized, CGRect(x: 1400, y: 0, width: 1920, height: 1050)))
        XCTAssertFalse(WindowGeometryRules.isSameClass(maximized, CGRect(x: 0, y: 0, width: 960, height: 1050)))
    }
}

final class WindowZOrderPairingTests: XCTestCase {

    func testFrontToBackOrderingKeepsTheIndex() {
        XCTAssertEqual(WindowZOrderPairing.index(inClass: 0, classCount: 2, axIsFrontToBack: true), 0)
        XCTAssertEqual(WindowZOrderPairing.index(inClass: 1, classCount: 2, axIsFrontToBack: true), 1)
    }

    func testReversedOrderingMirrorsTheIndex() {
        XCTAssertEqual(WindowZOrderPairing.index(inClass: 0, classCount: 2, axIsFrontToBack: false), 1)
        XCTAssertEqual(WindowZOrderPairing.index(inClass: 1, classCount: 2, axIsFrontToBack: false), 0)
        XCTAssertEqual(WindowZOrderPairing.index(inClass: 2, classCount: 5, axIsFrontToBack: false), 2)
    }

    func testUnusableCorrelationReturnsNil() {
        XCTAssertNil(WindowZOrderPairing.index(inClass: 0, classCount: 0, axIsFrontToBack: true))
        XCTAssertNil(WindowZOrderPairing.index(inClass: 3, classCount: 3, axIsFrontToBack: true))
        XCTAssertNil(WindowZOrderPairing.index(inClass: -1, classCount: 3, axIsFrontToBack: true))
    }

    /// Two maximized Chrome windows: the second card in the strip must map to
    /// the second window in the Accessibility ordering, whatever direction that
    /// ordering happens to use.
    func testTwoMaximizedWindowsMapToDistinctElements() {
        let front = WindowZOrderPairing.index(inClass: 0, classCount: 2, axIsFrontToBack: true)
        let back = WindowZOrderPairing.index(inClass: 1, classCount: 2, axIsFrontToBack: true)
        XCTAssertNotEqual(front, back)

        let reversedFront = WindowZOrderPairing.index(inClass: 0, classCount: 2, axIsFrontToBack: false)
        let reversedBack = WindowZOrderPairing.index(inClass: 1, classCount: 2, axIsFrontToBack: false)
        XCTAssertNotEqual(reversedFront, reversedBack)
        XCTAssertNotEqual(front, reversedFront)
    }
}
