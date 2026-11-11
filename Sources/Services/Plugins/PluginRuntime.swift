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

import AppKit
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
    /// Seconds since 1970 when the app was last frontmost; nil while unknown.
    var lastActiveAt: TimeInterval? = nil

    static func summarize(title: String, limit: Int = 40) -> String {
        title.count <= limit ? title : String(title.prefix(limit)) + "…"
    }
}

enum PluginRuntimeError: Error, Equatable {
    case notLoaded
    case suspended
    case disabled
    case timedOut
    case script(String)
    case invalidOutput(String)
}

/// Implemented by the host's per-plugin JSON store. Calls stay on the plugin's
/// serial queue so disk I/O cannot enter the main thread.
protocol PluginStorageProviding: AnyObject {
    func get(_ key: String) throws -> Any?
    func set(_ key: String, value: Any) throws
    func remove(_ key: String) throws
    func clear() throws
}

extension PluginStorage: PluginStorageProviding {}

protocol PluginRuntimeProtocol: AnyObject {
    var manifest: PluginManifest { get }
    var onInvalidate: (() -> Void)? { get set }
    /// The plugin's own directory, for assets named by `scene` sprites.
    var assetDirectory: URL? { get }
    func prewarmEngine() async
    func prepare(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError>
    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError>
    func render(context: PluginRenderContext, mediaRead: MediaReadContext?) async -> Result<[PluginSlotContent], PluginRuntimeError>
    func performAction(id: String, value: Double?, context: PluginRenderContext) async -> Result<Void, PluginRuntimeError>
    func suspend()
    func resume()
    func unmount()
}

extension PluginRuntimeProtocol {
    func prewarmEngine() async {}
    var assetDirectory: URL? { nil }
    func prepare(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> { .success([]) }
    func render(context: PluginRenderContext, mediaRead: MediaReadContext?) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        await render(context: context)
    }
    func suspend() {}
    func resume() {}
}

final class PluginRuntime: PluginRuntimeProtocol, @unchecked Sendable {
    let manifest: PluginManifest
    var assetDirectory: URL? { package.directory }
    /// Called on the plugin queue; consumers hop to the main actor themselves.
    /// This side-channel is lock-protected so changing it never waits behind a
    /// long-running plugin script on the serial queue.
    var onInvalidate: (() -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return invalidateHandler
        }
        set {
            stateLock.lock()
            invalidateHandler = newValue
            stateLock.unlock()
        }
    }

    private struct ControlledTimer {
        let callback: JSValue
        var remaining: TimeInterval
        var scheduleID = 0
        var startedAt: UInt64?
        var workItem: DispatchWorkItem?
    }

    private let package: PluginPackage
    private let timeout: TimeInterval
    private let maxConsecutiveTimeouts: Int
    private let preferredLanguages: [String]
    private let uiFeatures: [String: Bool]
    /// Authorized subset of the manifest's permissions (PluginAuthorization).
    let permissions: Set<PluginCapability>
    /// Only kept when a media permission is authorized.
    private let mediaBridge: MediaBridging?
    /// Only kept when `media.library` is authorized.
    private let libraryBridge: MusicLibraryPlaying?
    /// Only kept when `fs.read` is authorized.
    private let fileReader: PluginFileReading?
    private let settingsProvider: () -> [String: Bool]
    /// Host-held weather snapshot for `ctx.weather.current()`; nil when the
    /// permission is not granted. Never triggers a request from JS.
    private let weatherProvider: (() -> [String: Any]?)?
    private let storage: PluginStorageProviding?
    private let valuesProvider: () -> [String: PluginSettingValue]
    private let reduceMotion: () -> Bool
    /// 非 nil 时 JS 的 Date / Math.random / setTimeout 由虚拟时钟接管（仅预览使用）。
    private let virtualClock: PluginVirtualClock?
    private let queue: DispatchQueue
    private let stateLock = NSLock()

    // Everything below is confined to `queue`.
    private var context: JSContext?
    private var prewarmedContext: JSContext?
    /// stateLock 保护代际；Context 本身仍只在插件串行队列访问。
    private var engineGeneration = 0
    private var invalidateHandler: (() -> Void)?
    private var timers: [Int: ControlledTimer] = [:]
    private var callTimeouts: [Int: DispatchWorkItem] = [:]
    private var nextTimerID = 1
    private var nextTimerScheduleID = 1
    private var nextCallID = 1
    private var pending: [Int: (Result<String, PluginRuntimeError>) -> Void] = [:]
    private var consecutiveTimeouts = 0
    /// Host bridge calls (Apple Events to Music) still running for this VM.
    /// A call that times out while one is pending waited on the host, not on
    /// the plugin's own script, so it does not count toward disabling.
    private var hostCallsInFlight = 0
    private var disabled = false
    private var suspended = false
    private var strings: [String: String] = [:]

    private static let maxTimers = 32
    private static let maxLogLength = 500
    private static let maxBufferedConsoleLines = 200
    private let consoleLock = NSLock()
    private var consoleBuffer: [PluginConsoleLine] = []

    /// Returns and clears the console lines buffered since the last call (newest 200 at most).
    func drainConsole() -> [PluginConsoleLine] {
        consoleLock.lock()
        defer { consoleLock.unlock() }
        let lines = consoleBuffer
        consoleBuffer = []
        return lines
    }

    private func bufferConsole(level: String, message: String) {
        consoleLock.lock()
        consoleBuffer.append(PluginConsoleLine(level: level, message: String(message.prefix(Self.maxLogLength)),
                                               time: Date().timeIntervalSince1970))
        if consoleBuffer.count > Self.maxBufferedConsoleLines { consoleBuffer.removeFirst(consoleBuffer.count - Self.maxBufferedConsoleLines) }
        consoleLock.unlock()
    }

    init(package: PluginPackage,
         timeout: TimeInterval = 0.2,
         maxConsecutiveTimeouts: Int = 3,
         preferredLanguages: [String] = Locale.preferredLanguages,
         mediaBridge: MediaBridging? = nil,
         permissions: Set<PluginCapability>? = nil,
         libraryBridge: MusicLibraryPlaying? = nil,
         fileReader: PluginFileReading? = nil,
         settings: @escaping () -> [String: Bool] = { [:] },
         values: @escaping () -> [String: PluginSettingValue] = { [:] },
         weather: (() -> [String: Any]?)? = nil,
         storage: PluginStorageProviding? = nil,
         virtualClock: PluginVirtualClock? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         uiFeatures: [String: Bool] = ["scene3d": true]) {
        self.uiFeatures = uiFeatures
        self.virtualClock = virtualClock
        self.reduceMotion = reduceMotion
        self.settingsProvider = settings
        self.valuesProvider = values
        self.package = package
        self.manifest = package.manifest
        self.timeout = timeout
        self.maxConsecutiveTimeouts = maxConsecutiveTimeouts
        self.preferredLanguages = preferredLanguages
        let permissions = permissions.map { $0.intersection(package.manifest.permissions) } ?? Set(package.manifest.permissions)
        self.permissions = permissions
        self.mediaBridge = permissions.isDisjoint(with: [.mediaNowPlaying, .mediaControl]) ? nil : mediaBridge
        self.libraryBridge = permissions.contains(.mediaLibrary) ? libraryBridge : nil
        self.fileReader = permissions.contains(.fsRead) ? fileReader : nil
        self.weatherProvider = permissions.contains(.weatherCurrent) ? weather : nil
        self.storage = storage
        self.queue = DispatchQueue(label: "com.switchly.plugin.\(package.manifest.id)")
    }

    deinit {
        timers.values.forEach { $0.workItem?.cancel() }
        callTimeouts.values.forEach { $0.cancel() }
    }

    var isDisabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return disabled
    }

    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        await renderValidated(context: context).map(\.slots)
    }

    func render(context: PluginRenderContext, mediaRead: MediaReadContext?) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        await renderValidated(context: context, mediaRead: mediaRead).map(\.slots)
    }

    func prepare(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        await renderValidated(context: context, method: "prepare").map(\.slots)
    }

    /// 只创建空引擎；插件源码、桥接函数、Timer 和媒体读取仍留到正式可见调用。
    func prewarmEngine() async {
        guard !Task.isCancelled else { return }
        let generation = currentEngineGeneration()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }
                stateLock.lock()
                let current = engineGeneration == generation && !disabled
                stateLock.unlock()
                guard current, context == nil, prewarmedContext == nil else { return }
                let started = DispatchTime.now().uptimeNanoseconds
                prewarmedContext = JSContext(virtualMachine: JSVirtualMachine())
                AppLogger.performance("PluginEngineWarm", since: started)
            }
        }
    }

    private func currentEngineGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return engineGeneration
    }

    /// The worker forwards the original JSON after the same strict host decode.
    /// Re-encoding decoded UI values would lose unknown fields and create a second
    /// render representation.
    func renderJSON(context: PluginRenderContext) async -> Result<String, PluginRuntimeError> {
        // Worker 只持有 fixture 桥。每次 render 冻结一次元数据；动作仍走实时桥。
        var read: MediaReadContext?
        if permissions.contains(.mediaNowPlaying), let bridge = mediaBridge {
            let sampled: Result<NowPlaying?, Error> = await withCheckedContinuation { continuation in
                bridge.queue.async {
                    continuation.resume(returning: Result { try bridge.nowPlaying(bundleID: context.bundleID) })
                }
            }
            switch sampled {
            case .success(let playing):
                read = MediaReadContext(nowPlaying: playing, source: .fixture, artwork: nil, artworkToken: nil, validate: { true })
            case .failure(let error):
                read = MediaReadContext(nowPlaying: nil, readError: String(describing: error), artwork: nil,
                                        artworkToken: nil, validate: { true })
            }
        }
        return await renderValidated(context: context, mediaRead: read).map(\.json)
    }

    func performAction(id: String, value: Double?, context: PluginRenderContext) async -> Result<Void, PluginRuntimeError> {
        await invoke("onAction", context: context, extra: [id, value as Any? ?? NSNull()]).map { _ in () }
    }

    /// Pauses JS timers and releases host waiters without discarding the JS VM.
    /// A JS Promise may remain unresolved inside the preserved VM, but its host
    /// continuation is completed and late callbacks are ignored.
    func suspend() {
        queue.async { [weak self] in
            guard let self else { return }
            self.suspended = true
            self.pauseTimers()
            self.failPendingCalls(reason: .suspended)
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, self.suspended else { return }
            self.suspended = false
            Array(self.timers.keys).forEach(self.scheduleTimer)
        }
    }

    /// Safe to call repeatedly; the next render re-creates the VM.
    func unmount() {
        queue.async { [weak self] in
            self?.tearDown(reason: .notLoaded)
        }
    }

    // MARK: - Invocation

    private func renderValidated(context: PluginRenderContext, mediaRead: MediaReadContext? = nil, method: String = "render") async -> Result<(json: String, slots: [PluginSlotContent]), PluginRuntimeError> {
        let result = await invoke(method, context: context, extra: [], mediaRead: mediaRead)
        return result.flatMap { json in
            do {
                let slots = try PluginRenderOutput.decode(json: Data(json.utf8))
                return .success((json, slots))
            } catch {
                AppLogger.throttledWarning(key: "plugin.output.\(manifest.id)", "Plugin render output rejected. plugin=\(manifest.id) error=\(error)")
                return .failure(.invalidOutput(String(describing: error)))
            }
        }
    }

    private func invoke(_ method: String, context ctx: PluginRenderContext, extra: [Any], mediaRead: MediaReadContext? = nil) async -> Result<String, PluginRuntimeError> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isDisabled else { return continuation.resume(returning: .failure(.disabled)) }
                guard !suspended else { return continuation.resume(returning: .failure(.suspended)) }
                guard let js = self.context ?? loadContext() else {
                    return continuation.resume(returning: .failure(.notLoaded))
                }
                fileReader?.resetCalls()
                let callID = nextCallID
                nextCallID += 1
                let started = DispatchTime.now()
                pending[callID] = { [weak self] result in
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    AppLogger.verbose("Plugin call finished. plugin=\(self?.manifest.id ?? "?") phase=\(method) ms=\(String(format: "%.1f", ms))")
                    continuation.resume(returning: result)
                }
                let timeoutItem = DispatchWorkItem { [weak self] in
                    self?.handleTimeout(callID: callID, method: method)
                }
                callTimeouts[callID] = timeoutItem
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                let ok: @convention(block) (String) -> Void = { [weak self] json in
                    self?.complete(callID: callID, .success(json))
                }
                let fail: @convention(block) (String) -> Void = { [weak self] message in
                    let pluginID = self?.manifest.id ?? "?"
                    AppLogger.throttledWarning(key: "plugin.error.\(pluginID)",
                                               "Plugin script error. plugin=\(pluginID) phase=\(method) error=\(message.prefix(Self.maxLogLength))")
                    self?.complete(callID: callID, .failure(.script(message)))
                }
                let ctxValue = makeContextValue(ctx, in: js, mediaRead: mediaRead)
                if method == "prepare" {
                    for key in ["media", "weather", "fs", "storage", "invalidate", "capabilities"] {
                        ctxValue?.deleteProperty(key)
                    }
                }
                js.objectForKeyedSubscript("__switchlyInvoke")?
                    .call(withArguments: [method, ctxValue as Any, extra, unsafeBitCast(ok, to: AnyObject.self),
                                          unsafeBitCast(fail, to: AnyObject.self)])
            }
        }
    }

    private func complete(callID: Int, _ result: Result<String, PluginRuntimeError>) {
        dispatchPrecondition(condition: .onQueue(queue))
        callTimeouts.removeValue(forKey: callID)?.cancel()
        guard let handler = pending.removeValue(forKey: callID) else { return }
        if result != .failure(.timedOut) { consecutiveTimeouts = 0 }
        handler(result)
    }

    private func handleTimeout(callID: Int, method: String) {
        guard pending[callID] != nil else { return }
        callTimeouts.removeValue(forKey: callID)?.cancel()
        if hostCallsInFlight > 0 {
            // Rapid skips queue Apple Events behind each other; the plugin is
            // waiting on Music, so fail this call without counting it.
            AppLogger.warning("Plugin call timed out waiting on host. plugin=\(manifest.id) phase=\(method) hostCalls=\(hostCallsInFlight)")
            complete(callID: callID, .failure(.timedOut))
            return
        }
        consecutiveTimeouts += 1
        AppLogger.warning("Plugin call timed out. plugin=\(manifest.id) phase=\(method) consecutive=\(consecutiveTimeouts)")
        let shouldDisable = consecutiveTimeouts >= maxConsecutiveTimeouts
        if shouldDisable {
            stateLock.lock()
            disabled = true
            stateLock.unlock()
        }
        // 先发布停用状态，再恢复等待方，避免第三次超时返回后读到旧状态。
        complete(callID: callID, .failure(.timedOut))
        if shouldDisable {
            AppLogger.error("Plugin disabled after repeated timeouts. plugin=\(manifest.id)")
            tearDown(reason: .disabled)
        }
    }

    private func tearDown(reason: PluginRuntimeError) {
        stateLock.lock()
        engineGeneration += 1
        stateLock.unlock()
        prewarmedContext = nil
        dispatchPrecondition(condition: .onQueue(queue))
        timers.values.forEach { $0.workItem?.cancel() }
        timers.removeAll()
        failPendingCalls(reason: reason)
        context = nil
        suspended = false
    }

    private func failPendingCalls(reason: PluginRuntimeError) {
        dispatchPrecondition(condition: .onQueue(queue))
        callTimeouts.values.forEach { $0.cancel() }
        callTimeouts.removeAll()
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0(.failure(reason)) }
    }

    // MARK: - Context setup

    private func loadContext() -> JSContext? {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { AppLogger.performance("PluginVM", since: started) }
        let candidate = prewarmedContext ?? JSContext(virtualMachine: JSVirtualMachine())
        prewarmedContext = nil
        guard let js = candidate else { return nil }
        let pluginID = manifest.id
        js.name = "Switchly plugin \(pluginID)"
        js.exceptionHandler = { _, exception in
            AppLogger.throttledWarning(key: "plugin.exception.\(pluginID)", "Plugin exception. plugin=\(pluginID) error=\(exception?.toString().prefix(Self.maxLogLength) ?? "?")")
        }
        installConsole(in: js)
        installTimers(in: js)
        installMedia(in: js)
        installLibrary(in: js)
        installFS(in: js)
        installStorage(in: js)
        js.evaluateScript(Self.invokeHelper)
        strings = loadStrings()

        js.evaluateScript(package.source, withSourceURL: package.directory.appendingPathComponent(manifest.entry))
        if js.exception != nil || js.objectForKeyedSubscript("__switchlyPlugin")?.isObject != true {
            AppLogger.warning("Plugin did not register. plugin=\(pluginID)")
            timers.values.forEach { $0.workItem?.cancel() }
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
        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.bufferConsole(level: level, message: message)
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
        if let clock = virtualClock {
            installVirtualTime(in: js, clock: clock)
            return
        }
        let set: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, ms in
            guard let self, self.timers.count < Self.maxTimers else { return 0 }
            let id = self.nextTimerID
            self.nextTimerID += 1
            let delay = max(0, ms.isFinite ? ms : 0) / 1000
            self.timers[id] = ControlledTimer(callback: callback, remaining: delay)
            self.scheduleTimer(id)
            return id
        }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.workItem?.cancel()
        }
        js.setObject(set, forKeyedSubscript: "setTimeout" as NSString)
        js.setObject(clear, forKeyedSubscript: "clearTimeout" as NSString)
    }

    /// 虚拟时间：定时器只在 `advanceVirtualTime` 时触发；`suspend` 期间推进不触发回调。
    private func installVirtualTime(in js: JSContext, clock: PluginVirtualClock) {
        let set: @convention(block) (JSValue, Double) -> Int = { callback, ms in
            clock.schedule(afterMilliseconds: ms) { callback.call(withArguments: []) }
        }
        let clear: @convention(block) (Int) -> Void = { clock.cancel($0) }
        let now: @convention(block) () -> Double = { clock.nowMilliseconds }
        let random: @convention(block) () -> Double = { clock.nextRandom() }
        js.setObject(set, forKeyedSubscript: "setTimeout" as NSString)
        js.setObject(clear, forKeyedSubscript: "clearTimeout" as NSString)
        js.setObject(now, forKeyedSubscript: "__virtualNow" as NSString)
        js.setObject(random, forKeyedSubscript: "__virtualRandom" as NSString)
        js.evaluateScript("""
        (function () {
          var now = __virtualNow, random = __virtualRandom;
          var Native = Date;
          class VirtualDate extends Native {
            constructor(...args) { if (args.length === 0) super(now()); else super(...args); }
            static now() { return now(); }
          }
          Date = VirtualDate;
          Math.random = function () { return random(); };
          __virtualNow = undefined; __virtualRandom = undefined;
        })();
        """)
    }

    /// 推进虚拟时间并触发到期定时器；`suspend` 期间时间不推进。返回触发数，超限返回 nil。
    func advanceVirtualTime(byMilliseconds delta: Double) async -> Int? {
        guard let clock = virtualClock else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.suspended else { continuation.resume(returning: 0); return }
                continuation.resume(returning: clock.advance(byMilliseconds: delta))
            }
        }
    }

    private func scheduleTimer(_ id: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !suspended, var timer = timers[id] else { return }
        let scheduleID = nextTimerScheduleID
        nextTimerScheduleID += 1
        timer.scheduleID = scheduleID
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.suspended,
                  self.timers[id]?.scheduleID == scheduleID,
                  self.timers.removeValue(forKey: id) != nil else { return }
            timer.callback.call(withArguments: [])
        }
        timer.startedAt = DispatchTime.now().uptimeNanoseconds
        timer.workItem = item
        timers[id] = timer
        queue.asyncAfter(deadline: .now() + timer.remaining, execute: item)
    }

    private func pauseTimers() {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = DispatchTime.now().uptimeNanoseconds
        for id in Array(timers.keys) {
            guard var timer = timers[id] else { continue }
            timer.workItem?.cancel()
            if let startedAt = timer.startedAt {
                let elapsed = Double(now - startedAt) / 1_000_000_000
                timer.remaining = max(0, timer.remaining - elapsed)
            }
            timer.startedAt = nil
            timer.workItem = nil
            timers[id] = timer
        }
    }

    /// ctx.media exposes only the methods the manifest's permissions cover;
    /// undeclared ones do not exist on the object.
    /// ctx.media.library: pick, play and pause tracks. The bridge builds the
    /// AppleScript itself; the plugin only supplies genre keywords and a track id.
    private func installLibrary(in js: JSContext) {
        guard let bridge = libraryBridge else { return }
        let call: @convention(block) (String, JSValue, JSValue, JSValue) -> Void = { [weak self, weak js] method, argument, resolve, reject in
            guard let self else { return }
            let text = argument.isString ? argument.toString() ?? "" : ""
            let words = (argument.toArray() as? [String]) ?? []
            self.hostCallsInFlight += 1
            bridge.queue.async {
                let outcome: Result<Any, Error> = Result {
                    switch method {
                    case "pickRandom": return try bridge.pickRandomTrack(genreKeywords: Array(words.prefix(16)))?.jsObject ?? NSNull()
                    case "play": try bridge.play(persistentID: text); return NSNull()
                    case "pause": try bridge.pausePlayback(); return NSNull()
                    default: throw MediaBridgeError.unsupportedApp
                    }
                }
                self.queue.async {
                    self.hostCallsInFlight -= 1
                    guard let js, self.context === js else { return }
                    switch outcome {
                    case .success(let value): resolve.call(withArguments: [value])
                    case .failure(let error): reject.call(withArguments: [String(describing: error)])
                    }
                }
            }
        }
        js.setObject(call, forKeyedSubscript: "__switchlyLibraryCall" as NSString)
        js.evaluateScript("""
        globalThis.__switchlyLibrary = Object.freeze({
          pickRandom: function (keywords) { return new Promise(function (res, rej) { __switchlyLibraryCall("pickRandom", keywords || [], res, rej); }); },
          play: function (id) { return new Promise(function (res, rej) { __switchlyLibraryCall("play", String(id), res, rej); }); },
          pause: function () { return new Promise(function (res, rej) { __switchlyLibraryCall("pause", null, res, rej); }); },
        });
        """)
    }

    /// ctx.fs: read-only list / stat / readText inside the manifest's folders. The reader
    /// resolves paths and enforces the quotas; only a root id and a relative path come from JS.
    private func installFS(in js: JSContext) {
        guard let reader = fileReader else { return }
        let pluginID = manifest.id
        let call: @convention(block) (String, String, String, JSValue, JSValue, JSValue) -> Void = { [weak self, weak js] op, root, path, option, resolve, reject in
            guard let self else { return }
            let maxBytes = option.isNumber ? Int(option.toInt32()) : nil
            let scanOptions = option.isObject ? option.toDictionary() as? [String: Any] : nil
            DispatchQueue.global(qos: .utility).async {
                let outcome: Result<Any, PluginFSError> = Result {
                    switch op {
                    case "list": return try reader.list(root: root, path: path).map(\.jsObject)
                    case "stat": return try reader.stat(root: root, path: path).jsObject
                    case "readText": return try reader.readText(root: root, path: path, maxBytes: maxBytes)
                    case "isLocked": return try reader.isLocked(root: root, path: path)
                    case "scan":
                        return try reader.scan(root: root, path: path, depth: (scanOptions?["depth"] as? Int) ?? 1,
                                               suffix: scanOptions?["suffix"] as? String,
                                               modifiedWithin: scanOptions?["modifiedWithin"] as? Double).map(\.jsObject)
                    default: throw PluginFSError.denied
                    }
                }.mapError { $0 as? PluginFSError ?? .denied }
                if case .failure(let error) = outcome {
                    AppLogger.debug("Plugin fs. plugin=\(pluginID) root=\(root) op=\(op) result=\(error)")
                }
                self.queue.async {
                    guard let js, self.context === js else { return }
                    switch outcome {
                    case .success(let value): resolve.call(withArguments: [value])
                    case .failure(let error): reject.call(withArguments: ["\(error)"])
                    }
                }
            }
        }
        js.setObject(call, forKeyedSubscript: "__switchlyFSCall" as NSString)
        js.evaluateScript("""
        globalThis.__switchlyFS = Object.freeze({
          list: function (root, path) { return new Promise(function (res, rej) { __switchlyFSCall("list", String(root), String(path || ""), null, res, rej); }); },
          stat: function (root, path) { return new Promise(function (res, rej) { __switchlyFSCall("stat", String(root), String(path || ""), null, res, rej); }); },
          isLocked: function (root, path) { return new Promise(function (res, rej) { __switchlyFSCall("isLocked", String(root), String(path || ""), null, res, rej); }); },
          scan: function (root, path, opts) { return new Promise(function (res, rej) { __switchlyFSCall("scan", String(root), String(path || ""), opts || {}, res, rej); }); },
          readText: function (root, path, opts) { return new Promise(function (res, rej) { __switchlyFSCall("readText", String(root), String(path || ""), opts && opts.maxBytes, res, rej); }); },
        });
        """)
    }

    private func installStorage(in js: JSContext) {
        guard storage != nil else { return }
        let call: @convention(block) (String, String, JSValue, JSValue, JSValue) -> Void = {
            [weak self] method, key, value, resolve, reject in
            guard let self, let storage = self.storage else { return }
            do {
                switch method {
                case "get":
                    resolve.call(withArguments: [try storage.get(key) ?? NSNull()])
                case "set":
                    try storage.set(key, value: value.toObject() ?? NSNull())
                    resolve.call(withArguments: [NSNull()])
                case "remove":
                    try storage.remove(key)
                    resolve.call(withArguments: [NSNull()])
                case "clear":
                    try storage.clear()
                    resolve.call(withArguments: [NSNull()])
                default:
                    throw PluginRuntimeError.script("Unsupported storage operation")
                }
            } catch {
                reject.call(withArguments: [String(describing: error)])
            }
        }
        js.setObject(call, forKeyedSubscript: "__switchlyStorageCall" as NSString)
        js.evaluateScript("""
        globalThis.__switchlyStorage = Object.freeze({
          get: function (key) {
            return new Promise(function (res, rej) { __switchlyStorageCall("get", String(key), null, res, rej); });
          },
          set: function (key, value) {
            return new Promise(function (res, rej) { __switchlyStorageCall("set", String(key), value, res, rej); });
          },
          remove: function (key) {
            return new Promise(function (res, rej) { __switchlyStorageCall("remove", String(key), null, res, rej); });
          },
          clear: function () {
            return new Promise(function (res, rej) { __switchlyStorageCall("clear", "", null, res, rej); });
          },
        });
        """)
    }

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
            self.hostCallsInFlight += 1
            bridge.queue.async {
                let outcome: Result<Any, Error> = Result {
                    if let command {
                        try bridge.perform(command, bundleID: bundleID)
                        return NSNull()
                    }
                    return try bridge.nowPlaying(bundleID: bundleID)?.jsObject ?? NSNull()
                }
                self.queue.async {
                    self.hostCallsInFlight -= 1
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
        globalThis.__switchlyMakeMedia = function (bundleID, pinned, snapshot, readError) {
          const call = function (m) { return function () { return new Promise(function (res, rej) { __switchlyMediaCall(m, bundleID, res, rej); }); }; };
          const media = {};
          [\(list)].forEach(function (m) { media[m] = call(m); });
          \(canControl ? "media.setLiked = function (on) { return call(on ? \"like\" : \"unlike\")(); };" : "")
          if (pinned && typeof media.nowPlaying === "function") {
            media.nowPlaying = function () { if (readError) return Promise.reject(new Error(readError)); return Promise.resolve(snapshot === null ? null : Object.freeze(Object.assign({}, snapshot))); };
          }
          if (globalThis.__switchlyLibrary) media.library = globalThis.__switchlyLibrary;
          return Object.freeze(media);
        };
        """)
    }

    private func makeContextValue(_ ctx: PluginRenderContext, in js: JSContext, mediaRead: MediaReadContext? = nil) -> JSValue? {
        // Manifest defaults, overridden by the user's saved values.
        var settingValues = Dictionary(uniqueKeysWithValues: (manifest.settings ?? []).map { ($0.key, $0.defaultValue.jsValue) })
        for (key, flag) in settingsProvider() where settingValues[key] != nil { settingValues[key] = flag }
        for (key, saved) in valuesProvider() {
            // Saved select / number values only count for options the manifest declares.
            guard let spec = manifest.settings?.first(where: { $0.key == key }), spec.kind != .toggle else { continue }
            switch (spec.kind, saved) {
            case (.select, .string(let selected)) where spec.options.contains(where: { $0.value == selected }):
                settingValues[key] = selected
            case (.number, .number(let number)) where number.isFinite:
                settingValues[key] = min(max(number, spec.min ?? -Double.greatestFiniteMagnitude), spec.max ?? Double.greatestFiniteMagnitude)
            default: break
            }
        }
        let value = JSValue(object: [
            "app": ["bundleID": ctx.bundleID, "pid": ctx.pid, "name": ctx.appName,
                    // When the app was last in front (now, if it is); null if Switchly has not seen it yet.
                    "lastActiveAt": ctx.lastActiveAt.map { $0 as Any } ?? NSNull()],
            "window": ["windowID": ctx.windowID, "title": ctx.titleSummary],
            "locale": preferredLanguages.first ?? "en",
            "settings": settingValues,
            "capabilities": capabilitySnapshot(bundleID: ctx.bundleID),
            "reduceMotion": reduceMotion(),
            "uiFeatures": uiFeatures,
        ] as [String: Any], in: js)
        let strings = self.strings
        let t: @convention(block) (String) -> String = { key in strings[key] ?? key }
        let invalidate: @convention(block) () -> Void = { [weak self] in self?.onInvalidate?() }
        let currentWeather: @convention(block) () -> Any? = { [weak self] in self?.weatherProvider?() ?? NSNull() }
        let weather = JSValue(newObjectIn: js)
        weather?.setObject(currentWeather, forKeyedSubscript: "current" as NSString)
        value?.setObject(weather, forKeyedSubscript: "weather" as NSString)
        value?.setObject(t, forKeyedSubscript: "t" as NSString)
        value?.setObject(invalidate, forKeyedSubscript: "invalidate" as NSString)
        if let makeMedia = js.objectForKeyedSubscript("__switchlyMakeMedia"), !makeMedia.isUndefined {
            value?.setObject(makeMedia.call(withArguments: [ctx.bundleID, permissions.contains(.mediaNowPlaying) && mediaRead != nil,
                permissions.contains(.mediaNowPlaying) ? (mediaRead?.nowPlaying?.jsObject as Any? ?? NSNull()) : NSNull(),
                permissions.contains(.mediaNowPlaying) ? (mediaRead?.readError as Any? ?? NSNull()) : NSNull()]), forKeyedSubscript: "media" as NSString)
        } else if let library = js.objectForKeyedSubscript("__switchlyLibrary"), library.isObject {
            // Library without nowPlaying / control: ctx.media exists with just `library`.
            let media = JSValue(newObjectIn: js)
            media?.setObject(library, forKeyedSubscript: "library" as NSString)
            value?.setObject(media, forKeyedSubscript: "media" as NSString)
        }
        if let fs = js.objectForKeyedSubscript("__switchlyFS"), fs.isObject {
            value?.setObject(fs, forKeyedSubscript: "fs" as NSString)
        }
        if let storage = js.objectForKeyedSubscript("__switchlyStorage"), storage.isObject {
            value?.setObject(storage, forKeyedSubscript: "storage" as NSString)
        }
        return value
    }

    /// supported / granted / available 分开，声明过权限也不能把未实现能力说成可调用。
    private func capabilitySnapshot(bundleID: String) -> [String: [String: Bool]] {
        var result: [String: [String: Bool]] = [:]
        let capabilities: [PluginCapability] = [.mediaNowPlaying, .mediaControl, .mediaLibrary,
                                                .weatherCurrent, .fsRead, .windowFocus]
        for capability in Set(capabilities + manifest.permissions) {
            let supported: Bool
            let ready: Bool
            switch capability {
            case .mediaNowPlaying, .mediaControl:
                supported = true; ready = mediaBridge?.supports(bundleID: bundleID) == true
            case .mediaLibrary: supported = true; ready = libraryBridge != nil
            case .weatherCurrent: supported = true; ready = weatherProvider?() != nil
            case .fsRead: supported = true; ready = fileReader != nil
            case .windowFocus, .appleScript: supported = false; ready = false
            }
            let granted = permissions.contains(capability)
            result[capability.rawValue] = ["supported": supported, "granted": granted,
                                           "available": supported && granted && ready]
        }
        result["storage"] = ["supported": true, "granted": true, "available": storage != nil]
        return result
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
