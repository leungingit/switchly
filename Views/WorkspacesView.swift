//
//  WorkspacesView.swift
//  Switchly
//
//  Workspace management window
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class WorkspacesViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var availableApps: [WorkspaceAppItem] = []
    @Published var selectedWorkspaceID: UUID?
    @Published var errorMessage: String?

    private let settingsService: SettingsServiceProtocol
    private let shortcutService: ShortcutServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsService: SettingsServiceProtocol = SettingsService.shared,
        shortcutService: ShortcutServiceProtocol = ShortcutService.shared
    ) {
        self.settingsService = settingsService
        self.shortcutService = shortcutService
        self.settings = settingsService.loadSettings()
        self.selectedWorkspaceID = settings.workspaces.first?.id
        loadAvailableApps()
        observeAppearanceChanges()
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else {
            return nil
        }
        return settings.workspaces.first { $0.id == selectedWorkspaceID }
    }

    func addWorkspace() {
        let workspace = Workspace(
            name: "Workspace \(settings.workspaces.count + 1)",
            missingAppDisplayMode: settings.defaultWorkspaceMissingAppDisplayMode,
            windowSortStrategy: settings.defaultWorkspaceWindowSortStrategy
        )
        settings.workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        saveSettings()
    }

    func deleteSelectedWorkspace() {
        guard let selectedWorkspaceID else {
            return
        }
        settings.workspaces.removeAll { $0.id == selectedWorkspaceID }
        self.selectedWorkspaceID = settings.workspaces.first?.id
        saveSettings()
    }

    func moveSelectedWorkspace(offset: Int) {
        guard let selectedWorkspaceID,
              let index = settings.workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) else {
            return
        }
        let nextIndex = index + offset
        guard settings.workspaces.indices.contains(nextIndex) else {
            return
        }
        settings.workspaces.swapAt(index, nextIndex)
        saveSettings()
    }

    func updateSelectedWorkspace(_ update: (inout Workspace) -> Void) {
        guard let selectedWorkspaceID,
              let index = settings.workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) else {
            return
        }
        update(&settings.workspaces[index])
        saveSettings()
    }

    func setShortcutKey(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let conflict = shortcutConflict(for: trimmedKey) {
            errorMessage = conflict
            return
        }
        updateSelectedWorkspace { workspace in
            workspace.shortcutKey = trimmedKey.isEmpty ? nil : trimmedKey
        }
    }

    func addApp(_ appItem: WorkspaceAppItem) {
        updateSelectedWorkspace { workspace in
            guard !workspace.appItems.contains(where: { $0.bundleIdentifier == appItem.bundleIdentifier }) else {
                return
            }
            workspace.appItems.append(appItem)
        }
    }

    func removeApp(_ appItem: WorkspaceAppItem) {
        updateSelectedWorkspace { workspace in
            workspace.appItems.removeAll { $0.id == appItem.id }
        }
    }

    func moveApp(_ appItem: WorkspaceAppItem, offset: Int) {
        updateSelectedWorkspace { workspace in
            guard let index = workspace.appItems.firstIndex(where: { $0.id == appItem.id }) else {
                return
            }
            let nextIndex = index + offset
            guard workspace.appItems.indices.contains(nextIndex) else {
                return
            }
            workspace.appItems.swapAt(index, nextIndex)
        }
    }

    func availableAppsForSelectedWorkspace() -> [WorkspaceAppItem] {
        guard let selectedWorkspace else {
            return availableApps
        }
        let configuredBundleIDs = Set(selectedWorkspace.appItems.map(\.bundleIdentifier))
        return availableApps.filter { !configuredBundleIDs.contains($0.bundleIdentifier) }
    }

    func shortcutConflict(for key: String) -> String? {
        guard !key.isEmpty else {
            return nil
        }
        let normalizedKey = key.lowercased()

        if settings.globalShortcutKey?.lowercased() == normalizedKey {
            return "Shortcut conflicts with Toggle Preview."
        }
        if settings.monitoredApps.contains(where: { $0.shortcutKey?.lowercased() == normalizedKey }) {
            return "Shortcut conflicts with an app shortcut."
        }
        if settings.workspaces.contains(where: { workspace in
            workspace.id != selectedWorkspaceID && workspace.shortcutKey?.lowercased() == normalizedKey
        }) {
            return "Shortcut conflicts with another workspace."
        }
        return nil
    }

    private func saveSettings() {
        do {
            try settingsService.saveSettings(settings)
            shortcutService.setupGlobalShortcuts()
        } catch {
            errorMessage = "Failed to save workspaces: \(error.localizedDescription)"
            AppLogger.error("Failed to save workspaces. error=\(error)")
        }
    }

    /// Apps that can still be added to the selected workspace, filtered by
    /// `query`.
    ///
    /// The search is shared with the preferences picker so the two surfaces
    /// cannot drift into matching different fields.
    func filteredAvailableApps(query: String) -> [WorkspaceAppItem] {
        InstalledAppsService.filter(availableAppsForSelectedWorkspace(), query: query)
    }

    /// Points the picker at the installed-apps service.
    ///
    /// The list used to be built from `runningApplications` and to drop
    /// every `com.apple.*` bundle, which is why an app that was not running
    /// — and every Apple app, Safari included — could not be found at all. See
    /// `InstalledAppsService`.
    private func loadAvailableApps() {
        applyAvailableApps(InstalledAppsService.shared.apps)
        InstalledAppsService.shared.reload()
        observeAvailableApps()
    }

    private func applyAvailableApps(_ apps: [InstalledApp]) {
        availableApps = apps.map {
            WorkspaceAppItem(bundleIdentifier: $0.bundleIdentifier, appName: $0.appName)
        }
    }

    /// Re-reads the service whenever it re-enumerates, so an app installed or
    /// removed while this window is open shows up without reopening it.
    private func observeAvailableApps() {
        NotificationCenter.default.publisher(for: InstalledAppsService.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyAvailableApps(InstalledAppsService.shared.apps)
            }
            .store(in: &cancellables)
    }

    private func observeAppearanceChanges() {
        NotificationCenter.default.publisher(for: .settingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let latestSettings = settingsService.loadSettings()
                // 只同步外观，保留正在编辑的工作区及当前选择。
                settings.theme = latestSettings.theme
                settings.preferencesGlassOpacity = latestSettings.preferencesGlassOpacity
                settings.crystalMaterial = latestSettings.crystalMaterial
                ThemeApplier.apply(settings.theme)
            }
            .store(in: &cancellables)
    }
}

struct WorkspacesView: View {
    @StateObject private var viewModel = WorkspacesViewModel()
    @State private var appSearchText = ""

    var body: some View {
        ZStack {
            panelBackground
                .ignoresSafeArea() // Extend the glass under the hidden title bar

            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
        }
        .frame(width: 860, height: 560)
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
        WindowGlassSurface(
            opacity: viewModel.settings.preferencesGlassOpacity,
            material: viewModel.settings.crystalMaterial,
            style: .workspace
        )
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack {
                Text(t("Workspaces"))
                    .font(.headline)
                Spacer()
                Button(action: viewModel.addWorkspace) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(t("Add"))
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(viewModel.settings.workspaces) { workspace in
                        Button {
                            viewModel.selectedWorkspaceID = workspace.id
                        } label: {
                            HStack {
                                Text(workspace.name)
                                    .lineLimit(1)
                                Spacer()
                                if let shortcutKey = workspace.shortcutKey, !shortcutKey.isEmpty {
                                    Text("\(viewModel.settings.shortcutPrefix.displayName)\(shortcutKey.uppercased())")
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .liquidGlass(
                                isActive: workspace.id == viewModel.selectedWorkspaceID,
                                opacity: 0.18,
                                cornerRadius: 8,
                                tintColor: Color.accentColor,
                                interactive: false,
                                fallbackColor: Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                iconButton(t("Move Up"), systemImage: "chevron.up") {
                    viewModel.moveSelectedWorkspace(offset: -1)
                }
                iconButton(t("Move Down"), systemImage: "chevron.down") {
                    viewModel.moveSelectedWorkspace(offset: 1)
                }
                Spacer()
                iconButton(t("Delete"), systemImage: "trash") {
                    viewModel.deleteSelectedWorkspace()
                }
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    @ViewBuilder
    private var detail: some View {
        if let workspace = viewModel.selectedWorkspace {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(t("Workspace"), subtitle: t("Apps, shortcut, and display behavior"))

                    settingsGroup(t("Details")) {
                        settingRow(t("Name"), systemImage: "text.cursor") {
                            TextField("", text: Binding(
                                get: { viewModel.selectedWorkspace?.name ?? "" },
                                set: { name in viewModel.updateSelectedWorkspace { $0.name = name } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                        }

                        settingRow(t("Shortcut"), systemImage: "keyboard") {
                            HStack(spacing: 8) {
                                Text(viewModel.settings.shortcutPrefix.displayName)
                                    .font(.body.monospaced())
                                    .foregroundColor(.secondary)
                                Picker("", selection: Binding(
                                    get: { viewModel.selectedWorkspace?.shortcutKey ?? "" },
                                    set: { viewModel.setShortcutKey($0) }
                                )) {
                                    Text(t("None")).tag("")
                                    Divider()
                                    ForEach(shortcutChoices, id: \.self) { key in
                                        Text(key.uppercased()).tag(key)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }
                        }

                        settingRow(t("Missing apps"), systemImage: "app.badge") {
                            Picker("", selection: Binding(
                                get: { viewModel.selectedWorkspace?.missingAppDisplayMode ?? .hidden },
                                set: { mode in viewModel.updateSelectedWorkspace { $0.missingAppDisplayMode = mode } }
                            )) {
                                ForEach(WorkspaceMissingAppDisplayMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName(language: viewModel.settings.language)).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 260)
                        }

                        settingRow(t("Window sort"), systemImage: "arrow.up.arrow.down") {
                            Picker("", selection: Binding(
                                get: { viewModel.selectedWorkspace?.windowSortStrategy ?? .titleAscending },
                                set: { strategy in viewModel.updateSelectedWorkspace { $0.windowSortStrategy = strategy } }
                            )) {
                                ForEach(WorkspaceWindowSortStrategy.allCases, id: \.self) { strategy in
                                    Text(strategy.displayName(language: viewModel.settings.language)).tag(strategy)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                    }

                    settingsGroup(t("Apps")) {
                        workspaceApps(workspace.appItems)
                    }

                    settingsGroup(t("Add Apps")) {
                        addAppsList
                    }
                }
                .padding(22)
            }
        } else {
            VStack(spacing: 12) {
                Text(t("No workspace selected"))
                    .font(.headline)
                Button(t("Create Workspace")) {
                    viewModel.addWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func workspaceApps(_ appItems: [WorkspaceAppItem]) -> some View {
        VStack(spacing: 0) {
            if appItems.isEmpty {
                emptyInline(t("No apps in this workspace"))
            } else {
                ForEach(appItems) { appItem in
                    HStack(spacing: 10) {
                        appIcon(appItem)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appItem.appName)
                                .lineLimit(1)
                            Text(appItem.bundleIdentifier)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        iconButton(t("Move Up"), systemImage: "chevron.up") {
                            viewModel.moveApp(appItem, offset: -1)
                        }
                        iconButton(t("Move Down"), systemImage: "chevron.down") {
                            viewModel.moveApp(appItem, offset: 1)
                        }
                        iconButton(t("Remove"), systemImage: "minus.circle") {
                            viewModel.removeApp(appItem)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Divider()
                }
            }
        }
    }

    private var addAppsList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(t("Search apps"), text: $appSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)

            Divider()

            let apps = viewModel.filteredAvailableApps(query: appSearchText)
            if apps.isEmpty {
                emptyInline(t("No available apps"))
            } else {
                ForEach(apps) { appItem in
                    HStack(spacing: 10) {
                        appIcon(appItem)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appItem.appName)
                                .lineLimit(1)
                            Text(appItem.bundleIdentifier)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        iconButton(t("Add"), systemImage: "plus.circle.fill") {
                            viewModel.addApp(appItem)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Divider()
                }
            }
        }
    }

    private var shortcutChoices: [String] {
        ["space"] + (0...9).map(String.init) + (65...90).compactMap { UnicodeScalar($0).map { String($0).lowercased() } }
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
            .cardSurface(
                fill: Color.crystalSurfaceBase.opacity(0.10),
                cornerRadius: DesignTokens.Radius.card,
                material: viewModel.settings.crystalMaterial
            )
            .crystalSpecularRim(
                cornerRadius: DesignTokens.Radius.card,
                material: viewModel.settings.crystalMaterial
            )
        }
    }

    private func settingRow<Content: View>(_ title: String, systemImage: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 22)
            Text(title)
            Spacer(minLength: 16)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func iconButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(label)
    }

    private func emptyInline(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(22)
    }

    private func appIcon(_ appItem: WorkspaceAppItem) -> some View {
        Image(nsImage: icon(for: appItem))
            .resizable()
            .frame(width: 28, height: 28)
    }

    private func icon(for appItem: WorkspaceAppItem) -> NSImage {
        // Cached per bundle id — the raw call hits the file system on every
        // row render.
        AppIconCache.icon(forBundleIdentifier: appItem.bundleIdentifier)
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
    }

    private func t(_ key: String) -> String {
        viewModel.settings.language.localizedString(key)
    }
}

#Preview {
    WorkspacesView()
}
