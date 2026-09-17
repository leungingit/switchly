//
//  SettingsService.swift
//  Switchly
//
//  Service for managing user preferences
//

import Foundation

protocol SettingsServiceProtocol {
    func loadSettings() -> AppSettings
    func saveSettings(_ settings: AppSettings) throws
    func observeChanges(_ handler: @escaping (AppSettings) -> Void)
}

class SettingsService: SettingsServiceProtocol {
    private let defaults: UserDefaults
    private let settingsKey = "com.switchly.settings"
    private let legacySettingsKey = "com.windowsnap.settings"
    
    static let shared = SettingsService()
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        AppLogger.debug("SettingsService initialized. settingsKey=\(settingsKey)")
    }
    
    func loadSettings() -> AppSettings {
        guard let data = defaults.data(forKey: settingsKey) ?? defaults.data(forKey: legacySettingsKey) else {
            AppLogger.info("No saved settings found. Using defaults")
            return .default
        }

        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            AppLogger.verbose("Loaded settings. bytes=\(data.count), monitoredApps=\(settings.monitoredApps.count), previewStrategy=\(settings.previewStrategy.rawValue)")
            return settings
        } catch {
            AppLogger.error("Failed to decode settings. bytes=\(data.count), error=\(error). Using defaults")
            return .default
        }
    }
    
    func saveSettings(_ settings: AppSettings) throws {
        AppLogger.info("Saving settings. monitoredApps=\(settings.monitoredApps.count), launchAtLogin=\(settings.launchAtLogin), globalShortcutKey=\(settings.globalShortcutKey ?? "nil")")
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: settingsKey)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        AppLogger.debug("Settings saved and notification posted. bytes=\(data.count)")
    }
    
    func observeChanges(_ handler: @escaping (AppSettings) -> Void) {
        AppLogger.debug("Registered settings observer")
        NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { _ in
            AppLogger.debug("Settings change notification received")
            handler(self.loadSettings())
        }
    }
}

extension Notification.Name {
    static let settingsDidChange = Notification.Name("com.switchly.settingsDidChange")
}
