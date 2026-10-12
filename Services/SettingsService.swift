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

    /// Decoded-settings cache. `loadSettings` sits on hot paths — the window
    /// monitor tick, every thumbnail capture a card starts, every replica
    /// sync — and every call used to be a full UserDefaults read plus a JSON
    /// decode on the main thread (several times per second while panels are
    /// open). `saveSettings` is the only in-process writer, so it is also the
    /// only invalidation point. `AppSettings` is a value type, so handing out
    /// the cached instance is safe.
    private var cachedSettings: AppSettings?
    private let cacheLock = NSLock()

    static let shared = SettingsService()
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        AppLogger.debug("SettingsService initialized. settingsKey=\(settingsKey)")
    }
    
    func loadSettings() -> AppSettings {
        cacheLock.lock()
        let cached = cachedSettings
        cacheLock.unlock()
        if let cached {
            return cached
        }

        guard let data = defaults.data(forKey: settingsKey) ?? defaults.data(forKey: legacySettingsKey) else {
            AppLogger.info("No saved settings found. Using defaults")
            return .default
        }

        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            cacheLock.lock()
            cachedSettings = settings
            cacheLock.unlock()
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
        // Refresh the cache with exactly what was written, so a load on the
        // very next runloop turn (settingsDidChange observers read settings
        // immediately) never re-decodes.
        cacheLock.lock()
        cachedSettings = settings
        cacheLock.unlock()
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
