import SwiftUI

/// 左栏「模拟 Dock」卡片：把本体 Dock 预览相关设置（窗口数、布局、卡片宽度、玻璃材质、
/// 密度、水晶色、卡片底色）放到预览里调节。只改右栏展示，不写入场景。
struct PreviewLauncherMockDockSettingsView: View {
    @ObservedObject var model: PreviewLauncherModel
    @ObservedObject var state: PluginPreviewState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            LauncherControlLabel(text: t("Mock Dock"))

            Stepper(value: $model.mockDock.windowCount, in: PreviewMockWindows.windowCountRange) {
                Text(String(format: t("Mock Dock windows: %d"), model.mockDock.windowCount))
                    .font(.callout)
            }
            .accessibilityLabel(Text(t("Mock Dock windows")))

            row(t("Dock layout")) {
                Picker(t("Dock layout"), selection: $model.mockDock.layout) {
                    ForEach(DockPreviewLayout.allCases, id: \.self) { layout in
                        Text(t(layout.title)).tag(layout)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            slider(t("Card width"),
                   value: $model.mockDock.cardWidth,
                   range: PreviewMockDockOptions.cardWidthRange,
                   displayed: String(format: "%.0f pt", model.mockDock.cardWidth))

            Toggle(t("Glass"), isOn: Binding(
                get: { model.mockDock.glassEnabled ?? state.environment.glassEnabled },
                set: { model.mockDock.glassEnabled = $0 }
            ))
            .font(.callout)
            .accessibilityLabel(Text(t("Glass")))

            row(t("Glass material")) {
                Picker(t("Glass material"), selection: $model.mockDock.glassStyle) {
                    // 开关在上面的「玻璃」；这里只选清透/磨砂。
                    ForEach([GlassStyle.transparent, .frosted], id: \.self) { style in
                        Text(style.displayName(language: model.uiLanguage)).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            slider(t("Glass density"),
                   value: Binding(
                       get: { model.mockDock.density ?? AppSettings.default.panelGlassDensity },
                       set: { model.mockDock.density = $0 }
                   ),
                   range: 0...1,
                   displayed: String(format: "%.0f%%",
                                     (model.mockDock.density ?? AppSettings.default.panelGlassDensity) * 100))

            row(t("Crystal tint")) {
                ColorPicker(t("Crystal tint"), selection: $model.mockDock.tintColor, supportsOpacity: false)
                    .labelsHidden()
            }

            slider(t("Crystal tint strength"),
                   value: $model.mockDock.tintStrength,
                   range: CrystalMaterial.Range.panelTint,
                   displayed: String(format: "%.0f%%", model.mockDock.tintStrength * 100))

            row(t("Card background")) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ColorPicker(t("Card background"),
                                selection: Binding(
                                    get: { model.mockDock.windowCardBackdrop.resolvedColor() },
                                    set: { model.mockDock.windowCardBackdrop.tintColor = $0 }
                                ),
                                supportsOpacity: false)
                        .labelsHidden()
                    Button(t("Follow System")) {
                        model.mockDock.windowCardBackdrop = .followingSystem
                    }
                    .font(.caption)
                    .disabled(model.mockDock.windowCardBackdrop.tintColor == nil)
                }
            }

            Text(t("Mock Dock options only change this panel; they are not saved to the scenario."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .launcherCard(material: state.environment.material)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title).font(.callout)
            Spacer(minLength: DesignTokens.Spacing.sm)
            content()
        }
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        displayed: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title).font(.callout)
            Slider(value: value, in: range)
                .accessibilityLabel(Text(title))
            Text(displayed)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func t(_ key: String) -> String { model.t(key) }
}
