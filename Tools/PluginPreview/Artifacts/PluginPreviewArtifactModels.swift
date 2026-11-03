import Foundation

enum PluginPreviewArtifactStatus: String, Codable, Equatable {
    case passed
    case failed
    case unsupported
    case environmentError = "environment-error"
}

enum PluginPreviewArtifactFailureCode: String, Codable, Equatable {
    case invalidRenderOutput = "invalid-render-output"
    case missingScreenshot = "missing-screenshot"
    case invalidScreenshot = "invalid-screenshot"
    case invalidPackage = "invalid-package"
    case outputNotEmpty = "output-not-empty"
    case writeFailed = "write-failed"
    case unsupported
    case environmentUnavailable = "environment-unavailable"

    var message: String {
        switch self {
        case .invalidRenderOutput: return "Plugin render output did not pass host decoding."
        case .missingScreenshot: return "A caller-provided screenshot is required for a passed result."
        case .invalidScreenshot: return "The caller-provided screenshot is not a non-empty valid PNG."
        case .invalidPackage: return "The plugin package is not a bounded regular-file package."
        case .outputNotEmpty: return "The output directory is not empty."
        case .writeFailed: return "Artifacts could not be written completely."
        case .unsupported: return "The preview scenario uses an unsupported capability."
        case .environmentUnavailable: return "The preview environment is unavailable."
        }
    }
}

struct PluginPreviewArtifactFailure: Codable, Equatable {
    let code: String
    let message: String

    init(_ code: PluginPreviewArtifactFailureCode) {
        self.code = code.rawValue
        self.message = code.message
    }
}

/// Optional metadata is intentionally explicit so later environment and tool
/// versions can be added without placing paths or fixture contents in reports.
struct PluginPreviewArtifactVersions: Codable, Equatable {
    var toolVersion: String?
    var protocolVersion: Int?
    var scenarioSchemaVersion: Int?
    var pluginAPIVersion: Int?
    var sdkContractHash: String?

    init(
        toolVersion: String? = nil,
        protocolVersion: Int? = nil,
        scenarioSchemaVersion: Int? = nil,
        pluginAPIVersion: Int? = nil,
        sdkContractHash: String? = nil
    ) {
        self.toolVersion = toolVersion
        self.protocolVersion = protocolVersion
        self.scenarioSchemaVersion = scenarioSchemaVersion
        self.pluginAPIVersion = pluginAPIVersion
        self.sdkContractHash = sdkContractHash
    }
}

struct PluginPreviewArtifactEnvironment: Codable, Equatable {
    var operatingSystemVersion: String?
    var architecture: String?
    var locale: String?
    var appearance: String?

    init(
        operatingSystemVersion: String? = nil,
        architecture: String? = nil,
        locale: String? = nil,
        appearance: String? = nil
    ) {
        self.operatingSystemVersion = operatingSystemVersion
        self.architecture = architecture
        self.locale = locale
        self.appearance = appearance
    }
}

struct PluginPreviewArtifactIdentity: Equatable {
    let scenarioID: String
    let pluginID: String
    let pluginVersion: String
    let generation: UInt64
    let packageURL: URL
    var versions: PluginPreviewArtifactVersions
    var environment: PluginPreviewArtifactEnvironment?

    init(
        scenarioID: String,
        pluginID: String,
        pluginVersion: String,
        generation: UInt64,
        packageURL: URL,
        versions: PluginPreviewArtifactVersions = .init(),
        environment: PluginPreviewArtifactEnvironment? = nil
    ) {
        self.scenarioID = scenarioID
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.generation = generation
        self.packageURL = packageURL
        self.versions = versions
        self.environment = environment
    }
}

struct PluginPreviewArtifactPaths: Codable, Equatable {
    let report: String
    let screenshot: String?
    let uiTree: String?
    let actions: String?

    static let reportOnly = PluginPreviewArtifactPaths(
        report: "report.json",
        screenshot: nil,
        uiTree: nil,
        actions: nil
    )

    static let complete = PluginPreviewArtifactPaths(
        report: "report.json",
        screenshot: "preview.png",
        uiTree: "ui-tree.json",
        actions: "actions.json"
    )
}

struct PluginPreviewArtifactReport: Codable, Equatable {
    let schemaVersion: Int
    let status: PluginPreviewArtifactStatus
    let scenarioID: String
    let pluginID: String
    let pluginVersion: String
    let generation: UInt64
    let packageHash: String
    let artifacts: PluginPreviewArtifactPaths
    let versions: PluginPreviewArtifactVersions
    let environment: PluginPreviewArtifactEnvironment?
    let failure: PluginPreviewArtifactFailure?
}

enum PluginPreviewArtifactValue: Codable, Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported artifact value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

struct PluginPreviewArtifactAction: Codable, Equatable {
    let pluginID: String
    let actionID: String
    let value: PluginPreviewArtifactValue?
    let enabled: Bool
}

struct PluginPreviewArtifactActions: Codable, Equatable {
    let schemaVersion: Int
    let actions: [PluginPreviewArtifactAction]
}

enum PluginPreviewArtifactError: Error, Equatable, LocalizedError {
    case invalidIdentity
    case invalidPackage
    case invalidRenderOutput
    case missingScreenshot
    case invalidScreenshot
    case outputNotEmpty
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "Artifact identity is invalid."
        case .invalidPackage: return PluginPreviewArtifactFailureCode.invalidPackage.message
        case .invalidRenderOutput: return PluginPreviewArtifactFailureCode.invalidRenderOutput.message
        case .missingScreenshot: return PluginPreviewArtifactFailureCode.missingScreenshot.message
        case .invalidScreenshot: return PluginPreviewArtifactFailureCode.invalidScreenshot.message
        case .outputNotEmpty: return PluginPreviewArtifactFailureCode.outputNotEmpty.message
        case .writeFailed: return PluginPreviewArtifactFailureCode.writeFailed.message
        }
    }
}
