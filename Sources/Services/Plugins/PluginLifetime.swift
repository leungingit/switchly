import Foundation

/// 句柄取消幂等，销毁也释放；不在锁内调用 owner。
final class PluginLifetime {
    private let lock = NSLock()
    private var release: (() -> Void)?
    init(_ release: @escaping () -> Void) { self.release = release }
    func cancel() {
        lock.lock()
        let action = release
        release = nil
        lock.unlock()
        action?()
    }
    deinit { cancel() }
}
