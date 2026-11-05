import Foundation

/// 调试面板数据模型回归：scene 信息提取、JSON 美化、console 与渲染日志上限、清空。
enum DebugModelTests {
    @MainActor
    static func run() {
        sceneInfoFindsNestedScene()
        consoleIsCappedAndOrdered()
        rendersAreRecordedAndCapped()
        clearResetsEverything()
        jsonTreeParsesStructure()
        jsonTreeVisibleRowsFollowExpansion()
        jsonTreeCopyTextRebuildsValues()
        print("调试面板模型测试通过")
    }

    private static let sceneJSON = """
    [{"slot":"center","node":{"type":"surface","children":[{"type":"scene","key":"idle-sulk","epoch":1700000005.5,"layers":[]}]}}]
    """

    private static func sceneInfoFindsNestedScene() {
        let info = PreviewDebugModel.sceneInfo(in: sceneJSON)
        precondition(info.key == "idle-sulk")
        precondition(info.epoch == 1700000005.5)
        let none = PreviewDebugModel.sceneInfo(in: #"[{"slot":"center","node":{"type":"text"}}]"#)
        precondition(none.key == nil && none.epoch == nil)
        // 非 JSON 原样返回，不崩溃。
        precondition(PreviewDebugModel.pretty("not json") == "not json")
        precondition(PreviewDebugModel.pretty(sceneJSON).contains("\n"))
    }

    @MainActor
    private static func consoleIsCappedAndOrdered() {
        let model = PreviewDebugModel()
        let lines = (0..<(PreviewDebugModel.maxConsoleEntries + 20)).map {
            PluginConsoleLine(level: "log", message: "m\($0)", time: Double($0))
        }
        model.appendConsole(lines)
        precondition(model.console.count == PreviewDebugModel.maxConsoleEntries)
        precondition(model.console.first?.message == "m20")
        precondition(model.console.last?.message == "m\(PreviewDebugModel.maxConsoleEntries + 19)")
        model.appendConsole([])
        precondition(model.console.count == PreviewDebugModel.maxConsoleEntries)
    }

    @MainActor
    private static func rendersAreRecordedAndCapped() {
        let model = PreviewDebugModel()
        model.recordRender(json: sceneJSON, durationMs: 12)
        precondition(model.renders.count == 1 && model.renders[0].sceneKey == "idle-sulk")
        precondition(!model.prettyJSON.isEmpty)
        model.recordFailure("timedOut", durationMs: 2000)
        precondition(model.renders.last?.failure == "timedOut")
        precondition(model.renderCount == 2)
        for _ in 0..<(PreviewDebugModel.maxRenderEntries + 5) { model.recordRender(json: sceneJSON, durationMs: 1) }
        precondition(model.renders.count == PreviewDebugModel.maxRenderEntries)
    }

    @MainActor
    private static func clearResetsEverything() {
        let model = PreviewDebugModel()
        precondition(!model.isVisible, "debug panel defaults to collapsed")
        model.recordRender(json: sceneJSON, durationMs: 1)
        model.appendConsole([PluginConsoleLine(level: "warn", message: "x", time: 0)])
        model.clear()
        precondition(model.console.isEmpty && model.renders.isEmpty && model.prettyJSON.isEmpty && model.renderCount == 0)
        precondition(model.jsonRows.isEmpty)
        var notified: [Bool] = []
        model.onVisibilityChange = { notified.append($0) }
        model.setVisible(true); model.setVisible(true); model.setVisible(false)
        precondition(notified == [true, false])
    }

    /// 对象键按字典序展开，布尔与数字靠 CoreFoundation 类型区分，父子关系正确。
    private static let treeJSON = """
    {"ok":true,"count":3,"name":"Switchly","missing":null,"items":[1,"two"]}
    """

    private static func jsonTreeParsesStructure() {
        let rows = PreviewDebugModel.treeRows(fromJSON: treeJSON)
        precondition(rows.count == 8)
        precondition(rows[0].kind == .object && rows[0].childCount == 5 && rows[0].subtreeSize == 8)
        precondition(rows[1].key == "count" && rows[1].kind == .number && rows[1].literal == "3")
        precondition(rows[2].key == "items" && rows[2].kind == .array)
        precondition(rows[2].subtreeSize == 3 && rows[2].childCount == 2)
        precondition(rows[3].depth == 2 && rows[3].key == nil && rows[3].literal == "1")
        precondition(rows[4].kind == .string && rows[4].literal == "\"two\"")
        precondition(rows[5].kind == .null && rows[5].literal == "null")
        precondition(rows[6].kind == .string && rows[6].literal == "\"Switchly\"")
        precondition(rows[7].kind == .boolean && rows[7].literal == "true")
        // 无法解析的文本不建树，交给视图降级为纯文本。
        precondition(PreviewDebugModel.treeRows(fromJSON: "not json").isEmpty)
        // 空容器是一行且不可展开。
        let empty = PreviewDebugModel.treeRows(fromJSON: "{}")
        precondition(empty.count == 1 && !empty[0].isExpandable && empty[0].text == "{ 0 }")
        // 顶层标量（fragmentsAllowed）也能展示，且超长字符串只截断展示文本。
        let scalar = PreviewDebugModel.treeRows(fromJSON: "\"plain\"")
        precondition(scalar.count == 1 && scalar[0].kind == .string && scalar[0].literal == "\"plain\"")
        let long = String(repeating: "a", count: PreviewDebugModel.maxDisplayLength + 10)
        let longRows = PreviewDebugModel.treeRows(fromJSON: "{\"s\":\"\(long)\"}")
        precondition(longRows[1].text.hasSuffix("…") && longRows[1].literal.count > longRows[1].text.count)
    }

    /// 默认展开前两层；折叠后整段子树从可见行里消失。
    private static func jsonTreeVisibleRowsFollowExpansion() {
        let rows = PreviewDebugModel.treeRows(fromJSON: treeJSON)
        let expanded = PreviewDebugModel.defaultExpandedIDs(in: rows)
        precondition(expanded == [0, 2])
        precondition(PreviewDebugModel.visibleRowIndices(rows, expandedIDs: expanded) == Array(0..<8))
        precondition(PreviewDebugModel.visibleRowIndices(rows, expandedIDs: [0]) == [0, 1, 2, 5, 6, 7])
        precondition(PreviewDebugModel.visibleRowIndices(rows, expandedIDs: []) == [0])
        // 深层容器默认折叠：再把 items 展开时子项回来。
        precondition(PreviewDebugModel.visibleRowIndices(rows, expandedIDs: [0, 2]) == Array(0..<8))
    }

    /// 复制标量返回完整字面量；复制容器按子树重建紧凑 JSON（保持键顺序）。
    private static func jsonTreeCopyTextRebuildsValues() {
        let rows = PreviewDebugModel.treeRows(fromJSON: treeJSON)
        precondition(PreviewDebugModel.copyText(rows, at: 2) == "[1,\"two\"]")
        precondition(PreviewDebugModel.copyText(rows, at: 0)
            == "{\"count\":3,\"items\":[1,\"two\"],\"missing\":null,\"name\":\"Switchly\",\"ok\":true}")
        precondition(PreviewDebugModel.copyText(rows, at: 4) == "\"two\"")
        precondition(PreviewDebugModel.copyText(rows, at: 99) == nil)
        // 字符串转义：换行、引号、反斜杠、控制字符。
        let escaped = PreviewDebugModel.treeRows(fromJSON: #"{"s":"line\nbreak \"q\" tab\t ctrl\u0001 slash\/"}"#)
        precondition(PreviewDebugModel.copyText(escaped, at: 1)
            == "\"line\\nbreak \\\"q\\\" tab\\t ctrl\\u0001 slash/\"")
        precondition(PreviewDebugModel.jsonStringLiteral("a/b") == "\"a/b\"")
    }
}
