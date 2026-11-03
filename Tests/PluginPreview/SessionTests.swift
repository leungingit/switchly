import Foundation

private struct SessionTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class SessionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PluginPreviewSessionEvent] = []

    func record(_ event: PluginPreviewSessionEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [PluginPreviewSessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class SessionSuite {
    private(set) var passed = 0
    private(set) var failed = 0

    func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            let detail = (error as? SessionTestFailure)?.description ?? String(describing: error)
            print("FAIL \(name): \(detail)")
        }
    }
}

private func sessionExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw SessionTestFailure(description: message)
    }
}

private func sessionExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw SessionTestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

private func sessionExpectError<T>(
    _ predicate: (PluginPreviewSessionError) -> Bool,
    _ operation: () async throws -> T
) async throws {
    do {
        _ = try await operation()
    } catch let error as PluginPreviewSessionError {
        guard predicate(error) else {
            throw SessionTestFailure(description: "unexpected session error: \(error)")
        }
        return
    } catch {
        throw SessionTestFailure(description: "unexpected error type: \(error)")
    }
    throw SessionTestFailure(description: "expected a session error, but operation succeeded")
}

private func makeSession(
    mode: String,
    recorder: SessionEventRecorder,
    compatibility: PluginPreviewSessionCompatibility = PluginPreviewSessionCompatibility(
        pluginAPIVersion: 2,
        sdkContractHash: "test-contract",
        toolVersion: "test-tool"
    )
) throws -> PluginPreviewSession {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    return try makeSession(
        executable: executable,
        arguments: ["--fake-session-worker", mode],
        recorder: recorder,
        compatibility: compatibility
    )
}

private func makeSession(
    executable: URL,
    arguments: [String],
    recorder: SessionEventRecorder,
    compatibility: PluginPreviewSessionCompatibility
) throws -> PluginPreviewSession {
    let configuration = try PluginPreviewProcessConfiguration(
        executableURL: executable,
        arguments: arguments,
        environment: ["SWITCHLY_PREVIEW_ALLOWED": "1"],
        workingDirectoryURL: FileManager.default.temporaryDirectory,
        startupTimeout: 0.5,
        requestTimeout: 0.5,
        shutdownTimeout: 0.25,
        terminationGracePeriod: 0.1,
        reapingTimeout: 0.5
    )
    return PluginPreviewSession(
        configuration: configuration,
        compatibility: compatibility,
        eventHandler: { event in recorder.record(event) }
    )
}

private func sessionFrame(
    _ type: String,
    generation: UInt64,
    requestID: UInt64,
    payload: PluginPreviewWorkerPayload = PluginPreviewWorkerPayload()
) -> PluginPreviewWorkerFrame {
    PluginPreviewWorkerFrame(
        type: type,
        generation: generation,
        requestID: requestID,
        payload: payload
    )
}

private enum FakeSessionWorker {
    static func run(mode: String) -> Never {
        var nextRequestID: UInt64 = 1
        var currentGeneration: UInt64 = 0
        while let request = readFrame() {
            guard request.requestID == nextRequestID else {
                write(failure(request, code: "unexpectedSequence"))
                continue
            }
            nextRequestID += 1

            switch request.type {
            case PluginPreviewWorkerMessageType.hello:
                write(response(request, payload: helloPayload(mode: mode)))
            case PluginPreviewWorkerMessageType.load:
                guard request.generation > currentGeneration else {
                    write(failure(request, code: "staleGeneration"))
                    continue
                }
                if mode == "malformed-ok" {
                    write(response(request, payload: PluginPreviewWorkerPayload()))
                } else if mode == "contradictory" {
                    write(response(request, payload: PluginPreviewWorkerPayload(ok: true, errorCode: "unexpected")))
                } else {
                    currentGeneration = request.generation
                    write(response(request, payload: PluginPreviewWorkerPayload(
                        ok: true,
                        pluginID: "com.example.preview",
                        activeGeneration: currentGeneration,
                        grantedPermissions: ["media"],
                        fixtureSources: ["media": "fixture"]
                    )))
                }
            case PluginPreviewWorkerMessageType.render:
                guard request.generation == currentGeneration else {
                    write(failure(request, code: "staleGeneration"))
                    continue
                }
                if mode == "worker-error" {
                    write(failure(request, code: "pluginError", message: "plugin script failed"))
                } else if mode == "invalid-render" {
                    write(response(request, payload: PluginPreviewWorkerPayload(ok: true, renderJSON: "{}")))
                } else {
                    write(sessionFrame(
                        PluginPreviewWorkerMessageType.invalidate,
                        generation: currentGeneration,
                        requestID: 0
                    ))
                    write(response(request, payload: PluginPreviewWorkerPayload(
                        ok: true,
                        renderJSON: #"[{"slot":"center","node":{"type":"text","value":"Preview"}}]"#
                    )))
                }
            case PluginPreviewWorkerMessageType.action:
                guard request.generation == currentGeneration else {
                    write(failure(request, code: "staleGeneration"))
                    continue
                }
                write(response(request, payload: PluginPreviewWorkerPayload(ok: true)))
                write(sessionFrame(
                    PluginPreviewWorkerMessageType.action,
                    generation: currentGeneration,
                    requestID: 0,
                    payload: PluginPreviewWorkerPayload(
                        actionID: request.payload.actionID,
                        value: request.payload.value
                    )
                ))
            case PluginPreviewWorkerMessageType.suspend,
                 PluginPreviewWorkerMessageType.resume,
                 PluginPreviewWorkerMessageType.unmount,
                 PluginPreviewWorkerMessageType.shutdown:
                if request.type != PluginPreviewWorkerMessageType.shutdown,
                   request.generation != currentGeneration {
                    write(failure(request, code: "staleGeneration"))
                    continue
                }
                write(response(request, payload: PluginPreviewWorkerPayload(ok: true)))
            default:
                write(failure(request, code: "invalidRequest"))
            }
        }
        exit(0)
    }

    private static func helloPayload(mode: String) -> PluginPreviewWorkerPayload {
        PluginPreviewWorkerPayload(
            ok: true,
            toolVersion: mode == "bad-tool" ? "other-tool" : "test-tool",
            protocolVersion: mode == "bad-protocol" ? 2 : PluginPreviewFrameCodec.protocolVersion,
            scenarioSchemaVersion: 1,
            pluginAPIVersions: mode == "bad-api" ? [1] : [1, 2],
            sdkContractHash: mode == "bad-contract" ? "other-contract" : "test-contract",
            activeGeneration: 0
        )
    }

    private static func response(
        _ request: PluginPreviewWorkerFrame,
        payload: PluginPreviewWorkerPayload
    ) -> PluginPreviewWorkerFrame {
        sessionFrame(
            request.type,
            generation: request.generation,
            requestID: request.requestID,
            payload: payload
        )
    }

    private static func failure(
        _ request: PluginPreviewWorkerFrame,
        code: String,
        message: String? = nil
    ) -> PluginPreviewWorkerFrame {
        response(request, payload: PluginPreviewWorkerPayload(
            ok: false,
            errorCode: code,
            message: message
        ))
    }

    private static func readFrame() -> PluginPreviewWorkerFrame? {
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
        return try? PluginPreviewFrameCodec.decode(PluginPreviewWorkerPayload.self, from: wire)
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

    private static func write(_ frame: PluginPreviewWorkerFrame) {
        guard let wire = try? PluginPreviewFrameCodec.encode(frame) else { exit(2) }
        do {
            try FileHandle.standardOutput.write(contentsOf: wire)
        } catch {
            exit(2)
        }
    }
}

@main
private struct SessionTests {
    static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--fake-session-worker"),
           CommandLine.arguments.indices.contains(index + 1) {
            FakeSessionWorker.run(mode: CommandLine.arguments[index + 1])
        }

        var realWorkerPath: String?
        if let index = CommandLine.arguments.firstIndex(of: "--real-worker"),
           CommandLine.arguments.indices.contains(index + 1) {
            realWorkerPath = CommandLine.arguments[index + 1]
        }

        let suite = SessionSuite()

        await suite.run("runs the complete request sequence with strict identities") {
            let recorder = SessionEventRecorder()
            let session = try makeSession(mode: "happy", recorder: recorder)
            do {
                let handshake = try await session.start(generation: 0)
                try sessionExpectEqual(handshake.protocolVersion, 1, "protocol version")
                try sessionExpectEqual(handshake.pluginAPIVersions, [1, 2], "plugin API versions")

                let loaded = try await session.load(
                    pluginDirectory: URL(fileURLWithPath: "/plugin"),
                    scenarioPath: URL(fileURLWithPath: "/scenario.json")
                )
                try sessionExpectEqual(loaded.pluginID, "com.example.preview", "plugin ID")
                try sessionExpectEqual(loaded.generation, 1, "loaded generation")

                let render = try await session.render()
                try sessionExpect(render.contains("Preview"), "validated render JSON")
                try await session.action(id: "play", value: 0.5)
                try await session.suspend()
                try await session.resume()
                try await session.unmount()

                try await sessionExpectError({ $0 == .invalidState }) {
                    try await session.render()
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                try sessionExpect(
                    recorder.snapshot.contains { event in
                        if case .invalidate(generation: 1) = event { return true }
                        return false
                    },
                    "invalidate event"
                )
                try sessionExpect(
                    recorder.snapshot.contains { event in
                        if case .action(generation: 1, actionID: "play", value: 0.5) = event { return true }
                        return false
                    },
                    "action event"
                )

                await session.shutdown()
                let snapshot = await session.snapshot()
                try sessionExpectEqual(snapshot.state, .stopped, "stopped state")
                try sessionExpectEqual(snapshot.process.state, .stopped, "stopped process")
            } catch {
                await session.stop()
                throw error
            }
        }

        await suite.run("rejects incompatible handshake versions and contract identity") {
            let cases: [(String, (PluginPreviewSessionError) -> Bool)] = [
                ("bad-protocol", { $0 == .incompatibleProtocolVersion(found: 2) }),
                ("bad-api", { $0 == .unsupportedPluginAPIVersion(required: 2, advertised: [1]) }),
                ("bad-contract", { $0 == .incompatibleSDKContractHash(found: "other-contract") }),
                ("bad-tool", { $0 == .incompatibleToolVersion(found: "other-tool") }),
            ]
            for (mode, predicate) in cases {
                let session = try makeSession(mode: mode, recorder: SessionEventRecorder())
                try await sessionExpectError(predicate) {
                    try await session.start(generation: 0)
                }
                let snapshot = await session.snapshot()
                try sessionExpectEqual(snapshot.state, .failed, "failed handshake state")
                try sessionExpectEqual(snapshot.process.state, .stopped, "handshake worker cleanup")
            }
        }

        await suite.run("rejects missing and contradictory ok/error responses") {
            for (mode, predicate) in [
                ("malformed-ok", { $0 == .missingResponseStatus }),
                ("contradictory", { $0 == .contradictoryResponse }),
            ] as [(String, (PluginPreviewSessionError) -> Bool)] {
                let session = try makeSession(mode: mode, recorder: SessionEventRecorder())
                do {
                    _ = try await session.start(generation: 0)
                    try await sessionExpectError(predicate) {
                        try await session.load(
                            pluginDirectory: URL(fileURLWithPath: "/plugin"),
                            scenarioPath: URL(fileURLWithPath: "/scenario.json")
                        )
                    }
                    await session.stop()
                } catch {
                    await session.stop()
                    throw error
                }
            }
        }

        await suite.run("maps worker error codes and validates render output") {
            let errorSession = try makeSession(mode: "worker-error", recorder: SessionEventRecorder())
            do {
                _ = try await errorSession.start(generation: 0)
                _ = try await errorSession.load(
                    pluginDirectory: URL(fileURLWithPath: "/plugin"),
                    scenarioPath: URL(fileURLWithPath: "/scenario.json")
                )
                try await sessionExpectError({ error in
                    if case .workerFailure(code: "pluginError", message: "plugin script failed") = error {
                        return true
                    }
                    return false
                }) {
                    try await errorSession.render()
                }
                await errorSession.stop()
            } catch {
                await errorSession.stop()
                throw error
            }

            let renderSession = try makeSession(mode: "invalid-render", recorder: SessionEventRecorder())
            do {
                _ = try await renderSession.start(generation: 0)
                _ = try await renderSession.load(
                    pluginDirectory: URL(fileURLWithPath: "/plugin"),
                    scenarioPath: URL(fileURLWithPath: "/scenario.json")
                )
                try await sessionExpectError({ $0 == .invalidRenderJSON }) {
                    try await renderSession.render()
                }
                await renderSession.stop()
            } catch {
                await renderSession.stop()
                throw error
            }
        }

        await suite.run("runs against the real worker protocol with generation advance") {
            guard let realWorkerPath else {
                throw SessionTestFailure(description: "missing --real-worker path")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("switchly-preview-session-real-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let pluginDirectory = directory.appendingPathComponent("plugin", isDirectory: true)
            try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
            let manifest = #"{"id":"com.example.real-preview","name":{"en":"Real Preview"},"version":"1.0.0","apiVersion":2,"matches":["com.example.app"],"permissions":[],"entry":"main.js"}"#
            let source = #"globalThis.__switchlyPlugin={async render(ctx){let n=await ctx.storage.get("counter");return[{slot:"center",node:{type:"text",value:"Real Preview "+(n||0)}}]},async onAction(ctx){await ctx.storage.set("counter",7)}};"#
            let scenario = #"{"schemaVersion":1,"id":"real","environment":{"locale":"en","appearance":"light","glass":false,"reduceMotion":false,"contentWidthPoints":320},"target":{"bundleID":"com.example.app","appName":"Example"},"steps":[]}"#
            try Data(manifest.utf8).write(to: pluginDirectory.appendingPathComponent("manifest.json"))
            try Data(source.utf8).write(to: pluginDirectory.appendingPathComponent("main.js"))
            let scenarioURL = directory.appendingPathComponent("scenario.json")
            try Data(scenario.utf8).write(to: scenarioURL)

            let session = try makeSession(
                executable: URL(fileURLWithPath: realWorkerPath),
                arguments: [],
                recorder: SessionEventRecorder(),
                compatibility: PluginPreviewSessionCompatibility(
                    pluginAPIVersion: 2,
                    sdkContractHash: PluginPreviewContract.sdkContractHash,
                    toolVersion: "0.1.0"
                )
            )
            do {
                _ = try await session.start(generation: 0)
                let first = try await session.load(pluginDirectory: pluginDirectory, scenarioPath: scenarioURL)
                try sessionExpectEqual(first.generation, 1, "first load generation")
                let firstRender = try await session.render()
                try sessionExpect(firstRender.contains("Real Preview"), "real worker first render")
                try await session.action(id: "noop")
                let storage = try await session.storageDump()
                try sessionExpect(storage.contains("\"counter\":7"), "storage dump includes action state")
                try await session.suspend()
                try await session.resume()
                try await session.unmount()

                let second = try await session.load(pluginDirectory: pluginDirectory, scenarioPath: scenarioURL, storageJSON: storage)
                try sessionExpectEqual(second.generation, 2, "second load generation")
                let secondRender = try await session.render()
                try sessionExpect(secondRender.contains("Real Preview"), "real worker second render")
                try sessionExpect(secondRender.contains("Real Preview 7"), "storage restored after reload")

                await session.shutdown()
                let snapshot = await session.snapshot()
                try sessionExpectEqual(snapshot.state, .stopped, "real worker stopped state")
                try sessionExpectEqual(snapshot.process.state, .stopped, "real worker process cleanup")
                let replacement = try makeSession(
                    executable: URL(fileURLWithPath: realWorkerPath), arguments: [], recorder: SessionEventRecorder(),
                    compatibility: PluginPreviewSessionCompatibility(pluginAPIVersion: 2, sdkContractHash: PluginPreviewContract.sdkContractHash, toolVersion: "0.1.0")
                )
                do {
                    _ = try await replacement.start(generation: 2)
                    let third = try await replacement.load(pluginDirectory: pluginDirectory, scenarioPath: scenarioURL, storageJSON: storage)
                    try sessionExpectEqual(third.generation, 3, "new worker generation")
                    let thirdRender = try await replacement.render()
                    try sessionExpect(thirdRender.contains("Real Preview 7"), "new worker restores storage")
                    await replacement.shutdown()
                } catch {
                    await replacement.stop()
                    throw error
                }
            } catch {
                await session.stop()
                throw error
            }
        }

        print("SUMMARY passed=\(suite.passed) failed=\(suite.failed)")
        exit(suite.failed == 0 ? 0 : 1)
    }
}
