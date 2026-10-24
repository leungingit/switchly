//
//  PluginRuntime.swift
//  Switchly
//
//  One JavaScriptCore VM per plugin, confined to a private serial queue
//  (design doc §3.3). The bundle registers itself by assigning
//  `globalThis.__switchlyPlugin = { render, onAction }` — this is what the SDK's
//  definePlugin() emits. Only console, timers and the invoke helper are
//  injected: no fetch, XHR, file or process access exists in the context.
//
//  The timeout is soft: JSC has no public API to interrupt running script, so
//  a late result is discarded and repeated timeouts disable the plugin.
//

import Foundation
import JavaScriptCore

/// Read-only snapshot handed to render/onAction as `ctx`.
struct PluginRenderContext: Equatable {
    let bundleID: String
    let pid: Int32
    let appName: String
    let windowID: UInt32
    /// Already truncated by the caller; full titles never reach plugins.
    let titleSummary: String

    static func summarize(title: String, limit: Int = 40) -> String {
        title.count <= limit ? title : String(title.prefix(limit)) + "…"
    }
}

enum PluginRuntimeError: Error, Equatable {
    case notLoaded
    case disabled
    case timedOut
    case script(String)
    case invalidOutput(String)
}

protocol PluginRuntimeProtocol: AnyObject {
    var manifest: PluginManifest { get }
    var onInvalidate: (() -> Void)? { get set }
    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError>
    func performAction(id: String, value: Double?, context: PluginRenderContext) async -> Result<Void, PluginRuntimeError>
    func unmount()
}

final class PluginRuntime: PluginRuntimeProtocol, @unchecked Sendable {
    let manifest: PluginManifest
    /// Called on the plugin queue; consumers hop to the main actor themselves.
    var onInvalidate: (() -> Void)? {
        get { queue.sync { invalidateHandler } }
        set { queue.sync { invalidateHandler = newValue } }
    }

    private let package: PluginPackage
    private let timeout: TimeInterval
    private let maxConsecutiveTimeouts: Int
    private let preferredLanguages: [String]
    /// Authorized subset of the manifest's permissions (PluginAuthorization).
    let permissions: Set<PluginCapability>
    /// Only kept when a media permission is authorized.
    private let mediaBridge: MediaBridging?
    private let settingsProvider: () -> [String: Bool]
    private let queue: DispatchQueue

    // Everything below is confined to `queue`.
    private var context: JSContext?
    private var invalidateHandler: (() -> Void)?
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimerID = 1
    private var nextCallID = 1
    private var pending: [Int: (Result<String, PluginRuntimeError>) -> Void] = [:]
    private var consecutiveTimeouts = 0
    private var disabled = false
    private var strings: [String: String] = [:]

    private static let maxTimers = 32
    private static let maxLogLength = 500

    init(package: PluginPackage,
         timeout: TimeInterval = 0.2,
         maxConsecutiveTimeouts: Int = 3,
         preferredLanguages: [String] = Locale.preferredLanguages,
         mediaBridge: MediaBridging? = nil,
         permissions: Set<PluginCapability>? = nil,
         settings: @escaping () -> [String: Bool] = { [:] }) {
        self.settingsProvider = settings
        self.package = package
        self.manifest = package.manifest
        self.timeout = timeout
        self.maxConsecutiveTimeouts = maxConsecutiveTimeouts
        self.preferredLanguages = preferredLanguages
        let permissions = permissions.map { $0.intersection(package.manifest.permissions) } ?? Set(package.manifest.permissions)
        self.permissions = permissions
        self.mediaBridge = permissions.isDisjoint(with: [.mediaNowPlaying, .mediaControl]) ? nil : mediaBridge
        self.queue = DispatchQueue(label: "com.switchly.plugin.\(package.manifest.id)")
    }

    deinit {
        // Timers capture self weakly; cancel so nothing fires into a dead VM.
        timers.values.forEach { $0.cancel() }
    }

    var isDisabled: Bool { queue.sync { disabled } }

    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        let result = await invoke("render", context: context, extra: [])
        return result.flatMap { json in
            do {
                return .success(try PluginRenderOutput.decode(json: Data(json.utf8)))
            } catch {
                AppLogger.throttledWarning(key: "plugin.output.\(manifest.id)", "Plugin render output rejected. plugin=\(manifest.id) error=\(error)")
                return .failure(.invalidOutput(String(describing: error)))
            }
        }
    }

    func performAction(id: String, value: Double?, context: PluginRenderContext) async -> Result<Void, PluginRuntimeError> {
        await invoke("onAction", context: context, extra: [id, value as Any? ?? NSNull()]).map { _ in () }
    }

    /// Safe to call repeatedly; the next render re-creates the VM.
    func unmount() {
        queue.sync { tearDown(reason: .notLoaded) }
    }

    // MARK: - Invocation

    private func invoke(_ method: String, context ctx: PluginRenderContext, extra: [Any]) async -> Result<String, PluginRuntimeError> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !disabled else { return continuation.resume(returning: .failure(.disabled)) }
                guard let js = self.context ?? loadContext() else {
                    return continuation.resume(returning: .failure(.notLoaded))
                }
                let callID = nextCallID
                nextCallID += 1
                let started = DispatchTime.now()
                pending[callID] = { [weak self] result in
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    AppLogger.verbose("Plugin call finished. plugin=\(self?.manifest.id ?? "?") phase=\(method) ms=\(String(format: "%.1f", ms))")
                    continuation.resume(returning: result)
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.handleTimeout(callID: callID, method: method)
                }

                let ok: @convention(block) (String) -> Void = { [weak self] json in
                    self?.complete(callID: callID, .success(json))
                }
                let fail: @convention(block) (String) -> Void = { [weak self] message in
                    let pluginID = self?.manifest.id ?? "?"
                    AppLogger.throttledWarning(key: "plugin.error.\(pluginID)",
                                               "Plugin script error. plugin=\(pluginID) phase=\(method) error=\(message.prefix(Self.maxLogLength))")
                    self?.complete(callID: callID, .failure(.script(message)))
                }
                let ctxValue = makeContextValue(ctx, in: js)
                js.objectForKeyedSubscript("__switchlyInvoke")?
                    .call(withArguments: [method, ctxValue as Any, extra, unsafeBitCast(ok, to: AnyObject.self),
                                          unsafeBitCast(fail, to: AnyObject.self)])
            }
        }
    }

    private func complete(callID: Int, _ result: Result<String, PluginRuntimeError>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let handler = pending.removeValue(forKey: callID) else { return }
        if result != .failure(.timedOut) { consecutiveTimeouts = 0 }
        handler(result)
    }

    private func handleTimeout(callID: Int, method: String) {
        guard pending[callID] != nil else { return }
        consecutiveTimeouts += 1
        AppLogger.warning("Plugin call timed out. plugin=\(manifest.id) phase=\(method) consecutive=\(consecutiveTimeouts)")
        complete(callID: callID, .failure(.timedOut))
        if consecutiveTimeouts >= maxConsecutiveTimeouts {
            AppLogger.error("Plugin disabled after repeated timeouts. plugin=\(manifest.id)")
            disabled = true
            tearDown(reason: .disabled)
        }
    }

    private func tearDown(reason: PluginRuntimeError) {
        dispatchPrecondition(condition: .onQueue(queue))
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0(.failure(reason)) }
        context = nil
    }

    // MARK: - Context setup

    private func loadContext() -> JSContext? {
        guard let js = JSContext(virtualMachine: JSVirtualMachine()) else { return nil }
        let pluginID = manifest.id
        js.name = "Switchly plugin \(pluginID)"
        js.exceptionHandler = { _, exception in
            AppLogger.throttledWarning(key: "plugin.exception.\(pluginID)", "Plugin exception. plugin=\(pluginID) error=\(exception?.toString().prefix(Self.maxLogLength) ?? "?")")
        }
        installConsole(in: js)
        installTimers(in: js)
        installMedia(in: js)
        js.evaluateScript(Self.invokeHelper)
        strings = loadStrings()

        js.evaluateScript(package.source, withSourceURL: package.directory.appendingPathComponent(manifest.entry))
        if js.exception != nil || js.objectForKeyedSubscript("__switchlyPlugin")?.isObject != true {
            AppLogger.warning("Plugin did not register. plugin=\(pluginID)")
            timers.values.forEach { $0.cancel() }
            timers.removeAll()
            return nil
        }
        context = js
        AppLogger.info("Plugin mounted. plugin=\(pluginID) version=\(manifest.version)")
        return js
    }

    /// Normalizes sync / async / throwing plugin functions into ok(json) / fail(message).
    private static let invokeHelper = """
    globalThis.__switchlyInvoke = function (method, ctx, extra, ok, rawFail) {
      // JSC's e.stack holds frames only, so keep the message in front.
      const fail = function (e) { rawFail(String(e) + (e && e.stack ? "\\n" + e.stack : "")); };
      try {
        const plugin = globalThis.__switchlyPlugin;
        const fn = plugin && plugin[method];
        if (typeof fn !== "function") { ok("null"); return; }
        Promise.resolve(fn.apply(plugin, [ctx].concat(extra))).then(
          function (v) { ok(JSON.stringify(v === undefined ? null : v)); },
          fail);
      } catch (e) { fail(e); }
    };
    """

    private func installConsole(in js: JSContext) {
        let pluginID = manifest.id
        let log: @convention(block) (String, String) -> Void = { level, message in
            let line = "Plugin log. plugin=\(pluginID) message=\(message.prefix(Self.maxLogLength))"
            if level == "error" {
                AppLogger.throttledError(key: "plugin.console.\(pluginID)", line)
            } else if level == "warn" {
                AppLogger.throttledWarning(key: "plugin.console.\(pluginID)", line)
            } else {
                AppLogger.debug(line)
            }
        }
        js.setObject(log, forKeyedSubscript: "__switchlyLog" as NSString)
        js.evaluateScript("""
        globalThis.console = ["log", "info", "debug", "warn", "error"].reduce(function (c, level) {
          c[level] = function () { __switchlyLog(level, Array.prototype.map.call(arguments, String).join(" ")); };
          return c;
        }, {});
        """)
    }

    private func installTimers(in js: JSContext) {
        let set: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, ms in
            guard let self, self.timers.count < Self.maxTimers else { return 0 }
            let id = self.nextTimerID
            self.nextTimerID += 1
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                callback.call(withArguments: [])
            }
            self.timers[id] = item
            self.queue.asyncAfter(deadline: .now() + max(0, ms.isFinite ? ms : 0) / 1000, execute: item)
            return id
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.cancel()
        }
        js.setObject(set, forKeyedSubscript: "setTimeout" as NSString)
        js.setObject(clear, forKeyedSubscript: "clearTimeout" as NSString)
    }

    /// ctx.media exposes only the methods the manifest's permissions cover;
    /// undeclared ones do not exist on the object.
    private func installMedia(in js: JSContext) {
        guard let bridge = mediaBridge else { return }
        let canRead = permissions.contains(.mediaNowPlaying)
        let canControl = permissions.contains(.mediaControl)
        let call: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self, weak js] method, bundleID, resolve, reject in
            guard let self else { return }
            let command = MediaCommand(rawValue: method)
            guard (method == "nowPlaying" && canRead) || (command != nil && canControl) else {
                reject.call(withArguments: ["Permission denied: \(method)"])
                return
            }
            bridge.queue.async {
                let outcome: Result<Any, Error> = Result {
                    if let command {
                        try bridge.perform(command, bundleID: bundleID)
                        return NSNull()
                    }
                    return try bridge.nowPlaying(bundleID: bundleID)?.jsObject ?? NSNull()
                }
                self.queue.async {
                    // Drop results for a VM that was unmounted meanwhile.
                    guard let js, self.context === js else { return }
                    switch outcome {
                    case .success(let value): resolve.call(withArguments: [value])
                    case .failure(let error): reject.call(withArguments: [String(describing: error)])
                    }
                }
            }
        }
        js.setObject(call, forKeyedSubscript: "__switchlyMediaCall" as NSString)
        var methods: [String] = []
        if canRead { methods.append("nowPlaying") }
        if canControl { methods += ["togglePlayPause", "next", "previous"] }
        let list = methods.map { "\"\($0)\"" }.joined(separator: ",")
        js.evaluateScript("""
        globalThis.__switchlyMakeMedia = function (bundleID) {
          const call = function (m) { return function () { return new Promise(function (res, rej) { __switchlyMediaCall(m, bundleID, res, rej); }); }; };
          const media = {};
          [\(list)].forEach(function (m) { media[m] = call(m); });
          \(canControl ? "media.setLiked = function (on) { return call(on ? \"like\" : \"unlike\")(); };" : "")
          return Object.freeze(media);
        };
        """)
    }

    private func makeContextValue(_ ctx: PluginRenderContext, in js: JSContext) -> JSValue? {
        // Manifest defaults, overridden by the user's saved values.
        var settingValues = Dictionary(uniqueKeysWithValues: (manifest.settings ?? []).map { ($0.key, $0.default) })
        settingValues.merge(settingsProvider().filter { settingValues[$0.key] != nil }) { $1 }
        let value = JSValue(object: [
            "app": ["bundleID": ctx.bundleID, "pid": ctx.pid, "name": ctx.appName],
            "window": ["windowID": ctx.windowID, "title": ctx.titleSummary],
            "locale": preferredLanguages.first ?? "en",
            "settings": settingValues,
        ] as [String: Any], in: js)
        let strings = self.strings
        let t: @convention(block) (String) -> String = { key in strings[key] ?? key }
        let invalidate: @convention(block) () -> Void = { [weak self] in self?.invalidateHandler?() }
        value?.setObject(t, forKeyedSubscript: "t" as NSString)
        value?.setObject(invalidate, forKeyedSubscript: "invalidate" as NSString)
        if let makeMedia = js.objectForKeyedSubscript("__switchlyMakeMedia"), !makeMedia.isUndefined {
            value?.setObject(makeMedia.call(withArguments: [ctx.bundleID]), forKeyedSubscript: "media" as NSString)
        }
        return value
    }

    /// locales/<lang>.json, falling back to en.
    private func loadStrings() -> [String: String] {
        let localesDir = package.directory.appendingPathComponent("locales", isDirectory: true)
        let candidates = preferredLanguages.flatMap { lang -> [String] in
            lang.hasPrefix("zh-Hans") || lang.hasPrefix("zh-CN") ? ["zh-Hans"] : [lang, String(lang.prefix(2))]
        } + ["en"]
        for name in candidates {
            let url = localesDir.appendingPathComponent("\(name).json")
            if let data = try? Data(contentsOf: url),
               let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                return dict
            }
        }
        return [:]
    }
}
