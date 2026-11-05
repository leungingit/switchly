import Foundation

/// 预览 App 的命令行入口形态。只做形态校验；manifest 相关语义在 App 内由草稿校验。
enum PluginPreviewInvocation: Equatable {
    /// 无参数：GUI 启动器，不加载插件。
    case launcher
    /// 无 GUI、无屏幕录制；stdout 输出单个 JSON 对象。
    case inspect(plugin: URL)
    case preview(PluginPreviewCommandArguments)
}

struct PluginPreviewCommandArguments: Equatable {
    let command: String
    let plugin: URL
    /// 显式场景；为 nil 时使用推导场景并可叠加覆盖项。
    let scenario: URL?
    let overrides: PreviewScenarioOverrides
    let output: URL?
    let json: Bool
}

enum PluginPreviewCommandLineError: Error, Equatable {
    case invalidArguments
}

enum PluginPreviewCommandLine {
    static func parse(_ args: [String]) throws -> PluginPreviewInvocation {
        guard let first = args.first else { return .launcher }
        if first == "inspect" {
            guard args.count == 2, !args[1].hasPrefix("--") else { throw PluginPreviewCommandLineError.invalidArguments }
            return .inspect(plugin: URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL)
        }
        guard ["dev", "run"].contains(first) else { throw PluginPreviewCommandLineError.invalidArguments }
        guard args.count >= 2, !args[1].hasPrefix("--") else { throw PluginPreviewCommandLineError.invalidArguments }

        var scenario: URL?
        var output: URL?
        var json = false
        var overrides = PreviewScenarioOverrides()
        var seen = Set<String>()
        var settingKeys = Set<String>()
        var fixtureKinds = Set<PreviewScenarioDraft.FixtureKind>()
        var index = 2

        while index < args.count {
            let option = args[index]
            switch option {
            case "--json":
                guard !json else { throw PluginPreviewCommandLineError.invalidArguments }
                json = true
                index += 1
            case "--scenario", "--out",
                 "--locale", "--appearance", "--width", "--grants", "--set", "--fixture",
                 "--target-bundle-id", "--target-app-name":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw PluginPreviewCommandLineError.invalidArguments
                }
                let value = args[index + 1]
                switch option {
                case "--scenario":
                    guard scenario == nil else { throw PluginPreviewCommandLineError.invalidArguments }
                    scenario = URL(fileURLWithPath: value).standardizedFileURL
                case "--out":
                    guard output == nil, first == "run" else { throw PluginPreviewCommandLineError.invalidArguments }
                    output = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
                case "--locale":
                    try once("locale", into: &seen)
                    guard let locale = PreviewScenarioDraft.Locale(rawValue: value) else {
                        throw PluginPreviewCommandLineError.invalidArguments
                    }
                    overrides.locale = locale
                case "--appearance":
                    try once("appearance", into: &seen)
                    guard let appearance = PreviewScenarioDraft.Appearance(rawValue: value) else {
                        throw PluginPreviewCommandLineError.invalidArguments
                    }
                    overrides.appearance = appearance
                case "--width":
                    try once("width", into: &seen)
                    guard let width = Double(value), width.isFinite,
                          PreviewScenarioDraft.contentWidthRange.contains(width) else {
                        throw PluginPreviewCommandLineError.invalidArguments
                    }
                    overrides.width = width
                case "--grants":
                    try once("grants", into: &seen)
                    overrides.grants = try parseGrants(value)
                case "--set":
                    let pair = try parseSetting(value)
                    guard settingKeys.insert(pair.key).inserted else {
                        throw PluginPreviewCommandLineError.invalidArguments
                    }
                    overrides.settings[pair.key] = pair.value
                case "--fixture":
                    let fixture = try parseFixture(value)
                    guard fixtureKinds.insert(fixture.kind).inserted else {
                        throw PluginPreviewCommandLineError.invalidArguments
                    }
                    overrides.fixtures[fixture.kind] = fixture.url
                case "--target-bundle-id":
                    try once("targetBundleID", into: &seen)
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw PluginPreviewCommandLineError.invalidArguments
                    }
                    overrides.targetBundleID = value
                case "--target-app-name":
                    try once("targetAppName", into: &seen)
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw PluginPreviewCommandLineError.invalidArguments
                    }
                    overrides.targetAppName = value
                default:
                    throw PluginPreviewCommandLineError.invalidArguments
                }
                index += 2
            case "--glass", "--no-glass":
                let key = "glass"
                guard seen.insert(key).inserted else { throw PluginPreviewCommandLineError.invalidArguments }
                overrides.glass = option == "--glass"
                index += 1
            case "--reduce-motion", "--no-reduce-motion":
                let key = "reduceMotion"
                guard seen.insert(key).inserted else { throw PluginPreviewCommandLineError.invalidArguments }
                overrides.reduceMotion = option == "--reduce-motion"
                index += 1
            default:
                throw PluginPreviewCommandLineError.invalidArguments
            }
        }

        // 显式场景与任一覆盖项互斥（契约 §2.2）。
        guard scenario == nil || !overrides.hasAny else { throw PluginPreviewCommandLineError.invalidArguments }
        guard (first == "run") == (output != nil) else { throw PluginPreviewCommandLineError.invalidArguments }
        return .preview(PluginPreviewCommandArguments(
            command: first,
            plugin: URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL,
            scenario: scenario,
            overrides: overrides,
            output: output,
            json: json
        ))
    }

    private static func once(_ key: String, into seen: inout Set<String>) throws {
        guard seen.insert(key).inserted else { throw PluginPreviewCommandLineError.invalidArguments }
    }

    private static func parseGrants(_ value: String) throws -> [String] {
        if value == "none" { return [] }
        let items = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard items.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              Set(items).count == items.count else {
            throw PluginPreviewCommandLineError.invalidArguments
        }
        return items
    }

    private static func parseSetting(_ value: String) throws -> (key: String, value: String) {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            throw PluginPreviewCommandLineError.invalidArguments
        }
        let key = String(value[..<separator])
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginPreviewCommandLineError.invalidArguments
        }
        return (key, String(value[value.index(after: separator)...]))
    }

    private static func parseFixture(_ value: String) throws -> (kind: PreviewScenarioDraft.FixtureKind, url: URL) {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            throw PluginPreviewCommandLineError.invalidArguments
        }
        guard let kind = PreviewScenarioDraft.FixtureKind(rawValue: String(value[..<separator])) else {
            throw PluginPreviewCommandLineError.invalidArguments
        }
        let file = String(value[value.index(after: separator)...])
        guard !file.isEmpty else { throw PluginPreviewCommandLineError.invalidArguments }
        return (kind, URL(fileURLWithPath: file).standardizedFileURL)
    }
}
