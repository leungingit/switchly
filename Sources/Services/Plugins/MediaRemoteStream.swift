import Foundation

enum MediaRemoteStreamEvent {
    case data(connection: UUID, event: MediaRemoteEvent)
    case failed(connection: UUID, reason: MediaRemoteFailure)
    /// 一条连接最多一次；不包含原始 stderr、歌曲或路径。
    case diagnostic(connection: UUID)
}

/// 未接入默认媒体桥。回调位于私有串行队列，不得阻塞；消费者负责切换 UI 线程。
final class MediaRemoteStream {
    private let queue = DispatchQueue(label: "com.switchly.mediaremote.stream")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let makeChild: () -> MediaRemoteChildProcess
    private let startupSeconds: TimeInterval
    private let terminationSeconds: TimeInterval
    private let lineLimit: Int
    private var child: MediaRemoteChildProcess?
    private var connection: UUID?
    private var decoder: MediaRemoteLineDecoder
    private var receivedFull = false
    private var reportedDiagnostic = false
    private var failed = false
    private var startupTimer: DispatchWorkItem?
    private var observer: ((MediaRemoteStreamEvent) -> Void)?

    init(startupSeconds: TimeInterval = MediaRemoteBudget.startupSeconds,
         terminationSeconds: TimeInterval = MediaRemoteBudget.terminationSeconds,
         lineLimit: Int = MediaRemoteBudget.lineBytes,
         makeChild: @escaping () -> MediaRemoteChildProcess) {
        self.startupSeconds = startupSeconds
        self.terminationSeconds = terminationSeconds
        self.lineLimit = lineLimit
        self.makeChild = makeChild
        decoder = MediaRemoteLineDecoder(limit: lineLimit)
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// 失败期间重复 start 不重启；显式 stop 后开启新的兴趣周期才能重试。
    @discardableResult
    func start(observer: @escaping (MediaRemoteStreamEvent) -> Void) -> UUID {
        sync {
            if let connection { return connection }
            let id = UUID()
            connection = id
            self.observer = observer
            failed = false
            receivedFull = false
            reportedDiagnostic = false
            decoder = MediaRemoteLineDecoder(limit: lineLimit)
            let child = makeChild()
            self.child = child
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.connection == id, !self.receivedFull else { return }
                self.fail(.startupTimeout, connection: id)
            }
            startupTimer = timeout
            queue.asyncAfter(deadline: .now() + startupSeconds, execute: timeout)
            do {
                try child.launch { [weak self] output in
                    // 同步交接为管道提供背压，不按每个分片无限入队。
                    self?.sync { self?.receive(output, connection: id) }
                }
            } catch { fail(.launchFailed, connection: id) }
            return id
        }
    }

    func stop() {
        sync {
            connection = nil
            observer = nil
            startupTimer?.cancel()
            startupTimer = nil
            decoder = MediaRemoteLineDecoder(limit: lineLimit)
            retireChild()
        }
    }

    private func receive(_ output: MediaRemoteProcessOutput, connection id: UUID) {
        guard connection == id, !failed else { return }
        switch output {
        case .stdout(let data):
            do {
                // 分片内同步消费；emit 的回调可以 stop，但不能覆盖解析器正在修改的存储。
                var parser = decoder
                decoder = MediaRemoteLineDecoder(limit: lineLimit)
                var events: [MediaRemoteEvent] = []
                try parser.consume(data) { events.append($0) }
                decoder = parser
                for event in events {
                    guard connection == id, !failed else { break }
                    guard !event.isDiff || receivedFull else {
                        fail(.missingFullSnapshot, connection: id); break
                    }
                    if !event.isDiff {
                        receivedFull = true
                        startupTimer?.cancel()
                        startupTimer = nil
                    }
                    observer?(.data(connection: id, event: event))
                }
            } catch let error as MediaRemoteFailure { fail(error, connection: id) }
            catch { fail(.malformedEvent, connection: id) }
        case .stderr:
            if !reportedDiagnostic {
                reportedDiagnostic = true
                observer?(.diagnostic(connection: id))
            }
        case .stdoutClosed:
            do { try decoder.finish(); fail(.streamEnded, connection: id) }
            catch { fail(.truncatedLine, connection: id) }
        case .readFailed: fail(.pipeFailed, connection: id)
        case .exited(let code): fail(.exited(code), connection: id)
        }
    }

    private func fail(_ reason: MediaRemoteFailure, connection id: UUID) {
        guard connection == id, !failed else { return }
        failed = true
        startupTimer?.cancel()
        startupTimer = nil
        decoder = MediaRemoteLineDecoder(limit: lineLimit)
        retireChild()
        observer?(.failed(connection: id, reason: reason))
    }

    private func retireChild() {
        guard let child else { return }
        self.child = nil
        child.terminate()
        // 捕获子进程而非 owner；owner 销毁后仍完成有界清理。
        queue.asyncAfter(deadline: .now() + terminationSeconds) {
            if child.isRunning { child.kill() }
        }
    }

    private func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    deinit { stop() }
}
