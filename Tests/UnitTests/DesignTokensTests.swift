import XCTest
@testable import Switchly

final class DesignTokensTests: XCTestCase {

    func testGridIsThreeByThree() {
        XCTAssertEqual(DesignTokens.Grid.columnFractions.count, 3)
        XCTAssertEqual(DesignTokens.Grid.rowFractions.count, 3)
    }

    func testCentreCellDominates() {
        let cols = DesignTokens.Grid.columnFractions
        let rows = DesignTokens.Grid.rowFractions
        XCTAssertGreaterThan(cols[1], max(cols[0], cols[2]))
        XCTAssertGreaterThan(rows[1], max(rows[0], rows[2]))
    }

    func testOverviewScaleShrinksButStaysReadable() {
        XCTAssertLessThan(DesignTokens.Grid.overviewScale, 1)
        XCTAssertGreaterThan(DesignTokens.Grid.overviewScale, 0.5)
    }

    func testTargetScaleIsSubtle() {
        XCTAssertGreaterThan(DesignTokens.Grid.targetScale, 1)
        XCTAssertLessThanOrEqual(DesignTokens.Grid.targetScale, 1.05)
    }
}
