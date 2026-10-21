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
    /// Colour of the matte the window thumbnails sit on.
    ///
    /// A thumbnail never fills its card (rounded corners, aspect-fit), so the
    /// area behind the image is visible. It used to be a fixed black wash;
    /// this makes that backdrop tint adjustable.
    var thumbnailBackdrop: ThumbnailBackdrop
    /// Glass wash strength for the floating panels (preview, Dock preview,
    /// workspace bar) — surfaces that appear over the user's work and vanish.
    var backgroundBlurOpacity: Double
    /// 设置、工作区管理和统计等普通窗口共用的玻璃强度。
    /// 与临时浮动面板独立；沿用 preferencesGlassOpacity 存储键以兼容旧设置。
    var preferencesGlassOpacity: Double
    
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
    /// Optical crystal material: the four tunable parameters that replaced the
    /// former Ice / Quartz / Frameless presets.
    var crystalMaterial: CrystalMaterial
    /// Spatial layout style for the preview panel (Stage / Pill Matrix / Classic Grid / Frameless Tiles).
    var previewPanelStyle: PreviewPanelStyle

    init(
        previewStrategy: PreviewStrategy,
        shortcutPrefix: ShortcutPrefix,
        globalShortcutKey: String?,
        monitoredApps: [MonitoredApp],
        thumbnailSize: ThumbnailSize,
        showWindowTitles: Bool,
        refreshInterval: TimeInterval,
        enableBackgroundBlur: Bool,
        thumbnailBackdrop: ThumbnailBackdrop = .legacyDefault,
        backgroundBlurOpacity: Double = 0.30,
        preferencesGlassOpacity: Double = 0.70,
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
        efficiencyBaselineCustom: EfficiencyBaselineValues? = nil,
        crystalMaterial: CrystalMaterial = .legacyDefault,
        previewPanelStyle: PreviewPanelStyle = .classicGrid
    ) {
        self.previewStrategy = previewStrategy
        self.shortcutPrefix = shortcutPrefix
        self.globalShortcutKey = globalShortcutKey
        self.monitoredApps = monitoredApps
        self.thumbnailSize = thumbnailSize
        self.showWindowTitles = showWindowTitles
        self.refreshInterval = refreshInterval
        self.enableBackgroundBlur = enableBackgroundBlur
        self.thumbnailBackdrop = thumbnailBackdrop
        self.backgroundBlurOpacity = backgroundBlurOpacity
        self.preferencesGlassOpacity = preferencesGlassOpacity
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
        self.crystalMaterial = crystalMaterial
        self.previewPanelStyle = previewPanelStyle
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
        case thumbnailBackdrop
        case backgroundBlurOpacity
        case preferencesGlassOpacity
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
        case crystalMaterial
        case previewPanelStyle
    }

    /// Keys that are read but never written.
    ///
    /// They live outside `CodingKeys` on purpose: the synthesized
    /// `encode(to:)` requires a stored property for every key, so a read-only
    /// key in that enum would stop `AppSettings` from conforming to `Encodable`.
    private enum RetiredCodingKeys: String, CodingKey {
        /// The delay's name before the enlarged pane became a window replica.
        case previewHeroHoverDelay
        /// The three material presets, replaced by the four tunable parameters
        /// in `CrystalMaterial`. Read once so an existing choice is carried
        /// over, never written again.
        case crystalThemePreset
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
        // Absent in settings written before the backdrop became adjustable: the
        // fixed black wash is what those files rendered, so the default keeps
        // the upgrade invisible.
        if let backdrop = try container.decodeIfPresent(ThumbnailBackdrop.self, forKey: .thumbnailBackdrop) {
            self.thumbnailBackdrop = backdrop.clamped()
        } else {
            self.thumbnailBackdrop = .legacyDefault
        }
        self.backgroundBlurOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundBlurOpacity) ?? 0.30
        // Absent before the settings window got its own control: keep the
        // window opaque enough that text over a bright desktop stays readable,
        // which is what the fixed value effectively was.
        self.preferencesGlassOpacity = try container.decodeIfPresent(Double.self, forKey: .preferencesGlassOpacity) ?? 0.70
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
        // The material used to be one of three presets. Each preset is now
        // expanded into the four parameters it stood for, so an existing user
        // keeps the look they chose instead of silently reverting to Ice.
        if let material = try container.decodeIfPresent(CrystalMaterial.self, forKey: .crystalMaterial) {
            self.crystalMaterial = material.clamped()
        } else {
            let legacyPreset = try retired.decodeIfPresent(String.self, forKey: .crystalThemePreset)
            self.crystalMaterial = CrystalMaterial.legacy(expandedFrom: legacyPreset)
        }
        self.previewPanelStyle = try container.decodeIfPresent(PreviewPanelStyle.self, forKey: .previewPanelStyle) ?? .classicGrid
    }
    
    var panelGlassDensity: Double { crystalMaterial.sharedDensity ?? backgroundBlurOpacity }
    var windowGlassDensity: Double { crystalMaterial.sharedDensity ?? preferencesGlassOpacity }

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
            thumbnailBackdrop: .legacyDefault,
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

/// Which surface the floating panels are drawn on.
///
/// The crystal material used to be one of three fixed presets. It is now four
/// independent parameters (see `CrystalMaterial`); this enum only keeps the one
/// difference those parameters cannot express: whether a panel draws its glass
/// at all. `clear` dissolves the outer box so the cards float directly on the
/// desktop, which is a structure, not a colour.
enum CrystalPanelMaterial: String, Codable, CaseIterable, Hashable {
    case glass = "glass"
    case clear = "clear"

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .glass:
            return language.localizedString("Glass panel")
        case .clear:
            return language.localizedString("No panel")
        }
    }
}

/// Material selection is shared by floating panels and standard windows.
enum GlassStyle: String, Codable, CaseIterable {
    case transparent, frosted, opaque

    func displayName(language: AppLanguage) -> String {
        language.localizedString(self == .transparent ? "Clear glass" : self == .frosted ? "Frosted glass" : "Glass off")
    }
}

/// Controls only the system blur backing, independently of the window's text theme.
enum GlassBaseTone: String, Codable, CaseIterable {
    case automatic, light, dark

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .automatic: return language.localizedString("Match appearance")
        case .light: return language.localizedString("Light glass")
        case .dark: return language.localizedString("Dark glass")
        }
    }
}

/// The crystal material, as independent, user-editable parameters.
///
/// This replaced the former Ice / Quartz / Frameless presets. The presets were
/// only ever a colour plus three near-identical alphas (0.18/0.20/0.24 sheen,
/// 0.57/0.62/0.68 rim) — differences too small to see — so they added a
/// choice without adding a change. Each knob here maps to one line of the
/// render and is visible on its own.
struct CrystalMaterial: Hashable {
    /// Hue of the shared glass tint. Optical highlights remain neutral white.
    var tintColor: Color
    /// System material tone; automatic preserves existing settings.
    var baseTone: GlassBaseTone = .automatic
    var glassStyle: GlassStyle = .frosted
    /// nil preserves the two old strengths until the user moves the shared control.
    var sharedDensity: Double? = nil
    var cardOpacity: Double = 0.10
    /// Top specular sheen alpha for cards and panels (0–0.60).
    var topSheenOpacity: Double
    /// 面板和普通窗口共用的水晶染色强度（0–1）。保留旧存储键。
    var panelTintCap: Double
    /// Specular rim highlight top alpha (0–1).
    var rimTopOpacity: Double
    /// Whether panels draw their glass surface at all.
    var panelMaterial: CrystalPanelMaterial

    /// The values the presets shipped with, so an upgrade looks unchanged.
    ///
    /// These are the `ice` values (cold blue, 0.18 sheen, full panel tint,
    /// 0.57 rim), which were also the defaults for a fresh install.
    static let legacyDefault = CrystalMaterial(
        tintColor: Color(red: 60.0 / 255, green: 150.0 / 255, blue: 240.0 / 255),
        topSheenOpacity: 0.18,
        panelTintCap: 1.0,
        rimTopOpacity: 0.57,
        panelMaterial: .glass
    )

    /// Ranges the Preferences sliders offer. Kept here so the controls, the
    /// decode clamp and the QA checks cannot drift apart.
    enum Range {
        static let card: ClosedRange<Double> = 0...0.8
        static let sheen: ClosedRange<Double> = 0...0.60
        static let panelTint: ClosedRange<Double> = 0...1
        static let rim: ClosedRange<Double> = 0...1
    }

    func clamped() -> CrystalMaterial {
        var copy = self
        copy.cardOpacity = min(max(copy.cardOpacity, Range.card.lowerBound), Range.card.upperBound)
        copy.sharedDensity = copy.sharedDensity.map { min(max($0, 0), 1) }
        copy.topSheenOpacity = min(max(copy.topSheenOpacity, Range.sheen.lowerBound), Range.sheen.upperBound)
        copy.panelTintCap = min(max(copy.panelTintCap, Range.panelTint.lowerBound), Range.panelTint.upperBound)
        copy.rimTopOpacity = min(max(copy.rimTopOpacity, Range.rim.lowerBound), Range.rim.upperBound)
        return copy
    }

    /// Expands a retired preset into the parameters it used to stand for.
    ///
    /// The numbers are the ones the preset table held before it was removed;
    /// they are repeated here (rather than kept in a live enum) solely so a
    /// settings file written by an older build decodes to the same pixels.
    static func legacy(expandedFrom raw: String?) -> CrystalMaterial {
        switch raw {
        case "quartz":
            return CrystalMaterial(
                tintColor: Color(red: 235.0 / 255, green: 163.0 / 255, blue: 110.0 / 255),
                topSheenOpacity: 0.20,
                panelTintCap: 1.0,
                rimTopOpacity: 0.62,
                panelMaterial: .glass
            )
        case "frameless":
            // "Frameless" meant two things: a near-zero panel wash and no
            // panel surface at all. The second is structural and now lives on
            // the material switch, so carry it there instead of leaving the
            // user with an invisible 0.02 wash.
            return CrystalMaterial(
                tintColor: Color(red: 178.0 / 255, green: 178.0 / 255, blue: 178.0 / 255),
                topSheenOpacity: 0.24,
                panelTintCap: 1.0,
                rimTopOpacity: 0.68,
                panelMaterial: .clear
            )
        default:
            return .legacyDefault
        }
    }
}

// MARK: - CrystalMaterial Codable

extension CrystalMaterial: Codable {
    enum CodingKeys: String, CodingKey {
        case tintColor
        case baseTone
        case glassStyle
        case sharedDensity
        case cardOpacity
        case topSheenOpacity
        case panelTintCap
        case rimTopOpacity
        case panelMaterial
    }

    /// The tint is stored as three sRGB components rather than an archived
    /// colour: the settings file is JSON and `Color` has no canonical encoded
    /// form, so a component triple is what survives a round trip on every OS.
    private struct RGB: Codable {
        var red: Double
        var green: Double
        var blue: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CrystalMaterial.legacyDefault
        let rgb = try container.decodeIfPresent(RGB.self, forKey: .tintColor)
        self.tintColor = rgb.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? fallback.tintColor
        self.baseTone = try container.decodeIfPresent(GlassBaseTone.self, forKey: .baseTone) ?? .automatic
        self.glassStyle = try container.decodeIfPresent(GlassStyle.self, forKey: .glassStyle) ?? .frosted
        self.cardOpacity = min(max(try container.decodeIfPresent(Double.self, forKey: .cardOpacity) ?? 0.10, 0), 0.3)
        self.sharedDensity = try container.decodeIfPresent(Double.self, forKey: .sharedDensity).map { min(max($0, 0), 1) }
        self.topSheenOpacity = try container.decodeIfPresent(Double.self, forKey: .topSheenOpacity) ?? fallback.topSheenOpacity
        self.panelTintCap = try container.decodeIfPresent(Double.self, forKey: .panelTintCap) ?? fallback.panelTintCap
        self.rimTopOpacity = try container.decodeIfPresent(Double.self, forKey: .rimTopOpacity) ?? fallback.rimTopOpacity
        self.panelMaterial = try container.decodeIfPresent(CrystalPanelMaterial.self, forKey: .panelMaterial) ?? fallback.panelMaterial
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let resolved = NSColor(tintColor).usingColorSpace(.sRGB) ?? .systemBlue
        try container.encode(RGB(red: Double(resolved.redComponent),
                                  green: Double(resolved.greenComponent),
                                  blue: Double(resolved.blueComponent)),
                             forKey: .tintColor)
        try container.encode(baseTone, forKey: .baseTone)
        try container.encode(glassStyle, forKey: .glassStyle)
        try container.encodeIfPresent(sharedDensity, forKey: .sharedDensity)
        try container.encode(cardOpacity, forKey: .cardOpacity)
        try container.encode(topSheenOpacity, forKey: .topSheenOpacity)
        try container.encode(panelTintCap, forKey: .panelTintCap)
        try container.encode(rimTopOpacity, forKey: .rimTopOpacity)
        try container.encode(panelMaterial, forKey: .panelMaterial)
    }
}

/// The matte the window thumbnail sits on.
///
/// A thumbnail never covers its whole card — the image is aspect-fitted and
/// the corners are rounded — so the area behind it is visible. It used to be
/// a hard-coded black wash (0.16 on glass panels, 0.06 on opaque ones); this
/// makes that backdrop tint adjustable instead of leaving it as a fixed
/// blue-black.
///
/// Two dimensions, matching the style of CrystalMaterial: the colour and
/// how strongly it is laid down.
struct ThumbnailBackdrop: Hashable {
    /// Colour of the matte behind the thumbnail.
    var tintColor: Color
    /// How strongly the matte is laid down (0-0.60).
    var opacity: Double

    /// The values the hard-coded wash used, so an upgrade looks unchanged:
    /// black at 0.16 on glass panels.
    static let legacyDefault = ThumbnailBackdrop(
        tintColor: .black,
        opacity: 0.16
    )

    /// Ranges the Preferences slider offers. Kept here so the control and the
    /// decode clamp cannot drift apart.
    enum Range {
        static let opacity: ClosedRange<Double> = 0...0.60
    }

    func clamped() -> ThumbnailBackdrop {
        var copy = self
        copy.opacity = min(max(copy.opacity, Range.opacity.lowerBound), Range.opacity.upperBound)
        return copy
    }

    /// The requested strength is the actual matte alpha, independent of the
    /// panel style. A hidden solid-panel multiplier made this slider misleading.
    func resolvedColor() -> Color {
        tintColor.opacity(opacity)
    }
}

// MARK: - ThumbnailBackdrop Codable

extension ThumbnailBackdrop: Codable {
    enum CodingKeys: String, CodingKey {
        case tintColor
        case opacity
    }

    /// The tint is stored as three sRGB components rather than an archived
    /// colour: the settings file is JSON and Color has no canonical encoded
    /// form, so a component triple is what survives a round trip on every OS.
    private struct RGB: Codable {
        var red: Double
        var green: Double
        var blue: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThumbnailBackdrop.legacyDefault
        let rgb = try container.decodeIfPresent(RGB.self, forKey: .tintColor)
        self.tintColor = rgb.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? fallback.tintColor
        self.opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? fallback.opacity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let resolved = NSColor(tintColor).usingColorSpace(.sRGB) ?? .black
        try container.encode(RGB(red: Double(resolved.redComponent),
                                  green: Double(resolved.greenComponent),
                                  blue: Double(resolved.blueComponent)),
                             forKey: .tintColor)
        try container.encode(opacity, forKey: .opacity)
    }
}

/// Spatial layout presets for the floating preview panel, selectable in Preferences.
///
/// Every case must change the layout it names — a case that renders like
/// another one is a dead setting. `pillMatrix` and `framelessTiles` were
/// removed for exactly that reason: they were selectable but rendered the
/// classic grid (work/qa/report.md §1).
enum PreviewPanelStyle: String, Codable, CaseIterable, Hashable {
    case stage = "stage"
    case classicGrid = "classicGrid"

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .stage:
            return language.localizedString("Spatial Stage")
        case .classicGrid:
            return language.localizedString("Crystal Grid")
        }
    }

    /// Grid cell shape. Cards keep the same information; the stage variant
    /// shows a shorter thumbnail so the focus banner fits above it.
    enum Cell {
        case grid
        case stage
    }

    var cell: Cell {
        switch self {
        case .stage:
            return .stage
        case .classicGrid:
            return .grid
        }
    }

    /// Minimum cell width. The stage layout runs tighter so the four-column
    /// matrix still fits beside the ornament rail.
    func minimumCardWidth(for size: ThumbnailSize) -> CGFloat {
        switch cell {
        case .grid:
            return size.previewCardMinWidth
        case .stage:
            return size.previewCardMinWidth * 0.75
        }
    }

    /// Thumbnail height multiplier. Stage is authoritative about the focused
    /// window (the banner), so its grid cells are shorter than the classic grid.
    var thumbnailHeightScale: CGFloat {
        switch cell {
        case .grid:
            return 1.0
        case .stage:
            return 0.65
        }
    }
}
