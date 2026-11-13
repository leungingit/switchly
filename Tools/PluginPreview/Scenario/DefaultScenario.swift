import Foundation

/// 默认场景、覆盖项与场景文件之间的唯一可编辑模型。
///
/// GUI、覆盖项解析和“导出为场景文件”都绑定这个 `struct`：
/// - `derive(manifest:)` 给出契约 §2.1 的推导值；
/// - `applyOverrides(_:manifest:)` 应用契约 §2.2 的覆盖项；
/// - `encode(fixtureRelativePaths:)` 输出仅含场景 schema 允许字段的 JSON。
/// fixture 文件由调用者先复制到目标目录，再以相对路径传给 `encode`。
struct PreviewScenarioDraft: Equatable {
    enum Locale: String, CaseIterable, Codable, Equatable {
        case en
        case zhHans = "zh-Hans"
    }

    enum Appearance: String, CaseIterable, Codable, Equatable {
        case light
        case dark
    }

    enum FixtureKind: String, CaseIterable, Codable, Equatable {
        case media
        case weather
        case fs
        case activity

        /// 契约 §2.1：媒体类权限任一 → media；`weather.current` → weather；`fs.read` → fs。
        func isRequired(by manifest: PluginManifest) -> Bool {
            switch self {
            case .media:
                return manifest.permissions.contains { permission in
                    switch permission {
                    case .mediaNowPlaying, .mediaControl, .mediaLibrary: return true
                    default: return false
                    }
                }
            case .weather:
                return manifest.permissions.contains(.weatherCurrent)
            case .fs:
                return manifest.permissions.contains(.fsRead)
            case .activity:
                return manifest.permissions.contains(.activityRead)
            }
        }

        /// 只有 media/weather 随预览 App 分发合成样例；fs 内容取决于插件目录，必须显式提供。
        var hasBuiltinSample: Bool {
            self == .media || self == .weather
        }
    }

    /// fixture 的三种来源；`none` 表示该能力不可用，且不回退内置样例。
    enum FixtureSource: Equatable {
        case none
        case builtin
        case explicit(URL)
    }

    /// 与 `PluginPreviewEnvironment` 共用同一范围，避免 GUI 与参数校验出现两套常量。
    static let contentWidthRange: ClosedRange<Double> = 300...720
    static let derivedScenarioID = "default"
    static let defaultClockStartEpochMs: Double = 1_700_000_000_000
    static let defaultClockSeed: UInt32 = 1

    struct Target: Equatable {
        var bundleID: String
        var appName: String
    }

    struct Clock: Equatable {
        var isEnabled: Bool
        var startEpochMs: Double
        var seed: UInt32
    }

    /// 三种合成能力各自的来源；`none` 表示该能力不可用（场景中省略）。
    struct FixtureFiles: Equatable {
        var media: FixtureSource = .none
        var weather: FixtureSource = .none
        var fs: FixtureSource = .none
        var activity: FixtureSource = .none

        var isEmpty: Bool {
            media == .none && weather == .none && fs == .none && activity == .none
        }

        subscript(kind: FixtureKind) -> FixtureSource {
            get {
                switch kind {
                case .media: return media
                case .weather: return weather
                case .fs: return fs
                case .activity: return activity
                }
            }
            set {
                switch kind {
                case .media: media = newValue
                case .weather: weather = newValue
                case .fs: fs = newValue
                case .activity: activity = newValue
                }
            }
        }
    }

    var surface: String
    var id: String
    var locale: Locale
    var appearance: Appearance
    var glass: Bool
    var reduceMotion: Bool
    var contentWidthPoints: Double
    var target: Target
    /// 场景授予的权限；与 manifest 取交集后真正生效。
    var grants: [String]
    /// 仅存放显式覆盖的设置项；未给出的键由 manifest 默认值生效。
    var settings: [String: PluginSettingValue]
    var clock: Clock
    var fixtures: FixtureFiles

    init(
        id: String = PreviewScenarioDraft.derivedScenarioID,
        locale: Locale = .en,
        appearance: Appearance = .light,
        glass: Bool = false,
        reduceMotion: Bool = true,
        contentWidthPoints: Double = 360,
        target: Target,
        grants: [String],
        settings: [String: PluginSettingValue] = [:],
        clock: Clock = Clock(isEnabled: true,
                             startEpochMs: PreviewScenarioDraft.defaultClockStartEpochMs,
                             seed: PreviewScenarioDraft.defaultClockSeed),
        fixtures: FixtureFiles = FixtureFiles(),
        surface: String = "dockPreview"
    ) {
        self.surface = surface
        self.id = id
        self.locale = locale
        self.appearance = appearance
        self.glass = glass
        self.reduceMotion = reduceMotion
        self.contentWidthPoints = contentWidthPoints
        self.target = target
        self.grants = grants
        self.settings = settings
        self.clock = clock
        self.fixtures = fixtures
    }

    /// 契约 §2.1：默认场景可作视觉基线，因此时钟固定且 `glass` 为假。
    /// media/weather 按 manifest 权限自动使用内置合成样例；fs 没有内置样例。
    static func derive(manifest: PluginManifest) -> PreviewScenarioDraft {
        let bundleID = manifest.matches.first ?? ""
        var fixtures = FixtureFiles()
        for kind in FixtureKind.allCases where kind.isRequired(by: manifest) && kind.hasBuiltinSample {
            fixtures[kind] = .builtin
        }
        return PreviewScenarioDraft(
            target: Target(bundleID: bundleID, appName: appName(for: bundleID)),
            grants: manifest.permissions.map(\.rawValue),
            fixtures: fixtures,
            surface: manifest.supportsPanel && !manifest.supportsDock ? "panel" : "dockPreview"
        )
    }

    /// 渲染以 `plugin-script-error` 失败时，用于说明首个没有来源的必需 fixture。
    func missingRequiredFixtureKind(for manifest: PluginManifest) -> FixtureKind? {
        FixtureKind.allCases.first { kind in
            kind.isRequired(by: manifest) && fixtures[kind] == .none
        }
    }

    /// `com.example.app` → `App`；首个字符大写，其余保持原样。
    static func appName(for bundleID: String) -> String {
        guard let last = bundleID.split(separator: ".").last.map(String.init), !last.isEmpty else {
            return bundleID
        }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// 应用契约 §2.2 的覆盖项。参数形态错误由解析层拒绝；这里只做与 manifest 相关的语义校验。
    mutating func applyOverrides(_ overrides: PreviewScenarioOverrides, manifest: PluginManifest) throws {
        if let locale = overrides.locale { self.locale = locale }
        if let appearance = overrides.appearance { self.appearance = appearance }
        if let glass = overrides.glass { self.glass = glass }
        if let reduceMotion = overrides.reduceMotion { self.reduceMotion = reduceMotion }
        if let width = overrides.width {
            guard width.isFinite, Self.contentWidthRange.contains(width) else {
                throw PreviewScenarioOverrideError.invalidArgument("--width must be within 300...720")
            }
            contentWidthPoints = width
        }
        if let bundleID = overrides.targetBundleID {
            guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PreviewScenarioOverrideError.invalidArgument("--target-bundle-id must not be empty")
            }
            target.bundleID = bundleID
        }
        if let appName = overrides.targetAppName {
            guard !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PreviewScenarioOverrideError.invalidArgument("--target-app-name must not be empty")
            }
            target.appName = appName
        }
        if let grants = overrides.grants {
            guard grants.allSatisfy({ PluginCapability(rawValue: $0) != nil }) else {
                throw PreviewScenarioOverrideError.invalidGrants
            }
            // 显式列表仍与 manifest 取交集；超出声明的项被忽略。
            let declared = Set(manifest.permissions.map(\.rawValue))
            self.grants = grants.filter { declared.contains($0) }
        }
        for (key, raw) in overrides.settings {
            guard let spec = (manifest.settings ?? []).first(where: { $0.key == key }) else {
                throw PreviewScenarioOverrideError.invalidSettings
            }
            settings[key] = try Self.settingValue(raw: raw, spec: spec)
        }
        for (kind, url) in overrides.fixtures {
            // 显式文件覆盖同名内置样例。
            fixtures[kind] = .explicit(url)
        }
    }

    private static func settingValue(raw: String, spec: PluginSettingSpec) throws -> PluginSettingValue {
        switch spec.kind {
        case .toggle:
            guard raw == "true" || raw == "false" else { throw PreviewScenarioOverrideError.invalidSettings }
            return .bool(raw == "true")
        case .select:
            guard spec.options.contains(where: { $0.value == raw }) else {
                throw PreviewScenarioOverrideError.invalidSettings
            }
            return .string(raw)
        case .number:
            guard let number = Double(raw), number.isFinite,
                  (spec.min ?? -.infinity) <= number,
                  number <= (spec.max ?? .infinity) else {
                throw PreviewScenarioOverrideError.invalidSettings
            }
            return .number(number)
        }
    }

    /// 输出标准场景 JSON。`fixtureRelativePaths` 由 `materializeFixtures(in:)` 或 GUI 导出流程提供。
    func encode(fixtureRelativePaths: [FixtureKind: String] = [:]) throws -> Data {
        let fixtures = fixtureRelativePaths.isEmpty ? nil : EncodedFixtures(
            media: fixtureRelativePaths[.media],
            weather: fixtureRelativePaths[.weather],
            fs: fixtureRelativePaths[.fs],
            activity: fixtureRelativePaths[.activity]
        )
        let clock = clock.isEnabled
            ? EncodedClock(startEpochMs: clock.startEpochMs, seed: clock.seed)
            : nil
        let encoded = EncodedScenario(
            id: id,
            surface: surface == "dockPreview" ? nil : surface,
            environment: EncodedEnvironment(
                locale: locale.rawValue,
                appearance: appearance.rawValue,
                glass: glass,
                reduceMotion: reduceMotion,
                contentWidthPoints: contentWidthPoints
            ),
            target: EncodedTarget(bundleID: target.bundleID, appName: target.appName),
            fixtures: fixtures,
            clock: clock,
            grants: grants,
            settings: settings.isEmpty ? nil : settings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(encoded)
    }

    /// 从已校验的场景回读草稿；`scenarioDirectory` 用于还原 fixture 的相对路径。
    init(scenario: PreviewScenario, scenarioDirectory: URL) {
        self.init(
            id: scenario.id,
            locale: Locale(rawValue: scenario.environment.locale) ?? .en,
            appearance: Appearance(rawValue: scenario.environment.appearance) ?? .light,
            glass: scenario.environment.glass,
            reduceMotion: scenario.environment.reduceMotion,
            contentWidthPoints: scenario.environment.contentWidthPoints,
            target: Target(bundleID: scenario.target.bundleID, appName: scenario.target.appName),
            grants: scenario.grants ?? [],
            settings: Self.settings(from: scenario.settings),
            clock: scenario.clock.map {
                Clock(isEnabled: true, startEpochMs: $0.startEpochMs, seed: $0.seed)
            } ?? Clock(isEnabled: false, startEpochMs: Self.defaultClockStartEpochMs, seed: Self.defaultClockSeed),
            fixtures: FixtureFiles(
                media: Self.explicitFixture(scenario.fixtures?.media, scenarioDirectory),
                weather: Self.explicitFixture(scenario.fixtures?.weather, scenarioDirectory),
                fs: Self.explicitFixture(scenario.fixtures?.fs, scenarioDirectory),
                activity: Self.explicitFixture(scenario.fixtures?.activity, scenarioDirectory)
            ),
            surface: scenario.surface ?? "dockPreview"
        )
    }

    static func decode(_ data: Data, scenarioDirectory: URL) throws -> PreviewScenarioDraft {
        PreviewScenarioDraft(scenario: try PreviewScenario.decode(data), scenarioDirectory: scenarioDirectory)
    }

    /// 显式场景中的路径只表示“调用者提供了文件”，不会替调用者补内置样例。
    private static func explicitFixture(_ path: String?, _ scenarioDirectory: URL) -> FixtureSource {
        guard let path else { return .none }
        return .explicit(scenarioDirectory.appendingPathComponent(path))
    }

    private static func settings(from values: [String: JSONValue]?) -> [String: PluginSettingValue] {
        var result: [String: PluginSettingValue] = [:]
        for (key, value) in values ?? [:] {
            switch value {
            case .bool(let bool): result[key] = .bool(bool)
            case .number(let number): result[key] = .number(number)
            case .string(let string): result[key] = .string(string)
            default: break // PreviewScenario.decode 已拒绝非设置值。
            }
        }
        return result
    }

    /// 把选中的 fixture 复制到 `directory/fixtures/`，返回可直接写入场景的相对路径。
    /// 内置样例同样落盘后以相对路径引用；内容与 Schema 仍由 worker 的既有校验负责。
    /// 这里先拒绝缺失、链接与超限文件。测试可注入 `builtinFixtureURL`，生产默认读取 App 资源。
    func materializeFixtures(in directory: URL,
                             builtinFixtureURL: (FixtureKind) -> URL? = { BuiltinFixtureSample.url(for: $0) })
        throws -> [FixtureKind: String] {
        guard !fixtures.isEmpty else { return [:] }
        let fileManager = FileManager.default
        let fixtureDirectory = directory.appendingPathComponent("fixtures", isDirectory: true)
        if fileManager.fileExists(atPath: fixtureDirectory.path) {
            let values = try fixtureDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FixtureTransferError.invalidFixture
            }
        } else {
            try fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        var paths: [FixtureKind: String] = [:]
        for kind in FixtureKind.allCases {
            let source: URL
            switch fixtures[kind] {
            case .none:
                continue
            case .builtin:
                guard kind.hasBuiltinSample, let url = builtinFixtureURL(kind) else {
                    throw FixtureTransferError.invalidFixture
                }
                source = url
            case .explicit(let url):
                source = url
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= PluginPackageValidator.maxPackageBytes else {
                throw FixtureTransferError.invalidFixture
            }
            let name = kind.rawValue + "-" + (source.lastPathComponent.isEmpty ? "fixture.json" : source.lastPathComponent)
            let destination = fixtureDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            paths[kind] = "fixtures/" + name
        }
        return paths
    }
}

/// 随预览 App 分发的合成 fixture 资源名；`project.yml` 以 resources 打进 App bundle。
enum BuiltinFixtureSample {
    static func resourceName(for kind: PreviewScenarioDraft.FixtureKind) -> String? {
        switch kind {
        case .media: return "PluginPreviewBuiltinMedia"
        case .weather: return "PluginPreviewBuiltinWeather"
        case .fs, .activity: return nil
        }
    }

    static func url(for kind: PreviewScenarioDraft.FixtureKind, bundle: Bundle = .main) -> URL? {
        guard let name = resourceName(for: kind) else { return nil }
        return bundle.url(forResource: name, withExtension: "json")
    }
}

enum FixtureTransferError: Error, Equatable {
    case invalidFixture
}

enum PreviewScenarioOverrideError: Error, Equatable {
    /// 与 manifest 无关的形态错误；App 映射为退出码 2。
    case invalidArgument(String)
    case invalidGrants
    case invalidSettings
}

/// 契约 §2.2 的覆盖项；`nil` 表示未提供，保持推导值。
struct PreviewScenarioOverrides: Equatable {
    var locale: PreviewScenarioDraft.Locale?
    var appearance: PreviewScenarioDraft.Appearance?
    var glass: Bool?
    var reduceMotion: Bool?
    var width: Double?
    var grants: [String]?
    /// 原始字符串值，在 `applyOverrides` 中按 manifest 设置规格解析。
    var settings: [String: String] = [:]
    var fixtures: [PreviewScenarioDraft.FixtureKind: URL] = [:]
    var targetBundleID: String?
    var targetAppName: String?

    var hasAny: Bool {
        locale != nil || appearance != nil || glass != nil || reduceMotion != nil || width != nil
            || grants != nil || !settings.isEmpty || !fixtures.isEmpty
            || targetBundleID != nil || targetAppName != nil
    }
}

// MARK: - 场景 JSON 的编码形状

/// 只声明 schema 允许的字段；未知字段仍由 `PreviewScenario.decode` 拒绝。
private struct EncodedScenario: Encodable {
    let schemaVersion = 1
    let id: String
    let surface: String?
    let environment: EncodedEnvironment
    let target: EncodedTarget
    let fixtures: EncodedFixtures?
    let clock: EncodedClock?
    let grants: [String]?
    let settings: [String: PluginSettingValue]?
}

private struct EncodedEnvironment: Encodable {
    let locale: String
    let appearance: String
    let glass: Bool
    let reduceMotion: Bool
    let contentWidthPoints: Double
}

private struct EncodedTarget: Encodable {
    let bundleID: String
    let appName: String
}

private struct EncodedFixtures: Encodable {
    let media: String?
    let weather: String?
    let fs: String?
    let activity: String?
}

private struct EncodedClock: Encodable {
    let startEpochMs: Double
    let seed: UInt32
}
