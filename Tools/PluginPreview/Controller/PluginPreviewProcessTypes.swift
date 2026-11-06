import Foundation

/// worker 进程的显式启动配置。
///
/// `environment` 是子进程收到的完整环境，不从父进程自动复制。调用者必须明确列出
/// worker 所需的少量变量；协议输出与诊断日志分别使用 stdout 和 stderr。
struct PluginPreviewProcessConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL?
    let startupTimeout: TimeInterval
    let requestTimeout: TimeInterval
    let shutdownTimeout: TimeInterval
    let terminationGracePeriod: TimeInterval
    let reapingTimeout: TimeInterval

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectoryURL: URL? = nil,
        startupTimeout: TimeInterval = 5,
        requestTimeout: TimeInterval = 5,
        shutdownTimeout: TimeInterval = 3,
        terminationGracePeriod: TimeInterval = 0.5,
        reapingTimeout: TimeInterval = 1
    ) throws {
        guard executableURL.isFileURL else {
            throw PluginPreviewProcessError.invalidConfiguration
        }
        guard startupTimeout.isFinite, startupTimeout > 0,
              requestTimeout.isFinite, requestTimeout > 0,
              shutdownTimeout.isFinite, shutdownTimeout > 0,
              terminationGracePeriod.isFinite, terminationGracePeriod > 0,
              reapingTimeout.isFinite, reapingTimeout > 0
        else {
            throw PluginPreviewProcessError.invalidConfiguration
        }

        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        self.shutdownTimeout = shutdownTimeout
        self.terminationGracePeriod = terminationGracePeriod
        self.reapingTimeout = reapingTimeout
    }
}

enum PluginPreviewProcessState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed
}

struct PluginPreviewProcessStatus: Equatable, Sendable {
    let state: PluginPreviewProcessState
    let generation: UInt64?
    let queuedRequestCount: Int
    let stderrByteCount: Int
    let lastFailure: PluginPreviewProcessFailure?
}

enum PluginPreviewProcessFailureReason: Equatable, Sendable {
    case launchFailed
    case startupTimedOut
    case requestTimedOut
    case shutdownTimedOut
    case reapingTimedOut
    case workerExited(status: Int32)
    case protocolError(PluginPreviewFrameError)
    case pipeFailure
    case requestCancelled
}

/// 可安全进入 CLI 报告或日志的固定故障描述，不包含帧内容、路径或 stderr 文本。
struct PluginPreviewProcessFailure: Equatable, LocalizedError, Sendable {
    let reason: PluginPreviewProcessFailureReason
    let generation: UInt64?
    let requestID: UInt64?

    var errorDescription: String? {
        switch reason {
        case .launchFailed:
            return "preview worker failed to launch"
        case .startupTimedOut:
            return "preview worker startup timed out"
        case .requestTimedOut:
            return "preview worker request timed out"
        case .shutdownTimedOut:
            return "preview worker shutdown timed out"
        case .reapingTimedOut:
            return "preview worker could not be reaped"
        case .workerExited(let status):
            return "preview worker exited with status \(status)"
        case .protocolError(let error):
            return error.localizedDescription
        case .pipeFailure:
            return "preview worker pipe failed"
        case .requestCancelled:
            return "preview worker request was cancelled"
        }
    }
}

enum PluginPreviewProcessError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case notStarted
    case alreadyStarted
    case stopping
    case generationMismatch(expected: UInt64, found: UInt64)
    case requestQueueFull
    case duplicateRequestID(UInt64)
    case invalidRequestType(expected: String, found: String)
    case invalidGenerationTransition(current: UInt64, requested: UInt64)
    case failure(PluginPreviewProcessFailure)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "preview worker configuration is invalid"
        case .notStarted:
            return "preview worker is not running"
        case .alreadyStarted:
            return "preview worker is already running"
        case .stopping:
            return "preview worker is stopping"
        case .generationMismatch(let expected, let found):
            return "preview worker generation mismatch: expected \(expected), found \(found)"
        case .requestQueueFull:
            return "preview worker request queue is full"
        case .duplicateRequestID(let requestID):
            return "preview worker request ID \(requestID) is already active or queued"
        case .invalidRequestType(let expected, let found):
            return "preview worker expected \(expected) request, found \(found)"
        case .invalidGenerationTransition(let current, let requested):
            return "preview worker generation must advance: current \(current), requested \(requested)"
        case .failure(let failure):
            return failure.localizedDescription
        }
    }
}

extension PluginPreviewFrame: @unchecked Sendable where Payload: Sendable {}

enum PluginPreviewWorkerEvent<Payload: Codable & Sendable>: Sendable {
    case invalidate(PluginPreviewFrame<Payload>)
    case action(PluginPreviewFrame<Payload>)
    case discarded(type: String, generation: UInt64, requestID: UInt64)
    case failed(PluginPreviewProcessFailure)
}
