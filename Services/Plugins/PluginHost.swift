//
//  PluginHost.swift
//  Switchly
//
//  Owns the installed plugins and one runtime per plugin. Packages are read
//  lazily on first use; runtimes are created on demand and their JS VMs are
//  unmounted whenever the Dock preview closes. Only enabled plugins run, and
//  each runtime receives just its authorized permissions (PluginAuthorization).
//

import Foundation

struct InstalledPlugin: Equatable, Identifiable {
    let package: PluginPackage
    let authorization: PluginAuthorization
    var id: String { package.manifest.id }
}

protocol PluginHosting: AnyObject {
    func runtimes(for bundleID: String) -> [PluginRuntimeProtocol]
    func installedPlugins() -> [InstalledPlugin]
    /// Cover art for the target app; nil unless an enabled plugin matching it
    /// is authorized to read what's playing.
    func artwork(for bundleID: String) async -> Data?
    func unmountAll()
    func reload()
}

final class PluginHost: PluginHosting {
    static let shared = PluginHost()

    private let registry: PluginRegistryProtocol
    private let grants: () -> [String: PluginGrant]
    private let mediaBridge: MediaBridging
    private let makeRuntime: (PluginPackage, Set<PluginCapability>) -> PluginRuntimeProtocol
    private let lock = NSLock()
    private var packages: [PluginPackage]?
    /// Keyed by id; the permission set is kept so a grant change rebuilds the VM.
    private var runtimesByID: [String: (permissions: Set<PluginCapability>, runtime: PluginRuntimeProtocol)] = [:]

    init(registry: PluginRegistryProtocol = PluginRegistry(),
         grants: @escaping () -> [String: PluginGrant] = { SettingsService.shared.loadSettings().pluginGrants },
         mediaBridge: MediaBridging = MusicAppleScriptBridge(),
         weather: @escaping () -> [String: Any]? = { OnlineWeatherService.shared.current()?.jsObject },
         makeRuntime: ((PluginPackage, Set<PluginCapability>) -> PluginRuntimeProtocol)? = nil) {
        self.registry = registry
        self.grants = grants
        self.mediaBridge = mediaBridge
        self.makeRuntime = makeRuntime ?? { package, permissions in
            // Media calls are Apple Event round trips; 1 s leaves room for a
            // busy target app without letting a stuck plugin linger.
            PluginRuntime(package: package, timeout: 1, mediaBridge: mediaBridge, permissions: permissions,
                          libraryBridge: mediaBridge as? MusicLibraryPlaying,
                          settings: { SettingsService.shared.loadSettings().pluginSettings[package.manifest.id] ?? [:] },
                          values: { SettingsService.shared.loadSettings().pluginValues[package.manifest.id] ?? [:] },
                          weather: weather)
        }
    }

    func installedPlugins() -> [InstalledPlugin] {
        lock.lock()
        defer { lock.unlock() }
        return loadedPackages().map(resolve)
    }

    func runtimes(for bundleID: String) -> [PluginRuntimeProtocol] {
        lock.lock()
        var stale: [PluginRuntimeProtocol] = []
        var result: [PluginRuntimeProtocol] = []
        for plugin in loadedPackages().map(resolve) where plugin.package.manifest.matches(bundleID: bundleID) {
            let auth = plugin.authorization
            guard auth.isEnabled else {
                if let old = runtimesByID.removeValue(forKey: plugin.id) { stale.append(old.runtime) }
                continue
            }
            if let existing = runtimesByID[plugin.id], existing.permissions == auth.permissions {
                result.append(existing.runtime)
                continue
            }
            if let old = runtimesByID[plugin.id] { stale.append(old.runtime) }
            let runtime = makeRuntime(plugin.package, auth.permissions)
            runtimesByID[plugin.id] = (auth.permissions, runtime)
            result.append(runtime)
        }
        lock.unlock()
        stale.forEach { $0.unmount() }
        return result
    }

    func artwork(for bundleID: String) async -> Data? {
        let allowed = installedPlugins().contains {
            $0.authorization.isEnabled && $0.authorization.permissions.contains(.mediaNowPlaying)
                && $0.package.manifest.matches(bundleID: bundleID)
        }
        guard allowed, mediaBridge.supports(bundleID: bundleID) else { return nil }
        let bridge = mediaBridge
        return await withCheckedContinuation { continuation in
            bridge.queue.async {
                continuation.resume(returning: (try? bridge.artwork(bundleID: bundleID)) ?? nil)
            }
        }
    }

    func unmountAll() {
        lock.lock()
        let runtimes = runtimesByID.values.map(\.runtime)
        lock.unlock()
        runtimes.forEach { $0.unmount() }
    }

    func reload() {
        lock.lock()
        let old = runtimesByID.values.map(\.runtime)
        runtimesByID.removeAll()
        packages = nil
        lock.unlock()
        old.forEach { $0.unmount() }
    }

    /// Caller holds `lock`.
    private func loadedPackages() -> [PluginPackage] {
        if packages == nil { packages = registry.reload().plugins }
        return packages ?? []
    }

    private func resolve(_ package: PluginPackage) -> InstalledPlugin {
        InstalledPlugin(package: package, authorization: PluginAuthorization.resolve(
            manifest: package.manifest, origin: package.origin, grant: grants()[package.manifest.id]))
    }
}
