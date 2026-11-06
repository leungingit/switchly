import Foundation

struct PluginPreviewSessionCompatibility: Equatable, Sendable {
    let pluginAPIVersion: Int
    let scenarioSchemaVersion: Int
    let sdkContractHash: String
    let toolVersion: String?

    init(
        pluginAPIVersion: Int,
        scenarioSchemaVersion: Int = 1,
        sdkContractHash: String,
        toolVersion: String? = nil
    ) {
        self.pluginAPIVersion = pluginAPIVersion
        self.scenarioSchemaVersion = scenarioSchemaVersion
        self.sdkContractHash = sdkContractHash
        self.toolVersion = toolVersion
    }
}

struct PluginPreviewSessionHandshake: Equatable, Sendable {
    let toolVersion: String
    let protocolVersion: Int
    let scenarioSchemaVersion: Int
    let pluginAPIVersions: [Int]
    let sdkContractHash: String
}

struct PluginPreviewLoadedPlugin: Equatable, Sendable {
    let pluginID: String
    let generation: UInt64
    let grantedPermissions: [String]
    let fixtureSources: [String: String]
    let artworkBase64: String?
}

enum PluginPreviewSessionState: Equatable, Sendable {
    case idle
    case starting
    case ready
    case loaded
    case suspended
    case stopping
    case stopped
    case failed
}

struct PluginPreviewSessionSnapshot: Equatable, Sendable {
    let state: PluginPreviewSessionState
    let generation: UInt64?
    let handshake: PluginPreviewSessionHandshake?
    let loadedPlugin: PluginPreviewLoadedPlugin?
    let process: PluginPreviewProcessStatus
}

enum PluginPreviewSessionError: Error, Equatable, LocalizedError, Sendable {
    case invalidCompatibilityExpectation
    case alreadyStarted
    case notStarted
    case invalidState
    case generationExhausted
    case requestIDExhausted
    case invalidRequest
    case responseIdentityMismatch
    case missingResponseStatus
    case contradictoryResponse
    case malformedWorkerError
    case workerFailure(code: String, message: String?)
    case incompatibleProtocolVersion(found: Int?)
    case incompatibleScenarioSchemaVersion(found: Int?)
    case unsupportedPluginAPIVersion(required: Int, advertised: [Int])
    case incompatibleSDKContractHash(found: String?)
    case incompatibleToolVersion(found: String?)
    case invalidRenderJSON
    case process(PluginPreviewProcessError)
    case transportFailure

    var errorDescription: String? {
        switch self {
        case .invalidCompatibilityExpectation:
            return "preview session compatibility expectation is invalid"
        case .alreadyStarted:
            return "preview session is already started"
        case .notStarted:
            return "preview session is not started"
        case .invalidState:
            return "preview session is not in a valid state for this operation"
        case .generationExhausted:
            return "preview session generation space is exhausted"
        case .requestIDExhausted:
            return "preview session request ID space is exhausted"
        case .invalidRequest:
            return "preview session request is invalid"
        case .responseIdentityMismatch:
            return "preview worker response identity does not match the request"
        case .missingResponseStatus:
            return "preview worker response is missing ok status"
        case .contradictoryResponse:
            return "preview worker response contains contradictory ok/error fields"
        case .malformedWorkerError:
            return "preview worker returned a malformed error"
        case .workerFailure(let code, _):
            return "preview worker failed (\(code))"
        case .incompatibleProtocolVersion:
            return "preview worker protocol version is incompatible"
        case .incompatibleScenarioSchemaVersion:
            return "preview worker scenario schema version is incompatible"
        case .unsupportedPluginAPIVersion:
            return "preview worker does not support the required plugin API version"
        case .incompatibleSDKContractHash:
            return "preview worker SDK contract hash is incompatible"
        case .incompatibleToolVersion:
            return "preview worker tool version is incompatible"
        case .invalidRenderJSON:
            return "preview worker render output is invalid"
        case .process(let error):
            return error.localizedDescription
        case .transportFailure:
            return "preview worker transport failed"
        }
    }
}

enum PluginPreviewSessionEvent: Equatable, Sendable {
    case stateChanged(PluginPreviewSessionState)
    case invalidate(generation: UInt64)
    case action(generation: UInt64, actionID: String, value: Double?)
    case discarded(type: String, generation: UInt64, requestID: UInt64)
    case failure(PluginPreviewSessionError)
    /// 仅 `capturesConsole` 的会话产生：一次响应带回的插件 console 行。
    case console(generation: UInt64, lines: [PluginConsoleLine])
}

protocol PluginPreviewSessionWorker: Sendable {
    func start(generation: UInt64, hello: PluginPreviewWorkerFrame) async throws -> PluginPreviewWorkerFrame
    func request(_ frame: PluginPreviewWorkerFrame) async throws -> PluginPreviewWorkerFrame
    func requestForGenerationTransition(_ frame: PluginPreviewWorkerFrame) async throws -> PluginPreviewWorkerFrame
    func advanceGeneration(to generation: UInt64) async throws
    func stop(shutdown: PluginPreviewWorkerFrame?) async
    func snapshot() async -> PluginPreviewProcessStatus
}

private struct PluginPreviewSupervisorWorker: PluginPreviewSessionWorker {
    let supervisor: PluginPreviewWorkerSupervisor<PluginPreviewWorkerPayload>

    func start(generation: UInt64, hello: PluginPreviewWorkerFrame) async throws -> PluginPreviewWorkerFrame {
        try await supervisor.start(generation: generation, hello: hello)
    }

    func request(_ frame: PluginPreviewWorkerFrame) async throws -> PluginPreviewWorkerFrame {
        try await supervisor.request(frame)
    }

    func requestForGenerationTransition(_ frame: PluginPreviewWorkerFrame) async throws -> PluginPreviewWorkerFrame {
        try await supervisor.requestForGenerationTransition(frame)
    }

    func advanceGeneration(to generation: UInt64) async throws {
        try await supervisor.advanceGeneration(to: generation)
    }

    func stop(shutdown: PluginPreviewWorkerFrame?) async {
        await supervisor.stop(shutdown: shutdown)
    }

    func snapshot() async -> PluginPreviewProcessStatus {
        await supervisor.snapshot()
    }
}

/// CLI/GUI 共用的单 generation 会话。请求 ID 与状态转换由会话管理，
/// UI 只传业务参数；新 generation 的热重载留给 T10。
actor PluginPreviewSession {
    private let worker: any PluginPreviewSessionWorker
    private let compatibility: PluginPreviewSessionCompatibility
    private let eventHandler: (@Sendable (PluginPreviewSessionEvent) -> Void)?
    private let capturesConsole: Bool

    private var state: PluginPreviewSessionState = .idle
    private var generation: UInt64?
    private var nextRequestID: UInt64 = 1
    private var handshake: PluginPreviewSessionHandshake?
    private var loadedPlugin: PluginPreviewLoadedPlugin?

    init(
        configuration: PluginPreviewProcessConfiguration,
        compatibility: PluginPreviewSessionCompatibility,
        capturesConsole: Bool = false,
        eventHandler: (@Sendable (PluginPreviewSessionEvent) -> Void)? = nil
    ) {
        let supervisor = PluginPreviewWorkerSupervisor<PluginPreviewWorkerPayload>(
            configuration: configuration,
            eventHandler: { event in
                eventHandler?(Self.mapWorkerEvent(event))
            }
        )
        self.init(
            worker: PluginPreviewSupervisorWorker(supervisor: supervisor),
            compatibility: compatibility,
            capturesConsole: capturesConsole,
            eventHandler: eventHandler
        )
    }

    init(
        worker: any PluginPreviewSessionWorker,
        compatibility: PluginPreviewSessionCompatibility,
        capturesConsole: Bool = false,
        eventHandler: (@Sendable (PluginPreviewSessionEvent) -> Void)? = nil
    ) {
        self.worker = worker
        self.compatibility = compatibility
        self.capturesConsole = capturesConsole
        self.eventHandler = eventHandler
    }

    func snapshot() async -> PluginPreviewSessionSnapshot {
        PluginPreviewSessionSnapshot(
            state: state,
            generation: generation,
            handshake: handshake,
            loadedPlugin: loadedPlugin,
            process: await worker.snapshot()
        )
    }

    @discardableResult
    func start(generation: UInt64 = 0) async throws -> PluginPreviewSessionHandshake {
        guard state == .idle || state == .stopped || state == .failed else {
            throw PluginPreviewSessionError.alreadyStarted
        }
        guard PluginManifest.supportedAPIVersions.contains(compatibility.pluginAPIVersion),
              compatibility.scenarioSchemaVersion > 0,
              !compatibility.sdkContractHash.isEmpty
        else {
            throw PluginPreviewSessionError.invalidCompatibilityExpectation
        }

        transition(to: .starting)
        self.generation = generation
        nextRequestID = 1
        handshake = nil
        loadedPlugin = nil

        let requestID = try consumeRequestID()
        let frame = PluginPreviewWorkerFrame(
            type: PluginPreviewWorkerMessageType.hello,
            generation: generation,
            requestID: requestID,
            payload: PluginPreviewWorkerPayload()
        )

        do {
            let response = try await worker.start(generation: generation, hello: frame)
            try validateResponse(
                response,
                expectedType: PluginPreviewWorkerMessageType.hello,
                requestID: requestID,
                generation: generation
            )
            let checked = try validateHandshake(response.payload, expectedGeneration: generation)
            handshake = checked
            transition(to: .ready)
            return checked
        } catch {
            state = .failed
            emit(.stateChanged(.failed))
            let mapped = mapError(error)
            emit(.failure(mapped))
            await worker.stop(shutdown: nil)
            throw mapped
        }
    }

    @discardableResult
    func load(pluginDirectory: URL, scenarioPath: URL, storageJSON: String? = nil) async throws -> PluginPreviewLoadedPlugin {
        guard state == .ready, let generation else {
            throw PluginPreviewSessionError.invalidState
        }
        guard generation < UInt64.max else {
            throw PluginPreviewSessionError.generationExhausted
        }
        guard pluginDirectory.isFileURL, scenarioPath.isFileURL else {
            throw PluginPreviewSessionError.invalidRequest
        }
        let loadGeneration = generation + 1

        let response = try await send(
            type: PluginPreviewWorkerMessageType.load,
            payload: PluginPreviewWorkerPayload(
                pluginDirectory: pluginDirectory.path,
                scenarioPath: scenarioPath.path,
                storageJSON: storageJSON
            ),
            generation: loadGeneration,
            allowsGenerationTransition: true
        )
        guard let pluginID = response.payload.pluginID, !pluginID.isEmpty,
              response.payload.activeGeneration == loadGeneration
        else {
            throw PluginPreviewSessionError.responseIdentityMismatch
        }
        do {
            try await worker.advanceGeneration(to: loadGeneration)
        } catch {
            throw mapError(error)
        }
        self.generation = loadGeneration
        let loaded = PluginPreviewLoadedPlugin(
            pluginID: pluginID,
            generation: loadGeneration,
            grantedPermissions: response.payload.grantedPermissions ?? [],
            fixtureSources: response.payload.fixtureSources ?? [:],
            artworkBase64: response.payload.artworkBase64
        )
        loadedPlugin = loaded
        transition(to: .loaded)
        return loaded
    }

    func render() async throws -> String {
        guard state == .loaded else {
            throw PluginPreviewSessionError.invalidState
        }
        let response = try await send(
            type: PluginPreviewWorkerMessageType.render,
            payload: PluginPreviewWorkerPayload()
        )
        guard let json = response.payload.renderJSON, !json.isEmpty else {
            throw PluginPreviewSessionError.invalidRenderJSON
        }
        do {
            _ = try PluginRenderOutput.decode(json: Data(json.utf8))
        } catch {
            throw PluginPreviewSessionError.invalidRenderJSON
        }
        return json
    }

    func action(id: String, value: Double? = nil) async throws {
        guard state == .loaded else {
            throw PluginPreviewSessionError.invalidState
        }
        guard !id.isEmpty, value?.isFinite != false else {
            throw PluginPreviewSessionError.invalidRequest
        }
        _ = try await send(
            type: PluginPreviewWorkerMessageType.action,
            payload: PluginPreviewWorkerPayload(actionID: id, value: value)
        )
    }

    /// 推进虚拟时钟并返回触发的定时器数；场景未声明 `clock` 时 worker 返回 invalidRequest。
    @discardableResult
    func advance(milliseconds: Double) async throws -> Int {
        guard state == .loaded else { throw PluginPreviewSessionError.invalidState }
        guard milliseconds.isFinite, milliseconds >= 0 else { throw PluginPreviewSessionError.invalidRequest }
        let response = try await send(
            type: PluginPreviewWorkerMessageType.advance,
            payload: PluginPreviewWorkerPayload(value: milliseconds)
        )
        return response.payload.firedTimers ?? 0
    }

    func storageDump() async throws -> String {
        guard state == .loaded || state == .suspended else { throw PluginPreviewSessionError.invalidState }
        let response = try await send(type: PluginPreviewWorkerMessageType.storageDump, payload: PluginPreviewWorkerPayload())
        guard let json = response.payload.storageJSON, json.utf8.count <= PluginStorage.maxTotalBytes else {
            throw PluginPreviewSessionError.invalidRequest
        }
        return json
    }

    func suspend() async throws {
        guard state == .loaded else {
            throw PluginPreviewSessionError.invalidState
        }
        _ = try await send(
            type: PluginPreviewWorkerMessageType.suspend,
            payload: PluginPreviewWorkerPayload()
        )
        transition(to: .suspended)
    }

    func resume() async throws {
        guard state == .suspended else {
            throw PluginPreviewSessionError.invalidState
        }
        _ = try await send(
            type: PluginPreviewWorkerMessageType.resume,
            payload: PluginPreviewWorkerPayload()
        )
        transition(to: .loaded)
    }

    func unmount() async throws {
        guard state == .loaded || state == .suspended else {
            throw PluginPreviewSessionError.invalidState
        }
        _ = try await send(
            type: PluginPreviewWorkerMessageType.unmount,
            payload: PluginPreviewWorkerPayload()
        )
        loadedPlugin = nil
        transition(to: .ready)
    }

    /// 始终完成进程清理；关闭响应或传输错误通过事件报告。
    func shutdown() async {
        guard state != .idle, state != .stopped, state != .stopping else { return }
        transition(to: .stopping)

        if let generation {
            do {
                _ = try await send(
                    type: PluginPreviewWorkerMessageType.shutdown,
                    payload: PluginPreviewWorkerPayload(),
                    generation: generation
                )
            } catch {
                emit(.failure(mapError(error)))
            }
        }
        await worker.stop(shutdown: nil)
        loadedPlugin = nil
        handshake = nil
        self.generation = nil
        transition(to: .stopped)
    }

    /// UI 强制关闭入口；跳过 shutdown 握手但保留 terminate/kill/reap。
    func stop() async {
        guard state != .idle, state != .stopped else { return }
        transition(to: .stopping)
        await worker.stop(shutdown: nil)
        loadedPlugin = nil
        handshake = nil
        generation = nil
        transition(to: .stopped)
    }

    private func send(
        type: String,
        payload: PluginPreviewWorkerPayload,
        generation explicitGeneration: UInt64? = nil,
        allowsGenerationTransition: Bool = false
    ) async throws -> PluginPreviewWorkerFrame {
        guard let generation = explicitGeneration ?? generation else {
            throw PluginPreviewSessionError.notStarted
        }
        let requestID = try consumeRequestID()
        var payload = payload
        let wantsConsole = capturesConsole && Self.consoleRequestTypes.contains(type)
        if wantsConsole { payload.includeConsole = true }
        let frame = PluginPreviewWorkerFrame(
            type: type,
            generation: generation,
            requestID: requestID,
            payload: payload
        )
        do {
            let response = if allowsGenerationTransition {
                try await worker.requestForGenerationTransition(frame)
            } else {
                try await worker.request(frame)
            }
            try validateResponse(
                response,
                expectedType: type,
                requestID: requestID,
                generation: generation
            )
            if wantsConsole, let lines = response.payload.consoleLines, !lines.isEmpty {
                emit(.console(generation: generation, lines: lines))
            }
            return response
        } catch {
            let mapped = mapError(error)
            if case .process = mapped {
                state = .failed
                emit(.stateChanged(.failed))
            }
            throw mapped
        }
    }

    private static let consoleRequestTypes: Set<String> = [
        PluginPreviewWorkerMessageType.render, PluginPreviewWorkerMessageType.action, PluginPreviewWorkerMessageType.advance,
    ]

    private func validateResponse(
        _ response: PluginPreviewWorkerFrame,
        expectedType: String,
        requestID: UInt64,
        generation: UInt64
    ) throws {
        guard response.protocolVersion == PluginPreviewFrameCodec.protocolVersion else {
            throw PluginPreviewSessionError.incompatibleProtocolVersion(found: response.protocolVersion)
        }
        guard response.type == expectedType,
              response.generation == generation,
              response.requestID == requestID
        else {
            throw PluginPreviewSessionError.responseIdentityMismatch
        }
        guard let ok = response.payload.ok else {
            throw PluginPreviewSessionError.missingResponseStatus
        }
        if ok {
            guard response.payload.errorCode == nil else {
                throw PluginPreviewSessionError.contradictoryResponse
            }
            return
        }
        guard let code = response.payload.errorCode, !code.isEmpty, code.utf8.count <= 128 else {
            throw PluginPreviewSessionError.malformedWorkerError
        }
        let message = response.payload.message.map { String($0.prefix(500)) }
        throw PluginPreviewSessionError.workerFailure(code: code, message: message)
    }

    private func validateHandshake(
        _ payload: PluginPreviewWorkerPayload,
        expectedGeneration: UInt64
    ) throws -> PluginPreviewSessionHandshake {
        guard payload.protocolVersion == PluginPreviewFrameCodec.protocolVersion else {
            throw PluginPreviewSessionError.incompatibleProtocolVersion(found: payload.protocolVersion)
        }
        guard payload.scenarioSchemaVersion == compatibility.scenarioSchemaVersion else {
            throw PluginPreviewSessionError.incompatibleScenarioSchemaVersion(found: payload.scenarioSchemaVersion)
        }
        guard let versions = payload.pluginAPIVersions,
              !versions.isEmpty,
              Set(versions).count == versions.count,
              versions.allSatisfy({ PluginManifest.supportedAPIVersions.contains($0) }),
              versions.contains(compatibility.pluginAPIVersion)
        else {
            throw PluginPreviewSessionError.unsupportedPluginAPIVersion(
                required: compatibility.pluginAPIVersion,
                advertised: payload.pluginAPIVersions ?? []
            )
        }
        guard payload.sdkContractHash == compatibility.sdkContractHash else {
            throw PluginPreviewSessionError.incompatibleSDKContractHash(found: payload.sdkContractHash)
        }
        if let requiredToolVersion = compatibility.toolVersion,
           payload.toolVersion != requiredToolVersion {
            throw PluginPreviewSessionError.incompatibleToolVersion(found: payload.toolVersion)
        }
        guard let toolVersion = payload.toolVersion, !toolVersion.isEmpty else {
            throw PluginPreviewSessionError.incompatibleToolVersion(found: payload.toolVersion)
        }
        guard payload.activeGeneration == expectedGeneration else {
            throw PluginPreviewSessionError.responseIdentityMismatch
        }
        return PluginPreviewSessionHandshake(
            toolVersion: toolVersion,
            protocolVersion: payload.protocolVersion!,
            scenarioSchemaVersion: payload.scenarioSchemaVersion!,
            pluginAPIVersions: versions,
            sdkContractHash: payload.sdkContractHash!
        )
    }

    private func consumeRequestID() throws -> UInt64 {
        guard nextRequestID != 0 else {
            throw PluginPreviewSessionError.requestIDExhausted
        }
        let value = nextRequestID
        nextRequestID &+= 1
        return value
    }

    private func mapError(_ error: Error) -> PluginPreviewSessionError {
        if let sessionError = error as? PluginPreviewSessionError {
            return sessionError
        }
        if let processError = error as? PluginPreviewProcessError {
            return .process(processError)
        }
        return .transportFailure
    }

    private func transition(to next: PluginPreviewSessionState) {
        guard state != next else { return }
        state = next
        emit(.stateChanged(next))
    }

    private func emit(_ event: PluginPreviewSessionEvent) {
        eventHandler?(event)
    }

    private static func mapWorkerEvent(
        _ event: PluginPreviewWorkerEvent<PluginPreviewWorkerPayload>
    ) -> PluginPreviewSessionEvent {
        switch event {
        case .invalidate(let frame):
            return .invalidate(generation: frame.generation)
        case .action(let frame):
            return .action(
                generation: frame.generation,
                actionID: frame.payload.actionID ?? "",
                value: frame.payload.value
            )
        case .discarded(let type, let generation, let requestID):
            return .discarded(type: type, generation: generation, requestID: requestID)
        case .failed(let failure):
            return .failure(.process(.failure(failure)))
        }
    }
}
