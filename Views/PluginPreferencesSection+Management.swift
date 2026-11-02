import AppKit
import SwiftUI

// 搜索、状态、安装与卸载操作；设置控件留在主视图文件。
extension PluginPreferencesSection {
    var pendingPlugins: [InstalledPlugin] {
        plugins.filter { !$0.authorization.pendingPermissions.isEmpty }
    }

    var filteredPlugins: [InstalledPlugin] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return plugins.filter { plugin in
            pluginMatchesStatus(plugin) && (query.isEmpty || pluginMatchesSearch(plugin, query: query))
        }
    }

    var managementControls: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(t("Search plugins"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filteredPlugins.first {
                            selectPlugin(first.id)
                        }
                    }
                    .accessibilityLabel(Text(t("Search plugins")))
                    .accessibilityHint(Text(t("Press Return to select the first matching plugin.")))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(t("Clear plugin search")))
                }
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(t("Status"))
                    .font(.callout)
                Picker("", selection: $statusFilter) {
                    ForEach(PluginStatusFilter.allCases) { filter in
                        Text(t(filter.titleKey)).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(Text(t("Plugin status filter")))
                Spacer(minLength: DesignTokens.Spacing.md)
                Text(String(format: t("%d shown"), filteredPlugins.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(Text(String(format: t("%d plugins shown"), filteredPlugins.count)))
            }
        }
    }

    var attentionSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label(t("Needs attention"), systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundColor(Color(nsColor: .systemOrange))
            Text(t("Review plugin permission requests and loading problems."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(pendingPlugins.prefix(5))) { plugin in
                Button {
                    statusFilter = .all
                    searchText = ""
                    selectPlugin(plugin.id)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "checkmark.shield")
                            .foregroundColor(Color(nsColor: .systemOrange))
                        Text(plugin.package.manifest.displayName(preferredLanguages: [language.rawValue]))
                            .lineLimit(1)
                        Spacer(minLength: DesignTokens.Spacing.sm)
                        Text(t("Not allowed yet"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(
                    plugin.package.manifest.displayName(preferredLanguages: [language.rawValue])
                        + ": " + t("Not allowed yet")
                ))
            }

            ForEach(loadFailures, id: \.directory) { failure in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "xmark.octagon")
                            .foregroundColor(Color(nsColor: .systemRed))
                        Text(failure.directory.lastPathComponent)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: DesignTokens.Spacing.sm)
                        Text(t("Could not be loaded"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(failure.reason)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 24)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(
                    failure.directory.lastPathComponent + ": " + t("Could not be loaded")
                ))
            }
        }
        .padding(14)
        .cardSurface(
            fill: Color(nsColor: .systemOrange).opacity(0.08),
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            showsBorder: true
        )
    }

    func uninstallRow(_ plugin: InstalledPlugin) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(t("Installed plugins can be removed from Switchly."))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: DesignTokens.Spacing.md)
            Button(role: .destructive) {
                confirmUninstall(plugin)
            } label: {
                if uninstallingPluginID == plugin.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(t("Uninstall Plugin"), systemImage: "trash")
                }
            }
            .controlSize(.small)
            .disabled(isPluginOperationInProgress)
            .accessibilityLabel(Text(String(
                format: t("Uninstall “%@”"),
                plugin.package.manifest.displayName(preferredLanguages: [language.rawValue])
            )))
        }
    }

    func pluginMatchesStatus(_ plugin: InstalledPlugin) -> Bool {
        switch statusFilter {
        case .all:
            return true
        case .enabled:
            return plugin.authorization.isEnabled
        case .disabled:
            return !plugin.authorization.isEnabled
        case .needsAttention:
            return !plugin.authorization.pendingPermissions.isEmpty
        }
    }

    func pluginMatchesSearch(_ plugin: InstalledPlugin, query: String) -> Bool {
        let manifest = plugin.package.manifest
        let fields = [
            manifest.displayName(preferredLanguages: [language.rawValue]),
            manifest.id,
            manifest.localizedSummary(preferredLanguages: [language.rawValue]) ?? ""
        ]
        return fields.contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func pluginAccessibilityLabel(_ plugin: InstalledPlugin, isSelected: Bool) -> String {
        let name = plugin.package.manifest.displayName(preferredLanguages: [language.rawValue])
        let status = plugin.authorization.isEnabled ? t("Enabled") : t("Disabled")
        let selection = isSelected ? t("Selected plugin") : t("Show plugin details")
        return "\(name), \(status), \(selection)"
    }

    func selectPlugin(_ id: String) {
        selectedPluginID = id
        expandedInfo = nil
    }

    func synchronizeSelection() {
        let visibleIDs = filteredPlugins.map(\.id)
        if !visibleIDs.contains(where: { $0 == selectedPluginID }) {
            selectedPluginID = visibleIDs.first
        }
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let currentHost = host
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                (currentHost.installedPlugins(), currentHost.loadFailures())
            }.value
            await MainActor.run {
                guard generation == refreshGeneration else { return }
                plugins = snapshot.0
                loadFailures = snapshot.1
                synchronizeSelection()
            }
        }
    }

    func choosePluginFolder() {
        guard !isPluginOperationInProgress else { return }
        let panel = NSOpenPanel()
        panel.title = t("Install Plugin")
        panel.message = t("Choose a plugin folder containing manifest.json.")
        panel.prompt = t("Install or Replace")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let directory = panel.url, confirmInstallOrReplace() else { return }
        installPlugin(from: directory)
    }

    func confirmInstallOrReplace() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("Install or Replace Plugin")
        alert.informativeText = t("Install a plugin from the selected local folder. If a user-installed plugin with the same ID exists, its package will be replaced and it will need permission again.")
        alert.addButton(withTitle: t("Install or Replace"))
        alert.addButton(withTitle: t("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func installPlugin(from directory: URL) {
        guard !isPluginOperationInProgress else { return }
        isInstalling = true
        let installer = installer
        Task {
            let result: Result<PluginManifest, Error> = await Task.detached(priority: .userInitiated) {
                Result { try installer.install(directory: directory) }
            }.value
            await MainActor.run {
                isInstalling = false
                switch result {
                case .success(let manifest):
                    resetGrantAndReload(pluginID: manifest.id, select: manifest.id)
                case .failure(let error):
                    showOperationError(title: t("Install Failed"), error: error)
                }
            }
        }
    }

    func confirmUninstall(_ plugin: InstalledPlugin) {
        guard plugin.package.origin == .user, !isPluginOperationInProgress else { return }
        let name = plugin.package.manifest.displayName(preferredLanguages: [language.rawValue])
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: t("Uninstall “%@”?"), name)
        alert.informativeText = t("This removes the plugin package. Its saved settings are kept, and the plugin stays disabled if you install it again.")
        alert.addButton(withTitle: t("Uninstall"))
        alert.addButton(withTitle: t("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        uninstallPlugin(plugin)
    }

    func uninstallPlugin(_ plugin: InstalledPlugin) {
        guard !isPluginOperationInProgress else { return }
        let id = plugin.id
        uninstallingPluginID = id
        let installer = installer
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result { try installer.uninstall(id: id) }
            }.value
            await MainActor.run {
                uninstallingPluginID = nil
                switch result {
                case .success:
                    resetGrantAndReload(pluginID: id, select: nil)
                case .failure(let error):
                    showOperationError(title: t("Uninstall Failed"), error: error)
                }
            }
        }
    }

    func resetGrantAndReload(pluginID: String, select: String?) {
        var updated = settings
        updated.pluginGrants[pluginID] = PluginGrant(isEnabled: false, permissions: [])
        onSettingsChange(updated)
        host.reload()
        if select != nil {
            statusFilter = .all
            searchText = ""
        }
        refresh()
        selectedPluginID = select
        synchronizeSelection()
    }

    func showOperationError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = t("The plugin operation failed. Check its manifest, compatibility, and folder access.")
        AppLogger.warning("Plugin operation failed. errorType=\(type(of: error))")
        alert.addButton(withTitle: t("OK"))
        alert.runModal()
    }

    func openFolder() {
        let dir = PluginRegistry.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func permissionText(_ permission: PluginCapability) -> String {
        if case .appleScript(let bundleID) = permission {
            return String(format: t(permission.displayKey), bundleID)
        }
        return t(permission.displayKey)
    }

}
