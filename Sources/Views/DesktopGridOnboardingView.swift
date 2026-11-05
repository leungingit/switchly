//
//  DesktopGridOnboardingView.swift
//  Switchly
//
//  Standalone prerequisite window for the desktop grid (T18, D20, R6).
//
//  It is deliberately *not* part of the first-launch OnboardingView: the
//  first launch is about two permissions, this window is about the seven
//  conditions the grid needs, and it can be reopened from Preferences at any
//  time. It only reads state — every fix happens in System Settings, which the
//  per-row button opens. Closing it never marks anything as done.
//

import SwiftUI
import AppKit

// MARK: - Window

@MainActor
final class DesktopGridOnboardingWindow {
    private static var window: NSWindow?
    private static var model: GridPrerequisiteViewModel?

    /// Shows the window, or brings the existing one forward. Safe to call
    /// repeatedly from the settings tab and the menu.
    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = GridPrerequisiteViewModel()
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.center()
        w.title = SettingsService.shared.loadSettings().language.localizedString("Grid setup")
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = .clear
        w.isOpaque = false
        w.isMovableByWindowBackground = true
        // Menu bar apps are inactive, and AppKit suppresses tooltips for
        // inactive apps (see AppDelegate.openPreferences).
        w.allowsToolTipsWhenApplicationIsInactive = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(
            rootView: DesktopGridOnboardingView(model: model) {
                DesktopGridOnboardingWindow.close()
            }
        )

        window = w
        self.model = model
        model.startObserving()
        model.refreshSoon()

        Motion.fadeInWindow(w)
        NSApp.activate(ignoringOtherApps: true)
        AppLogger.info("Desktop grid onboarding window shown")
    }

    static func close() {
        model?.stopObserving()
        model = nil
        window?.close()
        window = nil
        AppLogger.info("Desktop grid onboarding window closed")
    }
}

// MARK: - View

struct DesktopGridOnboardingView: View {
    @ObservedObject var model: GridPrerequisiteViewModel
    let onClose: () -> Void

    private var language: AppLanguage { model.language }

    /// Same glass source as Preferences / Statistics, refreshed on change.
    @State private var settings = SettingsService.shared.loadSettings()

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.4)
                ScrollView {
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        ForEach(GridPrerequisite.allCases, id: \.self) { prerequisite in
                            stepRow(prerequisite)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.vertical, DesignTokens.Spacing.lg)
                }
                Divider().opacity(0.4)
                footer
            }
        }
        // Fill the window below the title-bar safe area; a fixed 600 pt
        // height plus that inset pushed the footer out of the window.
        .frame(width: 640)
        .frame(maxHeight: .infinity)
        .modifier(WindowCrystalModifier(density: settings.windowGlassDensity,
                                        material: settings.crystalMaterial, style: .preferences))
        .preferredColorScheme(settings.theme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            settings = SettingsService.shared.loadSettings()
        }
        .onAppear { model.refreshSoon() }
        .onDisappear { model.stopObserving() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(t("Set up the desktop grid"))
                .font(.title2.weight(.semibold))

            Text(t("The grid relies on macOS permissions and settings. Switchly re-checks when you come back to it."))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.md) {
                Text(model.snapshot.summary(language: language))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()

                ProgressView(
                    value: Double(model.snapshot.metCount),
                    total: Double(max(1, model.snapshot.totalCount))
                )
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .frame(maxWidth: .infinity)
                .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.stateDuration)),
                           value: model.snapshot.metCount)
                .accessibilityLabel(Text(t("Prerequisites met")))

                Button(t("Re-check")) {
                    model.refreshSoon()
                }
                .disabled(model.isRefreshing)
            }
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.lg)
    }

    // MARK: - Steps

    /// Met steps fold to a single line (D61-A), so the window's attention
    /// stays on what is still missing.
    private func stepRow(_ prerequisite: GridPrerequisite) -> some View {
        let state = model.snapshot.state(of: prerequisite)
        let folded = state == .met
        return HStack(alignment: folded ? .center : .top, spacing: DesignTokens.Spacing.md) {
            indexBadge(for: prerequisite, state: state)

            VStack(alignment: .leading, spacing: folded ? 0 : 2) {
                Text(prerequisite.title(language: language))
                    .font(folded ? DesignTokens.Typography.gridCard : .body.weight(.semibold))
                    .foregroundColor(folded ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !folded {
                    Text(state == .undetectable
                         ? prerequisite.undetectableDetail(language: language)
                         : prerequisite.detail(language: language))
                        .font(DesignTokens.Typography.gridMeta)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(state.statusText(language: language))
                        .font(DesignTokens.Typography.gridMeta.weight(.semibold))
                        .foregroundColor(color(for: state))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if folded {
                Text(state.statusText(language: language))
                    .font(DesignTokens.Typography.gridMeta.weight(.semibold))
                    .foregroundColor(color(for: state))
                    .fixedSize()
            } else if let action = actionTitle(for: prerequisite) {
                Button(action) {
                    model.openSettings(for: prerequisite)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, folded ? DesignTokens.Spacing.xs + 2 : DesignTokens.Spacing.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .fill(Color.appearanceAware(dark: .white.opacity(folded ? 0.03 : 0.06),
                                            light: .white.opacity(folded ? 0.30 : 0.55)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(borderColor(for: state), lineWidth: DesignTokens.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(prerequisite.title(language: language)), \(state.statusText(language: language))"
        )
    }

    private func indexBadge(for prerequisite: GridPrerequisite, state: GridPrerequisiteState) -> some View {
        let index = (GridPrerequisite.allCases.firstIndex(of: prerequisite) ?? 0) + 1
        return Group {
            switch state {
            case .met:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(DesignTokens.Grid.Status.ok))
            case .undetectable:
                Text("?")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5))
            case .unmet:
                Text("\(index)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(DesignTokens.Grid.Status.warn)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(DesignTokens.Grid.Status.warn.opacity(0.7), lineWidth: 1.5))
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private func actionTitle(for prerequisite: GridPrerequisite) -> String? {
        guard prerequisite.hasAction else { return nil }
        return prerequisite.opensMissionControl ? t("Open Mission Control") : t("Open System Settings")
    }

    private func color(for state: GridPrerequisiteState) -> Color {
        switch state {
        case .met: return DesignTokens.Grid.Status.ok
        case .unmet: return DesignTokens.Grid.Status.warn
        case .undetectable: return .secondary
        }
    }

    private func borderColor(for state: GridPrerequisiteState) -> Color {
        switch state {
        case .met: return DesignTokens.Grid.Status.ok.opacity(0.35)
        case .unmet: return DesignTokens.Grid.Status.warn.opacity(0.45)
        case .undetectable: return Color.appearanceAware(dark: .white.opacity(0.12), light: .black.opacity(0.08))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text(allMet
                 ? t("All set. You can start using the desktop grid.")
                 : t("Closing this window does not mark anything as done."))
                .font(DesignTokens.Typography.gridMeta)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(t("Close"), action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.lg)
    }

    private var allMet: Bool {
        model.snapshot.metCount == model.snapshot.totalCount
    }

    private func t(_ key: String) -> String {
        language.localizedString(key)
    }
}
