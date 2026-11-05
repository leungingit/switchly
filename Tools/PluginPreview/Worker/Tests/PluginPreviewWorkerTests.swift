import Darwin
import Foundation

#if PLUGIN_PREVIEW_WORKER_TESTS
private struct WorkerTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw WorkerTestFailure(description: message) }
}

private func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, _ message: String) throws {
    let value = try actual()
    guard value == expected else {
        throw WorkerTestFailure(description: "\(message): expected \(expected), got \(value)")
    }
}

private func expectFSError(_ expected: PluginFSError, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as PluginFSError {
        try expectEqual(error, expected, "fs error")
        return
    }
    throw WorkerTestFailure(description: "expected \(expected), no error was thrown")
}

@main
private enum PluginPreviewWorkerTests {
    static func main() throws {
        if CommandLine.arguments.dropFirst() == ["--standard-streams"] {
            exit(PluginPreviewWorkerService.runStandardStreams())
        }
        try testFixtureLimitsAndStableScanOrder()
        try testConsoleIsBufferedAndDrainedOnce()
        try testStandardStreamIsolation()
        try testProtocolErrorIsAFrame()
        try testRawRenderJSONUsesTheHostValidator()
        try testWorkerLifecycleAndFrames()
        try testVirtualClockAdvance()
        print("PluginPreviewWorker tests passed")
    }

    private static func testProtocolErrorIsAFrame() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-preview-protocol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let inputURL = temporary.appendingPathComponent("input.frames")
        let outputURL = temporary.appendingPathComponent("output.frames")
        let errorURL = temporary.appendingPathComponent("worker.stderr")
        try Data([0, 0, 0, 8, 0x7b]).write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        let code = PluginPreviewWorkerService(input: input, output: output, error: error).run()
        try input.close()
        try output.close()
        try error.close()

        try expectEqual(code, 65, "protocol error exit")
        var decoder = PluginPreviewFrameStreamDecoder<PluginPreviewWorkerPayload>()
        let frames = try decoder.append(Data(contentsOf: outputURL))
        try decoder.finish()
        try expectEqual(frames.count, 1, "one protocol error frame")
        try expectEqual(frames[0].type, "error", "protocol error type")
        try expectEqual(frames[0].payload.errorCode, "protocolError", "protocol error code")
    }

    private static func testRawRenderJSONUsesTheHostValidator() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-preview-invalid-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let manifest = PluginManifest(
            id: "com.example.invalid-output", name: ["en": "Invalid"], version: "1", apiVersion: 2,
            matches: ["com.example.app"], permissions: [], entry: "main.js", refreshInterval: nil
        )
        let package = PluginPackage(
            manifest: manifest, directory: temporary,
            source: #"globalThis.__switchlyPlugin={render(){return [{slot:"center",node:{type:"unknown"}}]}};"#,
            origin: .user
        )
        let runtime = PluginRuntime(package: package, timeout: 2, permissions: [])
        let context = PluginRenderContext(bundleID: "com.example.app", pid: 0, appName: "App", windowID: 0, titleSummary: "")
        let result = waitForAsync { await runtime.renderJSON(context: context) }
        guard case .failure(.invalidOutput) = result else {
            throw WorkerTestFailure(description: "raw render JSON bypassed PluginRenderOutput validation")
        }
    }

    /// 插件 console 只进内存缓冲，由请求方显式 drain；drain 后清空，缓冲有上限。
    private static func testConsoleIsBufferedAndDrainedOnce() throws {
        let manifest = PluginManifest(
            id: "com.example.console", name: ["en": "Console"], version: "1", apiVersion: 2,
            matches: ["com.example.app"], permissions: [], entry: "main.js", refreshInterval: nil
        )
        let source = #"globalThis.__switchlyPlugin={render(){for(let i=0;i<250;i++)console.log("n"+i);console.warn("w");return [{slot:"center",node:{type:"text",value:"x"}}]}};"#
        let package = PluginPackage(manifest: manifest, directory: FileManager.default.temporaryDirectory, source: source, origin: .user)
        let runtime = PluginRuntime(package: package, timeout: 2, permissions: [])
        let context = PluginRenderContext(bundleID: "com.example.app", pid: 0, appName: "App", windowID: 0, titleSummary: "")
        let result = waitForAsync { await runtime.renderJSON(context: context) }
        guard case .success = result else { throw WorkerTestFailure(description: "console plugin failed to render: \(result)") }
        let lines = runtime.drainConsole()
        try expectEqual(lines.count, 200, "console ring is capped")
        try expectEqual(lines.last?.level, "warn", "newest line kept")
        try expectEqual(lines.last?.message, "w", "newest message")
        try expectEqual(lines.first?.message, "n51", "oldest lines dropped")
        try expect(runtime.drainConsole().isEmpty, "drain clears the buffer")
    }

    private static func testStandardStreamIsolation() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-preview-streams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let pluginDirectory = temporary.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try Data(loggingManifest.utf8).write(to: pluginDirectory.appendingPathComponent("manifest.json"))
        try Data(loggingPluginSource.utf8).write(to: pluginDirectory.appendingPathComponent("main.js"))
        let scenarioURL = temporary.appendingPathComponent("scenario.json")
        try Data(loggingScenario.utf8).write(to: scenarioURL)

        var inputData = try frame("hello", generation: 0, requestID: 1)
        inputData.append(try frame("load", generation: 1, requestID: 2, payload: .init(
            pluginDirectory: pluginDirectory.path,
            scenarioPath: scenarioURL.path
        )))
        inputData.append(try frame("render", generation: 1, requestID: 3))
        inputData.append(try frame("shutdown", generation: 1, requestID: 4))
        let inputURL = temporary.appendingPathComponent("input.frames")
        let outputURL = temporary.appendingPathComponent("output.frames")
        let errorURL = temporary.appendingPathComponent("worker.stderr")
        try inputData.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--standard-streams"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        try input.close()
        try output.close()
        try error.close()

        try expectEqual(process.terminationStatus, 0, "standard stream worker exit")
        var decoder = PluginPreviewFrameStreamDecoder<PluginPreviewWorkerPayload>()
        let frames = try decoder.append(Data(contentsOf: outputURL))
        try decoder.finish()
        try expectEqual(frames.map(\.type), ["hello", "load", "render", "shutdown"], "stdout contains frames only")
        let stderr = try String(contentsOf: errorURL, encoding: .utf8)
        try expect(stderr.contains("worker_shutdown"), "worker diagnostics stay on stderr")
        try expect(!stderr.contains("fixture-log-secret"), "plugin console content is suppressed")
    }

    private static func testFixtureLimitsAndStableScanOrder() throws {
        let reader = try PluginFixtureFileReader(roots: ["s": .init(entries: [
            .init(path: "z.jsonl", text: "z", modified: 10),
            .init(path: "a.jsonl", text: "a", modified: 10),
            .init(path: "m.jsonl", text: "m", modified: 20),
        ])], now: { 100 })
        let scanned = try reader.scan(root: "s", path: "", depth: 1, suffix: ".jsonl", modifiedWithin: nil)
        try expectEqual(scanned.map(\.path), ["m.jsonl", "a.jsonl", "z.jsonl"], "mtime tie order")

        try expectFSError(.denied) {
            _ = try PluginFixtureFileReader(roots: ["s": .init(entries: [
                .init(path: "bad", modified: .infinity),
            ])])
        }
        try expectFSError(.denied) {
            _ = try PluginFixtureFileReader(roots: ["s": .init(entries: [
                .init(path: "large", text: String(repeating: "x", count: PluginFileReader.maxReadBytes + 1)),
            ])])
        }
        let tooMany = (0...PluginFixtureFileReader.maxFixtureEntriesPerRoot).map {
            PluginFixtureFileReader.Entry(path: "f\($0)")
        }
        try expectFSError(.tooLarge) {
            _ = try PluginFixtureFileReader(roots: ["s": .init(entries: tooMany)])
        }
        let tooManyRoots = Dictionary(uniqueKeysWithValues: (0...PluginFixtureFileReader.maxFixtureRoots).map {
            ("r\($0)", PluginFixtureFileReader.Root(entries: []))
        })
        try expectFSError(.tooLarge) {
            _ = try PluginFixtureFileReader(roots: tooManyRoots)
        }

        let tooManyTracks = (0...PluginPreviewMediaFixture.maxLibraryTracks).map {
            PluginPreviewMediaFixture.Track(persistentID: "p\($0)", title: "t", artist: "a", bpm: 120, genres: [])
        }
        do {
            _ = try PluginPreviewMediaFixture(nowPlaying: nil, library: tooManyTracks, artworkBase64: nil).validated()
            throw WorkerTestFailure(description: "media library limit was not enforced")
        } catch PluginPreviewWorkerFailure.invalidFixture {
        }
    }

    private static func testWorkerLifecycleAndFrames() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-preview-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let pluginDirectory = temporary.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: pluginDirectory.appendingPathComponent("manifest.json"))
        try Data(pluginSource.utf8).write(to: pluginDirectory.appendingPathComponent("main.js"))
        try Data(mediaFixture.utf8).write(to: temporary.appendingPathComponent("media.json"))
        try Data(weatherFixture.utf8).write(to: temporary.appendingPathComponent("weather.json"))
        try Data(fsFixture.utf8).write(to: temporary.appendingPathComponent("fs.json"))
        let scenarioURL = temporary.appendingPathComponent("scenario.json")
        try Data(scenario.utf8).write(to: scenarioURL)

        let mediaURL = temporary.appendingPathComponent("media.json")
        for invalid in [mediaFixture.replacingOccurrences(of: "\"progress\":0.06666666666666667,", with: ""),
                        mediaFixture.replacingOccurrences(of: "\"progress\":0.06666666666666667", with: "\"progress\":0.9"),
                        mediaFixture.replacingOccurrences(of: "\"nowPlaying\":", with: "\"supported\":true,\"nowPlaying\":")] {
            try Data(invalid.utf8).write(to: mediaURL)
            do {
                _ = try PluginPreviewWorkerLoader.load(pluginDirectory: pluginDirectory.path, scenarioPath: scenarioURL.path)
                throw WorkerTestFailure(description: "invalid media fixture accepted")
            } catch PluginPreviewWorkerFailure.invalidFixture { }
        }
        try Data(mediaFixture.utf8).write(to: mediaURL)
        let weatherURL = temporary.appendingPathComponent("weather.json")
        try Data(weatherFixture.replacingOccurrences(of: "\"online\"", with: "\"fixture\"").utf8).write(to: weatherURL)
        do {
            _ = try PluginPreviewWorkerLoader.load(pluginDirectory: pluginDirectory.path, scenarioPath: scenarioURL.path)
            throw WorkerTestFailure(description: "invalid weather source accepted")
        } catch PluginPreviewWorkerFailure.invalidFixture { }
        try Data(weatherFixture.utf8).write(to: weatherURL)

        let requests = try [
            frame("hello", generation: 0, requestID: 1),
            frame("render", generation: 0, requestID: 2),
            frame("load", generation: 1, requestID: 3, payload: .init(
                pluginDirectory: pluginDirectory.path,
                scenarioPath: scenarioURL.path
            )),
            frame("render", generation: 1, requestID: 4),
            frame("action", generation: 1, requestID: 5, payload: .init(actionID: "set", value: 1)),
            frame("suspend", generation: 1, requestID: 6),
            frame("render", generation: 1, requestID: 7),
            frame("resume", generation: 1, requestID: 8),
            frame("render", generation: 1, requestID: 9),
            frame("render", generation: 0, requestID: 10),
            frame("load", generation: 1, requestID: 11, payload: .init(
                pluginDirectory: pluginDirectory.path,
                scenarioPath: scenarioURL.path
            )),
            frame("render", generation: 1, requestID: 12),
            frame("unmount", generation: 1, requestID: 13),
            frame("render", generation: 1, requestID: 14),
            frame("load", generation: 2, requestID: 15, payload: .init(
                pluginDirectory: pluginDirectory.path,
                scenarioPath: scenarioURL.path
            )),
            frame("shutdown", generation: 2, requestID: 16),
        ].reduce(into: Data()) { $0.append($1) }

        let inputURL = temporary.appendingPathComponent("input.frames")
        let outputURL = temporary.appendingPathComponent("output.frames")
        let errorURL = temporary.appendingPathComponent("worker.stderr")
        try requests.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        let service = PluginPreviewWorkerService(input: input, output: output, error: error)
        let exitCode = service.run()
        try input.close()
        try output.close()
        try error.close()
        try expectEqual(exitCode, 0, "worker exit")

        var decoder = PluginPreviewFrameStreamDecoder<PluginPreviewWorkerPayload>()
        let responses = try decoder.append(Data(contentsOf: outputURL))
        try decoder.finish()

        let hello = try response(1, in: responses)
        try expectEqual(hello.payload.toolVersion, PluginPreviewWorkerService.toolVersion, "tool version")
        try expectEqual(hello.payload.pluginAPIVersions, [1, 2], "plugin API versions")
        try expectEqual(hello.payload.sdkContractHash, PluginPreviewContract.sdkContractHash, "contract hash marker")

        try expectEqual(try response(2, in: responses).payload.errorCode, "notLoaded", "render before load")
        let loaded = try response(3, in: responses)
        try expectEqual(loaded.payload.pluginID, "com.example.preview", "loaded plugin")
        try expectEqual(loaded.payload.fixtureSources?["media"], "fixture", "media source")
        try expectEqual(loaded.payload.fixtureSources?["weather"], "fixture", "weather source")
        try expectEqual(loaded.payload.fixtureSources?["fs"], "fixture", "fs source")
        try expectEqual(loaded.payload.fixtureSources?["storage"], "memory", "storage source")

        let firstRender = try response(4, in: responses)
        let firstJSON = try expectUnwrap(firstRender.payload.renderJSON, "render JSON")
        _ = try PluginRenderOutput.decode(json: Data(firstJSON.utf8))
        try expect(firstJSON.contains("Fixture Song"), "media fixture reached JS")
        try expect(firstJSON.contains("rain"), "weather fixture reached JS")
        try expect(firstJSON.contains("session.jsonl.zstd"), "fs fixture reached JS")
        try expect(firstJSON.contains("ready"), "storage seed reached JS")
        try expect(firstJSON.contains("true|rain"), "settings reached JS")

        try expectEqual(try response(5, in: responses).payload.ok, true, "action")
        try expect(responses.contains { $0.type == "invalidate" && $0.generation == 1 && $0.requestID == 0 }, "invalidate event")
        try expectEqual(try response(6, in: responses).payload.ok, true, "suspend")
        try expectEqual(try response(7, in: responses).payload.errorCode, "suspended", "render while suspended")
        try expectEqual(try response(8, in: responses).payload.ok, true, "resume")
        let resumedJSON = try expectUnwrap(try response(9, in: responses).payload.renderJSON, "resumed render")
        try expect(resumedJSON.contains("yes"), "action storage mutation")
        try expectEqual(try response(10, in: responses).payload.errorCode, "staleGeneration", "stale render")
        try expectEqual(try response(11, in: responses).payload.errorCode, "staleGeneration", "non-advancing reload")
        try expectEqual(try response(12, in: responses).payload.ok, true, "failed reload keeps old runtime")
        try expectEqual(try response(13, in: responses).payload.ok, true, "unmount")
        try expectEqual(try response(14, in: responses).payload.errorCode, "notLoaded", "render after unmount")
        try expectEqual(try response(15, in: responses).payload.activeGeneration, 2, "generation reload")
        try expectEqual(try response(16, in: responses).payload.ok, true, "shutdown")
        try expect(!responses.contains { $0.requestID > 16 }, "no frames after shutdown")
    }

    private static func testVirtualClockAdvance() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchly-preview-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let pluginDirectory = temporary.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try Data(loggingManifest.utf8).write(to: pluginDirectory.appendingPathComponent("manifest.json"))
        try Data(clockPluginSource.utf8).write(to: pluginDirectory.appendingPathComponent("main.js"))
        let withClock = temporary.appendingPathComponent("clock.json")
        let realtime = temporary.appendingPathComponent("realtime.json")
        try Data(clockScenario.utf8).write(to: withClock)
        try Data(loggingScenario.utf8).write(to: realtime)

        let session = PluginPreviewWorkerSession(
            output: PluginPreviewWorkerFrameWriter(handle: FileHandle(forWritingAtPath: "/dev/null")!),
            diagnostics: PluginPreviewWorkerDiagnostics(handle: FileHandle(forWritingAtPath: "/dev/null")!)
        )
        func send(_ type: String, _ generation: UInt64, _ id: UInt64, _ payload: PluginPreviewWorkerPayload = .init()) -> PluginPreviewWorkerPayload {
            let request = PluginPreviewWorkerFrame(type: type, generation: generation, requestID: id, payload: payload)
            return waitForAsync { await session.handle(request) }.response.payload
        }
        func texts(_ payload: PluginPreviewWorkerPayload) -> String { payload.renderJSON ?? "" }

        _ = send("hello", 0, 1)
        let loaded = send("load", 1, 2, .init(pluginDirectory: pluginDirectory.path, scenarioPath: withClock.path))
        try expectEqual(loaded.ok, true, "clock scenario loads")
        let first = texts(send("render", 1, 3))
        try expect(first.contains("1700000000000|0"), "virtual start time and no tick yet: \(first)")
        try expectEqual(send("advance", 1, 4, .init(value: 99)).firedTimers, 0, "early advance fires nothing")
        try expect(texts(send("render", 1, 5)).contains("1700000000099|0"), "time advanced by 99 ms")
        try expectEqual(send("advance", 1, 6, .init(value: 1)).firedTimers, 1, "due advance fires the timer")
        try expect(texts(send("render", 1, 7)).contains("|1"), "timer callback ran")
        try expectEqual(send("advance", 1, 8, .init(value: -1)).errorCode, "invalidRequest", "negative advance rejected")
        try expectEqual(send("advance", 1, 9, .init(value: 1e12)).errorCode, "invalidRequest", "oversized advance rejected")

        let realtimeLoaded = send("load", 2, 10, .init(pluginDirectory: pluginDirectory.path, scenarioPath: realtime.path))
        try expectEqual(realtimeLoaded.ok, true, "realtime scenario loads")
        try expectEqual(send("advance", 2, 11, .init(value: 10)).errorCode, "invalidRequest", "advance needs a declared clock")
    }

    private static let clockScenario = #"""
    {"schemaVersion":1,"id":"clock","environment":{"locale":"en","appearance":"light","glass":false,"reduceMotion":false,"contentWidthPoints":320},"target":{"bundleID":"com.example.app","appName":"Example"},"clock":{"startEpochMs":1700000000000,"seed":7},"steps":[]}
    """#

    private static let clockPluginSource = #"""
    var ticks = 0, armed = false;
    globalThis.__switchlyPlugin = {
      async render(ctx) {
        if (!armed) { armed = true; setTimeout(function () { ticks = 1; }, 100); }
        return [{ slot: "center", node: { type: "text", value: Date.now() + "|" + ticks } }];
      },
      onAction(ctx, id, value) {}
    };
    """#

    private static func frame(
        _ type: String,
        generation: UInt64,
        requestID: UInt64,
        payload: PluginPreviewWorkerPayload = .init()
    ) throws -> Data {
        try PluginPreviewFrameCodec.encode(PluginPreviewWorkerFrame(
            type: type, generation: generation, requestID: requestID, payload: payload
        ))
    }

    private static func response(_ requestID: UInt64, in frames: [PluginPreviewWorkerFrame]) throws -> PluginPreviewWorkerFrame {
        try expectUnwrap(frames.first { $0.requestID == requestID && $0.type != "invalidate" }, "response \(requestID)")
    }

    private static func expectUnwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw WorkerTestFailure(description: "missing \(message)") }
        return value
    }

    private static func waitForAsync<T>(_ operation: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var value: T?
        Task {
            value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return value!
    }

    private static let manifest = #"""
    {
      "id":"com.example.preview",
      "name":{"en":"Preview"},
      "version":"1.0.0",
      "apiVersion":2,
      "matches":["com.example.app"],
      "permissions":["media.nowPlaying","media.control","media.library","weather.current","fs.read"],
      "entry":"main.js",
      "fsRoots":[{"id":"sessions","path":"~/.preview-fixture","summary":{"en":"fixture"}}],
      "settings":[
        {"key":"wheelLayout","title":{"en":"Wheel"},"default":false},
        {"key":"condition","type":"select","title":{"en":"Condition"},"default":"clear","options":[{"value":"clear","title":{"en":"Clear"}},{"value":"rain","title":{"en":"Rain"}}]},
        {"key":"temperature","type":"number","title":{"en":"Temperature"},"default":20,"min":-40,"max":50,"step":1}
      ]
    }
    """#

    private static let loggingManifest = #"""
    {"id":"com.example.stream","name":{"en":"Stream"},"version":"1","apiVersion":2,"matches":["com.example.app"],"permissions":[],"entry":"main.js"}
    """#

    private static let loggingPluginSource = #"""
    console.log("fixture-log-secret");
    globalThis.__switchlyPlugin = {
      render() { return [{ slot: "center", node: { type: "text", value: "ok" } }]; }
    };
    """#

    private static let loggingScenario = #"""
    {"schemaVersion":1,"id":"stream","environment":{"locale":"en","appearance":"light","glass":false,"reduceMotion":false,"contentWidthPoints":320},"target":{"bundleID":"com.example.app","appName":"Example"},"steps":[]}
    """#

    private static let pluginSource = #"""
    globalThis.__switchlyPlugin = {
      async render(ctx) {
        const np = await ctx.media.nowPlaying();
        const weather = ctx.weather.current();
        const names = (await ctx.fs.list("sessions", "run")).map(e => e.name).join(",");
        const seed = await ctx.storage.get("seed");
        const action = await ctx.storage.get("action");
        return [{ slot: "center", node: { type: "text", value: [
          np && np.title, weather && weather.condition, names, seed, action || "none",
          String(ctx.settings.wheelLayout) + "|" + ctx.settings.condition
        ].join("|") } }];
      },
      async onAction(ctx, id, value) {
        if (id === "set" && value === 1) {
          await ctx.storage.set("action", "yes");
          ctx.invalidate();
        }
      }
    };
    """#

    private static let mediaFixture = #"""
    {"nowPlaying":{"playing":true,"title":"Fixture Song","artist":"Fixture Artist","album":"Fixture Album","position":12,"duration":180,"progress":0.06666666666666667,"liked":false,"canLike":true},"library":[{"persistentID":"track-1","title":"Fixture Song","artist":"Fixture Artist","bpm":120,"genres":["pop"]}]}
    """#

    private static let weatherFixture = #"{"condition":"rain","temperature":12,"wind":18,"source":"online"}"#

    private static let fsFixture = #"""
    {"roots":{"sessions":{"entries":[
      {"path":"run","isDirectory":true},
      {"path":"run/session.jsonl.zstd","text":"{}","modified":99},
      {"path":"run/session.lock","text":"","modified":99,"locked":true}
    ]}}}
    """#

    private static let scenario = #"""
    {
      "schemaVersion":1,
      "id":"worker-fixture",
      "environment":{"locale":"zh-Hans","appearance":"dark","glass":false,"reduceMotion":true,"contentWidthPoints":360},
      "target":{"bundleID":"com.example.app","appName":"Example","titleSummary":"Fixture"},
      "fixtures":{"media":"media.json","weather":"weather.json","fs":"fs.json"},
      "grants":["media.nowPlaying","media.control","media.library","weather.current","fs.read"],
      "settings":{"wheelLayout":true,"condition":"rain","temperature":12},
      "storageSeed":{"seed":"ready"},
      "steps":[]
    }
    """#
}
#endif
