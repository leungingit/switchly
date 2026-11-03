import Darwin
import Foundation

/// 由控制器持有的单向管道读取端；关闭时取消 Dispatch source 并释放文件描述符。
final class PluginPreviewPipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let queue: DispatchQueue
    private let onData: (Data) -> Void
    private let onEnd: () -> Void
    private let onFailure: () -> Void
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var closed = false

    init(
        fileHandle: FileHandle,
        label: String,
        onData: @escaping (Data) -> Void,
        onEnd: @escaping () -> Void,
        onFailure: @escaping () -> Void
    ) {
        self.fileHandle = fileHandle
        self.queue = DispatchQueue(label: label)
        self.onData = onData
        self.onEnd = onEnd
        self.onFailure = onFailure
    }

    func start() {
        lock.lock()
        guard !closed, source == nil else {
            lock.unlock()
            return
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileHandle.fileDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.setCancelHandler { [fileHandle] in
            try? fileHandle.close()
        }
        self.source = source
        lock.unlock()
        source.resume()
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let source = self.source
        self.source = nil
        lock.unlock()
        source?.cancel()
    }

    private func readAvailableBytes() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count: Int = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(fileHandle.fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            onData(Data(buffer[0..<count]))
            return
        }
        if count == 0 {
            finishStream()
            return
        }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return
        }
        do {
            guard !isClosed else { return }
            onFailure()
            close()
        }
    }

    private func finishStream() {
        guard !isClosed else { return }
        onEnd()
        close()
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

/// 串行写入 worker stdin，避免多个异步写交错破坏长度前缀帧。
final class PluginPreviewPipeWriter: @unchecked Sendable {
    private enum WriteFailure: Error {
        case closed
    }

    private let fileHandle: FileHandle
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false

    init(fileHandle: FileHandle, label: String) {
        self.fileHandle = fileHandle
        self.queue = DispatchQueue(label: label)
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                lock.lock()
                let isClosed = closed
                lock.unlock()
                guard !isClosed else {
                    continuation.resume(throwing: WriteFailure.closed)
                    return
                }

                do {
                    try fileHandle.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: WriteFailure.closed)
                }
            }
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        try? fileHandle.close()
    }
}

/// 只调用一次 `waitUntilExit()`，让正常退出和 SIGKILL 后都经过同一条回收路径。
final class PluginPreviewProcessReaper: @unchecked Sendable {
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "com.switchly.preview.process-reaper.timers")
    private var status: Int32?
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Int32?, Never>] = [:]

    init(process: Process) {
        let waitQueue = DispatchQueue(label: "com.switchly.preview.process-reaper.wait")
        waitQueue.async { [self] in
            process.waitUntilExit()
            complete(with: process.terminationStatus)
        }
    }

    func wait() async -> Int32? {
        await wait(timeout: nil)
    }

    func wait(timeout: TimeInterval) async -> Int32? {
        await wait(timeout: Optional(timeout))
    }

    private func wait(timeout: TimeInterval?) async -> Int32? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
                return
            }

            nextWaiterID &+= 1
            let waiterID = nextWaiterID
            waiters[waiterID] = continuation
            lock.unlock()

            if let timeout {
                timerQueue.asyncAfter(deadline: .now() + timeout) { [self] in
                    expireWaiter(waiterID)
                }
            }
        }
    }

    private func expireWaiter(_ waiterID: UInt64) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    private func complete(with status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let continuations = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in continuations {
            continuation.resume(returning: status)
        }
    }
}
