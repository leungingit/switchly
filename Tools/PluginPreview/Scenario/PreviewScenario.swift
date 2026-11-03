import Foundation
import Darwin

/// 开发场景与发布包 manifest 分离。这里不初始化任何真实系统能力。
struct PreviewScenario: Decodable {
    struct Environment: Decodable {
        let locale: String
        let appearance: String
        let glass: Bool
        let reduceMotion: Bool
        let contentWidthPoints: Double
    }

    struct Target: Decodable {
        let bundleID: String
        let appName: String
        let titleSummary: String?
        let lastActiveAt: Double?
    }

    struct Fixtures: Decodable {
        let media: String?
        let weather: String?
        let fs: String?
    }

    let schemaVersion: Int
    let id: String
    let environment: Environment
    let target: Target
    let fixtures: Fixtures?
    let grants: [String]?
    // 业务值保留在 JSON 对象中，稍后使用 manifest 的设置规则校验。
    let settings: [String: JSONValue]?
    let storageSeed: [String: JSONValue]?
    let steps: [JSONValue]?

    enum Failure: Error, Equatable {
        case invalidScenario
        case unsupportedSteps
        case invalidFixturePath
        case fixtureTooLarge
    }

    static func decode(_ data: Data) throws -> PreviewScenario {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              hasOnly(object, ["schemaVersion", "id", "environment", "target", "fixtures", "grants", "settings", "storageSeed", "steps"]),
              let environment = object["environment"] as? [String: Any],
              hasOnly(environment, ["locale", "appearance", "glass", "reduceMotion", "contentWidthPoints"]),
              let target = object["target"] as? [String: Any],
              hasOnly(target, ["bundleID", "appName", "titleSummary", "lastActiveAt"]) else {
            throw Failure.invalidScenario
        }
        if let fixtures = object["fixtures"] {
            guard let fixtures = fixtures as? [String: Any], hasOnly(fixtures, ["media", "weather", "fs"]) else {
                throw Failure.invalidScenario
            }
            guard fixtures.values.allSatisfy({ ($0 as? String).map(PreviewFixtureFile.isSafeRelativePath) == true }) else {
                throw Failure.invalidFixturePath
            }
        }
        for key in ["grants", "settings", "storageSeed", "steps"] where object[key] is NSNull {
            throw Failure.invalidScenario
        }
        if target["titleSummary"] is NSNull { throw Failure.invalidScenario }
        let value: PreviewScenario
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw Failure.invalidScenario }
        guard value.schemaVersion == 1, !value.id.isEmpty,
              ["en", "zh-Hans"].contains(value.environment.locale),
              ["light", "dark"].contains(value.environment.appearance),
              value.environment.contentWidthPoints.isFinite, value.environment.contentWidthPoints > 0,
              !value.target.bundleID.isEmpty, !value.target.appName.isEmpty,
              value.target.lastActiveAt?.isFinite != false,
              Set(value.grants ?? []).count == (value.grants ?? []).count,
              (value.grants ?? []).allSatisfy({ !$0.isEmpty }),
              (value.settings ?? [:]).values.allSatisfy(\.isSettingValue) else {
            throw Failure.invalidScenario
        }
        if !(value.steps ?? []).isEmpty { throw Failure.unsupportedSteps }
        return value
    }

    private static func hasOnly(_ object: [String: Any], _ allowed: Set<String>) -> Bool {
        Set(object.keys).isSubset(of: allowed)
    }
}

/// JSON 值不通过字符串化往返，保证 storage seed 中的嵌套结构不丢失。
indirect enum JSONValue: Decodable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var isSettingValue: Bool {
        switch self { case .bool, .number, .string: return true; default: return false }
    }
}

/// 只读取场景目录内调用者明确指定的普通文件；每个路径分量均不得为链接。
enum PreviewFixtureFile {
    static func isSafeRelativePath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && !path.contains("\0") && !segments.isEmpty
            && segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    }

    static func read(relativePath: String, scenarioDirectory: URL, maximumBytes: Int) throws -> Data {
        let segments = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard maximumBytes >= 0, isSafeRelativePath(relativePath) else {
            throw PreviewScenario.Failure.invalidFixturePath
        }
        var descriptor = open(scenarioDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PreviewScenario.Failure.invalidFixturePath }
        defer { close(descriptor) }
        for (index, segment) in segments.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index < segments.count - 1 ? O_DIRECTORY : 0)
            let next = openat(descriptor, String(segment), flags)
            guard next >= 0 else { throw PreviewScenario.Failure.invalidFixturePath }
            close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw PreviewScenario.Failure.invalidFixturePath
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes, maximumBytes < Int.max else {
            throw PreviewScenario.Failure.fixtureTooLarge
        }
        // 文件描述符固定了目标，即使路径被并发替换也不会追随新链接。
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = handle.readData(ofLength: maximumBytes + 1)
        guard data.count <= maximumBytes else { throw PreviewScenario.Failure.fixtureTooLarge }
        return data
    }
}
