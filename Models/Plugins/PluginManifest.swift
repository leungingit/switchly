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
    case windowFocus
    /// Only host-provided script templates targeting this bundle ID (phase 2).
    case appleScript(bundleID: String)

    init?(rawValue: String) {
        switch rawValue {
        case "media.nowPlaying": self = .mediaNowPlaying
        case "media.control": self = .mediaControl
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

/// A boolean option a plugin exposes in Preferences → Plugins.
struct PluginSettingSpec: Codable, Equatable {
    let key: String
    /// Localized title keyed by locale identifier ("en", "zh-Hans").
    let title: [String: String]
    let `default`: Bool
    /// Host-handled behaviour; currently only "hideWindowPreviews".
    var effect: String? = nil

    func displayTitle(preferredLanguages: [String]) -> String {
        for language in preferredLanguages {
            if let exact = title[language] { return exact }
            if language.hasPrefix("zh-Hans") || language.hasPrefix("zh-CN"), let zh = title["zh-Hans"] { return zh }
            if let base = language.split(separator: "-").first.map(String.init), let match = title[base] { return match }
        }
        return title["en"] ?? key
    }
}

struct PluginManifest: Codable, Equatable {
    /// API versions this host can run.
    static let supportedAPIVersions: ClosedRange<Int> = 1...1

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
