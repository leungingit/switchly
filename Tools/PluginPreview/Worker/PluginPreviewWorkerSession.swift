import Foundation

final class PluginPreviewWorkerFrameWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ frame: PluginPreviewWorkerFrame) throws {
        let data = try PluginPreviewFrameCodec.encode(frame)
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }
}

final class PluginPreviewWorkerSession: @unchecked Sendable {
    private struct ActivePlugin {
        let runtime: PluginRuntime
        let context: PluginRenderContext
        let activityProvider: PluginFixtureActivityProvider?
        let generation: UInt64
        let storage: PluginPreviewFixtureStorage
        let hasVirtualClock: Bool
    }

    private let output: PluginPreviewWorkerFrameWriter
    private let diagnostics: PluginPreviewWorkerDiagnostics
    private let lock = NSLock()
    private var active: ActivePlugin?
    private var currentGeneration: UInt64 = 0
    private var didHandshake = false

    init(output: PluginPreviewWorkerFrameWriter, diagnostics: PluginPreviewWorkerDiagnostics) {
        self.output = output
        self.diagnostics = diagnostics
    }

    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    func handle(_ request: PluginPreviewWorkerFrame) async -> (response: PluginPreviewWorkerFrame, keepRunning: Bool) {
        guard didHandshake || request.type == PluginPreviewWorkerMessageType.hello else {
            return (failure(request, .invalidRequest), true)
        }
        switch request.type {
        case PluginPreviewWorkerMessageType.hello:
            guard !didHandshake else { return (failure(request, .invalidRequest), true) }
            beginHandshake(generation: request.generation)
            return (response(request, payload: helloPayload()), true)
        case PluginPreviewWorkerMessageType.load:
            return load(request)
        case PluginPreviewWorkerMessageType.render:
            return await render(request)
        case PluginPreviewWorkerMessageType.action:
            return await action(request)
        case PluginPreviewWorkerMessageType.advance:
            return await advance(request)
        case PluginPreviewWorkerMessageType.suspend:
            return lifecycle(request, operation: .suspend)
        case PluginPreviewWorkerMessageType.resume:
            return lifecycle(request, operation: .resume)
        case PluginPreviewWorkerMessageType.unmount:
            return unmount(request, shutdown: false)
        case PluginPreviewWorkerMessageType.shutdown:
            return unmount(request, shutdown: true)
        case PluginPreviewWorkerMessageType.storageDump:
            return storageDump(request)
        default:
            return (errorResponse(generation: request.generation, requestID: request.requestID, .invalidRequest), true)
        }
    }

    private func beginHandshake(generation: UInt64) {
        lock.lock()
        currentGeneration = generation
        didHandshake = true
        lock.unlock()
    }

    private func helloPayload() -> PluginPreviewWorkerPayload {
        PluginPreviewWorkerPayload(
            ok: true,
            toolVersion: PluginPreviewWorkerService.toolVersion,
            protocolVersion: PluginPreviewFrameCodec.protocolVersion,
            scenarioSchemaVersion: PluginPreviewContract.scenarioSchemaVersion,
            pluginAPIVersions: Array(PluginManifest.supportedAPIVersions),
            sdkContractHash: PluginPreviewContract.sdkContractHash,
            activeGeneration: generation
        )
    }

    private func load(_ request: PluginPreviewWorkerFrame) -> (PluginPreviewWorkerFrame, Bool) {
        guard let pluginDirectory = request.payload.pluginDirectory,
              let scenarioPath = request.payload.scenarioPath,
              !pluginDirectory.isEmpty, !scenarioPath.isEmpty else {
            return (failure(request, .invalidRequest), true)
        }
        guard request.generation > generation else {
            return (failure(request, .staleGeneration), true)
        }

        let prepared: PluginPreviewPreparedPlugin
        do {
            prepared = try PluginPreviewWorkerLoader.load(pluginDirectory: pluginDirectory, scenarioPath: scenarioPath, storageJSON: request.payload.storageJSON)
        } catch let failure as PluginPreviewWorkerFailure {
            diagnostics.log("load_failed code=\(failure.code)")
            return (failureResponse(request, failure), true)
        } catch {
            diagnostics.log("load_failed code=internal")
            return (failure(request, .invalidPackage), true)
        }

        let previous: ActivePlugin?
        lock.lock()
        previous = active
        currentGeneration = request.generation
        let activePlugin = ActivePlugin(
            runtime: prepared.runtime,
            context: prepared.context,
            activityProvider: prepared.activityProvider,
            generation: request.generation,
            storage: prepared.storage,
            hasVirtualClock: prepared.hasVirtualClock
        )
        active = activePlugin
        lock.unlock()

        prepared.runtime.onInvalidate = { [weak self] in
            self?.emitInvalidate(generation: request.generation)
        }
        previous?.runtime.onInvalidate = nil
        previous?.runtime.unmount()
        diagnostics.log("plugin_loaded plugin=\(prepared.pluginID) generation=\(request.generation)")
        return (response(request, payload: PluginPreviewWorkerPayload(
            ok: true,
            pluginID: prepared.pluginID,
            activeGeneration: request.generation,
            grantedPermissions: prepared.permissions,
            fixtureSources: prepared.fixtureSources,
            artworkBase64: prepared.artworkBase64
        )), true)
    }

    private func render(_ request: PluginPreviewWorkerFrame) async -> (PluginPreviewWorkerFrame, Bool) {
        guard let active = activePlugin(for: request) else { return (failure(request, stateFailure(request)), true) }
        let result = await active.runtime.renderJSON(context: active.context)
        switch result {
        case .success(let json):
            return (response(request, payload: PluginPreviewWorkerPayload(ok: true, renderJSON: json, consoleLines: console(request, active))), true)
        case .failure(let error):
            let failure = runtimeFailure(error)
            diagnostics.log("render_failed code=\(failure.code)")
            return (failureResponse(request, failure), true)
        }
    }

    private func action(_ request: PluginPreviewWorkerFrame) async -> (PluginPreviewWorkerFrame, Bool) {
        guard let active = activePlugin(for: request) else { return (failure(request, stateFailure(request)), true) }
        guard let actionID = request.payload.actionID, !actionID.isEmpty,
              request.payload.value?.isFinite != false else {
            return (failure(request, .invalidRequest), true)
        }
        let result = await active.runtime.performAction(
            id: actionID,
            value: request.payload.value,
            context: active.context
        )
        switch result {
        case .success:
            return (response(request, payload: PluginPreviewWorkerPayload(ok: true, consoleLines: console(request, active))), true)
        case .failure(let error):
            let failure = runtimeFailure(error)
            diagnostics.log("action_failed code=\(failure.code)")
            return (failureResponse(request, failure), true)
        }
    }

    /// 仅当场景声明 `clock` 时可用；实时场景明确拒绝，避免静默忽略。
    private func advance(_ request: PluginPreviewWorkerFrame) async -> (PluginPreviewWorkerFrame, Bool) {
        guard let active = activePlugin(for: request) else { return (failure(request, stateFailure(request)), true) }
        guard active.hasVirtualClock, let delta = request.payload.value,
              delta.isFinite, delta >= 0, delta <= PluginPreviewWorkerSession.maxAdvanceMilliseconds else {
            return (failure(request, .invalidRequest), true)
        }
        guard let fired = await active.runtime.advanceVirtualTime(byMilliseconds: delta) else {
            diagnostics.log("advance_failed code=timerLimit")
            return (failure(request, .timedOut), true)
        }
        return (response(request, payload: PluginPreviewWorkerPayload(ok: true, firedTimers: fired, consoleLines: console(request, active))), true)
    }

    /// 单次推进上限 24 小时，防止无意义的超大推进。
    static let maxAdvanceMilliseconds: Double = 24 * 60 * 60 * 1000

    private func storageDump(_ request: PluginPreviewWorkerFrame) -> (PluginPreviewWorkerFrame, Bool) {
        guard let active = activePlugin(for: request) else { return (failure(request, stateFailure(request)), true) }
        guard let data = try? JSONSerialization.data(withJSONObject: active.storage.snapshot, options: [.sortedKeys]),
              data.count <= PluginStorage.maxTotalBytes, let json = String(data: data, encoding: .utf8) else {
            return (failure(request, .invalidFixture), true)
        }
        return (response(request, payload: PluginPreviewWorkerPayload(ok: true, storageJSON: json)), true)
    }

    /// 仅在请求方要求时回传缓冲的 console 行（预览 GUI 的控制台面板）；CLI 与场景运行从不请求，
    /// 插件 console 仍保持抑制。
    private func console(_ request: PluginPreviewWorkerFrame, _ active: ActivePlugin) -> [PluginConsoleLine]? {
        request.payload.includeConsole == true ? active.runtime.drainConsole() : nil
    }

    private enum LifecycleOperation { case suspend, resume }

    private func lifecycle(_ request: PluginPreviewWorkerFrame, operation: LifecycleOperation) -> (PluginPreviewWorkerFrame, Bool) {
        guard let active = activePlugin(for: request) else { return (failure(request, stateFailure(request)), true) }
        switch operation {
        case .suspend: active.runtime.suspend()
        case .resume: active.runtime.resume()
        }
        return (response(request, payload: PluginPreviewWorkerPayload(ok: true)), true)
    }

    private func unmount(_ request: PluginPreviewWorkerFrame, shutdown: Bool) -> (PluginPreviewWorkerFrame, Bool) {
        if shutdown {
            detachActive()?.runtime.unmount()
            diagnostics.log("worker_shutdown generation=\(request.generation)")
            return (response(request, payload: PluginPreviewWorkerPayload(ok: true)), false)
        }
        guard let active = activePlugin(for: request) else { return (failure(request, stateFailure(request)), true) }
        lock.lock()
        if active.generation == currentGeneration { self.active = nil }
        lock.unlock()
        active.runtime.onInvalidate = nil
        active.runtime.unmount()
        return (response(request, payload: PluginPreviewWorkerPayload(ok: true)), true)
    }

    private func detachActive() -> ActivePlugin? {
        lock.lock()
        let previous = active
        active = nil
        lock.unlock()
        previous?.runtime.onInvalidate = nil
        return previous
    }

    private func activePlugin(for request: PluginPreviewWorkerFrame) -> ActivePlugin? {
        lock.lock()
        defer { lock.unlock() }
        guard request.generation == currentGeneration else { return nil }
        return active
    }

    private func stateFailure(_ request: PluginPreviewWorkerFrame) -> PluginPreviewWorkerFailure {
        request.generation == generation ? .notLoaded : .staleGeneration
    }

    private func runtimeFailure(_ error: PluginRuntimeError) -> PluginPreviewWorkerFailure {
        switch error {
        case .notLoaded: return .notLoaded
        case .timedOut: return .timedOut
        case .script: return .pluginError
        case .disabled: return .disabled
        case .suspended: return .suspended
        case .invalidOutput: return .invalidOutput
        }
    }

    private func emitInvalidate(generation: UInt64) {
        lock.lock()
        let belongsToActive = active?.generation == generation && currentGeneration == generation
        lock.unlock()
        guard belongsToActive else { return }
        let event = PluginPreviewWorkerFrame(
            type: PluginPreviewWorkerMessageType.invalidate,
            generation: generation,
            requestID: 0,
            payload: PluginPreviewWorkerPayload()
        )
        do { try output.write(event) }
        catch { diagnostics.log("invalidate_write_failed") }
    }

    private func response(_ request: PluginPreviewWorkerFrame, payload: PluginPreviewWorkerPayload) -> PluginPreviewWorkerFrame {
        PluginPreviewWorkerFrame(type: request.type, generation: request.generation, requestID: request.requestID, payload: payload)
    }

    private func failure(_ request: PluginPreviewWorkerFrame, _ failure: PluginPreviewWorkerFailure) -> PluginPreviewWorkerFrame {
        failureResponse(request, failure)
    }

    private func failureResponse(_ request: PluginPreviewWorkerFrame, _ failure: PluginPreviewWorkerFailure) -> PluginPreviewWorkerFrame {
        response(request, payload: PluginPreviewWorkerPayload(ok: false, errorCode: failure.code, message: failure.message))
    }

    private func errorResponse(generation: UInt64, requestID: UInt64, _ failure: PluginPreviewWorkerFailure) -> PluginPreviewWorkerFrame {
        PluginPreviewWorkerFrame(
            type: PluginPreviewWorkerMessageType.error,
            generation: generation,
            requestID: requestID,
            payload: PluginPreviewWorkerPayload(ok: false, errorCode: failure.code, message: failure.message)
        )
    }
}
