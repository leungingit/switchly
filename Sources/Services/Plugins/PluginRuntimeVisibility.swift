import Foundation

/// Host 统一管理共享 VM 的可见消费者；叠层不再相互覆盖失效回调或挂起对方的 VM。
final class PluginRuntimeVisibility {
    private struct Entry {
        let runtime: PluginRuntimeProtocol
        var listeners: [UUID: PluginInvalidator]
    }
    private let queue = DispatchQueue(label: "com.switchly.plugin.visibility")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var entries: [ObjectIdentifier: Entry] = [:]

    init() { queue.setSpecific(key: queueKey, value: 1) }

    func acquire(_ runtimes: [PluginRuntimeProtocol], invalidate: @escaping () -> Void) -> PluginLifetime {
        let consumer = UUID()
        sync {
            for runtime in runtimes {
                let key = ObjectIdentifier(runtime)
                let first = entries[key] == nil
                if first { entries[key] = Entry(runtime: runtime, listeners: [:]) }
                entries[key]?.listeners[consumer] = PluginInvalidator(invalidate)
                if first {
                    runtime.onInvalidate = { [weak self] in self?.invalidate(key) }
                    runtime.resume()
                }
            }
        }
        return PluginLifetime { [weak self] in self?.release(consumer) }
    }

    private func invalidate(_ key: ObjectIdentifier) {
        let listeners = sync { entries[key].map { Array($0.listeners.values) } ?? [] }
        listeners.forEach { $0.invalidate() }
    }

    private func release(_ consumer: UUID) {
        sync {
            for key in Array(entries.keys) {
                guard let listener = entries[key]?.listeners.removeValue(forKey: consumer) else { continue }
                listener.cancel()
                if entries[key]?.listeners.isEmpty == true, let entry = entries.removeValue(forKey: key) {
                    entry.runtime.onInvalidate = nil
                    entry.runtime.suspend()
                }
            }
        }
    }

    func reset() {
        sync {
            let old = entries.values
            entries.removeAll()
            for entry in old {
                entry.listeners.values.forEach { $0.cancel() }
                entry.runtime.onInvalidate = nil
                entry.runtime.suspend()
            }
        }
    }

    private func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    deinit { reset() }
}
