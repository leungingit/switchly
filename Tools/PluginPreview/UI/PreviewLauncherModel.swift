import Combine
import Foundation

/// 启动器与预览会话控制器之间的边界。实现方负责工作目录、worker 与会话生命周期。
@MainActor
protocol PreviewLauncherHost: AnyObject {
    func launcherApply(plugin: URL, draft: PreviewScenarioDraft) async throws
    func launcherAdvance(milliseconds: Double) async throws
    func launcherExport(draft: PreviewScenarioDraft, to destination: URL) throws
}

/// 无参数启动器的状态：插件选择、最近使用、默认/自定义草稿与防抖渲染。
///
/// 草稿始终来自 `PreviewScenarioDraft`（GUI、覆盖项和导出的唯一来源）；
/// 视图只修改草稿，真正的会话重建由 `PreviewLauncherHost` 完成。
@MainActor
final class PreviewLauncherModel: ObservableObject {
    static let recentDefaultsKey = "PluginPreviewRecentPluginDirectories"

    @Published private(set) var mode: PreviewLauncherMode = .derivedDefault
    @Published private(set) var pluginURL: URL?
    @Published private(set) var manifest: PluginManifest?
    @Published private(set) var derivedDraft: PreviewScenarioDraft?
    @Published private(set) var customDraft: PreviewScenarioDraft?
    @Published private(set) var recentPlugins: [URL] = []
    @Published private(set) var isRendering = false
    @Published private(set) var errorMessage: String?
    /// 模拟 Dock 浮层的本体设置项；只影响右栏展示，不属于场景、不导出、不进入 run。
    @Published var mockDock = PreviewMockDockOptions()
    /// 玻璃检查模式：仅清空工作台舞台底色，不改场景，也不进入导出。
    @Published var showsRawDesktop = false

    weak var host: PreviewLauncherHost?

    private lazy var debouncer = PreviewRenderDebouncer { [weak self] in
        await self?.renderCurrentDraft()
    }
    private var renderRevision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentPlugins = PreviewRecentPluginList.decoding(defaults.stringArray(forKey: Self.recentDefaultsKey) ?? [])
    }

    private let defaults: UserDefaults

    var hasPlugin: Bool { manifest != nil }

    /// 当前生效的草稿：默认模式恒为推导值，自定义模式保留用户修改。
    var displayedDraft: PreviewScenarioDraft? {
        mode == .custom ? customDraft : derivedDraft
    }

    var uiLanguage: AppLanguage {
        AppLanguage(rawValue: displayedDraft?.locale.rawValue ?? "") ?? .english
    }

    func t(_ key: String) -> String {
        uiLanguage.localizedString(key)
    }

    func displayName(language: AppLanguage) -> String {
        guard let manifest else { return "" }
        return manifest.name[language.rawValue] ?? manifest.name["en"] ?? manifest.name.values.first ?? manifest.id
    }

    var pluginIdentity: String {
        guard let manifest else { return "" }
        return "\(manifest.id) · \(manifest.version)"
    }

    var permissionKeys: [String] {
        manifest?.permissions.map(\.rawValue) ?? []
    }

    var settingSpecs: [PluginSettingSpec] {
        manifest?.settings ?? []
    }

    // MARK: - 插件选择

    func openPlugin(_ url: URL) {
        do {
            let package = try PluginPackageValidator.load(directory: url, origin: .user)
            let standardized = url.standardizedFileURL
            let derived = PreviewScenarioDraft.derive(manifest: package.manifest)
            pluginURL = standardized
            manifest = package.manifest
            derivedDraft = derived
            customDraft = derived
            mode = .derivedDefault
            errorMessage = nil
            recordRecent(standardized)
            debouncer.cancel()
            Task { await renderCurrentDraft() }
        } catch {
            errorMessage = message(for: error)
        }
    }

    func forgetError() {
        errorMessage = nil
    }

    // MARK: - 模式

    func setMode(_ newMode: PreviewLauncherMode) {
        guard newMode != mode, hasPlugin else { return }
        mode = newMode
        debouncer.cancel()
        Task { await renderCurrentDraft() }
    }

    // MARK: - 草稿编辑

    func updateDraft(_ change: (inout PreviewScenarioDraft) -> Void) {
        guard mode == .custom, var draft = customDraft else { return }
        change(&draft)
        guard draft != customDraft else { return }
        customDraft = draft
        debouncer.schedule()
    }

    func setWidth(_ value: Double) {
        let range = PreviewScenarioDraft.contentWidthRange
        updateDraft { $0.contentWidthPoints = min(max(value, range.lowerBound), range.upperBound) }
    }

    func setGrant(_ rawValue: String, enabled: Bool) {
        updateDraft { draft in
            var values = Set(draft.grants)
            if enabled { values.insert(rawValue) } else { values.remove(rawValue) }
            // 与 manifest 保持同一顺序，并丢弃未声明的权限。
            draft.grants = permissionKeys.filter { values.contains($0) }
        }
    }

    func settingValue(_ spec: PluginSettingSpec) -> PluginSettingValue {
        customDraft?.settings[spec.key] ?? spec.defaultValue
    }

    func setSetting(_ spec: PluginSettingSpec, value: PluginSettingValue) {
        updateDraft { $0.settings[spec.key] = value }
    }

    func setFixture(_ kind: PreviewScenarioDraft.FixtureKind, url: URL?) {
        // 显式选择覆盖内置样例；传入 nil（「清除」）表示不可用，不回退内置样例。
        updateDraft { $0.fixtures[kind] = url.map(PreviewScenarioDraft.FixtureSource.explicit) ?? .none }
    }

    func fixtureSource(_ kind: PreviewScenarioDraft.FixtureKind) -> PreviewScenarioDraft.FixtureSource {
        displayedDraft?.fixtures[kind] ?? .none
    }

    /// fixture 区的人类可读来源；内置样例与缺失必需文件分别标注。
    func fixtureDescription(_ kind: PreviewScenarioDraft.FixtureKind) -> String {
        switch fixtureSource(kind) {
        case .builtin:
            return t("Built-in sample")
        case .explicit(let url):
            return url.lastPathComponent
        case .none:
            if kind == .fs, manifest?.permissions.contains(.fsRead) == true {
                return t("Needs a file")
            }
            return t("None")
        }
    }

    /// 默认模式的只读摘要：只列出内置或显式来源，以及需要显式文件的 fs。
    func fixturesSummary() -> String {
        guard let manifest else { return t("None") }
        let parts = PreviewScenarioDraft.FixtureKind.allCases.compactMap { kind -> String? in
            switch fixtureSource(kind) {
            case .builtin:
                return "\(kind.rawValue): \(t("Built-in sample"))"
            case .explicit(let url):
                return "\(kind.rawValue): \(url.lastPathComponent)"
            case .none:
                return kind.isRequired(by: manifest) ? "\(kind.rawValue): \(t("Needs a file"))" : nil
            }
        }
        return parts.isEmpty ? t("None") : parts.joined(separator: ", ")
    }

    // MARK: - 虚拟时钟

    func advance(milliseconds: Double) {
        guard let host, milliseconds.isFinite, milliseconds > 0, milliseconds <= 86_400_000 else { return }
        Task {
            do {
                try await host.launcherAdvance(milliseconds: milliseconds)
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                errorMessage = message(for: error)
            }
        }
    }

    // MARK: - 导出

    func export(to destination: URL) {
        guard let host, let draft = displayedDraft else { return }
        do {
            try host.launcherExport(draft: draft, to: destination)
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
        }
    }

    // MARK: - 渲染

    private func renderCurrentDraft() async {
        guard let host, let pluginURL, let draft = displayedDraft else { return }
        renderRevision += 1
        let revision = renderRevision
        isRendering = true
        defer { if renderRevision == revision { isRendering = false } }
        do {
            try await host.launcherApply(plugin: pluginURL, draft: draft)
            if renderRevision == revision { errorMessage = nil }
        } catch is CancellationError {
        } catch {
            if renderRevision == revision { errorMessage = message(for: error) }
        }
    }

    private func recordRecent(_ url: URL) {
        recentPlugins = PreviewRecentPluginList.adding(url, to: recentPlugins)
        defaults.set(PreviewRecentPluginList.encoding(recentPlugins), forKey: Self.recentDefaultsKey)
    }

    /// 窗口内固定提示：不暴露路径、fixture 内容或堆栈。
    private func message(for error: Error) -> String {
        let failure = PreviewFailure.classify(error)
        if failure.code == "plugin-script-error", let manifest, let draft = displayedDraft,
           let missing = draft.missingRequiredFixtureKind(for: manifest) {
            return PreviewFixtureHint.message(kind: missing, localize: { t($0) })
        }
        switch failure.code {
        case "invalid-package":
            return t("The plugin directory is not a valid preview package.")
        case "invalid-fixture":
            return t("A selected fixture file is invalid or too large.")
        case "invalid-scenario", "invalid-settings", "invalid-grants":
            return t("The current scenario is invalid for this plugin.")
        case "environment-unavailable", "worker-unavailable", "incompatible-preview-tool":
            return t("The preview environment is unavailable.")
        case "preview-failed":
            return t("Preview failed")
        default:
            return t("The plugin failed to render.")
        }
    }
}
