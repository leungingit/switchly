//
//  MonitoredApp.swift
//  Switchly
//
//  Model representing a monitored application configuration
//

import Foundation

struct MonitoredApp: Identifiable, Codable, Hashable {
    let id: UUID
    let bundleIdentifier: String
    let appName: String
    var shortcutKey: String?
    var isEnabled: Bool
    var autoSwitchIfSingle: Bool
    var cachedIconPath: String?
    
    init(
        bundleIdentifier: String,
        appName: String,
        shortcutKey: String? = nil,
        isEnabled: Bool = true,
        autoSwitchIfSingle: Bool = true
    ) {
        self.id = UUID()
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.shortcutKey = shortcutKey
        self.isEnabled = isEnabled
        self.autoSwitchIfSingle = autoSwitchIfSingle
        self.cachedIconPath = nil
    }
}
