//
//  PluginPreferencesSection.swift
//  Switchly
//
//  Preferences → Plugins (design doc §3.6 / §3.7): one card per installed
//  Dock preview plugin. The card keeps only what users act on — name, version,
//  on/off and the plugin's own options; what it can do (its summary and the
//  permissions it was granted) lives behind the “?” next to the name, so the
//  list stays scannable. A user-installed plugin only runs after its permission
//  list is confirmed here; an update that declares new permissions turns
//  pending until confirmed again.
//

import AppKit
import SwiftUI

struct PluginPreferencesSection: View {
    let settings: AppSettings
    let onSettingsChange: (AppSettings) -> Void
    var host: PluginHosting = PluginHost.shared

    @State private var plugins: [InstalledPlugin] = []
    @State private var pendingConfirmation: InstalledPlugin?
    @State private var expandedInfo: String?

    private var language: AppLanguage { settings.language }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if plugins.isEmpty {
                emptyState
            }
            ForEach(plugins) { plugin in
                pluginCard(plugin)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button { openFolder() } label: { Label(t("Open Plugins Folder"), systemImage: "folder") }
                Button {
                    host.reload()
                    refresh()
                } label: { Label(t("Reload Plugins"), systemImage: "arrow.clockwise") }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, DesignTokens.Spacing.xs)
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

    // MARK: - Card

    private func pluginCard(_ plugin: InstalledPlugin) -> some View {
        let options = plugin.package.manifest.settings ?? []
        return VStack(spacing: 0) {
            header(plugin)
            ForEach(options, id: \.key) { spec in
                Divider().padding(.leading, 14)
                settingControl(spec, plugin: plugin)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
        .cardSurface(
            fill: Color.crystalSurfaceBase.opacity(settings.crystalMaterial.cardOpacity),
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            showsBorder: true
        )
    }

    private func header(_ plugin: InstalledPlugin) -> some View {
        let manifest = plugin.package.manifest
        let auth = plugin.authorization
        return HStack(spacing: DesignTokens.Spacing.sm) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(manifest.displayName(preferredLanguages: [language.rawValue]))
                        .font(.headline)
                    infoButton(plugin)
                }
                HStack(spacing: 6) {
                    Text("v" + manifest.version)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    badge(t(plugin.package.origin == .builtin ? "Built-in" : "Installed"), tone: .neutral)
                    if !auth.pendingPermissions.isEmpty {
                        badge(t("Not allowed yet"), tone: .warning)
                    }
                }
            }
            Spacer(minLength: DesignTokens.Spacing.md)
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
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(manifest.displayName(preferredLanguages: [language.rawValue])))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The “?” by the name: hover shows a short summary, click lists exactly what the plugin may do.
    private func infoButton(_ plugin: InstalledPlugin) -> some View {
        let id = plugin.id
        return Image(systemName: "questionmark.circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .help(infoTooltip(plugin))
            .contentShape(Circle())
            .onTapGesture { expandedInfo = expandedInfo == id ? nil : id }
            .popover(isPresented: Binding(get: { expandedInfo == id }, set: { if !$0 { expandedInfo = nil } }),
                     arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(plugin.package.manifest.displayName(preferredLanguages: [language.rawValue]))
                        .font(.headline)
                    if let summary = plugin.package.manifest.localizedSummary(preferredLanguages: [language.rawValue]) {
                        Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    permissionList(plugin)
                }
                .padding(14)
                .frame(width: 280, alignment: .leading)
            }
            .accessibilityLabel(Text(t("What this plugin can do")))
            .accessibilityAddTraits(.isButton)
    }

    private func infoTooltip(_ plugin: InstalledPlugin) -> String {
        var lines: [String] = []
        if let summary = plugin.package.manifest.localizedSummary(preferredLanguages: [language.rawValue]) {
            lines.append(summary)
        }
        lines.append(plugin.package.manifest.permissions.map { permissionText($0) }.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    private func permissionList(_ plugin: InstalledPlugin) -> some View {
        let auth = plugin.authorization
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(plugin.package.manifest.permissions, id: \.rawValue) { permission in
                let pending = auth.pendingPermissions.contains(permission)
                Label(permissionText(permission), systemImage: permission.systemImageName)
                    .font(.caption)
                    .foregroundColor(pending ? Color(nsColor: .systemOrange) : .secondary)
            }
        }
    }

    private enum BadgeTone { case neutral, warning }

    private func badge(_ text: String, tone: BadgeTone) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundColor(tone == .warning ? Color(nsColor: .systemOrange) : .secondary)
            .background(Capsule().fill(tone == .warning
                ? Color(nsColor: .systemOrange).opacity(0.14)
                : Color.primary.opacity(0.07)))
    }

    private var emptyState: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Text(t("No plugins installed"))
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(14)
        .cardSurface(
            fill: Color.crystalSurfaceBase.opacity(settings.crystalMaterial.cardOpacity),
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            showsBorder: true
        )
    }

    // MARK: - Options

    /// One option row: label on the left, its control on the right, so every
    /// kind lines up instead of macOS centring a switch next to its label.
    @ViewBuilder
    private func settingControl(_ spec: PluginSettingSpec, plugin: InstalledPlugin) -> some View {
        switch spec.kind {
        case .toggle:
            optionRow(spec) {
                Toggle("", isOn: Binding(
                    get: { settings.pluginSettings[plugin.id]?[spec.key] ?? spec.default },
                    set: { value in
                        var updated = settings
                        updated.pluginSettings[plugin.id, default: [:]][spec.key] = value
                        onSettingsChange(updated)
                    }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        case .select:
            let selected = Binding<String>(
                get: {
                    if case .string(let s)? = settings.pluginValues[plugin.id]?[spec.key], spec.options.contains(where: { $0.value == s }) { return s }
                    if case .string(let s) = spec.defaultValue { return s }
                    return spec.options.first?.value ?? ""
                },
                set: { value in
                    var updated = settings
                    updated.pluginValues[plugin.id, default: [:]][spec.key] = .string(value)
                    onSettingsChange(updated)
                })
            optionRow(spec) {
                Picker("", selection: selected) {
                    ForEach(spec.options, id: \.value) { option in
                        Text(PluginSettingSpec.localized(option.title, fallback: option.value, preferredLanguages: [language.rawValue])).tag(option.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        case .number:
            let value = Binding<Double>(
                get: {
                    if case .number(let n)? = settings.pluginValues[plugin.id]?[spec.key] { return n }
                    if case .number(let n) = spec.defaultValue { return n }
                    return 0
                },
                set: { number in
                    var updated = settings
                    updated.pluginValues[plugin.id, default: [:]][spec.key] = .number(number)
                    onSettingsChange(updated)
                })
            optionRow(spec) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(verbatim: formatted(value.wrappedValue))
                        .font(.callout)
                        .monospacedDigit()
                        .frame(minWidth: 40, alignment: .trailing)
                    Stepper("", value: value, in: (spec.min ?? -1_000_000)...(spec.max ?? 1_000_000), step: spec.step ?? 1)
                        .labelsHidden()
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(spec.displayTitle(preferredLanguages: [language.rawValue])): \(formatted(value.wrappedValue))"))
            }
        }
    }

    private func optionRow<Control: View>(_ spec: PluginSettingSpec, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(spec.displayTitle(preferredLanguages: [language.rawValue]))
                .font(.callout)
            Spacer(minLength: DesignTokens.Spacing.md)
            control()
        }
    }

    /// Whole numbers show without a decimal point; anything else keeps one.
    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: - Actions

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
