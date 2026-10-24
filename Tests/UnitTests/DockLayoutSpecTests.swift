//
//  DockLayoutSpecTests.swift
//  SwitchlyTests
//

import XCTest
@testable import Switchly

final class DockLayoutSpecTests: XCTestCase {
    private let screen = CGSize(width: 1440, height: 900)

    func testHorizontalMatchesHistoricalSizing() {
        // 3 cards at width 120: 3 * 132 + 2 * 10 + 24 wide; 40 + 20 + (75 + 38) high.
        let size = DockPanelMetrics.panelSize(spec: DockPreviewLayout.horizontal.spec, count: 3, cardWidth: 120, visibleSize: screen)
        XCTAssertEqual(size.width, 440)
        XCTAssertEqual(size.height, 173)
    }

    func testHorizontalClampsToScreenWidth() {
        let size = DockPanelMetrics.panelSize(spec: DockPreviewLayout.horizontal.spec, count: 40, cardWidth: 120, visibleSize: screen)
        XCTAssertEqual(size.width, screen.width - DockPanelMetrics.screenMargin)
    }

    func testVerticalStacksOneColumnAndClampsHeight() {
        let spec = DockPreviewLayout.vertical.spec
        let few = DockPanelMetrics.panelSize(spec: spec, count: 2, cardWidth: 120, visibleSize: screen)
        XCTAssertEqual(few.width, 132 + 24)
        XCTAssertEqual(few.height, 40 + 2 * 113 + 10 + 20)
        let many = DockPanelMetrics.panelSize(spec: spec, count: 40, cardWidth: 120, visibleSize: screen)
        XCTAssertEqual(many.height, screen.height - DockPanelMetrics.screenMargin)
    }

    func testGridWrapsIntoColumns() {
        let spec = DockPreviewLayout.grid.spec
        XCTAssertEqual(spec.columns(for: 2), 2)
        XCTAssertEqual(spec.columns(for: 7), DockLayoutSpec.gridColumns)
        let size = DockPanelMetrics.panelSize(spec: spec, count: 7, cardWidth: 120, visibleSize: screen)
        XCTAssertEqual(size.width, 3 * 132 + 2 * 10 + 24)
        XCTAssertEqual(size.height, 40 + 3 * 113 + 2 * 10 + 20)
    }

    func testEmptyUsesFixedWidth() {
        let size = DockPanelMetrics.panelSize(spec: DockPreviewLayout.grid.spec, count: 0, cardWidth: 120, visibleSize: screen)
        XCTAssertEqual(size.width, DockPanelMetrics.emptyWidth)
    }

    func testLayoutDecodesWithOldAndUnknownValues() throws {
        XCTAssertEqual(AppSettings.default.dockPreviewLayout, .horizontal)
        let data = try JSONEncoder().encode(AppSettings.default)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "dockPreviewLayout")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.dockPreviewLayout, .horizontal)
        json["dockPreviewLayout"] = "future-layout"
        let unknown = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(unknown.dockPreviewLayout, .horizontal)
        json["dockPreviewLayout"] = "grid"
        let grid = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(grid.dockPreviewLayout, .grid)
    }
}
