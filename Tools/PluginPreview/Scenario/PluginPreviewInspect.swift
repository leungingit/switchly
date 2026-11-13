import Foundation

/// `inspect` 的 stdout JSON（契约 §3.2）。不执行插件 JS、不读写用户目录、不需要屏幕录制。
enum PluginPreviewInspectReport {
    static func data(manifest: PluginManifest) throws -> Data {
        let draft = PreviewScenarioDraft.derive(manifest: manifest)
        guard let scenario = try JSONSerialization.jsonObject(with: draft.encode()) as? [String: Any] else {
            throw PluginPreviewInspectError.invalidScenario
        }
        let value: [String: Any] = [
            "schemaVersion": 1,
            "plugin": [
                "id": manifest.id,
                "name": manifest.name,
                "version": manifest.version,
                "apiVersion": manifest.apiVersion,
                "matches": manifest.matches,
                "permissions": manifest.permissions.map(\.rawValue),
            ],
            "defaultScenario": scenario,
            "settings": settings(manifest: manifest),
            "fixtures": fixtures(draft: draft, manifest: manifest),
        ]
        return try JSONSerialization.data(withJSONObject: value,
                                          options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])
    }

    private static func settings(manifest: PluginManifest) -> [[String: Any]] {
        (manifest.settings ?? []).map { spec in
            var value: [String: Any] = [
                "key": spec.key,
                "kind": spec.kind.rawValue,
                "default": jsonObject(spec.defaultValue),
            ]
            if spec.kind == .select {
                value["options"] = spec.options.map(\.value)
            }
            if spec.kind == .number {
                if let minimum = spec.min { value["min"] = minimum }
                if let maximum = spec.max { value["max"] = maximum }
                if let step = spec.step { value["step"] = step }
            }
            return value
        }
    }

    private static func fixtures(draft: PreviewScenarioDraft,
                                 manifest: PluginManifest) -> [[String: Any]] {
        PreviewScenarioDraft.FixtureKind.allCases.map { kind in
            let needed = kind.isRequired(by: manifest)
            return fixture(kind: kind, needed: needed,
                           source: sourceName(draft.fixtures[kind]),
                           reason: reason(kind: kind, needed: needed))
        }
    }

    private static func fixture(kind: PreviewScenarioDraft.FixtureKind, needed: Bool,
                                source: String, reason: String) -> [String: Any] {
        ["kind": kind.rawValue, "needed": needed, "source": source, "reason": reason]
    }

    /// 推导场景实际会使用的来源；`explicit` 供 GUI/覆盖项解析复用，`inspect` 通常只出现 builtin/none。
    private static func sourceName(_ source: PreviewScenarioDraft.FixtureSource) -> String {
        switch source {
        case .none: return "none"
        case .builtin: return "builtin"
        case .explicit: return "explicit"
        }
    }

    private static func reason(kind: PreviewScenarioDraft.FixtureKind, needed: Bool) -> String {
        switch kind {
        case .media:
            return needed ? "manifest declares media permissions"
                          : "manifest does not declare media permissions"
        case .weather:
            return needed ? "manifest declares weather.current"
                          : "manifest does not declare weather.current"
        case .activity:
            return needed ? "manifest declares activity.read; requires an explicit synthetic fixture" : "manifest does not declare activity.read"
        case .fs:
            return needed ? "manifest declares fs.read; requires an explicit fixture file"
                          : "manifest does not declare fs.read"
        }
    }

    private static func jsonObject(_ value: PluginSettingValue) -> Any {
        switch value {
        case .bool(let bool): return bool
        case .number(let number): return number
        case .string(let string): return string
        }
    }
}

enum PluginPreviewInspectError: Error, Equatable {
    case invalidScenario
}
