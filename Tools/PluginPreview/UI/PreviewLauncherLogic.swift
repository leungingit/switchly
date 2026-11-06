import Foundation

/// GUI 启动器的模式。默认模式只读展示推导场景，自定义模式允许编辑。
enum PreviewLauncherMode: String, CaseIterable, Equatable {
    case derivedDefault
    case custom

    var localizationKey: String {
        switch self {
        case .derivedDefault: return "Default"
        case .custom: return "Custom"
        }
    }
}

/// 启动器布局的纯几何规则：控制区保持窄而可读，并给工作台舞台留足宽度。
enum PreviewLauncherLayout {
    static let stackedWidthThreshold: CGFloat = 900
    static let controlWidthRange: ClosedRange<CGFloat> = 340...380
    static let minimumStageWidth: CGFloat = 460
    /// 标题控件避开交通灯；各栏背景仍可延伸到窗口顶边。
    static let windowTitlebarInset: CGFloat = 32

    static func controlWidth(for totalWidth: CGFloat) -> CGFloat {
        let preferred = max(totalWidth * 0.34, controlWidthRange.lowerBound)
        let widest = min(controlWidthRange.upperBound,
                         max(totalWidth - minimumStageWidth, controlWidthRange.lowerBound))
        return min(preferred, widest)
    }
}

/// 缺数据提示（契约 §3.4）：固定文案只含 fixture kind，不回显路径或插件内容。
enum PreviewFixtureHint {
    static let messageKey =
        "This plugin needs a %@ fixture. Pick a file in Custom mode or use --fixture %@=<file>."

    static func message(kind: PreviewScenarioDraft.FixtureKind,
                        localize: (String) -> String) -> String {
        String(format: localize(messageKey), kind.rawValue, kind.rawValue)
    }
}

/// 最近使用目录的纯逻辑：去重、置顶、上限。存入 App 自身 `UserDefaults`。
enum PreviewRecentPluginList {
    static let maximumCount = 8

    static func adding(_ url: URL, to existing: [URL], maximum: Int = maximumCount) -> [URL] {
        let standardized = url.standardizedFileURL
        var result = existing.filter { $0.standardizedFileURL != standardized }
        result.insert(standardized, at: 0)
        if result.count > maximum {
            result.removeLast(result.count - maximum)
        }
        return result
    }

    static func encoding(_ urls: [URL]) -> [String] {
        urls.map(\.path)
    }

    /// 读取时再次去重与截断，兼容旧数据或手工写坏的默认值。
    static func decoding(_ paths: [String], maximum: Int = maximumCount) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for path in paths where !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            result.append(url)
            if result.count == maximum { break }
        }
        return result
    }
}

/// 防抖 + 取消旧任务：任一草稿改动都重新计时，只有最后一次改动真正触发渲染。
@MainActor
final class PreviewRenderDebouncer {
    private let delayNanoseconds: UInt64
    private let action: @MainActor () async -> Void
    private var task: Task<Void, Never>?

    init(delayNanoseconds: UInt64 = 250_000_000, action: @escaping @MainActor () async -> Void) {
        self.delayNanoseconds = delayNanoseconds
        self.action = action
    }

    func schedule() {
        task?.cancel()
        let delay = delayNanoseconds
        let action = self.action
        task = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 测试与关闭路径用：等待当前任务结束；已取消的任务不会执行动作。
    func waitUntilFinished() async {
        await task?.value
    }
}
