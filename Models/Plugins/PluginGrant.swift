//
//  PluginGrant.swift
//  Switchly
//
//  The user's decision about one plugin, persisted in AppSettings.pluginGrants
//  keyed by plugin id (design doc §3.6).
//

import Foundation

struct PluginGrant: Codable, Equatable {
    var isEnabled: Bool
    /// Raw permission strings the user confirmed. Kept as strings so a grant
    /// written by a newer build with unknown permissions still decodes.
    var permissions: [String]
}

/// What a plugin may actually do, combining origin, manifest and grant.
struct PluginAuthorization: Equatable {
    let isEnabled: Bool
    /// Capabilities injected into the JS context.
    let permissions: Set<PluginCapability>
    /// Declared but not (yet) confirmed — e.g. added by a plugin update.
    let pendingPermissions: [PluginCapability]

    /// Built-in plugins ship with the app and are trusted with what they
    /// declare; they run unless the user turned them off. Anything else stays
    /// off until the user confirms its permission list, and only confirmed
    /// permissions are ever injected.
    static func resolve(manifest: PluginManifest, origin: PluginOrigin, grant: PluginGrant?) -> PluginAuthorization {
        let declared = manifest.permissions
        switch origin {
        case .builtin:
            return PluginAuthorization(isEnabled: grant?.isEnabled ?? true, permissions: Set(declared), pendingPermissions: [])
        case .user:
            let confirmed = Set(grant?.permissions ?? [])
            let granted = declared.filter { confirmed.contains($0.rawValue) }
            let pending = declared.filter { !confirmed.contains($0.rawValue) }
            return PluginAuthorization(isEnabled: grant?.isEnabled ?? false, permissions: Set(granted), pendingPermissions: pending)
        }
    }
}

extension PluginCapability {
    /// Localization key for the permission list shown before enabling.
    var displayKey: String {
        switch self {
        case .mediaNowPlaying: return "Read what's playing"
        case .mediaControl: return "Control playback"
        case .mediaLibrary: return "Pick and play songs from your library"
        case .weatherCurrent: return "Read the current weather"
        case .windowFocus: return "Focus windows"
        case .appleScript: return "Run Switchly's built-in scripts for %@"
        }
    }

    var systemImageName: String {
        switch self {
        case .mediaNowPlaying: return "music.note"
        case .mediaControl: return "playpause"
        case .mediaLibrary: return "music.note.list"
        case .weatherCurrent: return "cloud.sun"
        case .windowFocus: return "macwindow"
        case .appleScript: return "applescript"
        }
    }
}
