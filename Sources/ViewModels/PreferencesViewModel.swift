//
//  PreferencesViewModel.swift
//  Switchly
//
//  ViewModel for preferences view
//

import Foundation
import Combine
import AppKit
import ServiceManagement
import CoreGraphics

class PreferencesViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var availableApps: [MonitoredApp] = []
    @Published var errorMessage: String?
    @Published var isAccessibilityPermissionGranted: Bool = false
    @Published var isScreenCapturePermissionGranted: Bool = false
    @Published var permissionStatusLastUpdated: Date?
    
    private let settingsService: SettingsServiceProtocol
    private let shortcutService: ShortcutServiceProtocol
    private var cancellables = Set<AnyCancellable>()
    
    init(
        settingsService: SettingsServiceProtocol = SettingsService.shared,
        shortcutService: ShortcutServiceProtocol = ShortcutService.shared
    ) {
        self.settingsService = settingsService
        self.shortcutService = shortcutService
        self.settings = settingsService.loadSettings()
        AppLogger.info("PreferencesViewModel initialized. monitoredApps=\(settings.monitoredApps.count), availableApps=\(availableApps.count)")
        
        refreshPermissionStatus()
        loadAvailableApps()
        setupObservers()
    }
    
    func saveSettings() {
        AppLogger.info("PreferencesViewModel saving settings")
        do {
            try settingsService.saveSettings(settings)
            ThemeApplier.apply(settings.theme)
            shortcutService.setupGlobalShortcuts()
            
            if #available(macOS 13.0, *) {
                do {
                    if settings.launchAtLogin {
                        AppLogger.debug("Preferences requested launch-at-login register")
                        try SMAppService.mainApp.register()
                    } else {
                        AppLogger.debug("Preferences requested launch-at-login unregister")
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    AppLogger.error("Failed to update login item status from preferences: \(error)")
                }
            } else {
                if settings.launchAtLogin {
                    AppLogger.info("Launch at login requested on macOS <13; add the app manually via System Settings → Users & Groups → Login Items")
                }
            }
        } catch {
            errorMessage = String(format: settings.language.localizedString("Failed to save settings: %@"), error.localizedDescription)
            AppLogger.error("Failed to save settings from preferences: \(error)")
        }
    }

    func updateSettings(_ update: (inout AppSettings) -> Void) {
        update(&settings)
        saveSettings()
    }

    func setShortcutKey(_ key: String?, for app: MonitoredApp) {
        var updatedApp = app
        updatedApp.shortcutKey = key
        updateMonitoredApp(updatedApp)
    }

    func refreshPermissionStatus() {
        updatePermissionStatus(logWhenUnchanged: true)
    }

    func openAccessibilitySettings() {
        AccessibilityService.shared.requestPermission()
        AccessibilityService.shared.openAccessibilityPreferences()
        refreshPermissionStatusSoon()
    }

    func openScreenCaptureSettings() {
        AppLogger.info("Requesting screen capture permission prompt")
        let granted = CGRequestScreenCaptureAccess()
        AppLogger.info("Screen capture permission request completed. granted=\(granted)")
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            AppLogger.error("Failed to create screen capture preferences URL")
            refreshPermissionStatusSoon()
            return
        }
        AppLogger.info("Opening screen and system audio recording preferences")
        NSWorkspace.shared.open(url)
        refreshPermissionStatusSoon()
    }

    private var appBundlePath: String {
        Bundle.main.bundlePath
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }
    
    func addMonitoredApp(_ app: MonitoredApp) {
        AppLogger.info("Adding monitored app. name=\(app.appName), bundleID=\(app.bundleIdentifier)")
        if !settings.monitoredApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            var appToAdd = app
            if appToAdd.shortcutKey?.isEmpty != false {
                appToAdd.shortcutKey = Self.inferredShortcutKey(
                    for: appToAdd.appName,
                    globalShortcutKey: settings.globalShortcutKey
                )
            }
            settings.monitoredApps.append(appToAdd)
            saveSettings()
        } else {
            AppLogger.warning("Skipped adding duplicate monitored app. bundleID=\(app.bundleIdentifier)")
        }
    }

    static func inferredShortcutKey(for appName: String, globalShortcutKey: String?) -> String? {
        guard let scalar = appName.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.first else {
            return nil
        }

        let key: String
        switch scalar.value {
        case 65...90:
            key = String(UnicodeScalar(scalar.value + 32)!)
        case 97...122:
            key = String(scalar)
        default:
            return nil
        }

        guard key != globalShortcutKey?.lowercased() else {
            return nil
        }
        return key
    }
    
    func removeMonitoredApp(_ app: MonitoredApp) {
        AppLogger.info("Removing monitored app. name=\(app.appName), bundleID=\(app.bundleIdentifier)")
        settings.monitoredApps.removeAll { $0.id == app.id }
        shortcutService.unregisterShortcut(for: app)
        saveSettings()
    }
    
    func updateMonitoredApp(_ app: MonitoredApp) {
        AppLogger.info("Updating monitored app. name=\(app.appName), bundleID=\(app.bundleIdentifier), enabled=\(app.isEnabled), shortcutKey=\(app.shortcutKey ?? "nil")")
        if let index = settings.monitoredApps.firstIndex(where: { $0.id == app.id }) {
            let oldApp = settings.monitoredApps[index]
            settings.monitoredApps[index] = app
            
            if oldApp.shortcutKey != app.shortcutKey {
                shortcutService.unregisterShortcut(for: oldApp)
                if let key = app.shortcutKey {
                    shortcutService.registerShortcut(for: app, key: key)
                }
            }
            
            saveSettings()
        } else {
            AppLogger.warning("Skipped updating missing monitored app. id=\(app.id)")
        }
    }
    
    func toggleAppEnabled(_ app: MonitoredApp) {
        AppLogger.info("Toggling monitored app. name=\(app.appName), bundleID=\(app.bundleIdentifier)")
        if let index = settings.monitoredApps.firstIndex(where: { $0.id == app.id }) {
            settings.monitoredApps[index].isEnabled.toggle()
            AppLogger.debug("Monitored app toggled. enabled=\(settings.monitoredApps[index].isEnabled)")
            saveSettings()
        } else {
            AppLogger.warning("Skipped toggling missing monitored app. id=\(app.id)")
        }
    }
    
    /// Apps that can be added, filtered by `query`.
    ///
    /// Shares the predicate with the workspace picker so both surfaces search
    /// the same fields.
    func filteredAvailableApps(query: String) -> [MonitoredApp] {
        let unmonitored = availableApps.filter { availableApp in
            !settings.monitoredApps.contains { $0.bundleIdentifier == availableApp.bundleIdentifier }
        }
        return InstalledAppsService.filter(unmonitored, query: query)
    }

    /// Points the picker at the installed-apps service.
    ///
    /// It used to read `runningApplications` and to skip every
    /// `com.apple.*` bundle, so an app that was not running could not be
    /// added at all and no Apple app (Safari, Terminal, Xcode, …) ever showed up.
    /// See `InstalledAppsService`.
    private func loadAvailableApps() {
        applyAvailableApps(InstalledAppsService.shared.apps)
        InstalledAppsService.shared.reload()
        observeAvailableApps()
    }

    private func applyAvailableApps(_ apps: [InstalledApp]) {
        availableApps = apps.map {
            MonitoredApp(bundleIdentifier: $0.bundleIdentifier, appName: $0.appName)
        }
        AppLogger.info("Loaded available apps. count=\(availableApps.count)")
    }

    /// Re-reads the service when it re-enumerates, so the list cannot go stale
    /// behind an open preferences window.
    private func observeAvailableApps() {
        NotificationCenter.default.publisher(for: InstalledAppsService.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyAvailableApps(InstalledAppsService.shared.apps)
            }
            .store(in: &cancellables)
    }
    
    private func setupObservers() {
        AppLogger.debug("PreferencesViewModel setting up settings observer")
        settingsService.observeChanges { [weak self] newSettings in
            AppLogger.debug("PreferencesViewModel received settings update. monitoredApps=\(newSettings.monitoredApps.count)")
            self?.settings = newSettings
        }

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.updatePermissionStatus(logWhenUnchanged: false)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.updatePermissionStatus(logWhenUnchanged: false)
            }
            .store(in: &cancellables)
    }

    private func refreshPermissionStatusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updatePermissionStatus(logWhenUnchanged: true)
        }
    }

    private func updatePermissionStatus(logWhenUnchanged: Bool) {
        let accessibilityGranted = AccessibilityService.shared.checkPermissionStatus()
        let screenCaptureGranted = CGPreflightScreenCaptureAccess()
        let changed = accessibilityGranted != isAccessibilityPermissionGranted
            || screenCaptureGranted != isScreenCapturePermissionGranted

        isAccessibilityPermissionGranted = accessibilityGranted
        isScreenCapturePermissionGranted = screenCaptureGranted
        permissionStatusLastUpdated = Date()

        if changed || logWhenUnchanged {
            AppLogger.info("Permission status refreshed. accessibility=\(isAccessibilityPermissionGranted), screenCapture=\(isScreenCapturePermissionGranted), bundleID=\(bundleIdentifier), appPath=\(appBundlePath)")
        }
    }

}
