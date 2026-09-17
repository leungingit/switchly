//
//  StatisticsEfficiencyView.swift
//  Switchly
//
//  The "how much did shortcuts save me" half of the panel: headline cards and
//  the per-feature table. The baseline itself is configured in Preferences
//  (BaselinePicker); the panel only reflects the chosen values.
//
//  Every number here is an estimate; the panel says so once.
//

import SwiftUI

/// Shared duration formatting so the cards, the table and the footer agree.
enum EfficiencyText {
    static func duration(_ seconds: Double, language: AppLanguage) -> String {
        let parts = UsageStatisticsFormatter.duration(seconds: seconds)
        switch parts.unit {
        case .seconds:
            return String(format: language.localizedString("%d sec"), parts.primary)
        case .minutes:
            if parts.secondary == 0 {
                return String(format: language.localizedString("%d min"), parts.primary)
            }
            return String(format: language.localizedString("%d min %d sec"), parts.primary, parts.secondary)
        case .hours:
            if parts.secondary == 0 {
                return String(format: language.localizedString("%d hr"), parts.primary)
            }
            return String(format: language.localizedString("%d hr %d min"), parts.primary, parts.secondary)
        }
    }

    static func feature(_ feature: EfficiencyFeature, language: AppLanguage) -> String {
        switch feature {
        case .preview: return language.localizedString("Preview + switch")
        case .quickSwitch: return language.localizedString("Quick switch")
        case .workspace: return language.localizedString("Workspace")
        }
    }

    static func preset(_ preset: EfficiencyBaselinePreset, language: AppLanguage) -> String {
        switch preset {
        case .conservative: return language.localizedString("Conservative")
        case .standard: return language.localizedString("Default")
        case .aggressive: return language.localizedString("Aggressive")
        case .custom: return language.localizedString("Custom")
        }
    }
}

// MARK: - Headline

struct EfficiencyHighlightRow: View {
    let summary: EfficiencySummary
    let rangeTitle: String
    let language: AppLanguage

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(rangeTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("≈ " + EfficiencyText.duration(summary.savedSeconds, language: language))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(String(format: language.localizedString("%d shortcuts · %d mouse"),
                                summary.keyboardCount, summary.pointerCount))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(language.localizedString("Efficiency gain"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(UsageStatisticsFormatter.multiple(summary.multiple) + "×")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(String(format: language.localizedString("Mouse-only would take %@"),
                                EfficiencyText.duration(summary.baselineSeconds, language: language)))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(String(format: language.localizedString("Keyboard share %@"),
                                UsageStatisticsFormatter.percent(summary.keyboardShare)))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(fill: Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: DesignTokens.hairline)
            )
    }
}

// MARK: - Detail table

struct EfficiencyDetailTable: View {
    let flows: [EfficiencyFlow]
    let summary: EfficiencySummary
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(language.localizedString("By feature"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                header
                ForEach(flows, id: \.feature) { flow in
                    row(flow)
                }
                Divider().opacity(0.5)
                totalRow
            }
            .cardSurface(fill: Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: DesignTokens.hairline)
            )
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell(language.localizedString("Feature"), width: nil, alignment: .leading, isHeader: true)
            cell(language.localizedString("Keyboard"), width: 80, alignment: .trailing, isHeader: true)
            cell(language.localizedString("Mouse"), width: 80, alignment: .trailing, isHeader: true)
            cell(language.localizedString("Per use"), width: 90, alignment: .trailing, isHeader: true)
            cell(language.localizedString("Saved"), width: 130, alignment: .trailing, isHeader: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func row(_ flow: EfficiencyFlow) -> some View {
        HStack(spacing: 0) {
            cell(EfficiencyText.feature(flow.feature, language: language), width: nil, alignment: .leading)
            cell(String(flow.keyboardCount), width: 80, alignment: .trailing)
            cell(String(flow.pointerCount), width: 80, alignment: .trailing)
            cell(EfficiencyText.duration(flow.perUseSavedSeconds, language: language), width: 90, alignment: .trailing)
            cell(EfficiencyText.duration(flow.savedSeconds, language: language), width: 130, alignment: .trailing)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 6)
    }

    private var totalRow: some View {
        HStack(spacing: 0) {
            cell(language.localizedString("Total"), width: nil, alignment: .leading, isHeader: true)
            cell(String(summary.keyboardCount), width: 80, alignment: .trailing, isHeader: true)
            cell(String(summary.pointerCount), width: 80, alignment: .trailing, isHeader: true)
            cell("—", width: 90, alignment: .trailing, isHeader: true)
            cell(EfficiencyText.duration(summary.savedSeconds, language: language)
                    + " · " + UsageStatisticsFormatter.multiple(summary.multiple) + "×",
                 width: 130, alignment: .trailing, isHeader: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func cell(_ text: String,
                      width: CGFloat?,
                      alignment: Alignment,
                      isHeader: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: isHeader ? .semibold : .regular))
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .lineLimit(1)
    }
}

// MARK: - Baseline picker

/// Rendered in Preferences only: the statistics panel stays read-only and
/// reflects whatever is chosen here.
struct BaselinePicker: View {
    @ObservedObject var model: StatisticsViewModel
    @State private var isExpanded = false

    private var language: AppLanguage { model.language }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Text(language.localizedString("Efficiency baseline"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .help(assumptionSummary)

                Picker("", selection: presetBinding) {
                    ForEach(EfficiencyBaselinePreset.allCases, id: \.self) { preset in
                        Text(EfficiencyText.preset(preset, language: language)).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)

                Button(language.localizedString("Adjust baseline")) {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)

                Button(language.localizedString("Restore recommended defaults")) {
                    model.restoreRecommendedBaseline()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    adjustmentRow(.preview)
                    adjustmentRow(.quickSwitch)
                    adjustmentRow(.workspace)
                    Text(language.localizedString("Savings are estimates based on your baseline"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(DesignTokens.Spacing.md)
                .cardSurface(fill: Color(nsColor: .controlBackgroundColor).opacity(0.45))
            }
        }
    }

    private var presetBinding: Binding<EfficiencyBaselinePreset> {
        Binding(get: { model.baseline.preset }, set: { model.setPreset($0) })
    }

    private var assumptionSummary: String {
        let values = model.baseline.values
        return String(format: language.localizedString("Baseline (mouse/shortcut): preview %@/%@ · quick switch %@/%@ · workspace %@/%@"),
                      format(values.previewMouseSeconds), format(values.previewKeyboardSeconds),
                      format(values.quickSwitchMouseSeconds), format(values.quickSwitchKeyboardSeconds),
                      format(values.workspaceMouseSeconds), format(values.workspaceKeyboardSeconds))
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }

    private func adjustmentRow(_ feature: EfficiencyFeature) -> some View {
        let values = model.baseline.values
        return HStack(spacing: DesignTokens.Spacing.lg) {
            Text(EfficiencyText.feature(feature, language: language))
                .font(.system(size: 11))
                .frame(width: 120, alignment: .leading)

            stepper(language.localizedString("Per shortcut"),
                    value: values.keyboardSeconds(for: feature)) { seconds in
                model.setCustomSeconds(seconds, feature: feature, keyboard: true)
            }

            stepper(language.localizedString("Per mouse action"),
                    value: values.mouseSeconds(for: feature)) { seconds in
                model.setCustomSeconds(seconds, feature: feature, keyboard: false)
            }
        }
    }

    private func stepper(_ label: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(String(format: "%.1f s", value))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
            Stepper("",
                    onIncrement: { onChange(min(60, value + 0.5)) },
                    onDecrement: { onChange(max(0.5, value - 0.5)) })
                .labelsHidden()
                .controlSize(.small)
        }
    }
}
