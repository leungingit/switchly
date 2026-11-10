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

    /// 坐标从截图表面左上角转换到窗口，再让 AppKit hitTest 决定目标。
    /// 只适配已有 SceneKit 鼠标处理，不对 SwiftUI 控件猜测 action，也不投递全局事件。
    static func pointer(from start: PluginPreviewPoint, to end: PluginPreviewPoint?, in window: NSWindow,
                        checkIsolation: () throws -> Void) async throws {
        guard let root = window.contentView else { throw PluginPreviewStepFailure(code: "window-unavailable") }
        func location(_ point: PluginPreviewPoint) throws -> NSPoint {
            guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
                  point.x < root.bounds.width, point.y < root.bounds.height else {
                throw PluginPreviewStepFailure(code: "point-out-of-bounds")
            }
            let local = NSPoint(x: root.bounds.minX + point.x,
                                y: root.isFlipped ? root.bounds.minY + point.y : root.bounds.maxY - point.y)
            return root.convert(local, to: nil)
        }
        let first = try location(start)
        let last = try end.map(location) ?? first
        let rootPoint = root.convert(first, from: nil)
        guard let target = root.hitTest(root.convert(rootPoint, to: root.superview)) as? PluginScene3DPointerView else {
            throw PluginPreviewStepFailure(code: "pointer-target-unsupported")
        }
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: end == nil ? 1 : 0, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw PluginPreviewStepFailure(code: "pointer-event-unavailable")
            }
            return event
        }
        try checkIsolation()
        target.mouseDown(with: try event(.leftMouseDown, at: first))
        do {
            if end != nil {
                for index in 1...8 {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    try checkIsolation()
                    let progress = CGFloat(index) / 8
                    let point = NSPoint(x: first.x + (last.x - first.x) * progress,
                                        y: first.y + (last.y - first.y) * progress)
                    target.mouseDragged(with: try event(.leftMouseDragged, at: point))
                }
            }
            try checkIsolation()
            target.mouseUp(with: try event(.leftMouseUp, at: last))
        } catch {
            // 取消手势走原视图的既有路径，避免半截拖动留在输入会话里。
            if let cancel = try? event(.rightMouseDown, at: first) { target.rightMouseDown(with: cancel) }
            throw error
        }
    }

    static func press(label: String, in root: NSView) -> Outcome {
        var matches: [NSObject] = []
        var visited = 0
        collect(label: label, node: root, depth: 0, visited: &visited, into: &matches)
        guard let first = matches.first else { return .notFound }
        guard matches.count == 1 else { return .ambiguous }
        guard boolValue(first, #selector(NSAccessibilityProtocol.isAccessibilityEnabled)) ?? true else { return .disabled }
        return boolValue(first, #selector(NSAccessibilityProtocol.accessibilityPerformPress)) == true ? .pressed : .pressFailed
    }

    private static func collect(label: String, node: NSObject, depth: Int, visited: inout Int, into matches: inout [NSObject]) {
        guard depth <= maxDepth, visited < maxNodes else { return }
        visited += 1
        if let text = stringValue(node, #selector(NSAccessibilityProtocol.accessibilityLabel), key: "accessibilityLabel"),
           text == label { matches.append(node) }
        guard node.responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren)),
              let children = node.value(forKey: "accessibilityChildren") as? [Any] else { return }
        for child in children {
            if let object = child as? NSObject {
                collect(label: label, node: object, depth: depth + 1, visited: &visited, into: &matches)
            }
        }
    }

    private static func stringValue(_ node: NSObject, _ selector: Selector, key: String) -> String? {
        guard node.responds(to: selector) else { return nil }
        return node.value(forKey: key) as? String
    }

    /// 调用返回 BOOL 的无参 ObjC 方法；对象不响应时返回 nil。
    private static func boolValue(_ node: NSObject, _ selector: Selector) -> Bool? {
        guard node.responds(to: selector), let imp = node.method(for: selector) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Function.self)(node, selector)
    }
}
