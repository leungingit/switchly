//
//  DesktopGridPreferencesSection.swift
//  Switchly
//
//  The "Desktop Grid" preferences tab (T17).
//
//  One page, vertical sections (D21): master switch → prerequisites (one
//  shared snapshot, T20) → overview style C/B with a small preview →
//  background cream/white → onboarding entry. Everything is persisted through
//  PreferencesViewModel / SettingsService; no view here writes UserDefaults.
//

import SwiftUI
import AppKit

struct DesktopGridPreferencesSection: View {
    /// The current settings snapshot. The section never writes UserDefaults
    /// itself: `onSettingsChange` is `PreferencesViewModel.updateSettings`,
    /// which saves through `SettingsService` and posts `.settingsDidChange`.
    let settings: AppSettings
    let onSettingsChange: (AppSettings) -> Void

    @ObservedObject var prerequisites: GridPrerequisiteViewModel

    /// Opens the standalone prerequisite window (R6). Injected by the
    /// preferences view so this section never owns window lifecycle.
    let openOnboarding: () -> Void

    private var language: AppLanguage { settings.language }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg + 2) {
                header

                settingsGroup(t("Status & switch")) {
                    toggleRow(
                        t("Enable grid desktops"),
                        systemImage: "square.grid.3x3",
                        isOn: gridEnabledBinding,
                        help: t("Switch among nine desktops with a four-finger swipe or ⌃1–9.")
                    )
                    toggleRow(
                        t("Five-finger swipe down opens the overview"),
                        systemImage: "hand.draw",
                        isOn: overviewGestureBinding,
                        help: t("Three fingers stay free for dragging windows.")
                    )
                    .disabled(!settings.gridEnabled)
                    toggleRow(
                        t("Take over the system's four-finger swipes"),
                        systemImage: "hand.raised",
                        isOn: interceptBinding,
                        help: t("The system's four-finger swipes stop while the grid is on. Swipe up with five fingers to open Mission Control.")
                    )
                    .disabled(!settings.gridEnabled)
                    toggleRow(
                        t("Natural swipe direction"),
                        systemImage: "arrow.left.arrow.right",
                        isOn: naturalSwipeBinding,
                        help: t("On: the desktop follows your fingers, like the system's four-finger swipe. Off: swipe toward the desktop you want.")
                    )
                    .disabled(!settings.gridEnabled)
                    toggleRow(
                        t("Show desktop map when four fingers rest"),
                        systemImage: "hand.point.up.left",
                        isOn: holdLocateBinding,
                        help: t("Rest four fingers on the trackpad for a second to see which desktop you are on. Nothing switches.")
                    )
                    .disabled(!settings.gridEnabled)
                    if hasCustomLayout {
                        Text(t("The system slide animation follows the real desktop order, so it can differ from your arrangement. Turn on Reduce Motion in System Settings to make it a fade."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                prerequisitesGroup
                styleGroup
                backgroundGroup
                onboardingGroup
            }
            .padding(DesignTokens.Spacing.xl)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(t("Desktop Grid"))
                .font(.title2.weight(.semibold))
            Text(t("A 3×3 overview of your macOS desktops, with gesture and keyboard switching."))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Prerequisites (single source: GridPrerequisiteViewModel)

    private var prerequisitesGroup: some View {
        settingsGroup(t("Prerequisites")) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: prerequisitesMet ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(prerequisitesMet ? DesignTokens.Grid.Status.ok : DesignTokens.Grid.Status.warn)
                    .frame(width: 22)

                Text(prerequisites.snapshot.summary(language: language))
                    .font(.body)
                    .lineLimit(1)

                Spacer(minLength: DesignTokens.Spacing.sm)

                Button(t("Re-check")) {
                    prerequisites.refreshSoon()
                }
                .disabled(prerequisites.isRefreshing)

                Button(t("Open guide")) {
                    openOnboarding()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ForEach(GridPrerequisite.allCases, id: \.self) { prerequisite in
                prerequisiteRow(prerequisite)
            }
        }
    }

    private var prerequisitesMet: Bool {
        prerequisites.snapshot.metCount == prerequisites.snapshot.totalCount
    }

    private func prerequisiteRow(_ prerequisite: GridPrerequisite) -> some View {
        let state = prerequisites.snapshot.state(of: prerequisite)
        return HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: symbol(for: state))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color(for: state))
                .frame(width: 22)

            Text(prerequisite.title(language: language))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Text(state.statusText(language: language))
                .font(DesignTokens.Typography.gridMeta.weight(.semibold))
                .foregroundColor(color(for: state))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(prerequisite.title(language: language)), \(state.statusText(language: language))"
        )
    }

    private func symbol(for state: GridPrerequisiteState) -> String {
        switch state {
        case .met: return "checkmark.circle.fill"
        case .unmet: return "exclamationmark.circle.fill"
        case .undetectable: return "questionmark.circle"
        }
    }

    private func color(for state: GridPrerequisiteState) -> Color {
        switch state {
        case .met: return DesignTokens.Grid.Status.ok
        case .unmet: return DesignTokens.Grid.Status.warn
        case .undetectable: return .secondary
        }
    }

    // MARK: - Style

    private var styleGroup: some View {
        settingsGroup(t("Overview style")) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                ForEach(GridStyle.allCases, id: \.self) { style in
                    styleCard(style)
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private func styleCard(_ style: GridStyle) -> some View {
        let selected = settings.gridStyle == style
        return Button {
            save { $0.gridStyle = style }
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                GridStylePreview(style: style, background: settings.gridBackground)
                    .frame(height: 84)

                Text(style.displayName(language: language))
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(style == .c ? t("Default · fills the screen, centre cell enlarged")
                                 : t("Optional · one centred panel"))
                    .font(DesignTokens.Typography.gridMeta)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Spacing.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .fill(Color.appearanceAware(dark: .white.opacity(0.06), light: .black.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.appearanceAware(dark: .white.opacity(0.12), light: .black.opacity(0.08)),
                        lineWidth: selected ? 2 : DesignTokens.hairline
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.displayName(language: language))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Background

    private var backgroundGroup: some View {
        settingsGroup(t("Background")) {
            settingRow(
                t("Overview backdrop"),
                systemImage: "paintpalette",
                help: t("Backdrop tint of the overview in light appearance. Dark appearance always uses graphite.")
            ) {
                Picker("", selection: gridBackgroundBinding) {
                    ForEach(GridBackground.allCases, id: \.self) { background in
                        Text(background.displayName(language: language)).tag(background)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            HStack(spacing: DesignTokens.Spacing.md) {
                GridBackgroundSwatch(background: settings.gridBackground)
                    .frame(width: 96, height: 56)

                Text(settings.gridBackground.displayName(language: language))
                    .font(.callout)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Onboarding entry

    private var onboardingGroup: some View {
        settingsGroup(t("Setup guide")) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "checklist")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Prerequisite setup guide"))
                        .font(.body)
                    Text(t("Opens a separate window with each step and a link to the right System Settings pane."))
                        .font(DesignTokens.Typography.gridMeta)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                Button(t("Open guide"), action: openOnboarding)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Saving

    /// Applies one edit to a copy and hands it to the view model, which saves
    /// through `SettingsService` and posts `.settingsDidChange`.
    private func save(_ edit: (inout AppSettings) -> Void) {
        var updated = settings
        edit(&updated)
        onSettingsChange(updated)
    }

    // MARK: - Bindings (SettingsService through the view model)

    private var gridEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.gridEnabled },
            set: { newValue in
                save { $0.gridEnabled = newValue }
            }
        )
    }

    private var interceptBinding: Binding<Bool> {
        Binding(
            get: { settings.gridInterceptSystemGestures },
            set: { newValue in
                save { $0.gridInterceptSystemGestures = newValue }
            }
        )
    }

    private var hasCustomLayout: Bool {
        settings.gridLayouts.values.contains { $0 != DesktopGridLayout.identity }
    }

    private var holdLocateBinding: Binding<Bool> {
        Binding(
            get: { settings.gridHoldLocateEnabled },
            set: { newValue in
                save { $0.gridHoldLocateEnabled = newValue }
            }
        )
    }

    private var naturalSwipeBinding: Binding<Bool> {
        Binding(
            get: { settings.gridNaturalSwipeDirection },
            set: { newValue in
                save { $0.gridNaturalSwipeDirection = newValue }
            }
        )
    }

    private var overviewGestureBinding: Binding<Bool> {
        Binding(
            get: { settings.gridOverviewGestureEnabled },
            set: { newValue in
                save { $0.gridOverviewGestureEnabled = newValue }
            }
        )
    }

    private var gridBackgroundBinding: Binding<GridBackground> {
        Binding(
            get: { settings.gridBackground },
            set: { newValue in
                save { $0.gridBackground = newValue }
            }
        )
    }

    // MARK: - Shared row chrome (matches PreferencesView)

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                content()
            }
            .cardSurface(
                fill: Color.crystalSurfaceBase.opacity(0.10),
                cornerRadius: DesignTokens.Radius.card,
                material: settings.crystalMaterial
            )
            .crystalSpecularRim(
                cornerRadius: DesignTokens.Radius.card,
                material: settings.crystalMaterial
            )
        }
    }

    private func settingRow<Content: View>(
        _ title: String,
        systemImage: String,
        help: String? = nil,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 22)

            Text(title)
                .font(.body)

            if let help {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .help(help)
                    .accessibilityLabel(Text(help))
            }

            Spacer(minLength: DesignTokens.Spacing.lg)

            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func toggleRow(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        help: String? = nil
    ) -> some View {
        settingRow(title, systemImage: systemImage, help: help) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(Text(title))
        }
    }

    private func t(_ key: String) -> String {
        language.localizedString(key)
    }
}

// MARK: - Style preview

/// Small schematic of the two overview layouts. Uses the same wall tokens as
/// the real panel so the preview cannot drift from the overview's palette.
private struct GridStylePreview: View {
    let style: GridStyle
    let background: GridBackground

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? DesignTokens.Grid.Wall.graphite
                                : (background == .cream ? DesignTokens.Grid.Wall.cream : DesignTokens.Grid.Wall.white),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                cells(in: geo.size)
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous)
                    .strokeBorder(DesignTokens.Grid.Window.edge, lineWidth: DesignTokens.hairline)
            )
        }
        .accessibilityHidden(true)
    }

    private func cells(in size: CGSize) -> some View {
        let inset: CGFloat = 8
        let gap: CGFloat = 3
        let width = max(1, size.width - inset * 2)
        let height = max(1, size.height - inset * 2)
        let cellWidth = style == .c
            ? (width - gap * 2) / DesignTokens.Grid.columnFractions.reduce(0, +)
            : (width - gap * 2) / 3
        let cellHeight = (height - gap * 2) / 3

        return VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        let number = row * 3 + column + 1
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(fill(for: number))
                            .frame(
                                width: style == .c
                                    ? cellWidth * DesignTokens.Grid.columnFractions[column]
                                    : cellWidth,
                                height: cellHeight
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(
                                        stroke(for: number),
                                        style: StrokeStyle(lineWidth: 1, dash: number == 9 ? [2, 2] : [])
                                    )
                            )
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .rotation3DEffect(
            .degrees(style == .c ? DesignTokens.Grid.tilt : 0),
            axis: (x: 1, y: 0, z: 0),
            anchor: .center,
            perspective: style == .c ? DesignTokens.Grid.perspective : 0
        )
        .scaleEffect(style == .c ? 0.92 : 1)
    }

    private func fill(for number: Int) -> Color {
        if number == 5 { return Color.accentColor.opacity(0.75) }
        return Color.appearanceAware(dark: .white.opacity(0.14), light: .white.opacity(0.72))
    }

    private func stroke(for number: Int) -> Color {
        number == 9 ? Color.accentColor.opacity(0.8) : Color.clear
    }
}

/// Flat swatch of the chosen overview backdrop, so cream and white are
/// distinguishable side by side instead of only by name.
private struct GridBackgroundSwatch: View {
    let background: GridBackground

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous)
            .fill(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? DesignTokens.Grid.Wall.graphite
                        : (background == .cream ? DesignTokens.Grid.Wall.cream : DesignTokens.Grid.Wall.white),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous)
                    .strokeBorder(DesignTokens.Grid.Window.edge, lineWidth: DesignTokens.hairline)
            )
            .accessibilityHidden(true)
    }
}
