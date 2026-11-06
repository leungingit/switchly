import Combine
import CoreFoundation
import Foundation

/// 调试面板的数据：插件 console、最近一次渲染 JSON、渲染日志。
///
/// 只在交互式预览（启动器 / dev）里使用，数据全部留在内存，不落盘；
/// 切换插件时清空。视图只读取这里的状态。
@MainActor
final class PreviewDebugModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case console, json, renders
        var id: String { rawValue }
        var title: String {
            switch self {
            case .console: return "Console"
            case .json: return "JSON"
            case .renders: return "Renders"
            }
        }
    }

    struct ConsoleEntry: Identifiable, Equatable {
        let id: Int
        let level: String
        let message: String
        let time: Date
    }

    struct RenderEntry: Identifiable, Equatable {
        let id: Int
        let time: Date
        /// 一次 `render` 往返（含 worker 通信）的耗时，毫秒。
        let durationMs: Double
        let bytes: Int
        /// 输出里第一个 scene 的 key / epoch；没有 scene 时为 nil。
        let sceneKey: String?
        let sceneEpoch: Double?
        /// 失败时的原因；成功为 nil。
        let failure: String?
    }

    /// JSON 树节点的值类型；决定语法高亮颜色。
    enum JSONTreeKind: Equatable {
        case object, array, string, number, boolean, null
    }

    /// JSON 树的一个节点。解析后按深度优先顺序拍平成数组，`id` 即数组下标；
    /// 折叠时按 `subtreeSize` 整段跳过，因此树视图只需渲染可见行。
    struct JSONTreeRow: Identifiable, Equatable {
        let id: Int
        /// 对象成员名；数组元素和根节点为 nil。
        let key: String?
        let kind: JSONTreeKind
        /// 单行展示文本：标量为 JSON 字面量（超长截断），容器为 `{ 3 }` / `[ 2 ]` 汇总。
        let text: String
        /// 完整 JSON 字面量，复制时使用；容器为空串，复制时按子树重建。
        let literal: String
        let depth: Int
        /// 容器的直接子项数量。
        let childCount: Int
        /// 子树行数（含自身），折叠时据此跳过整段。
        var subtreeSize: Int

        var isExpandable: Bool {
            (kind == .object || kind == .array) && childCount > 0
        }
    }

    static let maxConsoleEntries = 500
    static let maxRenderEntries = 200
    static let panelWidth: CGFloat = 380

    /// 单个标量在面板里展示的最大字符数；完整字面量仍保留在 `literal` 里供复制。
    nonisolated static let maxDisplayLength = 240
    /// 默认展开根节点及其直接子节点（前两层）。
    nonisolated static let defaultExpandDepth = 2

    @Published var isVisible = false
    @Published var tab: Tab = .console
    @Published private(set) var console: [ConsoleEntry] = []
    @Published private(set) var renders: [RenderEntry] = []
    @Published private(set) var prettyJSON = ""
    /// 最近一次渲染 JSON 拍平后的树节点；JSON 内容变化时才重建。
    @Published private(set) var jsonRows: [JSONTreeRow] = []
    @Published private(set) var renderCount = 0

    /// 面板显示/隐藏时通知窗口增减宽度，避免挤压模拟 Dock。
    var onVisibilityChange: ((Bool) -> Void)?

    private var nextConsoleID = 0

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        onVisibilityChange?(visible)
    }

    func clear() {
        console = []
        renders = []
        prettyJSON = ""
        jsonRows = []
        renderCount = 0
    }

    func clearConsole() { console = [] }

    func appendConsole(_ lines: [PluginConsoleLine]) {
        guard !lines.isEmpty else { return }
        var next = console
        for line in lines {
            nextConsoleID += 1
            next.append(ConsoleEntry(id: nextConsoleID, level: line.level, message: line.message,
                                     time: Date(timeIntervalSince1970: line.time)))
        }
        if next.count > Self.maxConsoleEntries { next.removeFirst(next.count - Self.maxConsoleEntries) }
        console = next
    }

    /// 记录一次成功渲染，并刷新 JSON 查看器（内容没变时不重设文本，避免滚动位置跳回顶部）。
    func recordRender(json: String, durationMs: Double) {
        renderCount += 1
        let info = Self.sceneInfo(in: json)
        append(RenderEntry(id: renderCount, time: Date(), durationMs: durationMs, bytes: json.utf8.count,
                           sceneKey: info.key, sceneEpoch: info.epoch, failure: nil))
        let pretty = Self.pretty(json)
        if pretty != prettyJSON {
            prettyJSON = pretty
            // 树只随内容变化重建；视图据 `jsonRows` 发布重置展开状态。
            jsonRows = Self.treeRows(fromJSON: json)
        }
    }

    func recordFailure(_ reason: String, durationMs: Double) {
        renderCount += 1
        append(RenderEntry(id: renderCount, time: Date(), durationMs: durationMs, bytes: 0,
                           sceneKey: nil, sceneEpoch: nil, failure: reason))
    }

    private func append(_ entry: RenderEntry) {
        var next = renders
        next.append(entry)
        if next.count > Self.maxRenderEntries { next.removeFirst(next.count - Self.maxRenderEntries) }
        renders = next
    }

    // MARK: - 解析

    nonisolated static func pretty(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8) else { return json }
        return text
    }

    /// 深度优先找第一个 `type == "scene"` 的节点。
    nonisolated static func sceneInfo(in json: String) -> (key: String?, epoch: Double?) {
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return (nil, nil) }
        func find(_ value: Any) -> [String: Any]? {
            if let dict = value as? [String: Any] {
                if dict["type"] as? String == "scene" { return dict }
                for child in dict.values { if let hit = find(child) { return hit } }
            } else if let list = value as? [Any] {
                for child in list { if let hit = find(child) { return hit } }
            }
            return nil
        }
        guard let scene = find(root) else { return (nil, nil) }
        return (scene["key"] as? String, (scene["epoch"] as? NSNumber)?.doubleValue)
    }

    // MARK: - JSON 树

    /// 把 JSON 文本解析成深度优先顺序的扁平节点数组。无法解析时返回空数组，
    /// 由视图退回纯文本展示。对象键按字典序展开，与 `pretty` 的 `.sortedKeys` 一致。
    nonisolated static func treeRows(fromJSON json: String) -> [JSONTreeRow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return []
        }
        var rows: [JSONTreeRow] = []
        // 迭代展开，避免深嵌套 JSON 触发递归深度问题。
        var pending: [(value: Any, key: String?, depth: Int)] = [(root, nil, 0)]
        while let item = pending.popLast() {
            let id = rows.count
            let depth = item.depth
            if item.value is NSNull {
                rows.append(JSONTreeRow(id: id, key: item.key, kind: .null, text: "null", literal: "null",
                                        depth: depth, childCount: 0, subtreeSize: 1))
            } else if let dictionary = item.value as? [String: Any] {
                rows.append(JSONTreeRow(id: id, key: item.key, kind: .object, text: "{ \(dictionary.count) }",
                                        literal: "", depth: depth, childCount: dictionary.count, subtreeSize: 1))
                for childKey in dictionary.keys.sorted().reversed() {
                    pending.append((dictionary[childKey]!, childKey, depth + 1))
                }
            } else if let list = item.value as? [Any] {
                rows.append(JSONTreeRow(id: id, key: item.key, kind: .array, text: "[ \(list.count) ]",
                                        literal: "", depth: depth, childCount: list.count, subtreeSize: 1))
                for child in list.reversed() { pending.append((child, nil, depth + 1)) }
            } else if let string = item.value as? String {
                let literal = jsonStringLiteral(string)
                rows.append(JSONTreeRow(id: id, key: item.key, kind: .string, text: truncated(literal),
                                        literal: literal, depth: depth, childCount: 0, subtreeSize: 1))
            } else if let number = item.value as? NSNumber {
                // Bool 也桥接为 NSNumber，用 CoreFoundation 类型区分 1 与 true。
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    let literal = number.boolValue ? "true" : "false"
                    rows.append(JSONTreeRow(id: id, key: item.key, kind: .boolean, text: literal,
                                            literal: literal, depth: depth, childCount: 0, subtreeSize: 1))
                } else {
                    let literal = number.stringValue
                    rows.append(JSONTreeRow(id: id, key: item.key, kind: .number, text: truncated(literal),
                                            literal: literal, depth: depth, childCount: 0, subtreeSize: 1))
                }
            } else {
                // JSONSerialization 只会产出上述类型；未知值仍保留为一行，避免内容丢失。
                rows.append(JSONTreeRow(id: id, key: item.key, kind: .null, text: "null", literal: "null",
                                        depth: depth, childCount: 0, subtreeSize: 1))
            }
        }
        applySubtreeSizes(&rows)
        return rows
    }

    /// 默认展开根节点及其直接子节点；更深的节点保持折叠，避免上万节点一次性铺开。
    nonisolated static func defaultExpandedIDs(in rows: [JSONTreeRow],
                                               maxDepth: Int = defaultExpandDepth) -> Set<Int> {
        Set(rows.lazy.filter { $0.isExpandable && $0.depth < maxDepth }.map(\.id))
    }

    /// 可见行下标：折叠容器的整段子树被跳过，返回顺序即深度优先展示顺序。
    nonisolated static func visibleRowIndices(_ rows: [JSONTreeRow],
                                              expandedIDs: Set<Int>) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(rows.count)
        var index = 0
        while index < rows.count {
            indices.append(index)
            let row = rows[index]
            if row.isExpandable && !expandedIDs.contains(row.id) {
                index += max(row.subtreeSize, 1)
            } else {
                index += 1
            }
        }
        return indices
    }

    /// 复制某个节点：标量返回完整 JSON 字面量，容器按子树重建紧凑 JSON。
    nonisolated static func copyText(_ rows: [JSONTreeRow], at index: Int) -> String? {
        guard rows.indices.contains(index) else { return nil }
        func serialize(_ index: Int) -> String {
            let row = rows[index]
            guard row.isExpandable else { return row.literal }
            let end = min(index + row.subtreeSize, rows.count)
            var parts: [String] = []
            parts.reserveCapacity(row.childCount)
            var child = index + 1
            while child < end {
                let childRow = rows[child]
                let childText = serialize(child)
                if row.kind == .object, let key = childRow.key {
                    parts.append(jsonStringLiteral(key) + ":" + childText)
                } else {
                    parts.append(childText)
                }
                child += max(childRow.subtreeSize, 1)
            }
            let body = parts.joined(separator: ",")
            return (row.kind == .object ? "{" : "[") + body + (row.kind == .object ? "}" : "]")
        }
        return serialize(index)
    }

    /// JSON 字符串字面量编码（与 JSONSerialization 的转义规则一致，不转义斜杠）。
    nonisolated static func jsonStringLiteral(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out += String(scalar)
                }
            }
        }
        return out + "\""
    }

    private nonisolated static func truncated(_ text: String) -> String {
        guard text.count > maxDisplayLength else { return text }
        return String(text.prefix(maxDisplayLength)) + "…"
    }

    /// 反向扫描深度优先顺序，按 `depth` 闭合祖先，得到每行的子树行数。
    private nonisolated static func applySubtreeSizes(_ rows: inout [JSONTreeRow]) {
        var open: [Int] = []
        for index in rows.indices {
            while let top = open.last, rows[top].depth >= rows[index].depth {
                rows[top].subtreeSize = index - top
                open.removeLast()
            }
            open.append(index)
        }
        for top in open { rows[top].subtreeSize = rows.count - top }
    }
}
