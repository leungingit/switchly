import Darwin
import Foundation

/// 管理单个预览 worker 的启动、串行请求、代际过滤与关闭。
///
/// 会话控制器必须通过本类型管理子进程，避免 CLI 与 GUI 各自实现终止和回收。
/// stdout 只承载协议帧；stderr 持续排空且不进入错误文本。
actor PluginPreviewWorkerSupervisor<Payload: Codable & Sendable> {
    private enum Operation {
        case launch
        case request
        case shutdown
    }

    private struct ActiveRequest {
        let frame: PluginPreviewFrame<Payload>
        let operation: Operation
        let continuation: CheckedContinuation<PluginPreviewFrame<Payload>, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private struct QueuedRequest {
        let frame: PluginPreviewFrame<Payload>
        let continuation: CheckedContinuation<PluginPreviewFrame<Payload>, Error>
    }

    private let configuration: PluginPreviewProcessConfiguration
    private let eventHandler: (@Sendable (PluginPreviewWorkerEvent<Payload>) -> Void)?

    private var state: PluginPreviewProcessState = .idle
    private var currentGeneration: UInt64?
    private var process: Process?
    private var reaper: PluginPreviewProcessReaper?
    private var exitMonitorTask: Task<Void, Never>?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var inputWriter: PluginPreviewPipeWriter?
    private var outputReader: PluginPreviewPipeReader?
    private var errorReader: PluginPreviewPipeReader?
    private var decoder = PluginPreviewFrameStreamDecoder<Payload>()
    private var activeRequest: ActiveRequest?
    private var queuedRequest: QueuedRequest?
    private var cancelledBeforeEnqueue: Set<UInt64> = []
    private var stderrByteCount = 0
    private var lastFailure: PluginPreviewProcessFailure?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        configuration: PluginPreviewProcessConfiguration,
        eventHandler: (@Sendable (PluginPreviewWorkerEvent<Payload>) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.eventHandler = eventHandler
    }

    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    func snapshot() -> PluginPreviewProcessStatus {
        PluginPreviewProcessStatus(
            state: state,
            generation: currentGeneration,
            queuedRequestCount: queuedRequest == nil ? 0 : 1,
            stderrByteCount: stderrByteCount,
            lastFailure: lastFailure
        )
    }

    /// 启动 worker，并把 `hello` 作为启动 watchdog 覆盖的首个请求。
    @discardableResult
    func start(
        generation: UInt64,
        hello: PluginPreviewFrame<Payload>
    ) async throws -> PluginPreviewFrame<Payload> {
        if state == .stopping {
            throw PluginPreviewProcessError.stopping
        }
        if process != nil {
            throw PluginPreviewProcessError.alreadyStarted
        }
        guard hello.type == "hello" else {
            throw PluginPreviewProcessError.invalidRequestType(expected: "hello", found: hello.type)
        }
        guard hello.generation == generation else {
            throw PluginPreviewProcessError.generationMismatch(expected: generation, found: hello.generation)
        }

        state = .starting
        currentGeneration = generation
        decoder = PluginPreviewFrameStreamDecoder<Payload>()
        stderrByteCount = 0
        lastFailure = nil

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.currentDirectoryURL = configuration.workingDirectoryURL

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            closePipes(input: inputPipe, output: outputPipe, error: errorPipe)
            let failure = PluginPreviewProcessFailure(
                reason: .launchFailed,
                generation: generation,
                requestID: hello.requestID
            )
            state = .failed
            lastFailure = failure
            emit(.failed(failure))
            throw PluginPreviewProcessError.failure(failure)
        }

        closeChildSidePipeEnds(input: inputPipe, output: outputPipe, error: errorPipe)
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        inputWriter = PluginPreviewPipeWriter(
            fileHandle: inputPipe.fileHandleForWriting,
            label: "com.switchly.preview.worker.stdin"
        )

        let reaper = PluginPreviewProcessReaper(process: process)
        self.reaper = reaper
        exitMonitorTask = Task { [weak self] in
            guard let status = await reaper.wait() else { return }
            await self?.processExited(status: status)
        }
        startReaders(outputPipe: outputPipe, errorPipe: errorPipe)

        do {
            let response = try await enqueue(
                hello,
                operation: .launch,
                allowedDuringStart: true,
                allowedDuringStop: false
            )
            if state == .starting {
                state = .running
            }
            return response
        } catch {
            if self.process != nil {
                _ = await terminateAndWaitForExit()
                closeWorkerPipes()
                exitMonitorTask?.cancel()
                exitMonitorTask = nil
                self.process = nil
                self.reaper = nil
            }
            if state == .starting {
                state = .failed
            }
            throw error
        }
    }

    /// 发送一个变更请求。同一时刻只有一个执行中请求和一个等待请求。
    func request(
        _ frame: PluginPreviewFrame<Payload>
    ) async throws -> PluginPreviewFrame<Payload> {
        guard state == .running else {
            throw PluginPreviewProcessError.notStarted
        }
        guard let currentGeneration else {
            throw PluginPreviewProcessError.notStarted
        }
        guard frame.generation == currentGeneration else {
            throw PluginPreviewProcessError.generationMismatch(
                expected: currentGeneration,
                found: frame.generation
            )
        }
        return try await enqueue(
            frame,
            operation: .request,
            allowedDuringStart: false,
            allowedDuringStop: false
        )
    }

    /// load 是唯一允许在成功后推进 generation 的请求；成功前当前代际保持不变。
    func requestForGenerationTransition(
        _ frame: PluginPreviewFrame<Payload>
    ) async throws -> PluginPreviewFrame<Payload> {
        guard state == .running, let currentGeneration else {
            throw PluginPreviewProcessError.notStarted
        }
        guard frame.generation > currentGeneration else {
            throw PluginPreviewProcessError.generationMismatch(
                expected: currentGeneration,
                found: frame.generation
            )
        }
        guard activeRequest == nil, queuedRequest == nil else {
            throw PluginPreviewProcessError.invalidGenerationTransition(
                current: currentGeneration,
                requested: frame.generation
            )
        }
        return try await enqueue(
            frame,
            operation: .request,
            allowedDuringStart: false,
            allowedDuringStop: false
        )
    }

    /// 在 load 成功、活动请求已完成后推进后续请求使用的 generation。
    func advanceGeneration(to nextGeneration: UInt64) throws {
        guard state == .running, let currentGeneration else {
            throw PluginPreviewProcessError.notStarted
        }
        guard activeRequest == nil, queuedRequest == nil else {
            throw PluginPreviewProcessError.invalidGenerationTransition(
                current: currentGeneration,
                requested: nextGeneration
            )
        }
        guard nextGeneration > currentGeneration else {
            throw PluginPreviewProcessError.invalidGenerationTransition(
                current: currentGeneration,
                requested: nextGeneration
            )
        }
        self.currentGeneration = nextGeneration
    }

    /// 停止接收请求，可选发送 shutdown；随后 terminate、必要时 SIGKILL，并等待回收。
    func stop(shutdown: PluginPreviewFrame<Payload>? = nil) async {
        if state == .stopping {
            await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
            return
        }
        guard process != nil else {
            state = .stopped
            currentGeneration = nil
            return
        }

        state = .stopping
        cancelQueued(with: CancellationError())

        var canSendShutdown = activeRequest == nil
        if let activeRequest {
            self.activeRequest = nil
            activeRequest.timeoutTask?.cancel()
            activeRequest.continuation.resume(throwing: CancellationError())
        } else if let shutdown,
                  let currentGeneration,
                  shutdown.generation == currentGeneration,
                  shutdown.type == "shutdown" {
            do {
                _ = try await enqueue(
                    shutdown,
                    operation: .shutdown,
                    allowedDuringStart: false,
                    allowedDuringStop: true
                )
            } catch let error as PluginPreviewProcessError {
                if case .failure(let failure) = error, failure.reason == .shutdownTimedOut {
                    lastFailure = failure
                    emit(.failed(failure))
                }
            } catch {
                // 进程在关闭握手中退出也算完成关闭；强制回收仍由下方 watchdog 覆盖。
            }
            canSendShutdown = false
        }

        if canSendShutdown {
            inputWriter?.close()
        }
        if let reapingFailure = await terminateAndWaitForExit() {
            lastFailure = reapingFailure
            emit(.failed(reapingFailure))
        }
        finishStopped()
    }

    private func enqueue(
        _ frame: PluginPreviewFrame<Payload>,
        operation: Operation,
        allowedDuringStart: Bool,
        allowedDuringStop: Bool
    ) async throws -> PluginPreviewFrame<Payload> {
        let stateIsAllowed = state == .running
            || (allowedDuringStart && state == .starting)
            || (allowedDuringStop && state == .stopping)
        guard stateIsAllowed else {
            throw state == .stopping ? PluginPreviewProcessError.stopping : PluginPreviewProcessError.notStarted
        }
        guard activeRequest?.frame.requestID != frame.requestID,
              queuedRequest?.frame.requestID != frame.requestID
        else {
            throw PluginPreviewProcessError.duplicateRequestID(frame.requestID)
        }
        if cancelledBeforeEnqueue.remove(frame.requestID) != nil {
            throw CancellationError()
        }

        let bytes: Data
        do {
            bytes = try PluginPreviewFrameCodec.encode(frame)
        } catch let error as PluginPreviewFrameError {
            throw PluginPreviewProcessError.failure(PluginPreviewProcessFailure(
                reason: .protocolError(error),
                generation: frame.generation,
                requestID: frame.requestID
            ))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if activeRequest == nil {
                    activate(
                        frame,
                        bytes: bytes,
                        operation: operation,
                        continuation: continuation
                    )
                } else if queuedRequest == nil {
                    queuedRequest = QueuedRequest(frame: frame, continuation: continuation)
                } else {
                    continuation.resume(throwing: PluginPreviewProcessError.requestQueueFull)
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: frame.requestID) }
        }
    }

    private func activate(
        _ frame: PluginPreviewFrame<Payload>,
        bytes: Data,
        operation: Operation,
        continuation: CheckedContinuation<PluginPreviewFrame<Payload>, Error>
    ) {
        activeRequest = ActiveRequest(
            frame: frame,
            operation: operation,
            continuation: continuation,
            timeoutTask: nil
        )
        startTimeout(for: frame.requestID, operation: operation)

        guard let inputWriter else {
            writeFailed(requestID: frame.requestID)
            return
        }
        Task { [weak self] in
            do {
                try await inputWriter.write(bytes)
            } catch {
                await self?.writeFailed(requestID: frame.requestID)
            }
        }
    }

    private func activateQueuedRequest() {
        guard activeRequest == nil, let queuedRequest else { return }
        self.queuedRequest = nil
        let bytes: Data
        do {
            bytes = try PluginPreviewFrameCodec.encode(queuedRequest.frame)
        } catch let error as PluginPreviewFrameError {
            queuedRequest.continuation.resume(throwing: PluginPreviewProcessError.failure(
                PluginPreviewProcessFailure(
                    reason: .protocolError(error),
                    generation: queuedRequest.frame.generation,
                    requestID: queuedRequest.frame.requestID
                )
            ))
            activateQueuedRequest()
            return
        } catch {
            queuedRequest.continuation.resume(throwing: PluginPreviewProcessError.invalidConfiguration)
            activateQueuedRequest()
            return
        }

        activate(
            queuedRequest.frame,
            bytes: bytes,
            operation: .request,
            continuation: queuedRequest.continuation
        )
    }

    private func startTimeout(for requestID: UInt64, operation: Operation) {
        let timeout: TimeInterval
        switch operation {
        case .launch:
            timeout = configuration.startupTimeout
        case .request:
            timeout = configuration.requestTimeout
        case .shutdown:
            timeout = configuration.shutdownTimeout
        }
        let boundedSeconds = min(timeout, Double(UInt64.max) / 1_000_000_000)
        let nanoseconds = UInt64(boundedSeconds * 1_000_000_000)
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.timeoutExpired(requestID: requestID, operation: operation)
        }
        activeRequest?.timeoutTask = task
    }

    private func timeoutExpired(requestID: UInt64, operation: Operation) async {
        guard let activeRequest,
              activeRequest.frame.requestID == requestID,
              activeRequest.operation == operation
        else { return }

        let reason: PluginPreviewProcessFailureReason
        switch operation {
        case .launch:
            reason = .startupTimedOut
        case .request:
            reason = .requestTimedOut
        case .shutdown:
            reason = .shutdownTimedOut
        }
        let failure = PluginPreviewProcessFailure(
            reason: reason,
            generation: activeRequest.frame.generation,
            requestID: activeRequest.frame.requestID
        )

        if operation == .shutdown {
            self.activeRequest = nil
            activeRequest.timeoutTask?.cancel()
            lastFailure = failure
            activeRequest.continuation.resume(
                throwing: PluginPreviewProcessError.failure(failure)
            )
            return
        }
        await failAndTerminate(failure)
    }

    private func writeFailed(requestID: UInt64) {
        guard let activeRequest,
              activeRequest.frame.requestID == requestID
        else { return }
        let failure = PluginPreviewProcessFailure(
            reason: .pipeFailure,
            generation: activeRequest.frame.generation,
            requestID: requestID
        )
        Task { await self.failAndTerminate(failure) }
    }

    private func cancel(requestID: UInt64) async {
        if let queuedRequest, queuedRequest.frame.requestID == requestID {
            self.queuedRequest = nil
            queuedRequest.continuation.resume(throwing: CancellationError())
            return
        }
        guard let activeRequest,
              activeRequest.frame.requestID == requestID
        else {
            cancelledBeforeEnqueue.insert(requestID)
            return
        }

        let failure = PluginPreviewProcessFailure(
            reason: .requestCancelled,
            generation: activeRequest.frame.generation,
            requestID: requestID
        )
        await failAndTerminate(failure)
    }

    private func failAndTerminate(_ failure: PluginPreviewProcessFailure) async {
        guard state == .starting || state == .running else { return }

        state = .failed
        lastFailure = failure
        let activeRequest = self.activeRequest
        let queuedRequest = self.queuedRequest
        self.activeRequest = nil
        self.queuedRequest = nil
        activeRequest?.timeoutTask?.cancel()
        emit(.failed(failure))

        if let reapingFailure = await terminateAndWaitForExit() {
            lastFailure = reapingFailure
            emit(.failed(reapingFailure))
        }
        closeWorkerPipes()
        exitMonitorTask?.cancel()
        exitMonitorTask = nil
        process = nil
        reaper = nil

        activeRequest?.continuation.resume(
            throwing: PluginPreviewProcessError.failure(failure)
        )
        queuedRequest?.continuation.resume(throwing: CancellationError())
    }

    private func processExited(status: Int32) {
        if state == .stopping {
            if let activeRequest {
                self.activeRequest = nil
                activeRequest.timeoutTask?.cancel()
                activeRequest.continuation.resume(throwing: PluginPreviewProcessError.failure(
                    PluginPreviewProcessFailure(
                        reason: .workerExited(status: status),
                        generation: activeRequest.frame.generation,
                        requestID: activeRequest.frame.requestID
                    )
                ))
            }
            return
        }
        guard state == .starting || state == .running else { return }

        let activeRequest = self.activeRequest
        let queuedRequest = self.queuedRequest
        self.activeRequest = nil
        self.queuedRequest = nil
        activeRequest?.timeoutTask?.cancel()

        let failure = PluginPreviewProcessFailure(
            reason: .workerExited(status: status),
            generation: currentGeneration,
            requestID: activeRequest?.frame.requestID
        )
        state = .failed
        lastFailure = failure
        emit(.failed(failure))
        activeRequest?.continuation.resume(
            throwing: PluginPreviewProcessError.failure(failure)
        )
        queuedRequest?.continuation.resume(throwing: CancellationError())
        closeWorkerPipes()
        exitMonitorTask?.cancel()
        exitMonitorTask = nil
        process = nil
        reaper = nil
    }

    private func receiveStdout(_ data: Data) {
        guard state == .starting || state == .running || state == .stopping else { return }
        do {
            let frames = try decoder.append(data)
            for frame in frames {
                handle(frame)
            }
        } catch let error as PluginPreviewFrameError {
            guard state != .stopping else { return }
            let failure = PluginPreviewProcessFailure(
                reason: .protocolError(error),
                generation: currentGeneration,
                requestID: activeRequest?.frame.requestID
            )
            Task { await self.failAndTerminate(failure) }
        } catch {
            pipeFailed()
        }
    }

    private func handle(_ frame: PluginPreviewFrame<Payload>) {
        let matchesActiveRequest = activeRequest?.frame.generation == frame.generation
            && activeRequest?.frame.requestID == frame.requestID
        guard frame.generation == currentGeneration || matchesActiveRequest,
              state == .starting || state == .running || state == .stopping
        else {
            emit(.discarded(
                type: frame.type,
                generation: frame.generation,
                requestID: frame.requestID
            ))
            return
        }

        if frame.generation == currentGeneration, frame.type == "invalidate" {
            emit(.invalidate(frame))
            return
        }
        if frame.generation == currentGeneration,
           frame.type == "action",
           activeRequest?.frame.type != "action" {
            emit(.action(frame))
            return
        }

        if let activeRequest,
           activeRequest.frame.generation == frame.generation,
           activeRequest.frame.requestID == frame.requestID {
            self.activeRequest = nil
            activeRequest.timeoutTask?.cancel()
            activeRequest.continuation.resume(returning: frame)
            activateQueuedRequest()
            return
        }

        switch frame.type {
        case "action":
            emit(.action(frame))
        default:
            emit(.discarded(
                type: frame.type,
                generation: frame.generation,
                requestID: frame.requestID
            ))
        }
    }

    private func stdoutEnded() {
        guard state == .starting || state == .running else { return }
        do {
            try decoder.finish()
        } catch let error as PluginPreviewFrameError {
            let failure = PluginPreviewProcessFailure(
                reason: .protocolError(error),
                generation: currentGeneration,
                requestID: activeRequest?.frame.requestID
            )
            Task { await self.failAndTerminate(failure) }
            return
        } catch {
            pipeFailed()
            return
        }
        pipeFailed()
    }

    private func pipeFailed() {
        guard state == .starting || state == .running else { return }
        let failure = PluginPreviewProcessFailure(
            reason: .pipeFailure,
            generation: currentGeneration,
            requestID: activeRequest?.frame.requestID
        )
        Task { await self.failAndTerminate(failure) }
    }

    private func startReaders(outputPipe: Pipe, errorPipe: Pipe) {
        let outputReader = PluginPreviewPipeReader(
            fileHandle: outputPipe.fileHandleForReading,
            label: "com.switchly.preview.worker.stdout",
            onData: { [weak self] data in
                Task { await self?.receiveStdout(data) }
            },
            onEnd: { [weak self] in
                Task { await self?.stdoutEnded() }
            },
            onFailure: { [weak self] in
                Task { await self?.pipeFailed() }
            }
        )
        let errorReader = PluginPreviewPipeReader(
            fileHandle: errorPipe.fileHandleForReading,
            label: "com.switchly.preview.worker.stderr",
            onData: { [weak self] data in
                Task { await self?.recordStderr(bytes: data.count) }
            },
            onEnd: {},
            onFailure: { [weak self] in
                Task { await self?.pipeFailed() }
            }
        )
        self.outputReader = outputReader
        self.errorReader = errorReader
        outputReader.start()
        errorReader.start()
    }

    private func recordStderr(bytes: Int) {
        guard state == .starting || state == .running || state == .stopping else { return }
        stderrByteCount += bytes
    }

    private func terminateAndWaitForExit() async -> PluginPreviewProcessFailure? {
        guard let process, let reaper else { return nil }

        if process.isRunning {
            process.terminate()
        }
        if await reaper.wait(timeout: configuration.terminationGracePeriod) != nil {
            return nil
        }

        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        if await reaper.wait(timeout: configuration.reapingTimeout) != nil {
            return nil
        }
        return PluginPreviewProcessFailure(
            reason: .reapingTimedOut,
            generation: currentGeneration,
            requestID: activeRequest?.frame.requestID
        )
    }

    private func finishStopped() {
        closeWorkerPipes()
        exitMonitorTask?.cancel()
        exitMonitorTask = nil
        process = nil
        reaper = nil
        currentGeneration = nil
        activeRequest = nil
        queuedRequest = nil
        state = .stopped

        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelQueued(with error: Error) {
        guard let queuedRequest else { return }
        self.queuedRequest = nil
        queuedRequest.continuation.resume(throwing: error)
    }

    private func closeWorkerPipes() {
        outputReader?.close()
        errorReader?.close()
        inputWriter?.close()
        outputReader = nil
        errorReader = nil
        inputWriter = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func closeChildSidePipeEnds(input: Pipe, output: Pipe, error: Pipe) {
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
    }

    private func closePipes(input: Pipe, output: Pipe, error: Pipe) {
        try? input.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForReading.close()
        try? error.fileHandleForWriting.close()
    }

    private func emit(_ event: PluginPreviewWorkerEvent<Payload>) {
        eventHandler?(event)
    }
}
