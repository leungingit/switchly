import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 启动器左栏（控制区）：插件选择、默认/自定义草稿、fixture、导出与诊断。
///
/// 该栏是唯一不透明区域；右栏的模拟 Dock 保持透明。`dev`/`run` 仍使用
/// `PluginPreviewView`，因此这里的控件不会进入 run 的截图或可访问树匹配。
struct PreviewLauncherSidebarView: View {
    @ObservedObject var model: PreviewLauncherModel
    @ObservedObject var state: PluginPreviewState
    let isDropTarget: Bool

    var body: some View {
        ScrollView([.vertical]) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                header
                if model.hasPlugin {
                    pluginCard
                    modePicker
                    PreviewLauncherMockDockSettingsView(model: model, state: state)
                    if model.mode == .custom {
                        PreviewLauncherEditor(model: model, state: state)
                    } else {
                        derivedSummary
                    }
                } else {
                    emptyState
                }
                if let message = model.errorMessage { errorBanner(message) }
                diagnostics
                scopeNote
            }
            .padding(DesignTokens.Spacing.lg)
        }
        // 左栏默认磨砂玻璃：窗口非不透明，用系统侧栏材质托住控制卡片。
        .background(GlassBackground(material: .sidebar).ignoresSafeArea())
        .overlay(alignment: .top) {
            LauncherWindowDragArea().frame(height: 28).ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: DesignTokens.hairline)
                .allowsHitTesting(false)
        }
        .overlay(dropHighlight)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("Plugin Preview"))
                    .font(.title2.weight(.semibold))
                Text(model.hasPlugin ? model.pluginIdentity : t("No plugin selected"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            if model.isRendering {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(t("Rendering")))
            }
            statusBadge
        }
    }

    private var pluginCard: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(language: model.uiLanguage))
                        .font(.headline)
                    Text(model.pluginURL?.lastPathComponent ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button(t("Open Plugin Directory…"), action: choosePlugin)
                        .launcherAccessibleButton(t("Open Plugin Directory…"), action: choosePlugin)
                    Spacer(minLength: 0)
                    Menu(t("Recent Plugins")) {
                        if model.recentPlugins.isEmpty {
                            Text(t("No recent plugins yet"))
                        } else {
                            ForEach(model.recentPlugins, id: \.path) { url in
                                Button(url.lastPathComponent) { model.openPlugin(url) }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(Text(t("Recent Plugins")))
                }
                Button(t("Export as Scenario File…"), action: exportScenario)
                    .launcherAccessibleButton(t("Export as Scenario File…"), action: exportScenario)
            }
        }
    }

    private var modePicker: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LauncherControlLabel(text: t("Preview mode"))
                Picker(t("Preview mode"), selection: Binding(
                    get: { model.mode },
                    set: { model.setMode($0) }
                )) {
                    ForEach(PreviewLauncherMode.allCases, id: \.self) { mode in
                        Text(t(mode.localizationKey)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(!model.hasPlugin)
                .accessibilityLabel(Text(t("Preview mode")))
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        launcherCard {
            VStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(t("Choose plugin directory"))
                    .font(.title3.weight(.semibold))
                Text(t("Open a plugin folder to preview it. You can also drag a folder here."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(t("Open Plugin Directory…"), action: choosePlugin)
                    .keyboardShortcut("o", modifiers: .command)
                    .launcherAccessibleButton(t("Open Plugin Directory…"), action: choosePlugin)

                if !model.recentPlugins.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text(t("Recent Plugins"))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        ForEach(model.recentPlugins, id: \.path) { url in
                            recentRow(url)
                        }
                    }
                } else {
                    Text(t("No recent plugins yet"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }

    private func recentRow(_ url: URL) -> some View {
        let label = "\(url.lastPathComponent), \(url.path)"
        return Button {
            model.openPlugin(url)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "folder")
                Text(url.lastPathComponent).lineLimit(1)
                Spacer()
                Text(url.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .launcherAccessibleButton(label) { model.openPlugin(url) }
    }

    // MARK: - Derived (read-only) summary

    private var derivedSummary: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(t("Derived default scenario"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                        .foregroundColor(.accentColor)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    Spacer()
                    Text(t("Default scenario values are read-only."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let draft = model.derivedDraft {
                    readOnlyRow("Language", draft.locale == .zhHans ? "简体中文" : "English")
                    readOnlyRow("Appearance", t(draft.appearance == .dark ? "Dark" : "Light"))
                    readOnlyRow("Glass", t(draft.glass ? "On" : "Off"))
                    readOnlyRow("Reduce Motion", t(draft.reduceMotion ? "On" : "Off"))
                    readOnlyRow("Width", "\(Int(draft.contentWidthPoints)) pt")
                    readOnlyRow("Target application", "\(draft.target.appName) (\(draft.target.bundleID))")
                    readOnlyRow("Permissions", draft.grants.isEmpty ? t("None") : draft.grants.joined(separator: ", "))
                    readOnlyRow("Virtual clock", clockDescription(draft.clock))
                    readOnlyRow("Fixtures", model.fixturesSummary())
                    ForEach(model.settingSpecs, id: \.key) { spec in
                        readOnlyRow(PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage),
                                    PreviewLauncherFormat.settingText(spec.defaultValue, language: model.uiLanguage))
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnostics: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack {
                    Text(t("Diagnostics")).font(.headline)
                    Spacer()
                    Text(t(state.status.localizationKey))
                        .font(.caption.weight(.medium))
                        .foregroundColor(statusColor)
                }
                if state.diagnostics.isEmpty {
                    Text(t("No diagnostics")).font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(state.diagnostics) { diagnostic in
                        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                            Text(t(diagnostic.level.localizationKey))
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(color(for: diagnostic.level))
                                .frame(width: 58, alignment: .leading)
                            Text(t(diagnostic.message))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(t("Clear"), action: model.forgetError)
                .buttonStyle(.plain)
                .font(.caption)
                .launcherAccessibleButton(t("Clear"), action: model.forgetError)
        }
        .launcherCard(material: state.environment.material, fill: Color.orange.opacity(0.12))
    }

    private var scopeNote: some View {
        Text(t("The simulated Dock only reproduces hover presentation and plugin interaction. It is not a verification of the real Dock; real AX hover, cross-display placement, real thumbnails and desktop glass still need to be checked in Switchly."))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private func launcherCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().launcherCard(material: state.environment.material)
    }

    private func readOnlyRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(t(label))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func t(_ key: String) -> String { model.t(key) }

    private func clockDescription(_ clock: PreviewScenarioDraft.Clock) -> String {
        guard clock.isEnabled else { return t("Off") }
        let date = Date(timeIntervalSince1970: clock.startEpochMs / 1000)
        return "\(DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .medium)) · seed \(clock.seed)"
    }

    private var statusColor: Color {
        switch state.status {
        case .idle, .rendering: return .secondary
        case .ready: return .green
        case .stale: return .orange
        case .failed: return .red
        }
    }

    private func color(for level: PluginPreviewDiagnosticLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var dropHighlight: some View {
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: isDropTarget ? 2 : 0)
            .allowsHitTesting(false)
    }

    private var statusBadge: some View {
        Text(t(state.status.localizationKey))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .foregroundColor(statusColor)
            .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    // MARK: - Panels

    private func choosePlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = t("Open Plugin Directory…")
        panel.message = t("Choose plugin directory")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openPlugin(url)
    }

    private func exportScenario() {
        let panel = NSSavePanel()
        panel.title = t("Export as Scenario File…")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "scenario.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url)
    }
}
