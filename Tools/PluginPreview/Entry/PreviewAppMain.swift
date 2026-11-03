import AppKit
import Darwin
import Foundation
import SwiftUI

private struct PreviewArguments {
    let command: String
    let plugin: URL
    let scenario: URL
    let output: URL?
    let json: Bool

    init(_ args: [String]) throws {
        guard args.count >= 4, ["dev", "run"].contains(args[0]), !args[1].hasPrefix("--") else { throw PreviewAppError.arguments }
        command = args[0]
        plugin = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        var scenarioPath: String?
        var outputPath: String?
        var jsonMode = false
        var index = 2
        while index < args.count {
            switch args[index] {
            case "--json":
                guard !jsonMode else { throw PreviewAppError.arguments }
                jsonMode = true
                index += 1
            case "--scenario", "--out":
                let option = args[index]
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw PreviewAppError.arguments }
                if option == "--scenario" {
                    guard scenarioPath == nil else { throw PreviewAppError.arguments }
                    scenarioPath = args[index + 1]
                } else {
                    guard outputPath == nil else { throw PreviewAppError.arguments }
                    outputPath = args[index + 1]
                }
                index += 2
            default: throw PreviewAppError.arguments
            }
        }
        guard let scenarioPath, (command == "run") == (outputPath != nil) else { throw PreviewAppError.arguments }
        scenario = URL(fileURLWithPath: scenarioPath).standardizedFileURL
        output = outputPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        json = jsonMode
    }
}

private enum PreviewAppError: Error {
    case arguments, environment, worker, capture, invalidPackage
}

/// 失败出口的稳定分类：状态、退出码、固定码与固定提示。提示不含插件内容、路径或 fixture 数据。
private struct PreviewFailure {
    let status: String
    let exitCode: Int32
    let code: String
    let message: String

    private static func failed(_ code: String, _ message: String) -> PreviewFailure {
        PreviewFailure(status: "failed", exitCode: 1, code: code, message: message)
    }

    static func classify(_ error: Error) -> PreviewFailure {
        if error is PreviewAppError {
            if case PreviewAppError.invalidPackage = error { return failed("invalid-package", "The plugin package is invalid (manifest, entry file or limits).") }
            return PreviewFailure(status: "environment-error", exitCode: 4, code: "environment-unavailable", message: "The preview environment is unavailable.")
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
            case "pluginError": return failed("plugin-script-error", "The plugin script threw an error while running.")
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
        let arguments: PreviewArguments
        do { arguments = try PreviewArguments(args) }
        catch {
            let result = ["schemaVersion": 1, "status": "failed", "error": ["code": "invalid-arguments"]] as [String: Any]
            if json, let data = try? JSONSerialization.data(withJSONObject: result), let line = String(data: data, encoding: .utf8) {
                try? output.write(contentsOf: Data((line + "\n").utf8))
            }
            fputs("预览参数无效。\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = PreviewAppDelegate(arguments: arguments, output: output)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(delegate.exitCode)
    }
}

@MainActor
private final class PreviewAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let arguments: PreviewArguments
    private let output: FileHandle
    private let state = PluginPreviewState()
    private var session: PluginPreviewSession?
    private var window: NSWindow?
    private var scenario: PreviewScenario?
    private var package: PluginPackage?
    private var rawJSON: String?
    private var workRoot: URL?
    private var activeSnapshot: URL?
    private var activeHash: String?
    private var watcher: PluginPreviewPackageWatcher?
    private var reloadTask: Task<Void, Never>?
    private var reloadPending = false
    private var resetPending = false
    private var starting = true
    private var hidden = false
    private var signalSources: [DispatchSourceSignal] = []
    private var closing = false
    private(set) var exitCode: Int32 = 1

    init(arguments: PreviewArguments, output: FileHandle) {
        self.arguments = arguments
        self.output = output
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        guard NSScreen.main != nil else { finish(status: "environment-error", code: 4, reason: "gui-unavailable"); return }
        let view = PluginPreviewView(state: state)
        let hosting = NSHostingView(rootView: view)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Switchly Plugin Preview"
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
        state.actionHandler = { [weak self] pluginID, actionID, value in self?.perform(pluginID: pluginID, id: actionID, value: value) }
        state.reloadHandler = { [weak self] in self?.requestReload(force: true, reset: false) }
        state.resetHandler = { [weak self] in self?.requestReload(force: true, reset: true) }
        Task { await start() }
    }

    private func start() async {
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
            let scenarioData = try PreviewFixtureFile.read(relativePath: arguments.scenario.lastPathComponent,
                scenarioDirectory: arguments.scenario.deletingLastPathComponent(), maximumBytes: PluginStorage.maxTotalBytes)
            let scenario = try PreviewScenario.decode(scenarioData)
            self.scenario = scenario
            state.environment.language = AppLanguage(rawValue: scenario.environment.locale) ?? .english
            state.environment.theme = scenario.environment.appearance == "dark" ? .dark : .light
            state.environment.glassEnabled = scenario.environment.glass
            state.environment.contentWidth = CGFloat(scenario.environment.contentWidthPoints)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-preview-session-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workRoot = root
            if arguments.command == "dev" {
                let watcher = PluginPreviewPackageWatcher(directory: arguments.plugin) { [weak self] in
                    Task { @MainActor [weak self] in self?.requestReload(force: false, reset: false) }
                }
                try await Task.detached { try watcher.start() }.value
                self.watcher = watcher
            }
            try await replaceSession(force: true, reset: true)
            if arguments.command == "run" { try await captureAndReport() }
        } catch {
            state.status = .failed
            state.diagnostics = [PluginPreviewDiagnostic(level: .error, message: "Preview failed")]
            if arguments.command == "run" {
                let failure = PreviewFailure.classify(error)
                fputs("preview \(failure.status): \(failure.code)\n", stderr)
                finish(status: failure.status, code: failure.exitCode, reason: failure.code, message: failure.message)
            }
        }
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
        let json = try await session.render()
        guard self.session === session, !closing else { throw CancellationError() }
        let contents = try PluginRenderOutput.decode(json: Data(json.utf8))
        guard let package else { throw PreviewAppError.worker }
        rawJSON = json
        state.slots = Dictionary(uniqueKeysWithValues: contents.map { content in
            (content.slot, [PluginSlotSurface.Entry(id: package.manifest.id, node: content.node, assetDirectory: activeSnapshot)])
        })
    }

    private func render() async {
        guard let session, !closing, !hidden else { return }
        do { try await updateRender(session) }
        catch { state.status = .stale }
    }

    /// 最近一次经原生回调路由到会话的动作，供 nativeClick 步骤核对路径。
    private var routedAction: (id: String, task: Task<Void, Never>)?

    private func perform(pluginID: String, id: String, value: Double?) {
        guard pluginID == state.pluginID, let session else { return }
        let task = Task {
            do { try await session.action(id: id, value: value); try await updateRender(session) }
            catch { state.status = .stale }
        }
        routedAction = (id, task)
    }

    /// 通过可访问树 press 控件，等待（有界）回调把动作路由进会话并处理完成。
    fileprivate func nativeClick(label: String, expectAction: String?, expectDisabled: Bool) async throws {
        guard let root = window?.contentView else { throw PluginPreviewStepFailure(code: "window-unavailable") }
        routedAction = nil
        switch PluginPreviewNativeDriver.press(label: label, in: root) {
        case .notFound: throw PluginPreviewStepFailure(code: "element-not-found")
        case .ambiguous: throw PluginPreviewStepFailure(code: "element-ambiguous")
        case .pressFailed: throw PluginPreviewStepFailure(code: "press-failed")
        case .disabled:
            guard expectDisabled else { throw PluginPreviewStepFailure(code: "element-disabled") }
            try await Task.sleep(nanoseconds: 100_000_000)
            if routedAction != nil { throw PluginPreviewStepFailure(code: "disabled-control-fired") }
            return
        case .pressed:
            if expectDisabled { throw PluginPreviewStepFailure(code: "element-not-disabled") }
        }
        var waited = 0
        while routedAction == nil, waited < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        guard let routed = routedAction else { throw PluginPreviewStepFailure(code: "no-action-routed") }
        await routed.task.value
        if let expectAction, routed.id != expectAction { throw PluginPreviewStepFailure(code: "wrong-action-routed") }
    }

    private func requestReload(force: Bool, reset: Bool) {
        guard !closing, arguments.command == "dev" else { return }
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
        guard let root = workRoot, !closing else { throw CancellationError() }
        let snapshot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = arguments.plugin
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
            let next = PluginPreviewSession(configuration: configuration, compatibility: compatibility) { [weak self] event in
                guard case .invalidate(let generation) = event, generation == expectedGeneration else { return }
                Task { @MainActor [weak self] in
                    guard self?.state.generation == Int(clamping: generation) else { return }
                    await self?.render()
                }
            }
            candidate = next
            _ = try await next.start(generation: UInt64(state.generation))
            let loaded = try await next.load(pluginDirectory: snapshot, scenarioPath: arguments.scenario, storageJSON: saved)
            let json = try await next.render()
            let contents = try PluginRenderOutput.decode(json: Data(json.utf8))
            if hidden { try await next.suspend() }
            guard !closing, !Task.isCancelled else { throw CancellationError() }
            let old = session
            let oldSnapshot = activeSnapshot
            session = next
            self.package = package
            activeSnapshot = snapshot
            activeHash = hash
            state.pluginID = package.manifest.id
            state.pluginVersion = package.manifest.version
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
            displayScale: Double((window?.screen ?? NSScreen.main)?.backingScaleFactor ?? 0),
            rendererRevision: PluginPreviewContract.rendererRevision, glass: scenario.environment.glass,
            deterministicClock: scenario.clock != nil)
        return PluginPreviewArtifactIdentity(scenarioID: scenario.id, pluginID: package.manifest.id,
            pluginVersion: package.manifest.version, generation: UInt64(state.generation), packageURL: activeSnapshot ?? arguments.plugin,
            versions: .init(toolVersion: PluginPreviewContract.toolVersion, protocolVersion: PluginPreviewFrameCodec.protocolVersion,
                            scenarioSchemaVersion: PluginPreviewContract.scenarioSchemaVersion,
                            pluginAPIVersion: package.manifest.apiVersion, sdkContractHash: PluginPreviewContract.sdkContractHash),
            environment: environment)
    }

    private func emitReportAndExit(_ report: PluginPreviewArtifactReport, code: Int32) async throws {
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
        guard let scenario, let package, let outputDirectory = arguments.output,
              let screen = window?.screen ?? NSScreen.main,
              CGPreflightScreenCaptureAccess() else { throw PreviewAppError.capture }
        let steps = try await runScenarioSteps(scenario, package: package, outputDirectory: outputDirectory)
        if !scenario.typedSteps.isEmpty && steps == nil { return }
        guard let rawJSON else { throw PreviewAppError.capture }
        let entries = [PluginSlot.center, .bottomBar].flatMap { state.slots[$0] ?? [] }
        guard !entries.isEmpty else {
            // 没有可截图的内容不是环境问题：区分「只渲染了未接入的槽位」与「什么都没渲染」。
            let renderedElsewhere = state.slots.values.contains { !$0.isEmpty }
            let report = try PluginPreviewArtifactWriter().writeFailure(
                identity: artifactIdentity(scenario: scenario, package: package),
                status: renderedElsewhere ? .unsupported : .failed,
                failure: renderedElsewhere ? .noCapturableSlot : .emptyRender,
                outputDirectory: outputDirectory, steps: steps)
            try await emitReportAndExit(report, code: renderedElsewhere ? 3 : 1)
            return
        }
        let surface = PluginSlotSurface(entries: entries, material: state.environment.material,
                                        isGlassActive: state.environment.glassEnabled, artwork: state.artwork,
                                        fallback: nil) { _, _, _ in }
            .environment(\.pluginSceneNow, state.virtualNowSeconds.map { now in { now } })
            .frame(width: state.environment.contentWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(state.environment.theme.colorScheme)
            .environment(\.locale, Locale(identifier: state.environment.language.rawValue))
        let host = NSHostingView(rootView: surface)
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, size.width <= screen.visibleFrame.width,
              size.height <= screen.visibleFrame.height else { throw PreviewAppError.capture }
        let captureWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                     backing: .buffered, defer: false, screen: screen)
        captureWindow.isReleasedWhenClosed = false
        captureWindow.contentView = host
        captureWindow.center()
        captureWindow.makeKeyAndOrderFront(nil)
        defer { captureWindow.orderOut(nil); captureWindow.contentView = nil }
        try await Task.sleep(nanoseconds: 500_000_000)
        captureWindow.displayIfNeeded()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let screenshot = temporary.appendingPathComponent("preview.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(captureWindow.windowNumber), screenshot.path]
        capture.standardOutput = FileHandle.nullDevice
        capture.standardError = FileHandle.nullDevice
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw PreviewAppError.capture }
        let report = try PluginPreviewArtifactWriter().writeSuccess(
            identity: artifactIdentity(scenario: scenario, package: package), rawJSON: Data(rawJSON.utf8),
            screenshotURL: screenshot, outputDirectory: outputDirectory, steps: steps)
        // 截图已复制到输出目录。必须在终止进程前删除临时目录：emitReportAndExit 会结束进程，
        // 之后调用方的 defer 不会执行，否则每次 run 都会在系统临时目录留下一张插件截图。
        try? FileManager.default.removeItem(at: temporary)
        try await emitReportAndExit(report, code: 0)
    }

    private func finish(status: String, code: Int32, reason: String, message: String? = nil) {
        var errorValue: [String: Any] = ["code": reason]
        if let message { errorValue["message"] = message }
        let value: [String: Any] = ["schemaVersion": 1, "status": status, "error": errorValue]
        if arguments.json, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
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
        if state.status == .ready {
            exitCode = 0
            if arguments.json {
                let value: [String: Any] = ["schemaVersion": 1, "status": "passed"]
                if let data = try? JSONSerialization.data(withJSONObject: value) {
                    try? output.write(contentsOf: data + Data("\n".utf8))
                }
            }
        } else {
            exitCode = 1
            if arguments.json {
                let value: [String: Any] = ["schemaVersion": 1, "status": "failed"]
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
