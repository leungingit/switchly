import Foundation

/// 每位消费者最多挂起一个主线程通知，避免流事件把 UI 队列无限堆满。
final class PluginInvalidator {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var pending = false
    init(_ action: @escaping () -> Void) { self.action = action }
    func invalidate() {
        lock.lock()
        guard action != nil, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = false
            let callback = self.action
            self.lock.unlock()
            callback?()
        }
    }
    func cancel() { lock.lock(); action = nil; lock.unlock() }
}
