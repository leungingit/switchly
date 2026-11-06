//
//  PluginPreferencesSection.swift
//  Switchly
//
//  Preferences → Plugins (design doc §3.6 / §3.7): a searchable list of
//  installed Dock preview plugins. Only the selected card expands to show its
//  options, folder grant and host-level data source, keeping the narrow
//  Preferences window scannable. A user-installed plugin only runs after its
//  permission list is confirmed here; an update that declares new permissions
//  turns pending until confirmed again.
//

import AppKit
import SwiftUI

enum PluginStatusFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case disabled
    case needsAttention

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .all: return "All"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .needsAttention: return "Needs attention"
        }
    }
}

struct PluginPreferencesSection: View {
    let settings: AppSettings
    let onSettingsChange: (AppSettings) -> Void
    /// Host-level controls for every plugin authorized to read weather.
    let onOnlineWeatherChange: (OnlineWeatherSettings) -> Void
    var host: PluginHosting = PluginHost.shared
    var installer: PluginInstalling = PluginInstaller()

    @State var plugins: [InstalledPlugin] = []
    @State var loadFailures: [PluginLoadFailure] = []
    @State var pendingConfirmation: InstalledPlugin?
    @State var expandedInfo: String?
    @State var selectedPluginID: String?
    @State var searchText = ""
    @State var statusFilter: PluginStatusFilter = .all
    @State var refreshGeneration = 0
    @State var isInstalling = false
    @State var uninstallingPluginID: String?
    @FocusState var searchFocused: Bool

    var language: AppLanguage { settings.language }
    var isPluginOperationInProgress: Bool {
        isInstalling || uninstallingPluginID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if !plugins.isEmpty {
                managementControls
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button {
                        openFolder()
                    } label: {
                        Label(t("Open Plugins Folder"), systemImage: "folder")
                    }
                    .accessibilityLabel(Text(t("Open Plugins Folder")))
                    Button {
                        choosePluginFolder()
                    } label: {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(t("Install Plugin"), systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isPluginOperationInProgress)
                    .accessibilityLabel(Text(t("Install Plugin")))
                    Button {
                        host.reload()
                        refresh()
                    } label: { Label(t("Reload Plugins"), systemImage: "arrow.clockwise") }
                    .disabled(isPluginOperationInProgress)
                    .accessibilityLabel(Text(t("Reload Plugins")))
                    Spacer()
                    SettingsHelpButton(help: t("Built-in plugins ship inside Switchly itself — their cards above are marked Built-in. This folder only holds plugins you install yourself, so it stays empty until then."))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            }
            .padding(.top, DesignTokens.Spacing.xs)
            if !pendingPlugins.isEmpty || !loadFailures.isEmpty {
                attentionSection
            }
            if plugins.isEmpty {
                emptyState
            } else if filteredPlugins.isEmpty {
                filteredEmptyState
            } else {
                LazyVStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(filteredPlugins) { plugin in
                        pluginCard(plugin, isSelected: plugin.id == selectedPluginID)
                    }
                }
            }
        }
        .background(Button(t("Search plugins")) { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command).hidden())
        .onAppear(perform: refresh)
        .onChange(of: settings.pluginGrants) { _ in refresh() }
        .onChange(of: searchText) { _ in synchronizeSelection() }
        .onChange(of: statusFilter) { _ in synchronizeSelection() }
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

    private func pluginCard(_ plugin: InstalledPlugin, isSelected: Bool) -> some View {
        let options = plugin.package.manifest.settings ?? []
        return VStack(spacing: 0) {
            header(plugin, isSelected: isSelected)
            if isSelected {
                if plugin.package.manifest.permissions.contains(.fsRead) {
                    Divider().padding(.leading, 14)
                    folderAccessRow(plugin)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                ForEach(options, id: \.key) { spec in
                    Divider().padding(.leading, 14)
                    settingControl(spec, plugin: plugin)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                if plugin.package.manifest.permissions.contains(.weatherCurrent) {
                    OnlineWeatherPreferences(value: settings.onlineWeather,
                                             language: settings.language,
                                             onChange: onOnlineWeatherChange)
                }
                if plugin.package.origin == .user {
                    Divider().padding(.leading, 14)
                    uninstallRow(plugin)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
        .cardSurface(
            fill: Color.crystalSurfaceBase.opacity(settings.crystalMaterial.cardOpacity),
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            showsBorder: true
        )
    }

    private func header(_ plugin: InstalledPlugin, isSelected: Bool) -> some View {
        let manifest = plugin.package.manifest
        let auth = plugin.authorization
        return HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                selectPlugin(plugin.id)
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(manifest.displayName(preferredLanguages: [language.rawValue]))
                            .font(.headline)
                            .lineLimit(1)
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(pluginAccessibilityLabel(plugin, isSelected: isSelected)))
            .accessibilityHint(Text(isSelected ? t("Selected plugin") : t("Show plugin details")))

            Spacer(minLength: DesignTokens.Spacing.md)
            infoButton(plugin)
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
                .accessibilityLabel(Text(String(
                    format: t("Enable “%@”"),
                    manifest.displayName(preferredLanguages: [language.rawValue])
                )))
            Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The “?” by the name: hover shows a short summary, click lists exactly what the plugin may do.
    private func infoButton(_ plugin: InstalledPlugin) -> some View {
        let id = plugin.id
        return Button {
            expandedInfo = expandedInfo == id ? nil : id
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
        }
            .buttonStyle(.plain)
            .help(infoTooltip(plugin))
            .accessibilityLabel(Text(t("What this plugin can do")))
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
    }

    private func infoTooltip(_ plugin: InstalledPlugin) -> String {
        var lines: [String] = []
        if let summary = plugin.package.manifest.localizedSummary(preferredLanguages: [language.rawValue]) {
            lines.append(summary)
        }
        lines.append(listedPermissions(plugin).map { permissionText($0) }.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    private func permissionList(_ plugin: InstalledPlugin) -> some View {
        let auth = plugin.authorization
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(listedPermissions(plugin), id: \.rawValue) { permission in
                let pending = auth.pendingPermissions.contains(permission)
                Label(permissionText(permission), systemImage: permission.systemImageName)
                    .font(.caption)
                    .foregroundColor(pending ? Color(nsColor: .systemOrange) : .secondary)
            }
        }
    }

    /// `fs.read` is left out: its own row on the card names the folder and
    /// carries the switch that allows it, so listing it here would repeat it
    /// without the thing the user needs to decide.
    private func listedPermissions(_ plugin: InstalledPlugin) -> [PluginCapability] {
        plugin.package.manifest.permissions.filter { $0 != .fsRead }
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

    private var filteredEmptyState: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Text(t("No plugins match this search and status"))
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Button(t("Clear Filters")) {
                searchText = ""
                statusFilter = .all
            }
            .controlSize(.small)
            .accessibilityLabel(Text(t("Clear plugin filters")))
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
                .accessibilityLabel(Text(spec.displayTitle(preferredLanguages: [language.rawValue])))
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
                .accessibilityLabel(Text(spec.displayTitle(preferredLanguages: [language.rawValue])))
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

    /// `fs.read`: the folder, why the plugin wants it, and the switch that allows it.
    /// Without it the plugin runs but cannot see the folder.
    private func folderAccessRow(_ plugin: InstalledPlugin) -> some View {
        let allowed = plugin.authorization.permissions.contains(.fsRead)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: PluginCapability.fsRead.systemImageName)
                .foregroundColor(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(t(PluginCapability.fsRead.displayKey)).font(.callout)
                ForEach(plugin.package.manifest.fsRoots ?? [], id: \.id) { root in
                    Text(root.path).font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                    Text(PluginSettingSpec.localized(root.summary, fallback: "", preferredLanguages: [language.rawValue]))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            Toggle("", isOn: Binding(get: { allowed }, set: { setFolderAccess(plugin, allowed: $0) }))
                .labelsHidden()
                .accessibilityLabel(Text(t(PluginCapability.fsRead.displayKey)))
        }
    }

    private func setFolderAccess(_ plugin: InstalledPlugin, allowed: Bool) {
        var updated = settings
        let id = plugin.id
        var confirmed = Set(settings.pluginGrants[id]?.permissions ?? plugin.authorization.permissions.map(\.rawValue))
        if allowed { confirmed.insert(PluginCapability.fsRead.rawValue) } else { confirmed.remove(PluginCapability.fsRead.rawValue) }
        updated.pluginGrants[id] = PluginGrant(isEnabled: plugin.authorization.isEnabled, permissions: confirmed.sorted())
        AppLogger.info("Plugin folder access changed. plugin=\(id) allowed=\(allowed)")
        onSettingsChange(updated)
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

    func t(_ key: String) -> String {
        language.localizedString(key)
    }
}
