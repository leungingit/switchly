//
//  PreferencesView.swift
//  Switchly
//
//  SwiftUI view for preferences window
//

import SwiftUI
import AppKit

enum PreferencesTab: Hashable {
    case general
    case apps
    case permissions
    case shortcuts
}

struct PreferencesView: View {
    @StateObject var viewModel = PreferencesViewModel()
    /// Shares the statistics panel's picker component (and its persistence
    /// path) so the two surfaces can never disagree.
    @StateObject private var statisticsModel: StatisticsViewModel
    @State private var appSearchText = ""
    @State private var selectedTab: PreferencesTab

    @MainActor
    init(initialTab: PreferencesTab = .general) {
        _selectedTab = State(initialValue: initialTab)
        _statisticsModel = StateObject(wrappedValue: StatisticsViewModel())
    }

    var body: some View {
        ZStack {
            panelBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar
                TabView(selection: $selectedTab) {
                    generalSettingsTab
                        .tabItem {
                            Label(t("General"), systemImage: "gearshape")
                        }
                        .tag(PreferencesTab.general)

                    appsSettingsTab
                        .tabItem {
                            Label(t("Apps"), systemImage: "rectangle.stack")
                        }
                        .tag(PreferencesTab.apps)

                    permissionsSettingsTab
                        .tabItem {
                            Label(t("Permissions"), systemImage: "lock.shield")
                        }
                        .tag(PreferencesTab.permissions)

                    shortcutsSettingsTab
                        .tabItem {
                            Label(t("Shortcuts"), systemImage: "keyboard")
                        }
                        .tag(PreferencesTab.shortcuts)
                }
                .background(Color.clear)
                .apply {
                    if #available(macOS 13.0, *) {
                        $0.backgroundStyle(.clear)
                            .toolbarBackground(.clear, for: .automatic)
                    } else {
                        $0
                    }
                }
                // Cross-fade the tab content on switch. The TabView is keyed
                // by the selection so the old content fades out while the new
                // one fades in.
                .id(selectedTab)
                .transition(.opacity)
            }
        }
        .frame(width: 760, height: 560)
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            viewModel.settings = SettingsService.shared.loadSettings()
        }
        .alert(isPresented: .constant(viewModel.errorMessage != nil)) {
            Alert(
                title: Text(t("Error")),
                message: Text(viewModel.errorMessage ?? ""),
                dismissButton: .default(Text(t("OK"))) {
                    viewModel.errorMessage = nil
                }
            )
        }
    }

    private var panelBackground: some View {
        ZStack {
            GlassBackground(material: .hudWindow, cornerRadius: 0)

            Color(nsColor: .windowBackgroundColor)
                .opacity(viewModel.settings.backgroundBlurOpacity * 0.6)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.white.opacity(0.02),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    private var titleBar: some View {
        HStack {
            Spacer()
            Text(t("Switchly Preferences"))
                .font(.headline)
            Spacer()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var generalSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(t("General"), subtitle: t("Preview behavior and system integration"))

                settingsGroup(t("Preview")) {
                    settingRow(t("Window source"), systemImage: "square.stack.3d.up") {
                        Picker("", selection: previewStrategyBinding) {
                            ForEach(PreviewStrategy.allCases, id: \.self) { strategy in
                                Label(strategy.displayName(language: viewModel.settings.language), systemImage: strategy.systemImageName)
                                    .tag(strategy)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 360)
                    }

                    settingRow(t("Thumbnail size"), systemImage: "rectangle.inset.filled") {
                        Picker("", selection: thumbnailSizeBinding) {
                            ForEach(ThumbnailSize.allCases, id: \.self) { size in
                                Text(size.displayName(language: viewModel.settings.language)).tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }

                    settingRow(t("Preview interaction"),
                               systemImage: "macwindow.on.rectangle",
                               help: viewModel.settings.previewInteractionMode.summary(language: viewModel.settings.language)) {
                        Picker("", selection: previewInteractionModeBinding) {
                            ForEach(PreviewInteractionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName(language: viewModel.settings.language)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 320)
                    }

                    if viewModel.settings.previewInteractionMode.showsWindowReplica {
                        settingRow(t("Preview hover delay"), systemImage: "timer") {
                            HStack(spacing: 10) {
                                Slider(value: previewReplicaHoverDelayBinding, in: 0.1...1.0, step: 0.1)
                                    .frame(width: 220)
                                Text(String(format: "%.1fs", viewModel.settings.previewReplicaHoverDelay))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                    }

                    settingRow(t("Monitor frequency"), systemImage: "speedometer") {
                        Picker("", selection: monitorFrequencyBinding) {
                            Text(t("Fast")).tag(MonitorFrequency.highPerformance)
                            Text(t("Balanced")).tag(MonitorFrequency.balanced)
                            Text(t("Quiet")).tag(MonitorFrequency.powerSaving)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }
                }

                settingsGroup(t("Pointer triggers")) {
                    toggleRow(t("Edge hotspot"),
                              systemImage: "arrow.up.to.line",
                              isOn: previewHotspotEnabledBinding,
                              help: t("Rest the pointer against the selected edge of the screen briefly to open the preview."))

                    if viewModel.settings.previewHotspotEnabled {
                        settingRow(t("Hotspot edge"), systemImage: "rectangle.dashed") {
                            Picker("", selection: previewHotspotEdgeBinding) {
                                ForEach(PreviewHotspotEdge.allCases, id: \.self) { edge in
                                    Text(edge.displayName(language: viewModel.settings.language)).tag(edge)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 300)
                        }
                    }

                    toggleRow(t("Shake to open"),
                              systemImage: "cursorarrow.rays",
                              isOn: previewShakeEnabledBinding,
                              help: t("Shake the pointer back and forth quickly, like shaking to find the macOS cursor, to open the preview."))
                }

                settingsGroup(t("Display")) {
                    toggleRow(t("Show window titles"), systemImage: "textformat", isOn: showWindowTitlesBinding)
                    toggleRow(t("Show app name"), systemImage: "app", isOn: previewInfoShowsAppNameBinding)
                    toggleRow(t("Show window number"), systemImage: "number", isOn: previewInfoShowsWindowNumberBinding)
                    toggleRow(t("Show process ID"), systemImage: "cpu", isOn: previewInfoShowsProcessIDBinding)
                    toggleRow(t("Show window size"), systemImage: "ruler", isOn: previewInfoShowsSizeBinding)
                    toggleRow(t("Show window position"), systemImage: "point.3.connected.trianglepath.dotted", isOn: previewInfoShowsPositionBinding)
                    toggleRow(t("Enable background blur"), systemImage: "sparkles", isOn: backgroundBlurBinding)
                    if viewModel.settings.enableBackgroundBlur {
                        settingRow(t("Background opacity"), systemImage: "slider.horizontal.3") {
                            HStack(spacing: 16) {
                                Slider(value: backgroundBlurOpacityBinding, in: 0...1, step: 0.05)
                                    .frame(width: 220)
                                GlassPreviewCard(
                                    opacity: viewModel.settings.backgroundBlurOpacity,
                                    cornerRadius: 8
                                )
                            }
                        }
                    }
                }

                settingsGroup(t("Appearance")) {
                    settingRow(t("Language"), systemImage: "globe") {
                        Picker("", selection: languageBinding) {
                            ForEach(AppLanguage.allCases, id: \.self) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }

                    settingRow(t("Theme"), systemImage: "circle.lefthalf.filled") {
                        Picker("", selection: themeBinding) {
                            ForEach(AppTheme.allCases, id: \.self) { theme in
                                Text(theme.displayName(language: viewModel.settings.language)).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                    }
                }

                settingsGroup(t("Dock Preview")) {
                    toggleRow(t("Enable dock preview"), systemImage: "rectangle.on.rectangle", isOn: dockPreviewEnabledBinding)

                    if viewModel.settings.dockPreviewEnabled {
                        toggleRow(t("Hover to show"), systemImage: "cursorarrow.motionlines", isOn: dockPreviewHoverEnabledBinding)

                        settingRow(t("Hover delay"), systemImage: "timer") {
                            HStack(spacing: 10) {
                                Slider(value: dockPreviewHoverDelayBinding, in: 0.2...1.0, step: 0.1)
                                    .frame(width: 220)
                                Text(String(format: "%.1fs", viewModel.settings.dockPreviewHoverDelay))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }

                        settingRow(t("Card size"), systemImage: "rectangle.expand.vertical") {
                            HStack(spacing: 10) {
                                Slider(value: dockPreviewCardWidthBinding, in: 80...600, step: 10)
                                    .frame(width: 220)
                                Text("\(Int(viewModel.settings.dockPreviewCardWidth))pt")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                    }
                }

                settingsGroup(t("System")) {
                    toggleRow(t("Launch at login"), systemImage: "power", isOn: launchAtLoginBinding)
                    toggleRow(t("Hide main window on launch"), systemImage: "eye.slash", isOn: hideMainWindowBinding)
                }

                settingsGroup(t("Usage statistics")) {
                    UsageStatisticsPreferencesSection(isEnabled: usageStatisticsEnabledBinding,
                                                     model: statisticsModel)
                }
                .onAppear { statisticsModel.observeSettingsChanges() }
            }
            .padding(24)
        }
    }

    private var permissionsSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(t("Permissions"), subtitle: t("Required macOS permissions for switching and thumbnails"))

                settingsGroup(t("Required")) {
                    permissionRow(
                        title: t("Accessibility"),
                        subtitle: t("Used to focus and switch windows."),
                        isGranted: viewModel.isAccessibilityPermissionGranted,
                        actionTitle: t("Open Settings"),
                        action: viewModel.openAccessibilitySettings
                    )

                    permissionRow(
                        title: t("Screen & System Audio Recording"),
                        subtitle: t("Used by macOS to allow window thumbnails and related recording access."),
                        isGranted: viewModel.isScreenCapturePermissionGranted,
                        actionTitle: t("Open Settings"),
                        action: viewModel.openScreenCaptureSettings
                    )
                }

                permissionLastChecked

                HStack(spacing: 10) {
                    Button(t("Refresh Status")) {
                        viewModel.refreshPermissionStatus()
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            viewModel.refreshPermissionStatus()
        }
    }

    @ViewBuilder
    private var permissionLastChecked: some View {
        if let date = viewModel.permissionStatusLastUpdated {
            Text("\(t("Last checked")): \(date.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var appsSettingsTab: some View {
        VStack(spacing: 0) {
            appSearchBar
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)

            HStack(spacing: 0) {
                appList(
                    title: t("Monitored Apps"),
                    subtitle: String(format: t("%d configured"), viewModel.settings.monitoredApps.count),
                    apps: filteredMonitoredApps,
                    emptyText: appSearchText.isEmpty ? t("No monitored apps") : t("No monitored apps match your search")
                ) { app in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { app.isEnabled },
                            set: { _ in viewModel.toggleAppEnabled(app) }
                        ))
                        .labelsHidden()

                        appIdentity(app)

                        Spacer()

                        iconButton(t("Remove"), systemImage: "minus.circle") {
                            viewModel.removeMonitoredApp(app)
                        }
                    }
                }

                Divider()

                appList(
                    title: t("Available Apps"),
                    subtitle: t("Installed apps"),
                    apps: filteredAvailableApps,
                    emptyText: appSearchText.isEmpty ? t("No available apps") : t("No available apps match your search")
                ) { app in
                    HStack(spacing: 10) {
                        appIdentity(app)
                        Spacer()
                        iconButton(t("Add"), systemImage: "plus.circle.fill") {
                            viewModel.addMonitoredApp(app)
                        }
                    }
                }
            }
        }
    }

    private var appSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField(t("Search apps"), text: $appSearchText)
                .textFieldStyle(.plain)

            if !appSearchText.isEmpty {
                Button(action: { appSearchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .liquidGlass(
            isActive: true,
            opacity: 0.06,
            cornerRadius: 8,
            tintColor: Color(nsColor: .textBackgroundColor),
            interactive: true,
            fallbackColor: Color(nsColor: .textBackgroundColor)
        )
    }

    private var shortcutsSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(t("Shortcuts"), subtitle: t("Global and app shortcuts use the selected prefix."))

                settingsGroup(t("Global")) {
                    settingRow(t("Shortcut prefix"), systemImage: "command") {
                        Picker("", selection: shortcutPrefixBinding) {
                            ForEach(ShortcutPrefix.allCases, id: \.self) { prefix in
                                Text(prefix.displayName).tag(prefix)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                    }

                    shortcutRow(
                        title: t("Toggle Preview"),
                        subtitle: t("Show or hide the preview panel"),
                        modifier: viewModel.settings.shortcutPrefix.displayName,
                        selection: globalShortcutBinding
                    )
                }

                settingsGroup(t("Applications")) {
                    if viewModel.settings.monitoredApps.isEmpty {
                        emptyInline(t("Add apps in the Apps tab before assigning app shortcuts."))
                    } else {
                        ForEach(viewModel.settings.monitoredApps) { app in
                            shortcutRow(
                                title: app.appName,
                                subtitle: app.bundleIdentifier,
                                modifier: viewModel.settings.shortcutPrefix.displayName,
                                selection: shortcutBinding(for: app)
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var filteredMonitoredApps: [MonitoredApp] {
        InstalledAppsService.filter(viewModel.settings.monitoredApps, query: appSearchText)
    }

    private var filteredAvailableApps: [MonitoredApp] {
        viewModel.filteredAvailableApps(query: appSearchText)
    }

    private var previewInteractionModeBinding: Binding<PreviewInteractionMode> {
        Binding(
            get: { viewModel.settings.previewInteractionMode },
            set: { newValue in
                viewModel.updateSettings { $0.previewInteractionMode = newValue }
            }
        )
    }

    private var previewReplicaHoverDelayBinding: Binding<Double> {
        Binding(
            get: { viewModel.settings.previewReplicaHoverDelay },
            set: { newValue in
                viewModel.updateSettings { $0.previewReplicaHoverDelay = newValue }
            }
        )
    }

    private var previewHotspotEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.previewHotspotEnabled },
            set: { newValue in
                viewModel.updateSettings { $0.previewHotspotEnabled = newValue }
            }
        )
    }

    private var previewHotspotEdgeBinding: Binding<PreviewHotspotEdge> {
        Binding(
            get: { viewModel.settings.previewHotspotEdge },
            set: { newValue in
                viewModel.updateSettings { $0.previewHotspotEdge = newValue }
            }
        )
    }

    private var previewShakeEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.previewShakeEnabled },
            set: { newValue in
                viewModel.updateSettings { $0.previewShakeEnabled = newValue }
            }
        )
    }

    private var previewStrategyBinding: Binding<PreviewStrategy> {
        Binding(
            get: { viewModel.settings.previewStrategy },
            set: { newValue in
                viewModel.updateSettings { $0.previewStrategy = newValue }
            }
        )
    }

    private var thumbnailSizeBinding: Binding<ThumbnailSize> {
        Binding(
            get: { viewModel.settings.thumbnailSize },
            set: { newValue in
                viewModel.updateSettings { $0.thumbnailSize = newValue }
            }
        )
    }

    private var monitorFrequencyBinding: Binding<MonitorFrequency> {
        Binding(
            get: { viewModel.settings.monitorFrequency },
            set: { newValue in
                viewModel.updateSettings { $0.monitorFrequency = newValue }
            }
        )
    }

    private var showWindowTitlesBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.showWindowTitles },
            set: { newValue in
                viewModel.updateSettings { $0.showWindowTitles = newValue }
            }
        )
    }

    private var backgroundBlurBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.enableBackgroundBlur },
            set: { newValue in
                viewModel.updateSettings { $0.enableBackgroundBlur = newValue }
            }
        )
    }

    private var backgroundBlurOpacityBinding: Binding<Double> {
        Binding(
            get: { viewModel.settings.backgroundBlurOpacity },
            set: { newValue in
                viewModel.updateSettings { $0.backgroundBlurOpacity = newValue }
            }
        )
    }

    private var previewInfoShowsAppNameBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.previewInfoShowsAppName },
            set: { newValue in
                viewModel.updateSettings { $0.previewInfoShowsAppName = newValue }
            }
        )
    }

    private var previewInfoShowsWindowNumberBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.previewInfoShowsWindowNumber },
            set: { newValue in
                viewModel.updateSettings { $0.previewInfoShowsWindowNumber = newValue }
            }
        )
    }

    private var previewInfoShowsProcessIDBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.previewInfoShowsProcessID },
            set: { newValue in
                viewModel.updateSettings { $0.previewInfoShowsProcessID = newValue }
            }
        )
    }

    private var previewInfoShowsSizeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.previewInfoShowsSize },
            set: { newValue in
                viewModel.updateSettings { $0.previewInfoShowsSize = newValue }
            }
        )
    }

    private var previewInfoShowsPositionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.previewInfoShowsPosition },
            set: { newValue in
                viewModel.updateSettings { $0.previewInfoShowsPosition = newValue }
            }
        )
    }

    private var usageStatisticsEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.usageStatisticsEnabled },
            set: { newValue in
                viewModel.updateSettings { $0.usageStatisticsEnabled = newValue }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.launchAtLogin },
            set: { newValue in
                viewModel.updateSettings { $0.launchAtLogin = newValue }
            }
        )
    }

    private var hideMainWindowBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.hideMainWindowOnLaunch },
            set: { newValue in
                viewModel.updateSettings { $0.hideMainWindowOnLaunch = newValue }
            }
        )
    }

    private var dockPreviewEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.dockPreviewEnabled },
            set: { newValue in
                viewModel.updateSettings { $0.dockPreviewEnabled = newValue }
            }
        )
    }

    private var dockPreviewHoverEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.dockPreviewHoverEnabled },
            set: { newValue in
                viewModel.updateSettings { $0.dockPreviewHoverEnabled = newValue }
            }
        )
    }

    private var dockPreviewHoverDelayBinding: Binding<Double> {
        Binding(
            get: { viewModel.settings.dockPreviewHoverDelay },
            set: { newValue in
                viewModel.updateSettings { $0.dockPreviewHoverDelay = newValue }
            }
        )
    }

    private var dockPreviewCardWidthBinding: Binding<Double> {
        Binding(
            get: { viewModel.settings.dockPreviewCardWidth },
            set: { newValue in
                viewModel.updateSettings { $0.dockPreviewCardWidth = newValue }
            }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { viewModel.settings.language },
            set: { newValue in
                viewModel.updateSettings { $0.language = newValue }
            }
        )
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { viewModel.settings.theme },
            set: { newValue in
                viewModel.updateSettings { $0.theme = newValue }
            }
        )
    }

    private var globalShortcutBinding: Binding<String> {
        Binding(
            get: { viewModel.settings.globalShortcutKey ?? "" },
            set: { newValue in
                viewModel.updateSettings { $0.globalShortcutKey = newValue.isEmpty ? nil : newValue }
            }
        )
    }

    private var shortcutPrefixBinding: Binding<ShortcutPrefix> {
        Binding(
            get: { viewModel.settings.shortcutPrefix },
            set: { newValue in
                viewModel.updateSettings { $0.shortcutPrefix = newValue }
            }
        )
    }

    private func shortcutBinding(for app: MonitoredApp) -> Binding<String> {
        Binding(
            get: {
                viewModel.settings.monitoredApps.first(where: { $0.id == app.id })?.shortcutKey ?? ""
            },
            set: { newValue in
                viewModel.setShortcutKey(newValue.isEmpty ? nil : newValue, for: app)
            }
        )
    }

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                content()
            }
            // Solid translucent fill, not a live blur: every group used to
            // carry its own NSVisualEffectView (.behindWindow), so the
            // General tab scrolled under seven backdrop samplers and hitched
            // -- the exact per-card material cost cardSurface's doc comment
            // warns about. The window-level panelBackground provides the
            // glass; groups hold solid content on top of it.
            .cardSurface(fill: Color(nsColor: .controlBackgroundColor).opacity(0.45), cornerRadius: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private func settingRow<Content: View>(_ title: String,
                                           systemImage: String,
                                           help: String? = nil,
                                           @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 22)

            Text(title)
                .font(.body)

            if let help {
                // Hover explanation instead of a full-width caption row:
                // native tooltip, zero layout cost.
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .help(help)
            }

            Spacer(minLength: 16)

            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func toggleRow(_ title: String, systemImage: String, isOn: Binding<Bool>, help: String? = nil) -> some View {
        settingRow(title, systemImage: systemImage, help: help) {
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func shortcutRow(title: String, subtitle: String, modifier: String, selection: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Text(modifier)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)

            Picker("", selection: selection) {
                Text(t("None")).tag("")
                Divider()
                ForEach(shortcutChoices, id: \.self) { key in
                    Text(key.uppercased()).tag(key)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        isGranted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isGranted ? .green : .orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 16)

            Text(isGranted ? t("Enabled") : t("Required"))
                .font(.caption.weight(.medium))
                .foregroundColor(isGranted ? .green : .orange)

            Button(actionTitle, action: action)
                .disabled(isGranted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func appList<RowContent: View>(
        title: String,
        subtitle: String,
        apps: [MonitoredApp],
        emptyText: String,
        @ViewBuilder row: @escaping (MonitoredApp) -> RowContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            if apps.isEmpty {
                emptyInline(emptyText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(apps) { app in
                            row(app)
                                .padding(12)
                                // Solid fill, not liquidGlass: rows are
                                // recycled while scrolling, and a live
                                // glassEffect per row is the most expensive
                                // thing a scrolling list can carry.
                                .cardSurface(fill: Color(nsColor: .controlBackgroundColor).opacity(0.45), cornerRadius: 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appIdentity(_ app: MonitoredApp) -> some View {
        HStack(spacing: 10) {
            appIcon(for: app)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func appIcon(for app: MonitoredApp) -> some View {
        if let icon = resolvedIcon(for: app) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                )
        }
    }

    private func resolvedIcon(for app: MonitoredApp) -> NSImage? {
        // Cached per bundle id — the raw calls hit LaunchServices on every
        // row render (the app list re-renders on every search keystroke).
        if let runningIcon = AppIconCache.icon(forBundleIdentifier: app.bundleIdentifier) {
            return runningIcon
        }

        return NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == app.bundleIdentifier
        })?.icon
    }

    private func iconButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(label)
    }

    private func emptyInline(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
    }

    private var shortcutChoices: [String] {
        ["space", "comma"] + (0...9).map(String.init) + (65...90).compactMap { UnicodeScalar($0).map { String($0).lowercased() } }
    }

    private func t(_ key: String) -> String {
        viewModel.settings.language.localizedString(key)
    }
}

private extension View {
    func apply(@ViewBuilder _ transform: (Self) -> some View) -> some View {
        transform(self)
    }
}

#Preview {
    PreferencesView()
}
