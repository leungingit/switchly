import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 启动器自定义模式的控制区：环境、目标应用、权限、manifest 设置、虚拟时钟与 fixture。
struct PreviewLauncherEditor: View {
    @ObservedObject var model: PreviewLauncherModel
    @ObservedObject var state: PluginPreviewState
    @State private var customAdvanceText = "500"

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            environment
            target
            permissions
            if !model.settingSpecs.isEmpty { settings }
            clock
            fixtures
        }
    }

    private var environment: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LauncherControlLabel(text: t("Environment"))
                HStack(spacing: DesignTokens.Spacing.sm) {
                    LauncherControlLabel(text: t("Language"))
                    Picker(t("Language"), selection: Binding(
                        get: { model.displayedDraft?.locale ?? .en },
                        set: { value in model.updateDraft { $0.locale = value } }
                    )) {
                        Text("English").tag(PreviewScenarioDraft.Locale.en)
                        Text("简体中文").tag(PreviewScenarioDraft.Locale.zhHans)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text(t("Language")))
                }
                HStack(spacing: DesignTokens.Spacing.sm) {
                    LauncherControlLabel(text: t("Appearance"))
                    Picker(t("Appearance"), selection: Binding(
                        get: { model.displayedDraft?.appearance ?? .light },
                        set: { value in model.updateDraft { $0.appearance = value } }
                    )) {
                        Text(t("Light")).tag(PreviewScenarioDraft.Appearance.light)
                        Text(t("Dark")).tag(PreviewScenarioDraft.Appearance.dark)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text(t("Appearance")))
                }
                Toggle(t("Glass"), isOn: Binding(
                    get: { model.displayedDraft?.glass ?? false },
                    set: { value in model.updateDraft { $0.glass = value } }
                ))
                .toggleStyle(.switch)
                .accessibilityLabel(Text(t("Glass")))
                Toggle(t("Reduce Motion"), isOn: Binding(
                    get: { model.displayedDraft?.reduceMotion ?? true },
                    set: { value in model.updateDraft { $0.reduceMotion = value } }
                ))
                .toggleStyle(.switch)
                .accessibilityLabel(Text(t("Reduce Motion")))
                HStack(spacing: DesignTokens.Spacing.sm) {
                    LauncherControlLabel(text: t("Width"))
                    Slider(value: Binding(
                        get: { model.displayedDraft?.contentWidthPoints ?? 360 },
                        set: { model.setWidth($0) }
                    ), in: PreviewScenarioDraft.contentWidthRange, step: 20)
                    .accessibilityLabel(Text(t("Width")))
                    Text("\(Int(model.displayedDraft?.contentWidthPoints ?? 360)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
    }

    private var target: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LauncherControlLabel(text: t("Target application"))
                TextField(t("Bundle ID"), text: Binding(
                    get: { model.displayedDraft?.target.bundleID ?? "" },
                    set: { value in model.updateDraft { $0.target.bundleID = value } }
                ))
                .accessibilityLabel(Text(t("Bundle ID")))
                TextField(t("App name"), text: Binding(
                    get: { model.displayedDraft?.target.appName ?? "" },
                    set: { value in model.updateDraft { $0.target.appName = value } }
                ))
                .accessibilityLabel(Text(t("App name")))
            }
        }
    }

    private var permissions: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LauncherControlLabel(text: t("Permissions"))
                if model.permissionKeys.isEmpty {
                    Text(t("None")).font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(model.permissionKeys, id: \.self) { permission in
                        Toggle(permission, isOn: Binding(
                            get: { model.displayedDraft?.grants.contains(permission) ?? false },
                            set: { model.setGrant(permission, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text(permission))
                    }
                }
            }
        }
    }

    private var settings: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LauncherControlLabel(text: t("Settings"))
                ForEach(model.settingSpecs, id: \.key) { spec in
                    settingControl(spec)
                }
            }
        }
    }

    private var clock: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LauncherControlLabel(text: t("Virtual clock"))
                Toggle(t("Fixed clock"), isOn: Binding(
                    get: { model.displayedDraft?.clock.isEnabled ?? false },
                    set: { value in model.updateDraft { $0.clock.isEnabled = value } }
                ))
                .toggleStyle(.switch)
                .accessibilityLabel(Text(t("Fixed clock")))
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button(t("Advance 1 s")) { model.advance(milliseconds: 1_000) }
                        .launcherAccessibleButton(t("Advance 1 s"), isEnabled: clockEnabled) {
                            model.advance(milliseconds: 1_000)
                        }
                    Button(t("Advance 1 min")) { model.advance(milliseconds: 60_000) }
                        .launcherAccessibleButton(t("Advance 1 min"), isEnabled: clockEnabled) {
                            model.advance(milliseconds: 60_000)
                        }
                    Spacer()
                }
                .disabled(!clockEnabled)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    TextField(t("Custom advance (ms)"), text: $customAdvanceText)
                        .frame(width: 140)
                        .accessibilityLabel(Text(t("Custom advance (ms)")))
                    Button(t("Advance")) {
                        if let value = validCustomAdvance { model.advance(milliseconds: value) }
                    }
                    .disabled(validCustomAdvance == nil)
                    .launcherAccessibleButton(t("Advance"),
                                              isEnabled: clockEnabled && validCustomAdvance != nil) {
                        if let value = validCustomAdvance { model.advance(milliseconds: value) }
                    }
                    if validCustomAdvance == nil {
                        Text(t("Enter a duration between 1 ms and 24 hours."))
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .disabled(!clockEnabled)
            }
        }
    }

    private var fixtures: some View {
        launcherCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LauncherControlLabel(text: t("Fixtures"))
                ForEach(PreviewScenarioDraft.FixtureKind.allCases, id: \.self) { kind in
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text(kind.rawValue)
                            .font(.caption.weight(.semibold))
                            .frame(width: 58, alignment: .leading)
                        Text(model.fixtureDescription(kind))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(t("Choose File…")) { chooseFixture(kind) }
                            .launcherAccessibleButton(String(format: t("Choose %@ fixture file"), kind.rawValue)) {
                                chooseFixture(kind)
                            }
                        Button(t("Clear")) { model.setFixture(kind, url: nil) }
                            .disabled(model.fixtureSource(kind) == .none)
                            .launcherAccessibleButton(
                                String(format: t("Clear %@ fixture"), kind.rawValue),
                                isEnabled: model.fixtureSource(kind) != .none
                            ) {
                                model.setFixture(kind, url: nil)
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingControl(_ spec: PluginSettingSpec) -> some View {
        switch spec.kind {
        case .toggle:
            Toggle(PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage), isOn: Binding(
                get: {
                    if case .bool(let value) = model.settingValue(spec) { return value }
                    return spec.default
                },
                set: { model.setSetting(spec, value: .bool($0)) }
            ))
            .toggleStyle(.switch)
            .accessibilityLabel(Text(PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage)))
        case .select:
            HStack(spacing: DesignTokens.Spacing.sm) {
                LauncherControlLabel(text: PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage))
                Picker(PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage), selection: Binding(
                    get: { PreviewLauncherFormat.settingText(model.settingValue(spec), language: model.uiLanguage) },
                    set: { model.setSetting(spec, value: .string($0)) }
                )) {
                    ForEach(spec.options, id: \.value) { option in
                        Text(PreviewLauncherFormat.optionTitle(option, language: model.uiLanguage)).tag(option.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(Text(PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage)))
            }
        case .number:
            if let minimum = spec.min, let maximum = spec.max, minimum.isFinite, maximum.isFinite,
               minimum < maximum {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    LauncherControlLabel(text: PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage))
                    Slider(value: Binding(
                        get: { numberValue(spec) },
                        set: { model.setSetting(spec, value: .number($0)) }
                    ), in: minimum...maximum, step: (spec.step ?? 1) > 0 ? (spec.step ?? 1) : 1)
                    .accessibilityLabel(Text(PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage)))
                    Text(PreviewLauncherFormat.settingText(model.settingValue(spec), language: model.uiLanguage))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
            } else {
                TextField(PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage), text: Binding(
                    get: { PreviewLauncherFormat.settingText(model.settingValue(spec), language: model.uiLanguage) },
                    set: { text in
                        if let value = Double(text) { model.setSetting(spec, value: .number(value)) }
                    }
                ))
                .accessibilityLabel(Text(PreviewLauncherFormat.settingTitle(spec, language: model.uiLanguage)))
            }
        }
    }

    private func numberValue(_ spec: PluginSettingSpec) -> Double {
        if case .number(let value) = model.settingValue(spec) { return value }
        if let minimum = spec.min { return minimum }
        return 0
    }

    private var clockEnabled: Bool {
        model.displayedDraft?.clock.isEnabled ?? false
    }

    private var validCustomAdvance: Double? {
        guard let value = Double(customAdvanceText), value.isFinite, value > 0, value <= 86_400_000 else { return nil }
        return value
    }

    private func chooseFixture(_ kind: PreviewScenarioDraft.FixtureKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = t("Choose File…")
        panel.message = t("Choose a fixture file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setFixture(kind, url: url)
    }

    private func launcherCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().launcherCard(material: state.environment.material)
    }

    private func t(_ key: String) -> String { model.t(key) }
}
