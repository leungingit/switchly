//
//  PluginManifest.swift
//  Switchly
//
//  manifest.json of a Dock preview plugin (docs/dock-preview-plugins-design.md §3.2)
//

import Foundation

/// Capabilities a plugin may request. Anything not declared is never injected
/// into the plugin's JS context (absent rather than denied at call time).
enum PluginCapability: Hashable, Codable {
    case mediaNowPlaying
    case mediaControl
    /// Pick, play and pause tracks from the Music library (design doc §8).
    case mediaLibrary
    case windowFocus
    /// Only host-provided script templates targeting this bundle ID (phase 2).
    case appleScript(bundleID: String)

    init?(rawValue: String) {
        switch rawValue {
        case "media.nowPlaying": self = .mediaNowPlaying
        case "media.control": self = .mediaControl
        case "media.library": self = .mediaLibrary
        case "window.focus": self = .windowFocus
        default:
            let prefix = "appleScript:"
            guard rawValue.hasPrefix(prefix) else { return nil }
            let bundleID = String(rawValue.dropFirst(prefix.count))
            guard !bundleID.isEmpty else { return nil }
            self = .appleScript(bundleID: bundleID)
        }
    }

    var rawValue: String {
        switch self {
        case .mediaNowPlaying: return "media.nowPlaying"
        case .mediaControl: return "media.control"
        case .mediaLibrary: return "media.library"
        case .windowFocus: return "window.focus"
        case .appleScript(let bundleID): return "appleScript:\(bundleID)"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = PluginCapability(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown permission \(raw)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A saved plugin option: toggles are bools, `select` options strings, `number` options numbers.
enum PluginSettingValue: Codable, Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self), n.isFinite { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported setting value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }

    /// What `ctx.settings` hands to the plugin.
    var jsValue: Any {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        }
    }
}

struct PluginSettingOption: Codable, Equatable {
    let value: String
    let title: [String: String]
}

/// An option a plugin exposes in Preferences → Plugins: a toggle (default), a
/// `select` or a `number`.
struct PluginSettingSpec: Codable, Equatable {
    enum Kind: String, Codable { case toggle, select, number }

    let key: String
    /// Localized title keyed by locale identifier ("en", "zh-Hans").
    let title: [String: String]
    let defaultValue: PluginSettingValue
    /// Host-handled behaviour; currently only "hideWindowPreviews".
    var effect: String? = nil
    var kind: Kind = .toggle
    var options: [PluginSettingOption] = []
    var min: Double? = nil
    var max: Double? = nil
    var step: Double? = nil

    /// Toggle default; false for the other kinds.
    var `default`: Bool {
        if case .bool(let b) = defaultValue { return b }
        return false
    }

    init(key: String, title: [String: String], default value: Bool, effect: String? = nil) {
        self.key = key
        self.title = title
        self.defaultValue = .bool(value)
        self.effect = effect
    }

    private enum CodingKeys: String, CodingKey { case key, title, `default`, effect, type, options, min, max, step }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = try c.decode([String: String].self, forKey: .title)
        effect = try c.decodeIfPresent(String.self, forKey: .effect)
        kind = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .toggle
        options = try c.decodeIfPresent([PluginSettingOption].self, forKey: .options) ?? []
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        step = try c.decodeIfPresent(Double.self, forKey: .step)
        defaultValue = try c.decode(PluginSettingValue.self, forKey: .default)
        // The default must match the kind, and a select's default must be one of its options.
        let valid: Bool
        switch (kind, defaultValue) {
        case (.toggle, .bool): valid = true
        case (.number, .number(let n)): valid = (min ?? -.infinity) <= n && n <= (max ?? .infinity) && (step.map { $0 > 0 } ?? true)
        case (.select, .string(let s)): valid = options.contains { $0.value == s }
        default: valid = false
        }
        guard valid else {
            throw DecodingError.dataCorruptedError(forKey: .default, in: c, debugDescription: "Default does not fit option type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(title, forKey: .title)
        try c.encode(defaultValue, forKey: .default)
        try c.encodeIfPresent(effect, forKey: .effect)
        if kind != .toggle { try c.encode(kind, forKey: .type) }
        if !options.isEmpty { try c.encode(options, forKey: .options) }
        try c.encodeIfPresent(min, forKey: .min)
        try c.encodeIfPresent(max, forKey: .max)
        try c.encodeIfPresent(step, forKey: .step)
    }

    /// Option title in the user's language (select kind).
    static func localized(_ title: [String: String], fallback: String, preferredLanguages: [String]) -> String {
        for language in preferredLanguages {
            if let exact = title[language] { return exact }
            if language.hasPrefix("zh-Hans") || language.hasPrefix("zh-CN"), let zh = title["zh-Hans"] { return zh }
            if let base = language.split(separator: "-").first.map(String.init), let match = title[base] { return match }
        }
        return title["en"] ?? fallback
    }

    func displayTitle(preferredLanguages: [String]) -> String {
        Self.localized(title, fallback: key, preferredLanguages: preferredLanguages)
    }
}

struct PluginManifest: Codable, Equatable {
    /// API versions this host can run.
    static let supportedAPIVersions: ClosedRange<Int> = 1...2

    let id: String
    /// Localized display name keyed by locale identifier ("en", "zh-Hans").
    let name: [String: String]
    let version: String
    let apiVersion: Int
    /// Target bundle IDs.
    let matches: [String]
    let permissions: [PluginCapability]
    let entry: String
    /// Seconds between host-driven re-renders while visible; clamped to >= 1.
    let refreshInterval: TimeInterval?
    /// Options shown on the plugin's own settings card; values reach the plugin as `ctx.settings`.
    var settings: [PluginSettingSpec]? = nil

    enum ValidationError: Error, Equatable {
        case invalidID
        case unsupportedAPIVersion(Int)
        case emptyMatches
        case invalidEntry
    }

    func validate() throws {
        let idPattern = #"^[A-Za-z0-9]+(\.[A-Za-z0-9-]+)+$"#
        guard id.range(of: idPattern, options: .regularExpression) != nil else { throw ValidationError.invalidID }
        guard Self.supportedAPIVersions.contains(apiVersion) else {
            throw ValidationError.unsupportedAPIVersion(apiVersion)
        }
        guard !matches.isEmpty else { throw ValidationError.emptyMatches }
        // Entry must stay inside the plugin directory.
        guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else {
            throw ValidationError.invalidEntry
        }
    }

    var effectiveRefreshInterval: TimeInterval? {
        refreshInterval.map { max(1, $0) }
    }

    func displayName(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        for language in preferredLanguages {
            if let exact = name[language] { return exact }
            if let base = language.split(separator: "-").first.map(String.init), let match = name[base] {
                return match
            }
            if language.hasPrefix("zh-Hans") || language.hasPrefix("zh-CN"), let zh = name["zh-Hans"] { return zh }
        }
        return name["en"] ?? name.values.sorted().first ?? id
    }

    /// Settings that opt this plugin into hiding the window thumbnails.
    var hidePreviewsKeys: [PluginSettingSpec] {
        (settings ?? []).filter { $0.effect == "hideWindowPreviews" }
    }

    func matches(bundleID: String) -> Bool {
        matches.contains(bundleID)
    }
}
