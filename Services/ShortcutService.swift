//
//  ShortcutService.swift
//  Switchly
//
//  Service for managing global keyboard shortcuts
//

import Foundation
import AppKit
import HotKey

protocol ShortcutServiceProtocol {
    func setupGlobalShortcuts()
    func registerShortcut(for app: MonitoredApp, key: String)
    func unregisterShortcut(for app: MonitoredApp)
    func updateGlobalShortcut(_ key: String?)
    func unregisterAllShortcuts()
}

class ShortcutService: ShortcutServiceProtocol {
    private let settingsService: SettingsServiceProtocol
    private var hotKeys: [String: HotKey] = [:]
    private var globalHotKey: HotKey?
    private var previousAppWindowHotKey: HotKey?
    private var nextAppWindowHotKey: HotKey?
    private var workspaceHotKeys: [UUID: HotKey] = [:]
    
    static let shared = ShortcutService()
    
    private init(settingsService: SettingsServiceProtocol = SettingsService.shared) {
        self.settingsService = settingsService
        AppLogger.debug("ShortcutService initialized")
    }
    
    func setupGlobalShortcuts() {
        let settings = settingsService.loadSettings()
        AppLogger.info("Setting up shortcuts. globalShortcutKey=\(settings.globalShortcutKey ?? "nil"), monitoredApps=\(settings.monitoredApps.count)")
        unregisterAllShortcuts()
        
        if let globalKey = settings.globalShortcutKey {
            updateGlobalShortcut(globalKey)
        }
        registerCurrentAppWindowShortcuts()
        
        let appsByKey = Dictionary(grouping: settings.monitoredApps.filter { app in
            app.isEnabled && app.shortcutKey?.isEmpty == false
        }, by: { $0.shortcutKey ?? "" })

        for (key, apps) in appsByKey {
            registerShortcut(for: apps, key: key)
        }
        registerWorkspaceShortcuts(settings.workspaces)
        AppLogger.info("Shortcuts setup complete. appHotKeys=\(hotKeys.count), hasGlobalHotKey=\(globalHotKey != nil)")
    }
    
    func registerShortcut(for app: MonitoredApp, key: String) {
        AppLogger.debug("Registering app shortcut. app=\(app.appName), key=\(key)")
        registerShortcut(for: [app], key: key)
        AppLogger.info("Registered app shortcut. app=\(app.appName), key=\(key)")
    }
    
    func unregisterShortcut(for app: MonitoredApp) {
        setupGlobalShortcuts()
        AppLogger.info("Unregistered app shortcut. app=\(app.appName)")
    }
    
    func updateGlobalShortcut(_ key: String?) {
        AppLogger.info("Updating global shortcut. key=\(key ?? "nil")")
        globalHotKey = nil
        
        guard let key = key, let keyEquivalent = parseKey(key) else {
            AppLogger.warning("Global shortcut cleared or could not be parsed. key=\(key ?? "nil")")
            return
        }
        
        let modifiers = resolveModifiers()
        globalHotKey = HotKey(key: keyEquivalent, modifiers: modifiers, keyDownHandler: { [weak self] in
            self?.handleGlobalShortcut()
        })
        AppLogger.info("Registered global shortcut. key=\(key)")
    }
    
    func unregisterAllShortcuts() {
        hotKeys.removeAll()
        globalHotKey = nil
        previousAppWindowHotKey = nil
        nextAppWindowHotKey = nil
        workspaceHotKeys.removeAll()
        AppLogger.info("Unregistered all shortcuts")
    }
    
    private func parseKey(_ key: String) -> Key? {
        switch key.lowercased() {
        case "1", "one": return .one
        case "2", "two": return .two
        case "3", "three": return .three
        case "4", "four": return .four
        case "5", "five": return .five
        case "6", "six": return .six
        case "7", "seven": return .seven
        case "8", "eight": return .eight
        case "9", "nine": return .nine
        case "0", "zero": return .zero
        case "a": return .a
        case "b": return .b
        case "c": return .c
        case "d": return .d
        case "e": return .e
        case "f": return .f
        case "g": return .g
        case "h": return .h
        case "i": return .i
        case "j": return .j
        case "k": return .k
        case "l": return .l
        case "m": return .m
        case "n": return .n
        case "o": return .o
        case "p": return .p
        case "q": return .q
        case "r": return .r
        case "s": return .s
        case "t": return .t
        case "u": return .u
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "y": return .y
        case "z": return .z
        case "space": return .space
        case "comma": return .comma
        case "tab": return .tab
        case "return": return .return
        case "escape": return .escape
        default:
            if let scalar = UnicodeScalar(key.utf16.first ?? 0) {
                return Key(string: String(scalar))
            }
            return nil
        }
    }
    
    private func handleTogglePreview() {
        AppLogger.info("Handling toggle preview shortcut")
        NotificationCenter.default.post(name: .togglePreview, object: nil)
    }
    
    private func handleAppShortcut(_ app: MonitoredApp) {
        AppLogger.info("Handling app shortcut. app=\(app.appName), bundleID=\(app.bundleIdentifier)")
        NotificationCenter.default.post(name: .appShortcutTriggered, object: [app])
    }

    private func handleAppShortcut(_ apps: [MonitoredApp], key: String) {
        AppLogger.info("Handling shared app shortcut. key=\(key), apps=\(apps.map { $0.appName }.joined(separator: ","))")
        NotificationCenter.default.post(name: .appShortcutTriggered, object: apps)
    }
    
    private func handleGlobalShortcut() {
        AppLogger.info("Handling global shortcut")
        NotificationCenter.default.post(name: .globalShortcutTriggered, object: nil)
    }

    private func handleCurrentAppWindowShortcut(offset: Int) {
        AppLogger.info("Handling current app window shortcut. offset=\(offset)")
        NotificationCenter.default.post(name: .currentAppWindowShortcutTriggered, object: offset)
    }

    private func handleWorkspaceShortcut(_ workspace: Workspace) {
        AppLogger.info("Handling workspace shortcut. workspace=\(workspace.name), id=\(workspace.id)")
        NotificationCenter.default.post(name: .workspaceShortcutTriggered, object: workspace.id)
    }
}

private extension ShortcutService {
    /// Reads the user's ShortcutPrefix setting and returns the corresponding modifier flags.
    func resolveModifiers() -> NSEvent.ModifierFlags {
        let settings = settingsService.loadSettings()
        switch settings.shortcutPrefix {
        case .commandOption:
            return [.command, .option]
        case .commandControl:
            return [.command, .control]
        case .controlOption:
            return [.control, .option]
        case .commandShift:
            return [.command, .shift]
        case .commandOptionShift:
            return [.command, .option, .shift]
        }
    }

    func registerShortcut(for apps: [MonitoredApp], key: String) {
        AppLogger.debug("Registering shared app shortcut. key=\(key), apps=\(apps.map { $0.appName }.joined(separator: ","))")
        guard let keyEquivalent = parseKey(key) else {
            AppLogger.warning("Failed to parse shared app shortcut key. key=\(key)")
            return
        }

        let modifiers = resolveModifiers()
        let hotKey = HotKey(key: keyEquivalent, modifiers: modifiers, keyDownHandler: { [weak self] in
            self?.handleAppShortcut(apps, key: key)
        })

        hotKeys[key] = hotKey
        AppLogger.info("Registered shared app shortcut. key=\(key), appCount=\(apps.count)")
    }

    func registerCurrentAppWindowShortcuts() {
        let modifiers = resolveModifiers().union(.shift)
        previousAppWindowHotKey = HotKey(key: .comma, modifiers: modifiers, keyDownHandler: { [weak self] in
            self?.handleCurrentAppWindowShortcut(offset: -1)
        })
        nextAppWindowHotKey = HotKey(key: .period, modifiers: modifiers, keyDownHandler: { [weak self] in
            self?.handleCurrentAppWindowShortcut(offset: 1)
        })
        AppLogger.info("Registered current app window shortcuts. previous=<, next=>")
    }

    func registerWorkspaceShortcuts(_ workspaces: [Workspace]) {
        let reservedKeys = reservedShortcutKeys()
        var usedKeys = Set(hotKeys.keys.map { $0.lowercased() })

        for workspace in workspaces {
            guard let key = workspace.shortcutKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !key.isEmpty,
                  let keyEquivalent = parseKey(key) else {
                continue
            }

            guard !reservedKeys.contains(key), !usedKeys.contains(key) else {
                AppLogger.warning("Skipped workspace shortcut due to conflict. workspace=\(workspace.name), key=\(key)")
                continue
            }

            let hotKey = HotKey(key: keyEquivalent, modifiers: resolveModifiers(), keyDownHandler: { [weak self] in
                self?.handleWorkspaceShortcut(workspace)
            })
            workspaceHotKeys[workspace.id] = hotKey
            usedKeys.insert(key)
            AppLogger.info("Registered workspace shortcut. workspace=\(workspace.name), key=\(key)")
        }
    }

    func reservedShortcutKeys() -> Set<String> {
        let settings = settingsService.loadSettings()
        var keys = Set<String>()
        if let globalKey = settings.globalShortcutKey?.lowercased(), !globalKey.isEmpty {
            keys.insert(globalKey)
        }
        keys.insert("comma")
        keys.insert(",")
        keys.insert("period")
        keys.insert(".")
        return keys
    }
}

extension Notification.Name {
    static let togglePreview = Notification.Name("com.switchly.togglePreview")
    static let appShortcutTriggered = Notification.Name("com.switchly.appShortcutTriggered")
    static let globalShortcutTriggered = Notification.Name("com.switchly.globalShortcutTriggered")
    static let currentAppWindowShortcutTriggered = Notification.Name("com.switchly.currentAppWindowShortcutTriggered")
    static let workspaceShortcutTriggered = Notification.Name("com.switchly.workspaceShortcutTriggered")
}
