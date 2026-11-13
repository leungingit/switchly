import Foundation
import XCTest
@testable import Switchly

final class PluginActivityNodeTests: XCTestCase {
    private let reference = "12345678-1234-1234-1234-123456789abc"

    func testTimelineTraversesContentsAndPreservesTimestampOrder() throws {
        let node = try decodeNode(["type": "timeline", "items": [
            ["timestamp": 12, "content": ["type": "button", "id": "first", "symbol": "clock", "label": "会话"]],
            ["timestamp": 12, "content": ["type": "image", "source": ["activitySnapshot": reference]]]
        ]])
        guard case .timeline(let items) = node else { return XCTFail("Expected timeline") }
        XCTAssertEqual(items.map(\.timestamp), [12, 12])
        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.nodeCount, 3)
        XCTAssertEqual(node.depth, 2)
        XCTAssertEqual(node.actionIDs, ["first"])
        XCTAssertFalse(PluginSurfaceContentValidator.allows(node))
    }

    func testTimelineRejectsInvalidTimestampsAndItemBudget() throws {
        let entry: [String: Any] = ["timestamp": 0, "content": ["type": "text", "value": "会话"]]
        XCTAssertNoThrow(try decodeNode(["type": "timeline", "items": Array(repeating: entry, count: 12)]))
        XCTAssertThrowsError(try decodeNode(["type": "timeline", "items": Array(repeating: entry, count: 13)]))
        XCTAssertThrowsError(try decodeNode(["type": "timeline", "items": [["timestamp": -1, "content": ["type": "spacer"]]]]))
        for invalid in ["NaN", "Infinity", "1e309"] {
            let raw = "{\"type\":\"timeline\",\"items\":[{\"timestamp\":\(invalid),\"content\":{\"type\":\"spacer\"}}]}"
            XCTAssertThrowsError(try JSONDecoder().decode(PluginUINode.self, from: Data(raw.utf8)))
        }
        let duplicate: [String: Any] = ["timestamp": 0, "content": ["type": "button", "id": "same", "symbol": "clock", "label": "会话"]]
        XCTAssertThrowsError(try decodePanel(["type": "timeline", "items": [duplicate, duplicate]]))
    }

    func testLineChartPreservesChronologicalInputAndEnforcesBudgets() throws {
        let points = (0..<64).map { ["label": "\($0):00", "value": Double($0)] as [String: Any] }
        let node = try decodeNode(["type": "lineChart", "items": points])
        guard case .lineChart(let items, let series, let label) = node else { return XCTFail("Expected lineChart") }
        XCTAssertTrue(series.isEmpty)
        XCTAssertNil(label)
        XCTAssertEqual(items.count, 64)
        XCTAssertEqual(items.first?.label, "0:00")
        XCTAssertEqual(items.last?.value, 63)
        XCTAssertFalse(PluginSurfaceContentValidator.allows(node))
        XCTAssertThrowsError(try decodeNode(["type": "lineChart", "items": points + [points[0]]]))
        XCTAssertThrowsError(try decodeNode(["type": "lineChart", "items": [["label": "A", "value": -1]]]))
        XCTAssertThrowsError(try decodeNode(["type": "lineChart", "items": [["label": String(repeating: "中", count: 67), "value": 0]]]))
    }

    func testLineSeriesShareTimeAxisAndRetainIndependentValues() throws {
        let total: [[String: Any]] = [["label": "09:00", "value": 60], ["label": "10:00", "value": 30]]
        let app: [String: Any] = ["label": "编辑器", "items": [["label": "09:00", "value": 40], ["label": "10:00", "value": 0]]]
        let node = try decodeNode(["type": "lineChart", "label": "汇总", "items": total, "series": [app]])
        guard case .lineChart(let items, let series, let label) = node else { return XCTFail("Expected lineChart") }
        XCTAssertEqual(label, "汇总")
        XCTAssertEqual(items.map(\.value), [60, 30])
        XCTAssertEqual(series.first?.items.map(\.value), [40, 0])
        XCTAssertEqual(series.first?.label, "编辑器")
        XCTAssertFalse(PluginSurfaceContentValidator.allows(node))
        for invalid in [
            ["label": "应用", "items": [["label": "09:00", "value": 1]]],
            ["label": "应用", "items": [["label": "10:00", "value": 1], ["label": "09:00", "value": 0]]],
            ["label": "应用", "items": [["label": "09:00", "value": -1], ["label": "10:00", "value": 0]]],
            ["label": "", "items": total]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try decodeNode(["type": "lineChart", "label": "汇总", "items": total, "series": [invalid]]))
        }
        XCTAssertThrowsError(try decodeNode(["type": "lineChart", "items": total, "series": [app]]))
        _ = try decodeNode(["type": "lineChart", "label": "汇总", "items": total, "series": Array(repeating: app, count: 6)])
        XCTAssertThrowsError(try decodeNode(["type": "lineChart", "label": "汇总", "items": total, "series": Array(repeating: app, count: 7)]))
    }

    func testPanelSlotDecodesOpaqueActivitySnapshotReference() throws {
        let content = try decodePanel([
            "type": "image",
            "source": ["activitySnapshot": reference],
            "size": "m"
        ])

        XCTAssertEqual(content.slot, .panel)
        guard case .image(.activitySnapshot(let decoded), _, _) = content.node else {
            return XCTFail("Expected activity snapshot image")
        }
        XCTAssertEqual(decoded, reference)
        XCTAssertFalse(content.node.usesArtwork)
    }

    func testActivitySnapshotRejectsNonUUIDAndOverlongReferences() throws {
        let invalid = [
            "not-a-uuid",
            "/tmp/private.png",
            reference + String(repeating: "x", count: 201)
        ]
        for value in invalid {
            XCTAssertThrowsError(try decodeNode([
                "type": "image",
                "source": ["activitySnapshot": value]
            ]), value)
        }
    }

    func testSegmentedDecodeAndBounds() throws {
        let options = ["A", "B", "C", "D", "E", "F"]
        let node = try decodeNode([
            "type": "segmented",
            "id": "mode",
            "options": options,
            "selected": 5
        ])
        guard case .segmented(let id, let decodedOptions, let selected) = node else {
            return XCTFail("Expected segmented node")
        }
        XCTAssertEqual(id, "mode")
        XCTAssertEqual(decodedOptions, options)
        XCTAssertEqual(selected, 5)
        XCTAssertEqual(node.actionIDs, ["mode"])

        let tooMany = options + ["G"]
        for invalid in [
            ["type": "segmented", "id": "mode", "options": tooMany, "selected": 0] as [String: Any],
            ["type": "segmented", "id": "mode", "options": options, "selected": -1],
            ["type": "segmented", "id": "mode", "options": options, "selected": options.count]
        ] {
            XCTAssertThrowsError(try decodeNode(invalid))
        }
    }

    func testDateRangeDecodeBoundsAndActionIDs() throws {
        let day = 86_400.0
        let node = try decodeNode([
            "type": "dateRange",
            "id": "activity",
            "from": 0.0,
            "to": day * 400,
            "label": "Activity period"
        ])
        guard case .dateRange(let id, let from, let to, let label) = node else {
            return XCTFail("Expected dateRange node")
        }
        XCTAssertEqual(id, "activity")
        XCTAssertEqual(from, 0)
        XCTAssertEqual(to, day * 400)
        XCTAssertEqual(label, "Activity period")
        XCTAssertEqual(node.actionIDs, ["activity.from", "activity.to"])

        let invalid = [
            ["type": "dateRange", "id": "d", "from": 1.0, "to": 1.0, "label": "L"] as [String: Any],
            ["type": "dateRange", "id": "d", "from": 2.0, "to": 1.0, "label": "L"],
            ["type": "dateRange", "id": "d", "from": 0.0, "to": day * 400 + 1, "label": "L"]
        ]
        for value in invalid {
            XCTAssertThrowsError(try decodeNode(value))
        }

        for value in ["NaN", "Infinity", "-Infinity", "1e309", "-1e309"] {
            let json = """
            {"type":"dateRange","id":"d","from":\(value),"to":86400,"label":"L"}
            """
            XCTAssertThrowsError(try JSONDecoder().decode(
                PluginUINode.self,
                from: Data(json.utf8)
            ), value)
        }
    }

    func testDuplicateDateActionIDsAreRejectedGlobally() throws {
        let node: [String: Any] = [
            "type": "vstack",
            "children": [
                ["type": "dateRange", "id": "range", "from": 0, "to": 1, "label": "L"],
                ["type": "dateRange", "id": "range", "from": 0, "to": 1, "label": "L"]
            ]
        ]
        XCTAssertThrowsError(try decodePanel(node)) {
            XCTAssertEqual(
                $0 as? PluginRenderOutput.ValidationError,
                .duplicateActionID("range.from")
            )
        }
    }

    func testBarChartDecodeAndBounds() throws {
        let items = barItems(count: 12)
        let node = try decodeNode([
            "type": "barChart",
            "items": items
        ])
        guard case .barChart(let decoded) = node else {
            return XCTFail("Expected barChart node")
        }
        XCTAssertEqual(decoded.count, 12)
        XCTAssertEqual(decoded.first, PluginBarItem(label: "Item 1", value: 1))

        XCTAssertThrowsError(try decodeNode([
            "type": "barChart",
            "items": barItems(count: 13)
        ]))
        XCTAssertThrowsError(try decodeNode([
            "type": "barChart",
            "items": [["label": "Negative", "value": -1]]
        ]))
        XCTAssertNoThrow(try decodeNode([
            "type": "barChart",
            "items": [["label": String(repeating: "x", count: 200), "value": 0]]
        ]))
        XCTAssertThrowsError(try decodeNode([
            "type": "barChart",
            "items": [["label": String(repeating: "x", count: 201), "value": 1]]
        ]))

        for value in ["1e309", "-1e309"] {
            let json = """
            {"type":"barChart","items":[{"label":"N","value":\(value)}]}
            """
            XCTAssertThrowsError(try JSONDecoder().decode(
                PluginUINode.self,
                from: Data(json.utf8)
            ), value)
        }
    }

    func testGridBoundsAndActionIDsCountNestedChildren() throws {
        let children = (1...6).map { index in
            [
                "type": "segmented",
                "id": "choice\(index)",
                "options": ["A", "B"],
                "selected": 0
            ] as [String: Any]
        }
        let node = try decodeNode([
            "type": "grid",
            "children": children
        ])
        guard case .grid(let decodedChildren) = node else {
            return XCTFail("Expected grid node")
        }
        XCTAssertEqual(decodedChildren.count, 6)
        XCTAssertEqual(node.actionIDs, (1...6).map { "choice\($0)" })
        XCTAssertEqual(node.nodeCount, 7)

        XCTAssertThrowsError(try decodeNode([
            "type": "grid",
            "children": children + [
                ["type": "spacer"]
            ]
        ]))
    }

    func testNodeAndDepthBudgetsRemainUnchanged() throws {
        let textChildren = (1...63).map { index in
            ["type": "text", "value": "\(index)"] as [String: Any]
        }
        let atNodeLimit = try decodePanel([
            "type": "vstack",
            "children": textChildren
        ])
        XCTAssertEqual(atNodeLimit.node.nodeCount, PluginRenderOutput.maxNodes)

        let overNodeLimit: [String: Any] = [
            "type": "vstack",
            "children": textChildren + [["type": "spacer"]]
        ]
        XCTAssertThrowsError(try decodePanel(overNodeLimit)) {
            XCTAssertEqual($0 as? PluginRenderOutput.ValidationError, .tooManyNodes)
        }

        XCTAssertNoThrow(try decodePanel(chainJSON(depth: PluginRenderOutput.maxDepth)))
        XCTAssertThrowsError(try decodePanel(chainJSON(depth: PluginRenderOutput.maxDepth + 1))) {
            XCTAssertEqual($0 as? PluginRenderOutput.ValidationError, .tooDeep)
        }
    }

    func testScene3DSurfaceRejectsPanelOnlyNodesAndActivityImages() throws {
        let panelOnlyNodes = [
            [
                "type": "segmented",
                "id": "mode",
                "options": ["A", "B"],
                "selected": 0
            ] as [String: Any],
            ["type": "dateRange", "id": "range", "from": 0, "to": 1, "label": "L"],
            ["type": "barChart", "items": [["label": "Bar", "value": 1]]],
            ["type": "lineChart", "items": [["label": "Hour", "value": 1]]],
            ["type": "timeline", "items": [["timestamp": 0, "content": ["type": "text", "value": "会话"]]]],
            ["type": "grid", "children": [["type": "spacer"]]]
        ]
        for value in panelOnlyNodes {
            let node = try decodeNode(value)
            XCTAssertThrowsError(try PluginSurfaceContentValidator.validate(node), "\(value)")
        }

        let activityImage = try decodeNode([
            "type": "image",
            "source": ["activitySnapshot": reference]
        ])
        XCTAssertThrowsError(try PluginSurfaceContentValidator.validate(activityImage))
    }

    private func decodeNode(_ object: [String: Any]) throws -> PluginUINode {
        try JSONDecoder().decode(
            PluginUINode.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
    }

    private func decodePanel(_ node: [String: Any]) throws -> PluginSlotContent {
        let data = try JSONSerialization.data(withJSONObject: [
            ["slot": "panel", "node": node]
        ])
        guard let content = try PluginRenderOutput.decode(json: data).first else {
            throw TestError.expectedPanelContent
        }
        return content
    }

    private func barItems(count: Int) -> [[String: Any]] {
        (1...count).map {
            ["label": "Item \($0)", "value": Double($0)]
        }
    }

    private func chainJSON(depth: Int) -> [String: Any] {
        precondition(depth >= 1)
        return (1..<depth).reduce(["type": "spacer"] as [String: Any]) { child, _ in
            ["type": "zstack", "children": [child]]
        }
    }

    private enum TestError: Error {
        case expectedPanelContent
    }
}
