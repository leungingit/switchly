import Darwin
import Foundation

private struct TestPayload: Codable, Equatable, Sendable {
    let message: String
    let delayMilliseconds: Int
    let environmentOK: Bool
    let sequence: Int

    init(
        message: String = "",
        delayMilliseconds: Int = 0,
        environmentOK: Bool = true,
        sequence: Int = 0
    ) {
        self.message = message
        self.delayMilliseconds = delayMilliseconds
        self.environmentOK = environmentOK
        self.sequence = sequence
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvalidates: [PluginPreviewFrame<TestPayload>] = []
    private var storedActions: [PluginPreviewFrame<TestPayload>] = []
    private var storedFailures: [PluginPreviewProcessFailure] = []
    private var storedDiscarded = 0

    func record(_ event: PluginPreviewWorkerEvent<TestPayload>) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .invalidate(let frame):
            storedInvalidates.append(frame)
        case .action(let frame):
            storedActions.append(frame)
        case .discarded:
            storedDiscarded += 1
        case .failed(let failure):
            storedFailures.append(failure)
        }
    }

    var invalidates: [PluginPreviewFrame<TestPayload>] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidates
    }

    var actions: [PluginPreviewFrame<TestPayload>] {
        lock.lock()
        defer { lock.unlock() }
        return storedActions
    }

    var failures: [PluginPreviewProcessFailure] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }

    var discardedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDiscarded
    }
}

private final class Suite {
    private(set) var passed = 0
    private(set) var failed = 0

    func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            let detail = (error as? TestFailure)?.description ?? String(describing: error)
            print("FAIL \(name): \(detail)")
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

private func expectProcessFailure<T>(
    _ expected: PluginPreviewProcessFailureReason,
    _ operation: () async throws -> T
) async throws {
    do {
        _ = try await operation()
    } catch let error as PluginPreviewProcessError {
        guard case .failure(let failure) = error else {
            throw TestFailure(description: "expected process failure, got \(error)")
        }
        try expectEqual(failure.reason, expected, "failure reason")
        return
    } catch {
        throw TestFailure(description: "expected process failure, got \(error)")
    }
    throw TestFailure(description: "expected process failure, but operation succeeded")
}

private func frame(
    type: String,
    generation: UInt64,
    requestID: UInt64,
    payload: TestPayload = TestPayload()
) -> PluginPreviewFrame<TestPayload> {
    PluginPreviewFrame(
        type: type,
        generation: generation,
        requestID: requestID,
        payload: payload
    )
}

private func makeSupervisor(
    mode: String,
    recorder: EventRecorder,
    startupTimeout: TimeInterval = 0.5,
    requestTimeout: TimeInterval = 0.5,
    shutdownTimeout: TimeInterval = 0.25,
    terminationGracePeriod: TimeInterval = 0.1,
    reapingTimeout: TimeInterval = 0.5
) throws -> PluginPreviewWorkerSupervisor<TestPayload> {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let configuration = try PluginPreviewProcessConfiguration(
        executableURL: executable,
        arguments: ["--fake-worker", mode],
        environment: ["SWITCHLY_PREVIEW_ALLOWED": "1"],
        workingDirectoryURL: FileManager.default.temporaryDirectory,
        startupTimeout: startupTimeout,
        requestTimeout: requestTimeout,
        shutdownTimeout: shutdownTimeout,
        terminationGracePeriod: terminationGracePeriod,
        reapingTimeout: reapingTimeout
    )
    return PluginPreviewWorkerSupervisor(
        configuration: configuration,
        eventHandler: { event in recorder.record(event) }
    )
}

private func waitForStderr(_ supervisor: PluginPreviewWorkerSupervisor<TestPayload>) async throws {
    for _ in 0..<30 {
        if await supervisor.snapshot().stderrByteCount > 0 {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw TestFailure(description: "stderr was not drained")
}

private func waitForAdmission(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !(await condition()) {
        guard Date() < deadline else { throw TestFailure(description: "请求未进入预期状态") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private enum FakeWorker {
    static func run(mode: String) -> Never {
        if mode == "ignore-shutdown" {
            _ = signal(SIGTERM, SIG_IGN)
        }
        if mode == "ignore-start" {
            while true {
                sleep(1)
            }
        }

        var sequence = 0
        while let request = readFrame() {
            sequence += 1
            if mode == "ignore-render", request.type == "render" {
                continue
            }
            if mode == "ignore-shutdown", request.type == "shutdown" {
                continue
            }
            if mode == "gated-render", request.type == "render" {
                let release = URL(fileURLWithPath: request.payload.message)
                do { try Data().write(to: release.appendingPathExtension("entered")) }
                catch { exit(3) }
                let deadline = Date().addingTimeInterval(5)
                while !FileManager.default.fileExists(atPath: release.path) {
                    guard Date() < deadline else { exit(3) }
                    usleep(1_000)
                }
            }
            if request.payload.delayMilliseconds > 0 {
                usleep(useconds_t(request.payload.delayMilliseconds * 1_000))
            }

            if mode == "stale" {
                write(frame(
                    type: "invalidate",
                    generation: request.generation - 1,
                    requestID: request.requestID
                ))
                write(frame(
                    type: "action",
                    generation: request.generation - 1,
                    requestID: request.requestID
                ))
                write(frame(
                    type: "invalidate",
                    generation: request.generation,
                    requestID: request.requestID
                ))
                write(frame(
                    type: "action",
                    generation: request.generation,
                    requestID: request.requestID
                ))
                write(frame(
                    type: request.type,
                    generation: request.generation - 1,
                    requestID: request.requestID
                ))
            }

            if request.type == "hello" {
                FileHandle.standardError.write(Data("diagnostic-only\n".utf8))
            }
            let environmentOK = getenv("SWITCHLY_PREVIEW_ALLOWED") != nil
                && getenv("SWITCHLY_PREVIEW_PARENT_SENTINEL") == nil
            write(frame(
                type: request.type,
                generation: request.generation,
                requestID: request.requestID,
                payload: TestPayload(
                    message: "echo:\(request.type)",
                    environmentOK: environmentOK,
                    sequence: sequence
                )
            ))
        }
        exit(0)
    }

    private static func readFrame() -> PluginPreviewFrame<TestPayload>? {
        guard let prefix = readExactly(4),
              let bodyLength = readBigEndianLength(prefix),
              bodyLength > 0,
              bodyLength <= PluginPreviewFrameCodec.maxFrameBytes,
              let body = readExactly(bodyLength)
        else {
            return nil
        }
        var wire = prefix
        wire.append(body)
        return try? PluginPreviewFrameCodec.decode(TestPayload.self, from: wire)
    }

    private static func readExactly(_ count: Int) -> Data? {
        var result = Data()
        while result.count < count {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: count - result.count),
                  !chunk.isEmpty
            else {
                return nil
            }
            result.append(chunk)
        }
        return result
    }

    private static func readBigEndianLength(_ data: Data) -> Int? {
        guard data.count == 4 else { return nil }
        return data.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func write(_ frame: PluginPreviewFrame<TestPayload>) {
        guard let wire = try? PluginPreviewFrameCodec.encode(frame) else {
            exit(2)
        }
        do {
            try FileHandle.standardOutput.write(contentsOf: wire)
        } catch {
            exit(2)
        }
    }
}

@main
private struct ProcessSupervisorTests {
    static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--fake-worker"),
           CommandLine.arguments.indices.contains(index + 1) {
            FakeWorker.run(mode: CommandLine.arguments[index + 1])
        }

        let suite = Suite()

        await suite.run("starts with exact environment and keeps stderr out of frames") {
            setenv("SWITCHLY_PREVIEW_PARENT_SENTINEL", "1", 1)
            defer { unsetenv("SWITCHLY_PREVIEW_PARENT_SENTINEL") }
            let recorder = EventRecorder()
            let supervisor = try makeSupervisor(mode: "normal", recorder: recorder)
            let response = try await supervisor.start(
                generation: 7,
                hello: frame(type: "hello", generation: 7, requestID: 1)
            )
            try expectEqual(response.protocolVersion, 1, "protocol version")
            try expectEqual(response.requestID, UInt64(1), "request ID")
            try expect(response.payload.environmentOK, "worker inherited more than the configured environment")
            try await waitForStderr(supervisor)
            let statusAfterStderr = await supervisor.snapshot()
            try expect(statusAfterStderr.stderrByteCount > 0, "stderr byte count")
            await supervisor.stop(shutdown: frame(type: "shutdown", generation: 7, requestID: 2))
            let stoppedStatus = await supervisor.snapshot()
            try expectEqual(stoppedStatus.state, .stopped, "stopped state")

            _ = try await supervisor.start(
                generation: 8,
                hello: frame(type: "hello", generation: 8, requestID: 3)
            )
            await supervisor.stop(shutdown: frame(type: "shutdown", generation: 8, requestID: 4))
            let restartedStopStatus = await supervisor.snapshot()
            try expectEqual(restartedStopStatus.state, .stopped, "restart and stop state")
        }

        await suite.run("serializes requests and allows only one queued request") {
            let recorder = EventRecorder()
            let supervisor = try makeSupervisor(mode: "gated-render", recorder: recorder, requestTimeout: 5)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preview-queue-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let release = directory.appendingPathComponent("release")
            _ = try await supervisor.start(
                generation: 9,
                hello: frame(type: "hello", generation: 9, requestID: 10)
            )

            async let first = supervisor.request(frame(
                type: "render",
                generation: 9,
                requestID: 11,
                payload: TestPayload(message: release.path)
            ))
            // worker 明确进入首个请求后才创建第二个请求；容量断言前保持首个响应未返回。
            try await waitForAdmission {
                FileManager.default.fileExists(atPath: release.appendingPathExtension("entered").path)
            }
            async let second = supervisor.request(frame(
                type: "load",
                generation: 9,
                requestID: 12
            ))
            try await waitForAdmission { await supervisor.snapshot().queuedRequestCount == 1 }

            do {
                _ = try await supervisor.request(frame(
                    type: "action",
                    generation: 9,
                    requestID: 13
                ))
                throw TestFailure(description: "third request unexpectedly queued")
            } catch PluginPreviewProcessError.requestQueueFull {
                // 预期：一个执行中请求加一个等待请求后必须拒绝。
            }

            try Data().write(to: release)
            let firstResponse = try await first
            let secondResponse = try await second
            try expectEqual(firstResponse.payload.sequence, 2, "first worker sequence")
            try expectEqual(secondResponse.payload.sequence, 3, "second worker sequence")
            await supervisor.stop(shutdown: frame(type: "shutdown", generation: 9, requestID: 14))
        }

        await suite.run("drops stale responses, actions, and invalidates") {
            let recorder = EventRecorder()
            let supervisor = try makeSupervisor(mode: "stale", recorder: recorder)
            let response = try await supervisor.start(
                generation: 5,
                hello: frame(type: "hello", generation: 5, requestID: 1)
            )
            try expectEqual(response.generation, UInt64(5), "current response generation")
            try expectEqual(recorder.invalidates.map(\.generation), [5], "current invalidate only")
            try expectEqual(recorder.actions.map(\.generation), [5], "current action only")
            try expect(recorder.discardedCount >= 3, "stale envelopes should be observable only as discarded")
            await supervisor.stop(shutdown: frame(type: "shutdown", generation: 5, requestID: 2))
        }

        await suite.run("startup watchdog terminates and reaps a stuck worker") {
            let recorder = EventRecorder()
            let supervisor = try makeSupervisor(
                mode: "ignore-start",
                recorder: recorder,
                startupTimeout: 0.15
            )
            try await expectProcessFailure(.startupTimedOut) {
                try await supervisor.start(
                    generation: 1,
                    hello: frame(type: "hello", generation: 1, requestID: 1)
                )
            }
            let status = await supervisor.snapshot()
            let processIdentifier = await supervisor.processIdentifier
            try expectEqual(status.state, .failed, "failed state")
            try expect(processIdentifier == nil, "worker should be gone")
            try expect(recorder.failures.contains { $0.reason == .startupTimedOut }, "failure event")
        }

        await suite.run("request watchdog terminates a stuck execution") {
            let recorder = EventRecorder()
            let supervisor = try makeSupervisor(
                mode: "ignore-render",
                recorder: recorder,
                requestTimeout: 0.15
            )
            _ = try await supervisor.start(
                generation: 2,
                hello: frame(type: "hello", generation: 2, requestID: 1)
            )
            try await expectProcessFailure(.requestTimedOut) {
                try await supervisor.request(frame(type: "render", generation: 2, requestID: 2))
            }
            let status = await supervisor.snapshot()
            let processIdentifier = await supervisor.processIdentifier
            try expectEqual(status.state, .failed, "failed state")
            try expect(processIdentifier == nil, "worker should be gone")
            try expect(recorder.failures.contains { $0.reason == .requestTimedOut }, "failure event")
        }

        await suite.run("caller cancellation terminates the in-flight worker") {
            let recorder = EventRecorder()
            let supervisor = try makeSupervisor(
                mode: "ignore-render",
                recorder: recorder,
                requestTimeout: 2
            )
            _ = try await supervisor.start(
                generation: 4,
                hello: frame(type: "hello", generation: 4, requestID: 1)
            )
            let requestTask = Task {
                try await supervisor.request(frame(type: "render", generation: 4, requestID: 2))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            requestTask.cancel()

            try await expectProcessFailure(.requestCancelled) {
                try await requestTask.value
            }
            let status = await supervisor.snapshot()
            let processIdentifier = await supervisor.processIdentifier
            try expectEqual(status.state, .failed, "failed state")
            try expect(processIdentifier == nil, "cancelled worker should be gone")
            try expect(recorder.failures.contains { $0.reason == .requestCancelled }, "failure event")
        }

        await suite.run("shutdown watchdog escalates from terminate to kill and reap") {
            let recorder = EventRecorder()
            let supervisor = try makeSupervisor(
                mode: "ignore-shutdown",
                recorder: recorder,
                shutdownTimeout: 0.1,
                terminationGracePeriod: 0.1,
                reapingTimeout: 0.5
            )
            _ = try await supervisor.start(
                generation: 3,
                hello: frame(type: "hello", generation: 3, requestID: 1)
            )
            guard let processID = await supervisor.processIdentifier else {
                throw TestFailure(description: "missing worker PID")
            }

            let start = DispatchTime.now().uptimeNanoseconds
            await supervisor.stop(shutdown: frame(type: "shutdown", generation: 3, requestID: 2))
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

            try expect(elapsed < 1.5, "shutdown watchdog exceeded its bound")
            let status = await supervisor.snapshot()
            let remainingProcessIdentifier = await supervisor.processIdentifier
            try expectEqual(status.state, .stopped, "stopped state")
            try expect(remainingProcessIdentifier == nil, "worker PID should be cleared")
            try expectEqual(kill(processID, 0), -1, "worker must be reaped")
            try expectEqual(errno, ESRCH, "kill(0) should report no such process")
            try expect(recorder.failures.contains { $0.reason == .shutdownTimedOut }, "shutdown failure event")

            await supervisor.stop()
            let repeatedStopStatus = await supervisor.snapshot()
            try expectEqual(repeatedStopStatus.state, .stopped, "repeated stop state")
        }

        print("SUMMARY passed=\(suite.passed) failed=\(suite.failed)")
        exit(suite.failed == 0 ? 0 : 1)
    }
}
