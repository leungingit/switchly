//
//  PluginHost.swift
//  Switchly
//
//  Owns the installed plugins and one runtime per plugin. Packages are read
//  lazily on first use; runtimes are created on demand and their JS VMs are
//  suspended when the Dock preview closes and unmounted on reload. Only enabled plugins run, and
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
    func loadRuntimes(for bundleID: String) async -> [PluginRuntimeProtocol]
    func installedPlugins() -> [InstalledPlugin]
    func loadFailures() -> [PluginLoadFailure]
    /// Cover art for the target app; nil unless an enabled plugin matching it
    /// is authorized to read what's playing.
    func artwork(for bundleID: String) async -> Data?
    func mediaRead(for bundleID: String) async -> MediaReadContext?
    func mediaReadIsCurrent(_ read: MediaReadContext, bundleID: String) async -> Bool
    func acquireMediaRead(for bundleID: String, invalidate: @escaping () -> Void) -> MediaReadInterest?
    func acquireRuntimeVisibility(_ runtimes: [PluginRuntimeProtocol], invalidate: @escaping () -> Void) -> PluginLifetime
    func unmountAll()
    func reload()
}

extension PluginHosting {
    func loadRuntimes(for bundleID: String) async -> [PluginRuntimeProtocol] { runtimes(for: bundleID) }
    func acquireRuntimeVisibility(_ runtimes: [PluginRuntimeProtocol], invalidate: @escaping () -> Void) -> PluginLifetime {
        let visibility = PluginRuntimeVisibility()
        let lease = visibility.acquire(runtimes, invalidate: invalidate)
        return PluginLifetime { lease.cancel(); withExtendedLifetime(visibility) {} }
    }
    func loadFailures() -> [PluginLoadFailure] { [] }
    func mediaRead(for bundleID: String) async -> MediaReadContext? { nil }
    func mediaReadIsCurrent(_ read: MediaReadContext, bundleID: String) async -> Bool { read.isCurrent() }
    func acquireMediaRead(for bundleID: String, invalidate: @escaping () -> Void) -> MediaReadInterest? { nil }
}

/// 包与运行时表由 lock 保护；可见性和媒体生命周期各自使用已有的串行同步入口。
final class PluginHost: PluginHosting, @unchecked Sendable {
    static let shared = PluginHost(mediaBridge: MediaRemoteAssembly.makeBridge())

    private let visibility = PluginRuntimeVisibility()
    private let loadingQueue = DispatchQueue(label: "com.switchly.plugin.loading", qos: .userInitiated)
    private let registry: PluginRegistryProtocol
    private let grants: () -> [String: PluginGrant]
    private let mediaBridge: MediaBridging
    private let makeRuntime: ((PluginPackage, Set<PluginCapability>) -> PluginRuntimeProtocol)?
    private let weather: () -> [String: Any]?
    private var captureRequester: WindowCaptureRequesting?
    private let lock = NSLock()
    private var mediaInterests: [UUID: (bundleID: String, lease: MediaReadInterest)] = [:]
    private var failures: [PluginLoadFailure] = []
    private var packages: [PluginPackage]?
    private var engineWarmupTask: Task<Void, Never>?
    private var engineWarmupID: UUID?
    private var pendingEngineWarmupURL: URL?
    /// Keyed by id; the permission set is kept so a grant change rebuilds the VM.
    private var runtimesByID: [String: (permissions: Set<PluginCapability>, runtime: PluginRuntimeProtocol)] = [:]

    init(registry: PluginRegistryProtocol = PluginRegistry(),
         grants: @escaping () -> [String: PluginGrant] = { SettingsService.shared.loadSettings().pluginGrants },
         mediaBridge: MediaBridging,
         weather: @escaping () -> [String: Any]? = { OnlineWeatherService.shared.current()?.jsObject },
         makeRuntime: ((PluginPackage, Set<PluginCapability>) -> PluginRuntimeProtocol)? = nil) {
        self.registry = registry
        self.grants = grants
        self.mediaBridge = mediaBridge
        self.weather = weather
        self.makeRuntime = makeRuntime
    }

    /// App composition installs the capture session before presenting any Dock UI.
    func configureCapture(_ requester: WindowCaptureRequesting) {
        lock.lock()
        captureRequester = requester
        lock.unlock()
        reload()
    }

    func isCaptureAuthorized(pluginID: String) -> Bool {
        installedPlugins().contains {
            $0.id == pluginID && $0.authorization.isEnabled && $0.authorization.permissions.contains(.windowCapture)
        }
    }

    private func createRuntime(_ package: PluginPackage, permissions: Set<PluginCapability>) -> PluginRuntimeProtocol {
        if let makeRuntime { return makeRuntime(package, permissions) }
        return PluginRuntime(package: package, timeout: 1, mediaBridge: mediaBridge, permissions: permissions,
                             libraryBridge: mediaBridge as? MusicLibraryPlaying,
                             fileReader: PluginFileReader(roots: package.manifest.fsRoots ?? []),
                             settings: { SettingsService.shared.loadSettings().pluginSettings[package.manifest.id] ?? [:] },
                             values: { SettingsService.shared.loadSettings().pluginValues[package.manifest.id] ?? [:] },
                             weather: weather, storage: PluginStorage(pluginID: package.manifest.id),
                             captureRequester: captureRequester)
    }

    func installedPlugins() -> [InstalledPlugin] {
        lock.lock()
        defer { lock.unlock() }
        return loadedPackages().map(resolve)
    }

    func loadFailures() -> [PluginLoadFailure] {
        lock.lock()
        defer { lock.unlock() }
        _ = loadedPackages()
        return failures
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
            let runtime = createRuntime(plugin.package, permissions: auth.permissions)
            runtimesByID[plugin.id] = (auth.permissions, runtime)
            result.append(runtime)
        }
        lock.unlock()
        stale.forEach { $0.unmount() }
        pruneMediaInterests()
        return result
    }

    func loadRuntimes(for bundleID: String) async -> [PluginRuntimeProtocol] {
        await withCheckedContinuation { continuation in
            loadingQueue.async { [self] in
                let started = DispatchTime.now().uptimeNanoseconds
                let result = runtimes(for: bundleID)
                AppLogger.performance("PluginDiscovery", since: started)
                continuation.resume(returning: result)
            }
        }
    }

    /// 悬停等待期间只预热第一个获授权匹配插件的空引擎，不执行用户 JS。
    /// 始终只有一个任务和一个可替换的最新目标，避免快速扫过图标积压工作。
    func prewarmEngine(for bundleURL: URL) {
        lock.lock()
        pendingEngineWarmupURL = bundleURL
        guard engineWarmupTask == nil else { lock.unlock(); return }
        let id = UUID()
        engineWarmupID = id
        engineWarmupTask = Task { [weak self] in
            while !Task.isCancelled, let url = self?.takeEngineWarmupURL(id: id) {
                guard let root = WindowAttribution.productRootURL(for: url),
                      let bundleID = Bundle(url: root)?.bundleIdentifier else { continue }
                let runtimes = await self?.loadRuntimes(for: bundleID) ?? []
                guard !Task.isCancelled else { return }
                await runtimes.first?.prewarmEngine()
            }
        }
        lock.unlock()
    }

    private func takeEngineWarmupURL(id: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard engineWarmupID == id else { return nil }
        let url = pendingEngineWarmupURL
        pendingEngineWarmupURL = nil
        if url == nil { engineWarmupTask = nil; engineWarmupID = nil }
        return url
    }

    private func cancelEngineWarmup() {
        lock.lock()
        let task = engineWarmupTask
        engineWarmupTask = nil
        engineWarmupID = nil
        pendingEngineWarmupURL = nil
        lock.unlock()
        task?.cancel()
    }

    func acquireRuntimeVisibility(_ runtimes: [PluginRuntimeProtocol], invalidate: @escaping () -> Void) -> PluginLifetime {
        visibility.acquire(runtimes, invalidate: invalidate)
    }

    private func canReadMedia(_ bundleID: String) -> Bool {
        installedPlugins().contains {
            $0.authorization.isEnabled && $0.authorization.permissions.contains(.mediaNowPlaying)
                && $0.package.manifest.matches(bundleID: bundleID)
        } && mediaBridge.supports(bundleID: bundleID)
    }

    func acquireMediaRead(for bundleID: String, invalidate: @escaping () -> Void) -> MediaReadInterest? {
        guard canReadMedia(bundleID), let provider = mediaBridge as? MediaReadProviding else { return nil }
        let upstream = provider.acquireReadInterest(invalidate: invalidate)
        let id = UUID()
        let lease = MediaReadInterest { [weak self] in
            upstream.cancel()
            guard let self else { return }
            self.lock.lock()
            self.mediaInterests.removeValue(forKey: id)
            self.lock.unlock()
        }
        lock.lock()
        mediaInterests[id] = (bundleID, lease)
        lock.unlock()
        return lease
    }

    private func pruneMediaInterests() {
        lock.lock()
        let active = Array(mediaInterests.values)
        lock.unlock()
        for entry in active where !canReadMedia(entry.bundleID) { entry.lease.cancel() }
    }

    private func releaseMediaInterests() {
        lock.lock()
        let leases = mediaInterests.values.map(\.lease)
        mediaInterests.removeAll()
        lock.unlock()
        leases.forEach { $0.cancel() }
    }

    func mediaRead(for bundleID: String) async -> MediaReadContext? {
        guard canReadMedia(bundleID) else {
            pruneMediaInterests()
            return MediaReadContext(nowPlaying: nil, source: .unavailable, requiresAuthorization: false, artwork: nil,
                                    artworkToken: nil, validate: { true })
        }
        let bridge = mediaBridge
        return await withCheckedContinuation { continuation in
            bridge.queue.async {
                do { continuation.resume(returning: try bridge.frozenRead(bundleID: bundleID)) }
                catch {
                    let reason = (error as? MediaBridgeError).map { String(describing: $0) } ?? "Media read failed"
                    continuation.resume(returning: MediaReadContext(nowPlaying: nil, source: .unavailable, readError: reason, artwork: nil,
                                                                    artworkToken: nil, validate: { true }))
                }
            }
        }
    }

    func mediaReadIsCurrent(_ read: MediaReadContext, bundleID: String) async -> Bool {
        guard !read.requiresAuthorization || canReadMedia(bundleID) else { return false }
        return await withCheckedContinuation { continuation in
            mediaBridge.queue.async { continuation.resume(returning: read.isCurrent()) }
        }
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
        cancelEngineWarmup()
        visibility.reset()
        releaseMediaInterests()
        lock.lock()
        let runtimes = runtimesByID.values.map(\.runtime)
        lock.unlock()
        runtimes.forEach { $0.unmount() }
    }

    func reload() {
        cancelEngineWarmup()
        visibility.reset()
        releaseMediaInterests()
        lock.lock()
        let old = runtimesByID.values.map(\.runtime)
        runtimesByID.removeAll()
        packages = nil
        lock.unlock()
        old.forEach { $0.unmount() }
        DispatchQueue.main.async { [weak self] in self?.captureRequester?.validateAuthorization() }
    }

    deinit { cancelEngineWarmup(); releaseMediaInterests() }

    /// Caller holds `lock`.
    private func loadedPackages() -> [PluginPackage] {
        if packages == nil {
            let snapshot = registry.reload()
            packages = snapshot.plugins
            failures = snapshot.failures
        }
        return packages ?? []
    }

    private func resolve(_ package: PluginPackage) -> InstalledPlugin {
        InstalledPlugin(package: package, authorization: PluginAuthorization.resolve(
            manifest: package.manifest, origin: package.origin, grant: grants()[package.manifest.id]))
    }
}
