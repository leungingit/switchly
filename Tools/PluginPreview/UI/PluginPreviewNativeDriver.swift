import AppKit

/// 原生输入驱动：经进程内可访问树（与 VoiceOver 相同的 NSAccessibility 路径）按标签定位控件并 press。
/// 它证明控件有可理解的标签、禁用状态正确，且点击经 SwiftUI 回调进入动作路由；
/// 不等同于系统级鼠标事件，也不替代真实 Dock/AX 验收。
///
/// SwiftUI 的 AccessibilityNode 不声明遵循 NSAccessibilityProtocol（Swift `as?` 失败），
/// 但响应同名 ObjC 选择器，因此统一通过选择器访问。
@MainActor
enum PluginPreviewNativeDriver {
    enum Outcome: Equatable {
        case pressed
        case disabled
        case notFound
        case ambiguous
        case pressFailed
    }

    static let maxNodes = 5_000
    static let maxDepth = 64

    static func press(label: String, in root: NSView) -> Outcome {
        var matches: [NSObject] = []
        var visited = 0
        collect(label: label, node: root, depth: 0, visited: &visited, into: &matches)
        guard let first = matches.first else { return .notFound }
        guard matches.count == 1 else { return .ambiguous }
        guard boolValue(first, "isAccessibilityEnabled") ?? true else { return .disabled }
        return boolValue(first, "accessibilityPerformPress") == true ? .pressed : .pressFailed
    }

    private static func collect(label: String, node: NSObject, depth: Int, visited: inout Int, into matches: inout [NSObject]) {
        guard depth <= maxDepth, visited < maxNodes else { return }
        visited += 1
        if let text = stringValue(node, "accessibilityLabel"), text == label { matches.append(node) }
        guard node.responds(to: Selector(("accessibilityChildren"))),
              let children = node.value(forKey: "accessibilityChildren") as? [Any] else { return }
        for child in children {
            if let object = child as? NSObject {
                collect(label: label, node: object, depth: depth + 1, visited: &visited, into: &matches)
            }
        }
    }

    private static func stringValue(_ node: NSObject, _ selector: String) -> String? {
        guard node.responds(to: Selector((selector))) else { return nil }
        return node.value(forKey: selector) as? String
    }

    /// 调用返回 BOOL 的无参 ObjC 方法；对象不响应时返回 nil。
    private static func boolValue(_ node: NSObject, _ selector: String) -> Bool? {
        let sel = Selector((selector))
        guard node.responds(to: sel), let imp = node.method(for: sel) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Function.self)(node, sel)
    }
}
