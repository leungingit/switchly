//
//  PluginPreferencesSection.swift
//  Switchly
//
//  Preferences → Plugins (design doc §3.6 / §3.7): one card per installed
//  Dock preview plugin with its toggle, permissions and own options. A user-installed
//  plugin only runs after its permission list is confirmed here; a plugin
//  update that declares new permissions turns pending until confirmed again.
//

import AppKit
import SwiftUI

struct PluginPreferencesSection: View {
    let settings: AppSettings
    let onSettingsChange: (AppSettings) -> Void
    /// Wraps a plugin's content in the tab's titled card style.
    let group: (String, AnyView) -> AnyView
    var host: PluginHosting = PluginHost.shared

    @State private var plugins: [InstalledPlugin] = []
    @State private var pendingConfirmation: InstalledPlugin?

    private var language: AppLanguage { settings.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if plugins.isEmpty {
                Text(t("No plugins installed"))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            ForEach(plugins) { plugin in
                group(plugin.package.manifest.displayName(preferredLanguages: [language.rawValue]),
                      AnyView(pluginCard(plugin)))
            }
            HStack(spacing: 10) {
                Button(t("Open Plugins Folder")) { openFolder() }
                Button(t("Reload Plugins")) {
                    host.reload()
                    refresh()
                }
                Spacer()
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: settings.pluginGrants) { _ in refresh() }
        .alert(item: $pendingConfirmation) { plugin in
            Alert(
                title: Text(String(format: t("Allow “%@”?"), plugin.package.manifest.displayName(preferredLanguages: [language.rawValue]))),
                message: Text(t("This plugin will be able to:") + "\n"
                              + plugin.package.manifest.permissions.map { "• " + permissionText($0) }.joined(separator: "\n")),
                primaryButton: .default(Text(t("Allow"))) { setGrant(plugin, enabled: true, confirmAll: true) },
                secondaryButton: .cancel(Text(t("Cancel")))
            )
        }
    }

    private func pluginCard(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pluginRow(plugin)
            ForEach(plugin.package.manifest.settings ?? [], id: \.key) { spec in
                Divider().padding(.leading, 14)
                Toggle(spec.displayTitle(preferredLanguages: [language.rawValue]), isOn: Binding(
                    get: { settings.pluginSettings[plugin.id]?[spec.key] ?? spec.default },
                    set: { value in
                        var updated = settings
                        updated.pluginSettings[plugin.id, default: [:]][spec.key] = value
                        onSettingsChange(updated)
                    }))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private func pluginRow(_ plugin: InstalledPlugin) -> some View {
        let manifest = plugin.package.manifest
        let auth = plugin.authorization
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: 6) {
                    Text("v" + manifest.version).font(.caption).foregroundColor(.secondary)
                    Text(t(plugin.package.origin == .builtin ? "Built-in" : "Installed"))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                ForEach(manifest.permissions, id: \.rawValue) { permission in
                    let pending = auth.pendingPermissions.contains(permission)
                    Label(permissionText(permission) + (pending ? " · " + t("Not allowed yet") : ""),
                          systemImage: permission.systemImageName)
                        .font(.caption)
                        .foregroundColor(pending ? Color(nsColor: .systemOrange) : .secondary)
                }
            }
            Spacer(minLength: 16)
            Toggle("", isOn: Binding(
                get: { auth.isEnabled },
                set: { enabled in
                    if enabled && !auth.pendingPermissions.isEmpty {
                        pendingConfirmation = plugin
                    } else {
                        setGrant(plugin, enabled: enabled, confirmAll: false)
                    }
                }))
                .labelsHidden()
                .accessibilityLabel(Text(manifest.displayName(preferredLanguages: [language.rawValue])))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func setGrant(_ plugin: InstalledPlugin, enabled: Bool, confirmAll: Bool) {
        var updated = settings
        let id = plugin.id
        let confirmed = confirmAll
            ? plugin.package.manifest.permissions.map(\.rawValue)
            : (settings.pluginGrants[id]?.permissions ?? plugin.authorization.permissions.map(\.rawValue).sorted())
        updated.pluginGrants[id] = PluginGrant(isEnabled: enabled, permissions: confirmed)
        AppLogger.info("Plugin grant changed. plugin=\(id) enabled=\(enabled) permissions=\(confirmed.count)")
        onSettingsChange(updated)
    }

    private func refresh() {
        plugins = host.installedPlugins()
    }

    private func openFolder() {
        let dir = PluginRegistry.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func permissionText(_ permission: PluginCapability) -> String {
        if case .appleScript(let bundleID) = permission {
            return String(format: t(permission.displayKey), bundleID)
        }
        return t(permission.displayKey)
    }

    private func t(_ key: String) -> String {
        language.localizedString(key)
    }
}
