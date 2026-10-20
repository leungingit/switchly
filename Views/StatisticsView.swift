//
//  StatisticsView.swift
//  Switchly
//
//  Statistics window content: usage frequency first, then the estimated
//  savings of using shortcuts instead of the mouse.
//
//  See docs/plan/2026-09-29-statistics-panel.md (v3).
//

import SwiftUI

struct StatisticsView: View {
    @StateObject private var model: StatisticsViewModel
    @State private var settings = SettingsService.shared.loadSettings()
    @State private var showClearConfirmation = false

    /// Constructed on the main actor: the view model is main-actor isolated.
    @MainActor
    init() {
        _model = StateObject(wrappedValue: StatisticsViewModel())
    }

    /// Renders against an injected model -- SwiftUI previews, snapshot tests
    /// and anything that wants the panel backed by a scratch store.
    @MainActor
    init(model: StatisticsViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            panelBackground
                .ignoresSafeArea()

            // No scrolling: the report is meant to be read at a glance, so the
            // sections are sized to fit the window on a 13" MacBook (878 pt
            // screen). The small spacing token between sections is deliberate:
            // the report is ~30 pt taller than the 810 pt window with the
            // medium token, which used to clip the footer. Snapshot tests
            // render this exact layout offscreen.
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                header
                EfficiencyHighlightRow(summary: model.rangeSummary,
                                       rangeTitle: rangeTitle,
                                       language: model.language)
                frequencySection
                savingsSection
                if !model.isEmpty {
                    EfficiencyDetailTable(flows: model.flows,
                                          summary: model.rangeSummary,
                                          language: model.language)
                    summaryCards
                }
                footer
            }
            .padding(.top, DesignTokens.Spacing.lg)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.md)
            // Top-anchored: the window is resizable, and a taller window must
            // grow the background below the report, not float it mid-air.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 840, minHeight: 810)
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            settings = SettingsService.shared.loadSettings()
            ThemeApplier.apply(settings.theme)
        }
        .alert(isPresented: $showClearConfirmation) {
            Alert(title: Text(t("Clear Statistics...")),
                  message: Text(t("This permanently deletes all locally recorded counts.")),
                  primaryButton: .destructive(Text(t("Clear"))) { model.clear() },
                  secondaryButton: .cancel(Text(t("Cancel"))))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t("Statistics"))
                .font(.system(size: 20, weight: .semibold))
            Spacer()
            Picker("", selection: $model.granularity) {
                Text(t("Day")).tag(StatisticsGranularity.day)
                Text(t("Week")).tag(StatisticsGranularity.week)
                Text(t("Month")).tag(StatisticsGranularity.month)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
    }

    // MARK: Chart

    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            StatisticsLegendView(series: allSeries,
                                 isVisible: { model.isVisible($0) },
                                 toggle: { model.toggleSeries($0) })

            if model.isEmpty {
                emptyState
            } else {
                StatisticsChartView(labels: model.bucketLabels,
                                    series: visibleSeries,
                                    style: .line,
                                    valueFormat: .count)
                    .frame(height: 140)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .cardSurface(fill: Color.crystalSurfaceBase.opacity(0.10), material: settings.crystalMaterial)
        .crystalSpecularRim(cornerRadius: DesignTokens.Radius.card, material: settings.crystalMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text(t("No data yet"))
                .font(.system(size: 13, weight: .medium))
            Text(t("Open the preview once with your shortcut, then come back."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
    }

    private var savingsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(t("Estimated savings"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if model.isEmpty {
                Text(t("No data yet"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 52)
            } else {
                StatisticsChartView(labels: model.bucketLabels,
                                    series: [StatisticsSeries(id: "savings",
                                                              title: t("Estimated savings"),
                                                              color: .accentColor,
                                                              values: model.savedSecondsByBucket,
                                                              isDashed: false)],
                                    style: .bar,
                                    valueFormat: .seconds,
                                    // Bars only: the X dates repeat the
                                    // frequency chart directly above, and the
                                    // reclaimed inset gives the bars ~60%
                                    // more height in the same footprint.
                    insets: StatisticsChartInsets(bottom: 6),
                    showsXLabels: false)
                    .frame(height: 52)
            }
        }
    }

    // MARK: Series

    private var allSeries: [StatisticsSeries] {
        [
            StatisticsSeries(id: StatisticsViewModel.previewKeyboardID,
                             title: t("Preview · shortcut"),
                             color: .accentColor,
                             values: model.seriesValues.previewKeyboard,
                             isDashed: false),
            StatisticsSeries(id: StatisticsViewModel.previewPointerID,
                             title: t("Preview · mouse"),
                             color: Color(nsColor: .secondaryLabelColor),
                             values: model.seriesValues.previewPointer,
                             isDashed: true),
            StatisticsSeries(id: StatisticsViewModel.quickSwitchID,
                             title: t("Quick switch"),
                             color: .green,
                             values: model.seriesValues.quickSwitch,
                             isDashed: false),
            StatisticsSeries(id: StatisticsViewModel.workspaceID,
                             title: t("Workspace"),
                             color: .purple,
                             values: model.seriesValues.workspace,
                             isDashed: false),
            StatisticsSeries(id: StatisticsViewModel.committedKeyboardID,
                             title: t("Confirmed · keyboard"),
                             color: .orange,
                             values: model.seriesValues.committedKeyboard,
                             isDashed: false),
            StatisticsSeries(id: StatisticsViewModel.committedPointerID,
                             title: t("Confirmed · mouse"),
                             color: Color(nsColor: .tertiaryLabelColor),
                             values: model.seriesValues.committedPointer,
                             isDashed: true)
        ]
    }

    private var visibleSeries: [StatisticsSeries] {
        allSeries.filter { model.isVisible($0.id) }
    }

    // MARK: Cards + footer

    private var summaryCards: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            summaryCard(t("Today"), model.todaySummary)
            summaryCard(t("This week"), model.weekSummary)
            summaryCard(t("This month"), model.monthSummary)
            summaryCard(t("All time"), model.allTimeSummary)
        }
    }

    private func summaryCard(_ title: String, _ summary: EfficiencySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text("≈ " + EfficiencyText.duration(summary.savedSeconds, language: model.language))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(String(format: t("%d shortcuts · %d mouse"), summary.keyboardCount, summary.pointerCount))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(fill: Color.crystalSurfaceBase.opacity(0.10), material: settings.crystalMaterial)
        .crystalSpecularRim(cornerRadius: DesignTokens.Radius.card, material: settings.crystalMaterial)
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text(rangeTitle + " · " + String(format: t("Data kept for %d days"), UsageStatisticsService.retentionDays))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            if !model.isEnabled {
                Text(t("Usage statistics are turned off in Preferences."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Button(t("Clear Statistics...")) {
                showClearConfirmation = true
            }
            .controlSize(.small)
        }
    }

    private var panelBackground: some View {
        WindowGlassSurface(
            opacity: settings.preferencesGlassOpacity,
            material: settings.crystalMaterial,
            style: .statistics
        )
    }

    private var rangeTitle: String {
        let count = model.granularity.defaultRange
        switch model.granularity {
        case .day: return String(format: t("Last %d days"), count)
        case .week: return String(format: t("Last %d weeks"), count)
        case .month: return String(format: t("Last %d months"), count)
        }
    }

    private func t(_ key: String) -> String {
        model.language.localizedString(key)
    }
}
