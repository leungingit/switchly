//
//  AppSettings.swift
//  Switchly
//
//  Main application settings model
//

import Foundation
import SwiftUI

struct AppSettings: Codable, Equatable {
    var previewStrategy: PreviewStrategy
    var shortcutPrefix: ShortcutPrefix
    var globalShortcutKey: String?
    var monitoredApps: [MonitoredApp]
    
    var thumbnailSize: ThumbnailSize
    var showWindowTitles: Bool
    var refreshInterval: TimeInterval
    var enableBackgroundBlur: Bool
    var backgroundBlurOpacity: Double
    
    var previewDisplayMode: PreviewDisplayMode
    var notificationStrategy: NotificationStrategy
    
    var launchAtLogin: Bool
    var hideMainWindowOnLaunch: Bool
    
    var monitorFrequency: MonitorFrequency

    var previewInfoShowsAppName: Bool
    var previewInfoShowsWindowNumber: Bool
    var previewInfoShowsProcessID: Bool
    var previewInfoShowsSize: Bool
    var previewInfoShowsPosition: Bool
    var language: AppLanguage
    var theme: AppTheme
    var workspaces: [Workspace]
    var defaultWorkspaceMissingAppDisplayMode: WorkspaceMissingAppDisplayMode
    var defaultWorkspaceWindowSortStrategy: WorkspaceWindowSortStrategy

    var dockPreviewEnabled: Bool
    var dockPreviewHoverEnabled: Bool
    var dockPreviewHoverDelay: Double
    var dockPreviewCardWidth: Double

    /// How the preview panel presents window previews. Defaults to the
    /// historical grid so an upgrade never changes what the user sees.
    var previewInteractionMode: PreviewInteractionMode
    /// How long the pointer must rest on a card before the window replica
    /// follows it. Keyboard navigation deliberately ignores this.
    var previewReplicaHoverDelay: Double

    /// Pointer-only ways to summon the preview panel. Both default to off so
    /// an upgrade never starts popping the panel on its own; each is safe to
    /// combine with the other and with the keyboard shortcuts.
    /// Edge hotspot: rest the pointer against a screen edge briefly.
    var previewHotspotEnabled: Bool
    var previewHotspotEdge: PreviewHotspotEdge
    /// Shake: wiggle the pointer back and forth, like macOS's
    /// shake-to-find-the-pointer.
    var previewShakeEnabled: Bool

    /// Local usage counters. Defaults to on (the panel can be cleared and the
    /// switch turned off; recorded data is never deleted behind the user's back).
    var usageStatisticsEnabled: Bool
    /// Which duration preset the efficiency estimate uses, plus the optional
    /// custom values. See docs/plan/2026-09-29-statistics-panel.md section 8.5.
    var efficiencyBaselinePreset: EfficiencyBaselinePreset
    var efficiencyBaselineCustom: EfficiencyBaselineValues?

    init(
        previewStrategy: PreviewStrategy,
        shortcutPrefix: ShortcutPrefix,
        globalShortcutKey: String?,
        monitoredApps: [MonitoredApp],
        thumbnailSize: ThumbnailSize,
        showWindowTitles: Bool,
        refreshInterval: TimeInterval,
        enableBackgroundBlur: Bool,
        backgroundBlurOpacity: Double = 0.30,
        previewDisplayMode: PreviewDisplayMode,
        notificationStrategy: NotificationStrategy,
        launchAtLogin: Bool,
        hideMainWindowOnLaunch: Bool,
        monitorFrequency: MonitorFrequency,
        previewInfoShowsAppName: Bool = false,
        previewInfoShowsWindowNumber: Bool = false,
        previewInfoShowsProcessID: Bool = false,
        previewInfoShowsSize: Bool = false,
        previewInfoShowsPosition: Bool = false,
        language: AppLanguage = .english,
        theme: AppTheme = .system,
        workspaces: [Workspace] = [],
        defaultWorkspaceMissingAppDisplayMode: WorkspaceMissingAppDisplayMode = .hidden,
        defaultWorkspaceWindowSortStrategy: WorkspaceWindowSortStrategy = .titleAscending,
        dockPreviewEnabled: Bool = false,
        dockPreviewHoverEnabled: Bool = true,
        dockPreviewHoverDelay: Double = 0.4,
        dockPreviewCardWidth: Double = 120,
        previewInteractionMode: PreviewInteractionMode = .highlightOnly,
        previewReplicaHoverDelay: Double = 0.4,
        previewHotspotEnabled: Bool = false,
        previewHotspotEdge: PreviewHotspotEdge = .left,
        previewShakeEnabled: Bool = false,
        usageStatisticsEnabled: Bool = true,
        efficiencyBaselinePreset: EfficiencyBaselinePreset = .standard,
        efficiencyBaselineCustom: EfficiencyBaselineValues? = nil
    ) {
        self.previewStrategy = previewStrategy
        self.shortcutPrefix = shortcutPrefix
        self.globalShortcutKey = globalShortcutKey
        self.monitoredApps = monitoredApps
        self.thumbnailSize = thumbnailSize
        self.showWindowTitles = showWindowTitles
        self.refreshInterval = refreshInterval
        self.enableBackgroundBlur = enableBackgroundBlur
        self.backgroundBlurOpacity = backgroundBlurOpacity
        self.previewDisplayMode = previewDisplayMode
        self.notificationStrategy = notificationStrategy
        self.launchAtLogin = launchAtLogin
        self.hideMainWindowOnLaunch = hideMainWindowOnLaunch
        self.monitorFrequency = monitorFrequency
        self.previewInfoShowsAppName = previewInfoShowsAppName
        self.previewInfoShowsWindowNumber = previewInfoShowsWindowNumber
        self.previewInfoShowsProcessID = previewInfoShowsProcessID
        self.previewInfoShowsSize = previewInfoShowsSize
        self.previewInfoShowsPosition = previewInfoShowsPosition
        self.language = language
        self.theme = theme
        self.workspaces = workspaces
        self.defaultWorkspaceMissingAppDisplayMode = defaultWorkspaceMissingAppDisplayMode
        self.defaultWorkspaceWindowSortStrategy = defaultWorkspaceWindowSortStrategy
        self.dockPreviewEnabled = dockPreviewEnabled
        self.dockPreviewHoverEnabled = dockPreviewHoverEnabled
        self.dockPreviewHoverDelay = dockPreviewHoverDelay
        self.dockPreviewCardWidth = dockPreviewCardWidth
        self.previewInteractionMode = previewInteractionMode
        self.previewReplicaHoverDelay = previewReplicaHoverDelay
        self.previewHotspotEnabled = previewHotspotEnabled
        self.previewHotspotEdge = previewHotspotEdge
        self.previewShakeEnabled = previewShakeEnabled
        self.usageStatisticsEnabled = usageStatisticsEnabled
        self.efficiencyBaselinePreset = efficiencyBaselinePreset
        self.efficiencyBaselineCustom = efficiencyBaselineCustom
    }

    enum CodingKeys: String, CodingKey {
        case previewStrategy
        case shortcutPrefix
        case globalShortcutKey
        case monitoredApps
        case thumbnailSize
        case showWindowTitles
        case refreshInterval
        case enableBackgroundBlur
        case backgroundBlurOpacity
        case previewDisplayMode
        case notificationStrategy
        case launchAtLogin
        case hideMainWindowOnLaunch
        case monitorFrequency
        case previewInfoShowsAppName
        case previewInfoShowsWindowNumber
        case previewInfoShowsProcessID
        case previewInfoShowsSize
        case previewInfoShowsPosition
        case language
        case theme
        case workspaces
        case defaultWorkspaceMissingAppDisplayMode
        case defaultWorkspaceWindowSortStrategy
        case dockPreviewEnabled
        case dockPreviewHoverEnabled
        case dockPreviewHoverDelay
        case dockPreviewCardWidth
        case previewInteractionMode
        case previewReplicaHoverDelay
        case previewHotspotEnabled
        case previewHotspotEdge
        case previewShakeEnabled
        case usageStatisticsEnabled
        case efficiencyBaselinePreset
        case efficiencyBaselineCustom
    }

    /// Keys that are read but never written.
    ///
    /// They live outside `CodingKeys` on purpose: the synthesized
    /// `encode(to:)` requires a stored property for every key, so a read-only
    /// key in that enum would stop `AppSettings` from conforming to `Encodable`.
    private enum RetiredCodingKeys: String, CodingKey {
        /// The delay's name before the enlarged pane became a window replica.
        case previewHeroHoverDelay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.previewStrategy = try container.decode(PreviewStrategy.self, forKey: .previewStrategy)
        self.shortcutPrefix = try container.decode(ShortcutPrefix.self, forKey: .shortcutPrefix)
        self.globalShortcutKey = try container.decodeIfPresent(String.self, forKey: .globalShortcutKey)
        self.monitoredApps = try container.decode([MonitoredApp].self, forKey: .monitoredApps)
        self.thumbnailSize = try container.decode(ThumbnailSize.self, forKey: .thumbnailSize)
        self.showWindowTitles = try container.decode(Bool.self, forKey: .showWindowTitles)
        self.refreshInterval = try container.decode(TimeInterval.self, forKey: .refreshInterval)
        self.enableBackgroundBlur = try container.decode(Bool.self, forKey: .enableBackgroundBlur)
        self.backgroundBlurOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundBlurOpacity) ?? 0.30
        self.previewDisplayMode = try container.decode(PreviewDisplayMode.self, forKey: .previewDisplayMode)
        self.notificationStrategy = try container.decode(NotificationStrategy.self, forKey: .notificationStrategy)
        self.launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        self.hideMainWindowOnLaunch = try container.decode(Bool.self, forKey: .hideMainWindowOnLaunch)
        self.monitorFrequency = try container.decode(MonitorFrequency.self, forKey: .monitorFrequency)
        self.previewInfoShowsAppName = try container.decodeIfPresent(Bool.self, forKey: .previewInfoShowsAppName) ?? false
        self.previewInfoShowsWindowNumber = try container.decodeIfPresent(Bool.self, forKey: .previewInfoShowsWindowNumber) ?? false
        self.previewInfoShowsProcessID = try container.decodeIfPresent(Bool.self, forKey: .previewInfoShowsProcessID) ?? false
        self.previewInfoShowsSize = try container.decodeIfPresent(Bool.self, forKey: .previewInfoShowsSize) ?? false
        self.previewInfoShowsPosition = try container.decodeIfPresent(Bool.self, forKey: .previewInfoShowsPosition) ?? false
        self.language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .english
        self.theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        self.workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        self.defaultWorkspaceMissingAppDisplayMode = try container.decodeIfPresent(WorkspaceMissingAppDisplayMode.self, forKey: .defaultWorkspaceMissingAppDisplayMode) ?? .hidden
        self.defaultWorkspaceWindowSortStrategy = try container.decodeIfPresent(WorkspaceWindowSortStrategy.self, forKey: .defaultWorkspaceWindowSortStrategy) ?? .titleAscending
        self.dockPreviewEnabled = try container.decodeIfPresent(Bool.self, forKey: .dockPreviewEnabled) ?? false
        self.dockPreviewHoverEnabled = try container.decodeIfPresent(Bool.self, forKey: .dockPreviewHoverEnabled) ?? true
        self.dockPreviewHoverDelay = try container.decodeIfPresent(Double.self, forKey: .dockPreviewHoverDelay) ?? 0.4
        self.dockPreviewCardWidth = try container.decodeIfPresent(Double.self, forKey: .dockPreviewCardWidth) ?? 120
        // Absent in settings written before the enlarged preview existed: keep
        // the historical grid behaviour instead of failing the whole decode.
        self.previewInteractionMode = try container.decodeIfPresent(
            PreviewInteractionMode.self,
            forKey: .previewInteractionMode
        ) ?? .highlightOnly
        // Renamed when the enlarged pane became a window replica; the old key
        // is still read (and never written) so a stored delay is not lost.
        let replicaHoverDelay = try container.decodeIfPresent(
            Double.self,
            forKey: .previewReplicaHoverDelay
        )
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        let legacyHoverDelay = try retired.decodeIfPresent(
            Double.self,
            forKey: .previewHeroHoverDelay
        )
        self.previewReplicaHoverDelay = replicaHoverDelay ?? legacyHoverDelay ?? 0.4
        // Absent in settings written before the pointer triggers existed:
        // both stay off so the panel never starts appearing on its own.
        self.previewHotspotEnabled = try container.decodeIfPresent(Bool.self, forKey: .previewHotspotEnabled) ?? false
        self.previewHotspotEdge = try container.decodeIfPresent(PreviewHotspotEdge.self, forKey: .previewHotspotEdge) ?? .left
        self.previewShakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .previewShakeEnabled) ?? false
        // Absent in settings written before the statistics panel existed:
        // statistics default to on, and the baseline falls back to the
        // recommended preset (EfficiencyBaseline.resolved does the clamping).
        self.usageStatisticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .usageStatisticsEnabled) ?? true
        self.efficiencyBaselinePreset = try container.decodeIfPresent(EfficiencyBaselinePreset.self, forKey: .efficiencyBaselinePreset) ?? .standard
        self.efficiencyBaselineCustom = try container.decodeIfPresent(EfficiencyBaselineValues.self, forKey: .efficiencyBaselineCustom)
    }
    
    static var `default`: AppSettings {
        AppSettings(
            previewStrategy: .configuredOnly,
            shortcutPrefix: .commandOption,
            globalShortcutKey: "p",
            monitoredApps: [],
            thumbnailSize: .medium,
            showWindowTitles: true,
            refreshInterval: 2.0,
            enableBackgroundBlur: true,
            backgroundBlurOpacity: 0.30,
            previewDisplayMode: .currentScreen,
            notificationStrategy: .intelligent,
            launchAtLogin: false,
            hideMainWindowOnLaunch: true,
            monitorFrequency: .balanced
        )
    }
}

enum AppLanguage: String, Codable, CaseIterable, Hashable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main
        }
        return bundle
    }

    func localizedString(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

enum AppTheme: String, Codable, CaseIterable, Hashable {
    case system
    case light
    case dark

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .system:
            return language.localizedString("Follow System")
        case .light:
            return language.localizedString("Light")
        case .dark:
            return language.localizedString("Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum PreviewDisplayMode: String, Codable {
    case currentScreen = "current"
    case primaryScreen = "primary"
}

/// Presentation mode of the preview panel.
///
/// Phase 1/2 of `docs/plan/2026-09-28-preview-panel-live-switch.md`, revised by
/// §15: the "Large preview" pane and the "Full screen preview" backdrop were
/// merged into one mode that replays the highlighted window at its own size, in
/// its own place, behind the thumbnail grid. Raw values are persisted, so
/// `init(from:)` still accepts the retired ones.
enum PreviewInteractionMode: String, Codable, CaseIterable, Hashable {
    /// Historical behaviour: a grid of thumbnails where selection only
    /// highlights. The default, and the fallback if a decode finds nothing.
    case highlightOnly = "highlightOnly"

    /// The merged enlarged mode: the panel keeps its thumbnail grid and stays
    /// in front, and a second window behind it replays the highlighted window
    /// at its original size and position, 1:1.
    ///
    /// The retired `heroPane` (an enlarged pane inside a bigger panel) and
    /// `heroPaneFullScreen` (that pane plus a screen-filling backdrop) both
    /// scaled the capture to fit a surface of their choosing. This mode scales
    /// nothing: it recreates the window.
    case windowReplica = "windowReplica"

    /// Reads the mode from storage, mapping the retired raw values onto the
    /// mode that replaced them. An upgrade must not silently reset a stored
    /// selection back to the grid.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.highlightOnly.rawValue:
            self = .highlightOnly
        case Self.windowReplica.rawValue, "heroPane", "heroPaneFullScreen":
            self = .windowReplica
        default:
            self = .highlightOnly
        }
    }

    /// Writes the current raw value. The retired values above are only ever
    /// *read*: a settings file that had one is rewritten with the merged mode on
    /// the next save.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether this mode adds the window replica behind the panel.
    var showsWindowReplica: Bool {
        self == .windowReplica
    }

    /// Cache tier the replica reads. Always the native tier: the replica
    /// replays the window at its own size, so any cap below that size would
    /// scale it down — which is exactly what this design removes.
    var replicaTier: ThumbnailTier {
        .native
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .highlightOnly:
            return language.localizedString("Highlight only")
        case .windowReplica:
            return language.localizedString("Window replica")
        }
    }

    /// One-line explanation shown under the picker in Preferences.
    func summary(language: AppLanguage) -> String {
        switch self {
        case .highlightOnly:
            return language.localizedString("Grid of thumbnails; selection is highlighted in place.")
        case .windowReplica:
            return language.localizedString("The grid stays in front; the highlighted window is replayed behind it at its original size and position.")
        }
    }
}

enum MonitorFrequency: String, Codable, CaseIterable {
    case highPerformance = "high"
    case balanced = "balanced"
    case powerSaving = "powerSaving"
    
    var interval: TimeInterval {
        switch self {
        case .highPerformance:
            return 1.0
        case .balanced:
            return 2.0
        case .powerSaving:
            return 5.0
        }
    }
}
