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
    static let invalidate = "invalidate"
    static let error = "error"

    static let requests: Set<String> = [hello, load, render, action, suspend, resume, unmount, shutdown, storageDump]
}

typealias PluginPreviewWorkerFrame = PluginPreviewFrame<PluginPreviewWorkerPayload>
