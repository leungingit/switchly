import Foundation

/// One frame payload shared by worker requests, responses and events. Optional
/// fields keep the wire schema explicit while avoiding a second JSON model.
struct PluginPreviewWorkerPayload: Codable, Equatable {
    var ok: Bool? = nil
    var errorCode: String? = nil
    var message: String? = nil

    var pluginDirectory: String? = nil
    var scenarioPath: String? = nil
    var actionID: String? = nil
    var value: Double? = nil

    var toolVersion: String? = nil
    var protocolVersion: Int? = nil
    var scenarioSchemaVersion: Int? = nil
    var pluginAPIVersions: [Int]? = nil
    var sdkContractHash: String? = nil

    var pluginID: String? = nil
    var activeGeneration: UInt64? = nil
    var grantedPermissions: [String]? = nil
    var fixtureSources: [String: String]? = nil
    var artworkBase64: String? = nil
    var storageJSON: String? = nil
    var renderJSON: String? = nil
    /// `advance` 响应：本次推进实际触发的定时器数。
    var firedTimers: Int? = nil
    /// 请求方显式要求时，render / action / advance 响应附带自上次以来缓冲的插件 console 行；默认不回传。
    var includeConsole: Bool? = nil
    var consoleLines: [PluginConsoleLine]? = nil
}

enum PluginPreviewWorkerMessageType {
    static let hello = "hello"
    static let load = "load"
    static let render = "render"
    static let action = "action"
    static let suspend = "suspend"
    static let resume = "resume"
    static let unmount = "unmount"
    static let shutdown = "shutdown"
    static let storageDump = "storageDump"
    static let advance = "advance"
    static let invalidate = "invalidate"
    static let error = "error"

    static let requests: Set<String> = [hello, load, render, action, suspend, resume, unmount, shutdown, storageDump, advance]
}

typealias PluginPreviewWorkerFrame = PluginPreviewFrame<PluginPreviewWorkerPayload>

/// 预览公共契约的唯一常量，由 `Tools/PluginPreview/contract-hash.sh --check` 校验。
/// Plugins/api/ 下 6 个契约文件变化时必须同步更新并重新验收。
enum PluginPreviewContract {
    /// 预览工具版本与场景 Schema 版本的唯一来源（worker 握手、报告、`--version-json` 共用）。
    static let toolVersion = "0.1.0"
    static let scenarioSchemaVersion = 1
    /// 共享渲染源码的 revision，由 `renderer-revision.sh --check` 校验；变化即视觉基线失效。
    static let rendererRevision = "sha256:e019de6411d0b1f77f6a6f7cb760fb49de740415cc7709d5c2d5015e6d1eb874"
    static let sdkContractHash = "sha256:50397d0bf6be94848d48a883b6b182a40165c5431ade2af862378756dd6dcdfb"
}
