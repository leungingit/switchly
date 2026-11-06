import AppKit
import SwiftUI

/// Native preview shell for the injected `PluginPreviewState`. Session control,
/// worker supervision, reload policy and persistence stay outside this view.
struct PluginPreviewView: View {
    @ObservedObject var state: PluginPreviewState
    @State private var selectedSlot: PluginSlot = .center

    private let supportedSlots: Set<PluginSlot> = [.center, .bottomBar]

    init(state: PluginPreviewState, initialSlot: PluginSlot = .center) {
        self.state = state
        _selectedSlot = State(initialValue: initialSlot)
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                header
                environmentControls
                pluginArea
                diagnostics
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .frame(minWidth: 400)
        .background(shellBackground)
        .preferredColorScheme(state.environment.theme.colorScheme)
        .environment(\.locale, Locale(identifier: state.environment.language.rawValue))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Plugin Preview"))
                        .font(.title2.weight(.semibold))
                    Text(pluginIdentity)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                statusBadge
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(String(format: t("Generation %d"), state.generation))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: state.reload) {
                    Label(t("Reload"), systemImage: "arrow.clockwise")
                }
                .help(t("Reload"))

                Button(action: state.reset) {
                    Label(t("Reset"), systemImage: "arrow.counterclockwise")
                }
                .help(t("Reset"))
            }
        }
    }

    private var environmentControls: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                controlLabel("Theme")
                Picker(t("Theme"), selection: $state.environment.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName(language: state.environment.language)).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                controlLabel("Language")
                Picker(t("Language"), selection: $state.environment.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Toggle(t("Glass"), isOn: $state.environment.glassEnabled)
                    .toggleStyle(.switch)

                controlLabel("Width")
                Slider(
                    value: $state.environment.contentWidth,
                    in: PluginPreviewEnvironment.minimumContentWidth...PluginPreviewEnvironment.maximumContentWidth,
                    step: 20
                )
                .labelsHidden()
                Text("\(Int(state.environment.contentWidth)) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .cardSurface(
            fill: Color(nsColor: .controlBackgroundColor).opacity(state.environment.glassEnabled ? 0.32 : 0.88),
            cornerRadius: DesignTokens.Radius.control,
            material: state.environment.material,
            showsBorder: true
        )
    }

    private var pluginArea: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                controlLabel("Plugin area")
                Picker(t("Slot"), selection: $selectedSlot) {
                    ForEach(PluginSlot.allCases, id: \.self) { slot in
                        Text(slotName(slot)).tag(slot)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Spacer()

                Text(t(supportedSlots.contains(selectedSlot) ? "Connected" : "Component preview only"))
                    .font(.caption.weight(.medium))
                    .foregroundColor(supportedSlots.contains(selectedSlot) ? .accentColor : .secondary)
            }

            if !supportedSlots.contains(selectedSlot) {
                Label(
                    t("Switchly Dock currently connects only the center and bottom bar slots. This view still renders the shared component."),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            pluginSurface
                .padding(DesignTokens.Spacing.sm)
                .cardSurface(
                    fill: Color(nsColor: .controlBackgroundColor).opacity(state.environment.glassEnabled ? 0.26 : 0.9),
                    cornerRadius: DesignTokens.Radius.card,
                    material: state.environment.material,
                    showsBorder: true
                )
        }
    }

    @ViewBuilder
    private var pluginSurface: some View {
        let entries = state.slots[selectedSlot] ?? []
        if entries.isEmpty {
            emptyPluginArea
                .frame(width: state.environment.contentWidth)
                .frame(minHeight: 120)
        } else {
            PluginSlotSurface(
                entries: entries,
                material: state.environment.material,
                isGlassActive: state.environment.glassEnabled,
                artwork: state.artwork,
                fallback: nil
            ) { pluginID, actionID, value in
                state.perform(pluginID: pluginID, actionID: actionID, value: value)
            }
            .environment(\.pluginSceneNow, state.virtualNowSeconds.map { now in { now } })
            .frame(width: state.environment.contentWidth)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyPluginArea: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(.secondary)
            Text(t("No plugin content for this slot"))
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(t("Diagnostics"))
                    .font(.headline)
                Spacer()
                Text(t(state.status.localizationKey))
                    .font(.caption.weight(.medium))
                    .foregroundColor(statusColor)
            }

            if state.diagnostics.isEmpty {
                Text(t("No diagnostics"))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        .padding(DesignTokens.Spacing.md)
        .cardSurface(
            fill: Color(nsColor: .controlBackgroundColor).opacity(0.72),
            cornerRadius: DesignTokens.Radius.control,
            material: state.environment.material,
            showsBorder: true
        )
    }

    private var statusBadge: some View {
        Text(t(state.status.localizationKey))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .foregroundColor(statusColor)
            .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var shellBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                    .strokeBorder(Color.primary.opacity(DesignTokens.Glass.groupBorderOpacity),
                                  lineWidth: DesignTokens.hairline)
            )
    }

    private var pluginIdentity: String {
        let id = state.pluginID.isEmpty ? t("No plugin selected") : state.pluginID
        guard !state.pluginVersion.isEmpty else { return id }
        return "\(id) · \(state.pluginVersion)"
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

    private func slotName(_ slot: PluginSlot) -> String {
        switch slot {
        case .center: return t("Center")
        case .bottomBar: return t("Bottom bar")
        case .topTrailing: return t("Top trailing")
        case .titleAccessory: return t("Title accessory")
        }
    }

    private func controlLabel(_ key: String) -> some View {
        Text(t(key))
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
    }

    private func t(_ key: String) -> String {
        state.environment.language.localizedString(key)
    }
}
