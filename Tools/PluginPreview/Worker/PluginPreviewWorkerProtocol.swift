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
/// plugin-api/ 下 6 个契约文件变化时必须同步更新并重新验收。
enum PluginPreviewContract {
    /// 共享渲染源码的 revision，由 `renderer-revision.sh --check` 校验；变化即视觉基线失效。
    static let rendererRevision = "sha256:f87a797a7e20a25e07652ed299c5a7b4abbb04472cf56ffe697426a1363bc33a"
    static let sdkContractHash = "sha256:2ba89126f3eb0a194bd3cdadcd8b791b672c6eab34c3cab46c7b72b845d4aac3"
}
