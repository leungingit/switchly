import AppKit

/// 仅数据桥；Preview/Worker注入夹具，绝不构造真实采集器。
protocol PluginActivityProviding: AnyObject {
    func readValidity() -> PluginActivityReadValidity
    func query(method: String, options: [String: Any], pluginID: String, snapshotsAllowed: Bool) async throws -> [String: Any]
}

enum ActivityDataError: String, Error { case denied, invalidRange, tooLarge, staleCursor }

/// 交付点再次检查的数据/授权代次；不访问主线程状态，不持锁执行JS或回调。
struct PluginActivityReadValidity: Sendable {
    let isCurrent: @Sendable () -> Bool
}

final class PluginActivityValidityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    func invalidate() { lock.lock(); generation = UUID(); lock.unlock() }
    func capture() -> PluginActivityReadValidity {
        lock.lock(); let token = generation; lock.unlock()
        return PluginActivityReadValidity { [weak self] in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }; return self.generation == token
        }
    }
}

extension PluginActivityProviding {
    func readValidity() -> PluginActivityReadValidity { PluginActivityReadValidity { true } }
}

/// 图片解析边界由宿主注入，视图不访问真实文件或采集器。
protocol PluginActivityImageResolving: AnyObject {
    func image(reference: String, pluginID: String) async -> NSImage?
}
