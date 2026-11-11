import Foundation

struct PluginPreviewPoint: Equatable {
    let x: Double
    let y: Double
}

/// 场景步骤（契约 steps v1）。`advance` 推进虚拟时钟；`action` 是直接调用插件 onAction 的
/// 「业务动作」，不经过原生输入（原生输入回归见 T15）；`expectText` 断言当前渲染树中的文本。
enum PluginPreviewStep: Equatable {
    case advance(milliseconds: Double)
    case action(id: String, value: Double?)
    case expectText(contains: String)
    /// 经原生可访问树按标签定位控件并执行 press，再核对路由到会话的动作 ID（T15）。
    /// `expectDisabled` 为 true 时要求控件存在、处于禁用状态且没有动作被路由。
    case nativeClick(label: String, expectAction: String?, expectDisabled: Bool)
    case nativeClickAt(point: PluginPreviewPoint, expectAction: String?)
    case nativeDrag(from: PluginPreviewPoint, to: PluginPreviewPoint)

    static let maxCount = 64
    static let maxAdvanceMilliseconds: Double = 24 * 60 * 60 * 1000
    static let maxTextLength = 256
    static let maxActionIDLength = 128

    var typeName: String {
        switch self {
        case .advance: return "advance"
        case .action: return "action"
        case .expectText: return "expectText"
        case .nativeClick: return "nativeClick"
        case .nativeClickAt: return "nativeClickAt"
        case .nativeDrag: return "nativeDrag"
        }
    }

    /// 步骤的证据来源，写入 trace，区分业务动作、时钟与输出断言。
    var source: String {
        switch self {
        case .advance: return "clock"
        case .action: return "business-action"
        case .expectText: return "render-output"
        case .nativeClick, .nativeClickAt, .nativeDrag: return "native-input"
        }
    }

    /// 从已通过键白名单校验的 JSON 对象解析；未知 type 返回 unsupported，字段错误返回 invalid。
    static func parse(_ array: [Any]) throws -> [PluginPreviewStep] {
        guard array.count <= maxCount else { throw PreviewScenario.Failure.invalidScenario }
        return try array.map { element in
            guard let object = element as? [String: Any], let type = object["type"] as? String else {
                throw PreviewScenario.Failure.unsupportedSteps
            }
            func only(_ keys: Set<String>) throws {
                guard Set(object.keys).isSubset(of: keys.union(["type"])) else { throw PreviewScenario.Failure.invalidScenario }
            }
            func point(_ key: String) throws -> PluginPreviewPoint {
                guard let raw = object[key] as? [String: Any], Set(raw.keys) == ["x", "y"] else {
                    throw PreviewScenario.Failure.invalidScenario
                }
                func coordinate(_ key: String) throws -> Double {
                    guard let value = raw[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                          value.doubleValue.isFinite, value.doubleValue >= 0 else {
                        throw PreviewScenario.Failure.invalidScenario
                    }
                    return value.doubleValue
                }
                return try PluginPreviewPoint(x: coordinate("x"), y: coordinate("y"))
            }
            func expectedAction() throws -> String? {
                guard let raw = object["expectAction"] else { return nil }
                guard let id = raw as? String, !id.isEmpty, id.count <= maxActionIDLength else {
                    throw PreviewScenario.Failure.invalidScenario
                }
                return id
            }
            switch type {
            case "advance":
                try only(["ms"])
                guard let ms = (object["ms"] as? NSNumber).flatMap({ number -> Double? in
                          CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue }),
                      ms.isFinite, ms >= 0, ms <= maxAdvanceMilliseconds else {
                    throw PreviewScenario.Failure.invalidScenario
                }
                return .advance(milliseconds: ms)
            case "action":
                try only(["id", "value"])
                guard let id = object["id"] as? String, !id.isEmpty, id.count <= maxActionIDLength else {
                    throw PreviewScenario.Failure.invalidScenario
                }
                var value: Double?
                if let raw = object["value"] {
                    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite else { throw PreviewScenario.Failure.invalidScenario }
                    value = number.doubleValue
                }
                return .action(id: id, value: value)
            case "expectText":
                try only(["contains"])
                guard let text = object["contains"] as? String, !text.isEmpty, text.count <= maxTextLength else {
                    throw PreviewScenario.Failure.invalidScenario
                }
                return .expectText(contains: text)
            case "nativeClick":
                try only(["label", "expectAction", "expectDisabled"])
                guard let label = object["label"] as? String, !label.isEmpty, label.count <= maxTextLength else {
                    throw PreviewScenario.Failure.invalidScenario
                }
                var expectAction: String?
                if let raw = object["expectAction"] {
                    guard let id = raw as? String, !id.isEmpty, id.count <= maxActionIDLength else {
                        throw PreviewScenario.Failure.invalidScenario
                    }
                    expectAction = id
                }
                var disabled = false
                if let raw = object["expectDisabled"] {
                    guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                        throw PreviewScenario.Failure.invalidScenario
                    }
                    disabled = number.boolValue
                }
                if disabled && expectAction != nil { throw PreviewScenario.Failure.invalidScenario }
                return .nativeClick(label: label, expectAction: expectAction, expectDisabled: disabled)
            case "nativeClickAt":
                try only(["point", "expectAction"])
                return try .nativeClickAt(point: point("point"), expectAction: expectedAction())
            case "nativeDrag":
                try only(["from", "to"])
                return try .nativeDrag(from: point("from"), to: point("to"))
            default:
                throw PreviewScenario.Failure.unsupportedSteps
            }
        }
    }
}

/// 目标实现用固定失败码报告可预期的步骤失败（如控件不存在），不携带内容。
struct PluginPreviewStepFailure: Error, Equatable {
    let code: String
}

/// 每步结果。`detail` 只使用固定错误码，不回显断言文本或渲染内容。
struct PluginPreviewStepTrace: Codable, Equatable {
    let index: Int
    let type: String
    let source: String
    let status: String
    let detail: String?
}

struct PluginPreviewStepAction: Equatable {
    let id: String
    let enabled: Bool
}

/// 步骤执行目标。会话换代、取消等由实现方抛错，执行器统一记为失败。
protocol PluginPreviewStepTarget {
    func advance(milliseconds: Double) async throws
    func perform(actionID: String, value: Double?) async throws
    func renderJSON() async throws -> String
    func availableActions() async throws -> [PluginPreviewStepAction]
    func nativeClick(label: String, expectAction: String?, expectDisabled: Bool) async throws
    func nativeClickAt(point: PluginPreviewPoint, expectAction: String?) async throws
    func nativeDrag(from: PluginPreviewPoint, to: PluginPreviewPoint) async throws
}

struct PluginPreviewStepOutcome: Equatable {
    let traces: [PluginPreviewStepTrace]
    /// 首个失败步骤的下标；全部通过为 nil。
    let failedIndex: Int?
}

enum PluginPreviewStepRunner {
    static func run(_ steps: [PluginPreviewStep], on target: PluginPreviewStepTarget) async -> PluginPreviewStepOutcome {
        var traces: [PluginPreviewStepTrace] = []
        var failed: Int?
        for (index, step) in steps.enumerated() {
            if failed != nil {
                traces.append(trace(index, step, "skipped", nil))
                continue
            }
            if Task.isCancelled {
                failed = index
                traces.append(trace(index, step, "failed", "cancelled"))
                continue
            }
            if let code = await execute(step, on: target) {
                failed = index
                traces.append(trace(index, step, "failed", code))
            } else {
                traces.append(trace(index, step, "passed", nil))
            }
        }
        return PluginPreviewStepOutcome(traces: traces, failedIndex: failed)
    }

    private static func trace(_ index: Int, _ step: PluginPreviewStep, _ status: String, _ detail: String?) -> PluginPreviewStepTrace {
        PluginPreviewStepTrace(index: index, type: step.typeName, source: step.source, status: status, detail: detail)
    }

    /// 返回 nil 表示通过，否则为固定失败码。
    private static func execute(_ step: PluginPreviewStep, on target: PluginPreviewStepTarget) async -> String? {
        do {
            switch step {
            case .advance(let ms):
                try await target.advance(milliseconds: ms)
            case .action(let id, let value):
                let matches = try await target.availableActions().filter { $0.id == id }
                if matches.isEmpty { return "action-unavailable" }
                let enabled = matches.filter(\.enabled)
                if enabled.isEmpty { return "action-disabled" }
                if enabled.count > 1 { return "action-ambiguous" }
                try await target.perform(actionID: id, value: value)
            case .nativeClick(let label, let expectAction, let expectDisabled):
                try await target.nativeClick(label: label, expectAction: expectAction, expectDisabled: expectDisabled)
            case .nativeClickAt(let point, let action):
                try await target.nativeClickAt(point: point, expectAction: action)
            case .nativeDrag(let from, let to):
                try await target.nativeDrag(from: from, to: to)
            case .expectText(let needle):
                let json = try await target.renderJSON()
                guard let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) else { return "invalid-render-output" }
                if !strings(in: object).contains(where: { $0.contains(needle) }) { return "text-not-found" }
            }
            return nil
        } catch let failure as PluginPreviewStepFailure {
            return failure.code
        } catch is CancellationError {
            return "cancelled"
        } catch {
            return "step-error"
        }
    }

    private static func strings(in value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let array = value as? [Any] { return array.flatMap(strings(in:)) }
        if let object = value as? [String: Any] { return object.values.flatMap(strings(in:)) }
        return []
    }
}
