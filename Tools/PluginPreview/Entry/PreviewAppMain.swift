import AppKit
import Darwin
import Foundation
import SwiftUI

private enum PreviewAppError: Error {
    case arguments, environment, worker, capture, invalidPackage, invalidGrants, invalidSettings
}

/// 失败出口的稳定分类：状态、退出码、固定码与固定提示。提示不含插件内容、路径或 fixture 数据。
struct PreviewFailure {
    let status: String
    let exitCode: Int32
    let code: String
    let message: String

    private static func failed(_ code: String, _ message: String) -> PreviewFailure {
        PreviewFailure(status: "failed", exitCode: 1, code: code, message: message)
    }

    /// `missingFixtureKind` 仅在已知 manifest 必需但无来源时提供，用于契约 §3.4 的固定修复提示。
    static func classify(_ error: Error,
                         missingFixtureKind: PreviewScenarioDraft.FixtureKind? = nil,
                         language: AppLanguage = .english) -> PreviewFailure {
        if error is PluginPreviewSurfaceError {
            return PreviewFailure(status: "environment-error", exitCode: 4, code: "background-surface-unavailable",
                                  message: language.localizedString("The native preview surface is unavailable or failed isolation checks."))
        }
        if let error = error as? PreviewAppError {
            switch error {
            case .invalidPackage:
                return failed("invalid-package", "The plugin package is invalid (manifest, entry file or limits).")
            case .invalidGrants:
                return failed("invalid-grants", "The scenario grants are invalid for this plugin.")
            case .invalidSettings:
                return failed("invalid-settings", "The scenario settings are invalid for this plugin manifest.")
            case .arguments:
                return PreviewFailure(status: "failed", exitCode: 2, code: "invalid-arguments", message: "The preview arguments are invalid.")
            default:
                return PreviewFailure(status: "environment-error", exitCode: 4, code: "environment-unavailable", message: "The preview environment is unavailable.")
            }
        }
        if let error = error as? PreviewScenarioOverrideError {
            switch error {
            case .invalidArgument:
                return PreviewFailure(status: "failed", exitCode: 2, code: "invalid-arguments", message: "The preview arguments are invalid.")
            case .invalidGrants:
                return failed("invalid-grants", "The scenario grants are invalid for this plugin.")
            case .invalidSettings:
                return failed("invalid-settings", "The scenario settings are invalid for this plugin manifest.")
            }
        }
        if error is FixtureTransferError {
            return failed("invalid-fixture", "A scenario fixture is missing, oversized or does not match the plugin.")
        }
        if case PluginPreviewSessionError.workerFailure(let code, _) = error {
            switch code {
            case "unsupported": return PreviewFailure(status: "unsupported", exitCode: 3, code: "unsupported", message: "The scenario uses an unsupported capability.")
            case "invalidPackage": return failed("invalid-package", "The plugin package is invalid (manifest, entry file or limits).")
            case "invalidScenario": return failed("invalid-scenario", "The scenario file is invalid.")
            case "invalidFixture": return failed("invalid-fixture", "A scenario fixture is missing, oversized or does not match the plugin.")
            case "invalidGrants": return failed("invalid-grants", "The scenario grants are invalid for this plugin.")
            case "invalidSettings": return failed("invalid-settings", "The scenario settings are invalid for this plugin manifest.")
            case "timedOut": return failed("plugin-timeout", "The plugin did not finish rendering within the time limit.")
            case "pluginError":
                let message = missingFixtureKind.map {
                    PreviewFixtureHint.message(kind: $0, localize: language.localizedString)
                } ?? "The plugin script threw an error while running."
                return failed("plugin-script-error", message)
            case "invalidOutput": return failed("invalid-render-output", "The plugin returned UI that does not pass host decoding.")
            case "disabled": return failed("plugin-disabled", "The plugin was disabled after repeated timeouts.")
            default: break
            }
        }
        if case PluginPreviewArtifactError.invalidPackage = error {
            return failed("invalid-package", "The plugin package is invalid (manifest, entry file or limits).")
        }
        if case PluginPreviewSessionError.process(.failure(let processFailure)) = error {
            switch processFailure.reason {
            case .requestTimedOut:
                return failed("plugin-timeout", "The worker did not answer in time (possibly an endless loop); it was terminated.")
            case .workerExited:
                return failed("worker-crashed", "The preview worker exited unexpectedly.")
            case .startupTimedOut, .launchFailed:
                return PreviewFailure(status: "environment-error", exitCode: 4, code: "worker-unavailable", message: "The preview worker could not be started.")
            default: break
            }
        }
        switch error as? PluginPreviewSessionError {
        case .some(.incompatibleProtocolVersion), .some(.incompatibleScenarioSchemaVersion),
             .some(.incompatibleSDKContractHash), .some(.incompatibleToolVersion):
            return PreviewFailure(status: "environment-error", exitCode: 4, code: "incompatible-preview-tool", message: "The preview worker is not compatible with this app.")
        case .some(.unsupportedPluginAPIVersion):
            return PreviewFailure(status: "unsupported", exitCode: 3, code: "plugin-api-unsupported", message: "The plugin API version is not supported by this tool.")
        default: break
        }
        if let scenarioFailure = error as? PreviewScenario.Failure {
            switch scenarioFailure {
            case .unsupportedSteps: return PreviewFailure(status: "unsupported", exitCode: 3, code: "unsupported", message: "The scenario uses an unsupported step.")
            case .invalidScenario: return failed("invalid-scenario", "The scenario file is invalid.")
            case .invalidFixturePath, .fixtureTooLarge: return failed("invalid-fixture", "A scenario fixture is missing, oversized or does not match the plugin.")
            }
        }
        return failed("preview-failed", "The preview failed for an unclassified reason.")
    }
}

/// 无 GUI、无网络、不读取任何用户文件：只报告本工具的版本与契约指纹，供 CLI 在启动预览前核对兼容性。
private func printVersionAndExit() -> Never {
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = "unknown"
    #endif
    let value: [String: Any] = [
        "tool": "switchly-plugin-preview",
        "toolVersion": PluginPreviewContract.toolVersion,
        "protocolVersion": PluginPreviewFrameCodec.protocolVersion,
        "scenarioSchemaVersion": PluginPreviewContract.scenarioSchemaVersion,
        "pluginAPIVersions": Array(PluginManifest.supportedAPIVersions),
        "sdkContractHash": PluginPreviewContract.sdkContractHash,
        "rendererRevision": PluginPreviewContract.rendererRevision,
        "architecture": architecture,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data + Data("\n".utf8))
    exit(0)
}

@main
private enum PreviewAppMain {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let code = PluginPreviewAccessibilityPreparation.run(arguments: args) { exit(code) }
        if args == ["--version-json"] {
            printVersionAndExit()
        }
        let json = args.contains("--json")
        let protocolFD = dup(STDOUT_FILENO)
        guard protocolFD >= 0 else { exit(74) }
        let sink = open("/dev/null", O_WRONLY)
        guard sink >= 0, dup2(sink, STDOUT_FILENO) >= 0 else { exit(74) }
        close(sink)
        let output = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: true)
        let invocation: PluginPreviewInvocation
        do { invocation = try PluginPreviewCommandLine.parse(args) }
        catch {
            let result = ["schemaVersion": 1, "status": "failed", "error": ["code": "invalid-arguments"]] as [String: Any]
            if json, let data = try? JSONSerialization.data(withJSONObject: result), let line = String(data: data, encoding: .utf8) {
                try? output.write(contentsOf: Data((line + "\n").utf8))
            }
            fputs("预览参数无效。\n", stderr)
            exit(2)
        }
        if case .inspect(let plugin) = invocation {
            exit(runInspect(plugin: plugin, output: output))
        }
        let app = NSApplication.shared
        let delegate = PreviewAppDelegate(invocation: invocation, output: output)
        app.delegate = delegate
        if case .preview(let arguments) = invocation, arguments.background {
            app.setActivationPolicy(.accessory)
        } else {
            app.setActivationPolicy(.regular)
        }
        app.run()
        exit(delegate.exitCode)
    }

    /// 无 GUI 的 inspect：只读取插件包与 manifest，与 `--version-json` 同类。
    private static func runInspect(plugin: URL, output: FileHandle) -> Int32 {
        let failure: PreviewFailure
        do {
            let package = try PluginPackageValidator.load(directory: plugin, origin: .user)
            let data = try PluginPreviewInspectReport.data(manifest: package.manifest)
            try output.write(contentsOf: data + Data("\n".utf8))
            return 0
        } catch is PluginPreviewInspectError {
            failure = PreviewFailure(status: "failed", exitCode: 1, code: "invalid-scenario",
                                     message: "The default scenario could not be encoded.")
        } catch is PluginPackageValidator.Failure {
            failure = PreviewFailure(status: "failed", exitCode: 1, code: "invalid-package",
                                     message: "The plugin package is invalid (manifest, entry file or limits).")
        } catch {
            failure = PreviewFailure(status: "failed", exitCode: 1, code: "invalid-package",
                                     message: "The plugin package is invalid (manifest, entry file or limits).")
        }
        let value: [String: Any] = [
            "schemaVersion": 1,
            "status": failure.status,
            "error": ["code": failure.code, "message": failure.message],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            try? output.write(contentsOf: data + Data("\n".utf8))
        }
        return failure.exitCode
    }
}

@MainActor
private final class PreviewAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let arguments: PluginPreviewCommandArguments?
    private let output: FileHandle
    private let state = PluginPreviewState()
    private var session: PluginPreviewSession?
    private var window: NSWindow?
    private var captureSurface: PluginPreviewCaptureSurface?
    private var scenario: PreviewScenario?
    private var package: PluginPackage?
    private var rawJSON: String?
    private var workRoot: URL?
    private var activeSnapshot: URL?
    private var activeHash: String?
    private var watcher: PluginPreviewPackageWatcher?
    private var reloadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private let debugModel = PreviewDebugModel()
    private var reloadPending = false
    private var resetPending = false
    private var starting = true
    private var hidden = false
    private var signalSources: [DispatchSourceSignal] = []
    private var closing = false
    private(set) var exitCode: Int32 = 1

    // GUI 启动器：模型负责草稿与防抖，会话重建仍由本类完成。
    private var launcherModel: PreviewLauncherModel?
    /// 最新草稿的序号；旧请求在真正重建会话前发现序号已过期就直接放弃。
    private var launcherRevision = 0
    private var launcherRenderLocked = false
    private var launcherWaiters: [CheckedContinuation<Void, Never>] = []

    // GUI 扩展点：后续面板替换插件目录或草稿后调用 `start()` / `replaceSession`，
    // 会话创建只读取这两个属性与 `scenarioPath`。
    private var pluginURL: URL?
    /// 当前草稿（推导 + 覆盖项）；显式 `--scenario` 时由场景文件回读。
    private var draft: PreviewScenarioDraft?
    /// 当前插件 manifest；用于把缺失 fixture 的渲染失败映射为固定修复提示。
    private var pluginManifest: PluginManifest?
    private var scenarioPath: URL?
    private var scenarioSource: PluginPreviewScenarioSource = .derived
    private let overrides: PreviewScenarioOverrides

    var isLauncher: Bool { arguments == nil }

    init(invocation: PluginPreviewInvocation, output: FileHandle) {
        if case .preview(let arguments) = invocation {
            self.arguments = arguments
            self.overrides = arguments.overrides
            self.pluginURL = arguments.plugin
            self.scenarioSource = arguments.scenario == nil ? .derived : .file
        } else {
            self.arguments = nil
            self.overrides = PreviewScenarioOverrides()
        }
        self.output = output
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        guard NSScreen.main != nil else { finish(status: "environment-error", code: 4, reason: "gui-unavailable"); return }
        state.actionHandler = { [weak self] pluginID, actionID, value in self?.perform(pluginID: pluginID, id: actionID, value: value) }
        state.reloadHandler = { [weak self] in self?.requestReload(force: true, reset: false) }
        state.resetHandler = { [weak self] in self?.requestReload(force: true, reset: true) }
        if arguments?.background == true {
            Task { await start() }
            return
        }
        let content: NSView
        let windowSize: NSSize
        if isLauncher {
            let model = PreviewLauncherModel()
            model.host = self
            launcherModel = model
            let hosting = NSHostingView(rootView: PreviewLauncherView(model: model, state: state, debug: debugModel))
            // 右栏透明：宿主视图自身不能铺底色，否则窗口再透明也会被内容层挡住。
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            content = hosting
            windowSize = NSSize(width: 1080, height: 720)
        } else {
            content = NSHostingView(rootView: PluginPreviewView(state: state))
            windowSize = NSSize(width: 700, height: 700)
        }
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Switchly Plugin Preview"
        panel.contentView = content
        if isLauncher {
            // 只改启动器窗口：左栏不透明，右栏透出桌面。标题栏保持系统外观。
            // 堆叠布局需要足够的纵向空间让浮层完整落在模拟 Dock 栏内。
            panel.minSize = NSSize(width: 680, height: 700)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isMovableByWindowBackground = true
            // 标题栏与左栏同色：内容延伸到标题栏下方并让标题栏透明，避免透明窗口下
            // 标题栏落成另一种材质色。
            panel.styleMask.insert(.fullSizeContentView)
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            // 窗口阴影会沿右栏里浮层/Dock 条的半透明像素再描一圈灰黑边，
            // 与 SwiftUI 自带的浮层阴影叠加；右栏要的是“漂在桌面上”，故关闭系统阴影。
            panel.hasShadow = false
        }
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
        debugModel.onVisibilityChange = { [weak self] visible in self?.resizeWindowForDebugPanel(visible: visible) }
        // 无参数启动器只显示空状态，插件选择后由启动器模型触发会话重建。
        if !isLauncher { Task { await start() } }
    }

    private func start() async {
        guard let arguments, let pluginURL else { return }
        state.status = .rendering
        defer {
            starting = false
            if reloadPending && !closing {
                let reset = resetPending
                reloadPending = false
                resetPending = false
                requestReload(force: true, reset: reset)
            }
        }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-preview-session-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workRoot = root
            let scenario: PreviewScenario
            if let file = arguments.scenario {
                let scenarioData = try PreviewFixtureFile.read(relativePath: file.lastPathComponent,
                    scenarioDirectory: file.deletingLastPathComponent(), maximumBytes: PluginStorage.maxTotalBytes)
                scenario = try PreviewScenario.decode(scenarioData)
                scenarioPath = file
                scenarioSource = .file
                draft = PreviewScenarioDraft(scenario: scenario, scenarioDirectory: file.deletingLastPathComponent())
            } else {
                let pluginPackage: PluginPackage
                do { pluginPackage = try PluginPackageValidator.load(directory: pluginURL, origin: .user) }
                catch { throw PreviewAppError.invalidPackage }
                pluginManifest = pluginPackage.manifest
                var derived = PreviewScenarioDraft.derive(manifest: pluginPackage.manifest)
                do { try derived.applyOverrides(overrides, manifest: pluginPackage.manifest) }
                catch PreviewScenarioOverrideError.invalidGrants { throw PreviewAppError.invalidGrants }
                catch PreviewScenarioOverrideError.invalidSettings { throw PreviewAppError.invalidSettings }
                draft = derived
                scenarioSource = .derived
                let prepared = try writeDerivedScenario(derived, root: root)
                scenarioPath = prepared.path
                scenario = prepared.scenario
            }
            self.scenario = scenario
            applyEnvironment(scenario)
            if arguments.command == "dev" {
                let watcher = PluginPreviewPackageWatcher(directory: pluginURL) { [weak self] in
                    Task { @MainActor [weak self] in self?.requestReload(force: false, reset: false) }
                }
                try await Task.detached { try watcher.start() }.value
                self.watcher = watcher
            }
            try await replaceSession(force: true, reset: true)
            if arguments.command == "run" { try await captureAndReport() }
        } catch {
            guard !closing else { return }
            state.status = .failed
            state.diagnostics = [PluginPreviewDiagnostic(level: .error, message: "Preview failed")]
            if arguments.command == "run" {
                let manifest = pluginManifest
                    ?? (try? PluginPackageValidator.load(directory: pluginURL, origin: .user).manifest)
                let missing = manifest.flatMap { manifest in
                    draft?.missingRequiredFixtureKind(for: manifest)
                }
                let language = AppLanguage(rawValue: draft?.locale.rawValue ?? "") ?? .english
                let failure = PreviewFailure.classify(error, missingFixtureKind: missing, language: language)
                fputs("preview \(failure.status): \(failure.code)\n", stderr)
                finish(status: failure.status, code: failure.exitCode, reason: failure.code, message: failure.message)
            }
        }
    }

    /// 把场景环境同步到预览视图；命令行与 GUI 启动器共用。
    private func applyEnvironment(_ scenario: PreviewScenario) {
        state.environment.language = AppLanguage(rawValue: scenario.environment.locale) ?? .english
        state.environment.theme = scenario.environment.appearance == "dark" ? .dark : .light
        state.environment.glassEnabled = scenario.environment.glass
        state.environment.contentWidth = CGFloat(scenario.environment.contentWidthPoints)
    }

    /// 把草稿写成会话私有场景文件；fixtures 复制进同一 `workRoot`，场景内只写相对路径。
    private func writeDerivedScenario(_ draft: PreviewScenarioDraft, root: URL) throws -> (path: URL, scenario: PreviewScenario) {
        let fixturePaths = try draft.materializeFixtures(in: root)
        let data = try draft.encode(fixtureRelativePaths: fixturePaths)
        let scenario = try PreviewScenario.decode(data)
        let path = root.appendingPathComponent("scenario.json")
        do {
            try data.write(to: path, options: [.atomic])
        } catch {
            throw PreviewAppError.environment
        }
        return (path, scenario)
    }

    private func workerURL() throws -> URL {
        guard let executable = Bundle.main.executableURL else { throw PreviewAppError.environment }
        let bundled = executable.deletingLastPathComponent().appendingPathComponent("SwitchlyPluginPreviewWorker")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("SwitchlyPluginPreviewWorker")
        guard FileManager.default.isExecutableFile(atPath: sibling.path) else { throw PreviewAppError.environment }
        return sibling
    }

    private func updateRender(_ session: PluginPreviewSession) async throws {
        let started = Date()
        let json: String
        do { json = try await session.render() }
        catch {
            debugModel.recordFailure(String(describing: error), durationMs: Date().timeIntervalSince(started) * 1000)
            throw error
        }
        guard self.session === session, !closing else { throw CancellationError() }
        debugModel.recordRender(json: json, durationMs: Date().timeIntervalSince(started) * 1000)
        let contents = try PluginRenderOutput.decode(json: Data(json.utf8))
        guard let package else { throw PreviewAppError.worker }
        rawJSON = json
        state.slots = Dictionary(uniqueKeysWithValues: contents.map { content in
            (content.slot, [PluginSlotSurface.Entry(id: package.manifest.id, node: content.node, assetDirectory: activeSnapshot)])
        })
    }

    /// 按 manifest 的 refreshInterval 周期重绘，与宿主 Dock 浮层一致；否则依赖时间推进的插件
    /// （如空闲阶段）在预览里只渲染一次，永远停在第一帧。只用于交互式预览（启动器 / dev），
    /// 一次性截图与场景步骤保持确定性。会话被替换或关闭后循环自行退出。
    /// 面板展开时把窗口向右加宽一个面板的宽度（屏幕放不下则向左补），收起时还原，模拟 Dock 区不被挤压。
    private func resizeWindowForDebugPanel(visible: Bool) {
        guard let window else { return }
        let delta = PreviewDebugModel.panelWidth * (visible ? 1 : -1)
        var frame = window.frame
        frame.size.width = max(window.minSize.width, frame.size.width + delta)
        if visible, let screen = window.screen ?? NSScreen.main, frame.maxX > screen.visibleFrame.maxX {
            frame.origin.x = max(screen.visibleFrame.minX, screen.visibleFrame.maxX - frame.width)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    private func startRefreshLoop(for session: PluginPreviewSession, interval: TimeInterval) {
        guard isLauncher || arguments?.command == "dev" else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !self.closing, self.session === session else { return }
                await self.render()
            }
        }
    }

    private func render() async {
        guard let session, !closing, !hidden else { return }
        do { try await updateRender(session) }
        catch { state.status = .stale }
    }

    /// 最近一次经原生回调路由到会话的动作，供 nativeClick 步骤核对路径。
    private var routedAction: (id: String, task: Task<Void, Error>)?

    private func perform(pluginID: String, id: String, value: Double?) {
        guard pluginID == state.pluginID, let session else { return }
        let task = Task<Void, Error> {
            do { try await session.action(id: id, value: value); try await updateRender(session) }
            catch { state.status = .stale; throw error }
        }
        routedAction = (id, task)
    }

    /// 通过可访问树 press 控件，等待（有界）回调把动作路由进会话并处理完成。
    fileprivate func nativeClick(label: String, expectAction: String?, expectDisabled: Bool) async throws {
        let root: NSView?
        if arguments?.background == true {
            try await captureSurface?.layout()
            root = captureSurface?.window.contentView
        } else {
            root = window?.contentView
        }
        guard let root else { throw PluginPreviewStepFailure(code: "window-unavailable") }
        routedAction = nil
        switch PluginPreviewNativeDriver.press(label: label, in: root) {
        case .notFound: throw PluginPreviewStepFailure(code: "element-not-found")
        case .ambiguous: throw PluginPreviewStepFailure(code: "element-ambiguous")
        case .pressFailed: throw PluginPreviewStepFailure(code: "press-failed")
        case .disabled:
            guard expectDisabled else { throw PluginPreviewStepFailure(code: "element-disabled") }
            try await Task.sleep(nanoseconds: 100_000_000)
            if routedAction != nil { throw PluginPreviewStepFailure(code: "disabled-control-fired") }
            try captureSurface?.requireIsolation()
            return
        case .pressed:
            if expectDisabled { throw PluginPreviewStepFailure(code: "element-not-disabled") }
        }
        try await waitForRoutedAction(expectAction: expectAction)
        try captureSurface?.requireIsolation()
    }

    private func waitForRoutedAction(expectAction: String?) async throws {
        var waited = 0
        while routedAction == nil, waited < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        guard let routed = routedAction else { throw PluginPreviewStepFailure(code: "no-action-routed") }
        try await routed.task.value
        if let expectAction, routed.id != expectAction { throw PluginPreviewStepFailure(code: "wrong-action-routed") }
    }

    private func nativePointer(from: PluginPreviewPoint, to: PluginPreviewPoint?, expectAction: String?) async throws {
        guard let surface = captureSurface else { throw PluginPreviewStepFailure(code: "window-unavailable") }
        try await surface.layout()
        routedAction = nil
        try await PluginPreviewNativeDriver.pointer(from: from, to: to, in: surface.window,
                                                    checkIsolation: surface.requireIsolation)
        if to == nil {
            try await waitForRoutedAction(expectAction: expectAction)
        } else if let routed = routedAction {
            try await routed.task.value
        }
        try surface.requireIsolation()
    }

    private func requestReload(force: Bool, reset: Bool) {
        guard !closing, arguments?.command == "dev" else { return }
        fputs("preview reload requested\n", stderr)
        if starting || reloadTask != nil {
            reloadPending = true
            resetPending = resetPending || reset
            return
        }
        reloadTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.replaceSession(force: force, reset: reset) }
            catch {
                fputs("preview reload failed\n", stderr)
                self.state.status = self.session == nil ? .failed : .stale
                self.state.diagnostics = [PluginPreviewDiagnostic(level: .error, message: "Preview failed")]
            }
            self.reloadTask = nil
            if self.reloadPending && !self.closing {
                let resetAgain = self.resetPending
                self.reloadPending = false
                self.resetPending = false
                self.requestReload(force: true, reset: resetAgain)
            }
        }
    }

    private func replaceSession(force: Bool, reset: Bool) async throws {
        guard let root = workRoot, let pluginURL, let scenarioPath, !closing else { throw CancellationError() }
        let snapshot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = pluginURL
        let hash = try await Task.detached { try PluginPreviewPackageHasher.snapshot(packageURL: source, destination: snapshot) }.value
        guard !closing, !Task.isCancelled else { try? FileManager.default.removeItem(at: snapshot); throw CancellationError() }
        if !force && hash == activeHash { try? FileManager.default.removeItem(at: snapshot); return }
        var candidate: PluginPreviewSession?
        do {
            let package: PluginPackage
            do { package = try PluginPackageValidator.load(directory: snapshot, origin: .user) }
            catch { throw PreviewAppError.invalidPackage }
            let saved = reset ? nil : try await session?.storageDump()
            let configuration = try PluginPreviewProcessConfiguration(executableURL: workerURL(), environment: [:])
            let compatibility = PluginPreviewSessionCompatibility(pluginAPIVersion: package.manifest.apiVersion,
                                                                   sdkContractHash: PluginPreviewContract.sdkContractHash)
            let expectedGeneration = UInt64(state.generation) + 1
            let debugModel = self.debugModel
            let captures = isLauncher
            let next = PluginPreviewSession(configuration: configuration, compatibility: compatibility, capturesConsole: captures) { [weak self] event in
                if case .console(let generation, let lines) = event, generation == expectedGeneration {
                    Task { @MainActor in debugModel.appendConsole(lines) }
                    return
                }
                guard case .invalidate(let generation) = event, generation == expectedGeneration else { return }
                Task { @MainActor [weak self] in
                    guard self?.state.generation == Int(clamping: generation) else { return }
                    await self?.render()
                }
            }
            debugModel.clear()
            candidate = next
            _ = try await next.start(generation: UInt64(state.generation))
            let loaded = try await next.load(pluginDirectory: snapshot, scenarioPath: scenarioPath, storageJSON: saved)
            let firstRenderStart = Date()
            let json = try await next.render()
            debugModel.recordRender(json: json, durationMs: Date().timeIntervalSince(firstRenderStart) * 1000)
            let contents = try PluginRenderOutput.decode(json: Data(json.utf8))
            if hidden { try await next.suspend() }
            guard !closing, !Task.isCancelled else { throw CancellationError() }
            let old = session
            let oldSnapshot = activeSnapshot
            session = next
            self.package = package
            pluginManifest = package.manifest
            activeSnapshot = snapshot
            activeHash = hash
            state.pluginID = package.manifest.id
            state.pluginVersion = package.manifest.version
            state.renderScope = package.manifest.renderScope ?? .app
            state.generation = Int(clamping: loaded.generation)
            state.virtualNowSeconds = scenario?.clock.map { $0.startEpochMs / 1000 }
            state.artwork = loaded.artworkBase64.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            rawJSON = json
            state.slots = Dictionary(uniqueKeysWithValues: contents.map { content in
                (content.slot, [PluginSlotSurface.Entry(id: package.manifest.id, node: content.node, assetDirectory: snapshot)])
            })
            state.diagnostics = []
            state.status = .ready
            fputs("preview generation ready\n", stderr)
            startRefreshLoop(for: next, interval: package.manifest.effectiveRefreshInterval ?? 1)
            await old?.shutdown()
            if let oldSnapshot { try? FileManager.default.removeItem(at: oldSnapshot) }
        } catch {
            await candidate?.stop()
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
    }

    /// 步骤执行目标：所有操作绑定到创建时的会话，会话换代后旧步骤立即失败（取消）。
    private final class StepTarget: PluginPreviewStepTarget {
        private let owner: PreviewAppDelegate
        private let session: PluginPreviewSession
        init(owner: PreviewAppDelegate, session: PluginPreviewSession) { self.owner = owner; self.session = session }

        private func requireCurrent() async throws {
            guard await owner.session === session, await !owner.closing else { throw CancellationError() }
        }
        func advance(milliseconds: Double) async throws {
            try await requireCurrent()
            try await session.advance(milliseconds: milliseconds)
            await owner.advanceVirtualNow(by: milliseconds)
            try await owner.updateRender(session)
        }
        func perform(actionID: String, value: Double?) async throws {
            try await requireCurrent()
            try await session.action(id: actionID, value: value)
            try await owner.updateRender(session)
        }
        func renderJSON() async throws -> String {
            try await requireCurrent()
            return try await session.render()
        }
        func nativeClick(label: String, expectAction: String?, expectDisabled: Bool) async throws {
            try await requireCurrent()
            try await owner.nativeClick(label: label, expectAction: expectAction, expectDisabled: expectDisabled)
        }
        func nativeClickAt(point: PluginPreviewPoint, expectAction: String?) async throws {
            try await requireCurrent()
            try await owner.nativePointer(from: point, to: nil, expectAction: expectAction)
        }
        func nativeDrag(from: PluginPreviewPoint, to: PluginPreviewPoint) async throws {
            try await requireCurrent()
            try await owner.nativePointer(from: from, to: to, expectAction: nil)
        }
        func availableActions() async throws -> [PluginPreviewStepAction] {
            try await requireCurrent()
            let json = try await session.render()
            let slots = try PluginRenderOutput.decode(json: Data(json.utf8))
            return PluginPreviewArtifactBuilder.actions(pluginID: await owner.state.pluginID, slots: slots)
                .actions.map { PluginPreviewStepAction(id: $0.actionID, enabled: $0.enabled) }
        }
    }

    private func advanceVirtualNow(by milliseconds: Double) {
        state.virtualNowSeconds = (state.virtualNowSeconds ?? 0) + milliseconds / 1000
    }

    /// 执行场景步骤。无步骤返回 nil；有步骤返回 trace，失败时已写入失败报告并结束进程。
    private func runScenarioSteps(_ scenario: PreviewScenario, package: PluginPackage,
                                  outputDirectory: URL) async throws -> [PluginPreviewStepTrace]? {
        guard !scenario.typedSteps.isEmpty else { return nil }
        guard let session else { throw PreviewAppError.worker }
        let outcome = await PluginPreviewStepRunner.run(scenario.typedSteps, on: StepTarget(owner: self, session: session))
        // 信号清理可能在原生手势 await 期间关闭表面；不能再写失败报告覆盖 128+signal。
        guard !closing else { throw CancellationError() }
        guard outcome.failedIndex != nil else { return outcome.traces }
        let report = try PluginPreviewArtifactWriter().writeFailure(
            identity: artifactIdentity(scenario: scenario, package: package), status: .failed, failure: .stepFailed,
            outputDirectory: outputDirectory, steps: outcome.traces)
        try await emitReportAndExit(report, code: 1)
        return nil
    }

    private func artifactIdentity(scenario: PreviewScenario, package: PluginPackage) -> PluginPreviewArtifactIdentity {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let environment = PluginPreviewArtifactEnvironment(
            operatingSystemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture, locale: scenario.environment.locale, appearance: scenario.environment.appearance,
            displayScale: Double((captureSurface?.screen ?? window?.screen ?? NSScreen.main)?.backingScaleFactor ?? 0),
            rendererRevision: PluginPreviewContract.rendererRevision, glass: scenario.environment.glass,
            deterministicClock: scenario.clock != nil)
        return PluginPreviewArtifactIdentity(scenarioID: scenario.id, pluginID: package.manifest.id,
            pluginVersion: package.manifest.version, generation: UInt64(state.generation),
            packageURL: activeSnapshot ?? pluginURL ?? URL(fileURLWithPath: "/"),
            versions: .init(toolVersion: PluginPreviewContract.toolVersion, protocolVersion: PluginPreviewFrameCodec.protocolVersion,
                            scenarioSchemaVersion: PluginPreviewContract.scenarioSchemaVersion,
                            pluginAPIVersion: package.manifest.apiVersion, sdkContractHash: PluginPreviewContract.sdkContractHash),
            environment: environment, scenarioSource: scenarioSource)
    }

    private func emitReportAndExit(_ report: PluginPreviewArtifactReport, code: Int32) async throws {
        guard !closing else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        try output.write(contentsOf: data + Data("\n".utf8))
        exitCode = code
        closing = true
        await cleanup()
        NSApp.terminate(nil)
    }

    private func captureAndReport() async throws {
        guard let scenario, let package, let outputDirectory = arguments?.output,
              let screen = window?.screen ?? NSScreen.main,
              CGPreflightScreenCaptureAccess() else { throw PreviewAppError.capture }
        let entries = state.capturedSlots.flatMap { state.slots[$0] ?? [] }
        guard !entries.isEmpty else {
            // 没有可截图的内容不是环境问题：区分「只渲染了未接入的槽位」与「什么都没渲染」。
            let renderedElsewhere = state.slots.values.contains { !$0.isEmpty }
            let report = try PluginPreviewArtifactWriter().writeFailure(
                identity: artifactIdentity(scenario: scenario, package: package),
                status: renderedElsewhere ? .unsupported : .failed,
                failure: renderedElsewhere ? .noCapturableSlot : .emptyRender,
                outputDirectory: outputDirectory, steps: nil)
            try await emitReportAndExit(report, code: renderedElsewhere ? 3 : 1)
            return
        }
        let surface = try PluginPreviewCaptureSurface(state: state, screen: screen, background: arguments?.background == true)
        captureSurface = surface
        defer { surface.close(); captureSurface = nil }
        guard let workRoot else { throw PreviewAppError.environment }
        let temporary = workRoot.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let screenshot = temporary.appendingPathComponent("preview.png")
        // 真实图像自检在步骤前执行，避免在返回空图的系统上仍派发输入。
        try await surface.capture(to: screenshot)
        if arguments?.background == true && scenario.typedSteps.contains(where: {
            if case .nativeClick = $0 { return true }; return false
        }) { try await surface.prepareAccessibility() }
        let steps = try await runScenarioSteps(scenario, package: package, outputDirectory: outputDirectory)
        if !scenario.typedSteps.isEmpty && steps == nil { return }
        guard let rawJSON else { throw PreviewAppError.capture }
        try FileManager.default.removeItem(at: screenshot)
        try await surface.capture(to: screenshot)
        let report = try PluginPreviewArtifactWriter().writeSuccess(
            identity: artifactIdentity(scenario: scenario, package: package), rawJSON: Data(rawJSON.utf8),
            screenshotURL: screenshot, outputDirectory: outputDirectory, steps: steps)
        // 截图已复制到输出目录，在上报并结束进程之前显式删除临时目录，不依赖 defer 是否还能执行
        // （进程被信号杀死时 defer 同样不会执行，此处无法覆盖）。
        try? FileManager.default.removeItem(at: temporary)
        try await emitReportAndExit(report, code: 0)
    }

    /// 报告对象里的场景来源；GUI 启动器不产生运行结果，因此省略。
    private var reportedScenarioSource: String? {
        arguments == nil ? nil : scenarioSource.rawValue
    }

    private func finish(status: String, code: Int32, reason: String, message: String? = nil) {
        guard !closing else { return }
        var errorValue: [String: Any] = ["code": reason]
        if let message { errorValue["message"] = message }
        var value: [String: Any] = ["schemaVersion": 1, "status": status, "error": errorValue]
        if let source = reportedScenarioSource { value["scenarioSource"] = source }
        if arguments?.json == true, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? output.write(contentsOf: data + Data("\n".utf8))
        }
        exitCode = code
        closing = true
        Task {
            await cleanup()
            NSApp.terminate(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        if isLauncher {
            // 启动器正常关窗不是失败。
            exitCode = 0
        } else if state.status == .ready {
            exitCode = 0
            if arguments?.json == true {
                var value: [String: Any] = ["schemaVersion": 1, "status": "passed"]
                if let source = reportedScenarioSource { value["scenarioSource"] = source }
                if let data = try? JSONSerialization.data(withJSONObject: value) {
                    try? output.write(contentsOf: data + Data("\n".utf8))
                }
            }
        } else {
            exitCode = 1
            if arguments?.json == true {
                var value: [String: Any] = ["schemaVersion": 1, "status": "failed"]
                if let source = reportedScenarioSource { value["scenarioSource"] = source }
                if let data = try? JSONSerialization.data(withJSONObject: value) {
                    try? output.write(contentsOf: data + Data("\n".utf8))
                }
            }
        }
        Task {
            await cleanup()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !closing else { return .terminateNow }
        closing = true
        Task {
            await cleanup()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // NSApplication.terminate 默认直接 exit(0)，不会返回 main 的 app.run() 之后。
        // 清理已在上述终止入口完成，此处保留与 JSON 报告一致的 CLI 退出码。
        exit(exitCode)
    }

    func windowDidMiniaturize(_ notification: Notification) { setHidden(true) }
    func windowDidDeminiaturize(_ notification: Notification) { setHidden(false) }
    func applicationDidHide(_ notification: Notification) { setHidden(true) }
    func applicationDidUnhide(_ notification: Notification) { setHidden(false) }

    private func setHidden(_ value: Bool) {
        guard hidden != value else { return }
        hidden = value
        guard let session else { return }
        Task {
            do {
                if value { try await session.suspend() }
                else { try await session.resume(); await render() }
            } catch {
                if self.session === session && !closing { state.status = .stale }
            }
        }
    }

    private func cleanup() async {
        captureSurface?.close()
        captureSurface = nil
        watcher?.stop()
        watcher = nil
        reloadTask?.cancel()
        let pending = reloadTask
        await session?.shutdown()
        await pending?.value
        session = nil
        if let workRoot { try? FileManager.default.removeItem(at: workRoot) }
        workRoot = nil
    }

    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, !self.closing else { return }
                self.closing = true
                self.exitCode = 128 + number
                Task {
                    await self.cleanup()
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// GUI 启动器的会话边界：插件目录与草稿由模型提供，本扩展只负责安全替换会话。
extension PreviewAppDelegate: PreviewLauncherHost {
    func launcherApply(plugin: URL, draft: PreviewScenarioDraft) async throws {
        launcherRevision += 1
        let revision = launcherRevision
        // 同一时刻只允许一个会话重建；等待者被唤醒后若已过期或取消会直接退出。
        if launcherRenderLocked {
            await withCheckedContinuation { launcherWaiters.append($0) }
        }
        launcherRenderLocked = true
        defer {
            launcherRenderLocked = false
            if !launcherWaiters.isEmpty {
                launcherWaiters.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        guard !closing, launcherRevision == revision else { return }
        try await applyLauncherDraft(plugin: plugin, draft: draft)
    }

    func launcherAdvance(milliseconds: Double) async throws {
        guard !closing, milliseconds.isFinite, milliseconds > 0, milliseconds <= 86_400_000 else {
            throw PreviewAppError.arguments
        }
        // 时钟开关的草稿更新有防抖：新会话尚未就绪时按钮点击按无操作处理。
        guard let session, draft?.clock.isEnabled == true, scenario?.clock != nil else { return }
        try await session.advance(milliseconds: milliseconds)
        advanceVirtualNow(by: milliseconds)
        try await updateRender(session)
    }

    /// 导出当前草稿：fixtures 复制到导出目录下的独立子目录，场景内写相对路径；
    /// 写出后立即按 `run` 相同路径回读，schema 或 fixture 校验失败则清理本次产物。
    func launcherExport(draft: PreviewScenarioDraft, to destination: URL) throws {
        try PreviewScenarioExporter.write(draft, to: destination)
    }

    private func applyLauncherDraft(plugin: URL, draft: PreviewScenarioDraft) async throws {
        let standardized = plugin.standardizedFileURL
        if pluginURL?.path != standardized.path || workRoot == nil {
            await teardownLauncherSession()
            pluginURL = standardized
            scenarioSource = .derived
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("switchly-preview-session-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            workRoot = root
        }
        guard let root = workRoot else { throw PreviewAppError.environment }
        self.draft = draft
        let prepared = try writeDerivedScenario(draft, root: root)
        scenarioPath = prepared.path
        scenario = prepared.scenario
        applyEnvironment(prepared.scenario)
        state.status = .rendering
        try Task.checkCancellation()
        try await replaceSession(force: true, reset: true)
    }

    /// 切换插件前停止旧 watcher 与 worker，并清理该会话的私有目录。
    private func teardownLauncherSession() async {
        refreshTask?.cancel()
        refreshTask = nil
        watcher?.stop()
        watcher = nil
        await session?.shutdown()
        session = nil
        if let workRoot { try? FileManager.default.removeItem(at: workRoot) }
        workRoot = nil
        activeSnapshot = nil
        activeHash = nil
        rawJSON = nil
        package = nil
        pluginManifest = nil
        scenario = nil
        scenarioPath = nil
        state.slots = [:]
        state.artwork = nil
        state.pluginID = ""
        state.pluginVersion = ""
        state.renderScope = .app
        state.virtualNowSeconds = nil
    }
}
