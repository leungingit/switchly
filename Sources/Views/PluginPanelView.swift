import SwiftUI

struct PluginPanelView: View {
    @ObservedObject var model: PluginPanelModel
    let activityImages: PluginActivityImageResolving?
    @State private var settings: AppSettings
    init(model: PluginPanelModel, activityImages: PluginActivityImageResolving?, settings: AppSettings) {
        self.model = model; self.activityImages = activityImages; _settings = State(initialValue: settings)
    }
    private func t(_ key: String) -> String { settings.language.localizedString(key) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                if model.isLoading { ProgressView().accessibilityLabel(Text(t("Loading"))) }
                if !model.pendingPermissions.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        Label(t("Plugin permissions need confirmation"), systemImage: "checkmark.shield")
                            .font(.headline)
                        Text(t("Recording settings and plugin access are separate. Review this plugin's permissions in Plugins settings."))
                            .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(model.pendingPermissions, id: \.rawValue) { permission in
                            Label(permissionLabel(permission), systemImage: permission.systemImageName)
                        }
                        Button(t("Review permissions..."), action: openPluginSettings)
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let key = model.errorKey {
                    Text(t(key)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(t("Preferences..."), action: openPluginSettings)
                }
                ForEach(model.entries) { entry in
                    PluginOverlayView(node: entry.node, material: settings.crystalMaterial,
                                      isGlassActive: settings.enableBackgroundBlur,
                                      assetDirectory: entry.assetDirectory, pluginID: entry.id,
                                      activityImages: activityImages, onAction: model.perform)
                }
                .id(model.presentationRevision)
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(WindowCrystalModifier(density: settings.windowGlassDensity,
                                        material: settings.crystalMaterial, style: .preferences))
        .preferredColorScheme(settings.theme.colorScheme)
        .environment(\.locale, Locale(identifier: settings.language.rawValue))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in settings = SettingsService.shared.loadSettings() }
    }

    private func openPluginSettings() {
        NotificationCenter.default.post(name: .openPreferences, object: nil,
                                        userInfo: ["tab": PreferencesTab.plugins, "pluginID": model.pluginID])
    }

    private func permissionLabel(_ permission: PluginCapability) -> String {
        if case .appleScript(let bundleID) = permission { return String(format: t(permission.displayKey), bundleID) }
        return t(permission.displayKey)
    }
}

struct PluginPanelLauncherView: View {
    let host: PluginHosting
    let open: (String, String) -> Void
    @State private var plugins: [InstalledPlugin] = []
    @State private var loading = true
    @State private var settings = SettingsService.shared.loadSettings()
    private var language: AppLanguage { settings.language }
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text(language.localizedString("Plugin Panels")).font(.title2.bold())
            if loading { ProgressView() }
            else if plugins.isEmpty { Text(language.localizedString("No panel plugins are installed.")) }
            ForEach(plugins) { plugin in
                Button {
                    open(plugin.id, plugin.package.manifest.displayName(preferredLanguages: [language.rawValue]))
                } label: {
                    Label(plugin.package.manifest.displayName(preferredLanguages: [language.rawValue]), systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered)
            }
            Button(language.localizedString("Preferences...")) { NotificationCenter.default.post(name: .openPreferences, object: nil) }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(WindowCrystalModifier(density: settings.windowGlassDensity,
                                        material: settings.crystalMaterial, style: .preferences))
        .preferredColorScheme(settings.theme.colorScheme)
        .environment(\.locale, Locale(identifier: language.rawValue))
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            settings = SettingsService.shared.loadSettings()
        }
        .task {
            let source = host
            let installed = await Task.detached(priority: .userInitiated) { source.installedPlugins() }.value
            guard !Task.isCancelled else { return }
            plugins = installed.filter { $0.package.manifest.supportsPanel }; loading = false
        }
    }
}
