import AppKit
import SwiftUI

/// 模拟 Dock 的浮层：与本体 Dock 预览一致的薄面板壳 —— 标题头 + 窗口条 + 窗口卡片，
/// 并按 `Sources/Views/DockPreviewView.swift` 的规则挂载插件槽位。
///
/// 这里只组装共享组件（`DockWindowCard`、`PluginSlotSurface`、材质与动效令牌），
/// 不复制卡片或插件渲染实现；窗口、缩略图、交通灯都是模拟数据。
struct PreviewDockPanelView: View {
    @ObservedObject var state: PluginPreviewState
    let appName: String
    let bundleID: String
    let width: CGFloat
    let options: PreviewMockDockOptions
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    private let windows: [WindowInfo]
    private let thumbnails: [CGWindowID: NSImage]
    private let settings: AppSettings

    init(state: PluginPreviewState, appName: String, bundleID: String, width: CGFloat,
         options: PreviewMockDockOptions = PreviewMockDockOptions(),
         maxHeight: CGFloat = .infinity) {
        self.state = state
        self.appName = appName
        self.bundleID = bundleID
        self.width = width
        self.options = options
        self.maxHeight = maxHeight

        let language = state.environment.language
        let windows = PreviewMockWindows.make(appName: appName, bundleID: bundleID, count: options.windowCount)
        self.windows = windows
        self.thumbnails = Dictionary(uniqueKeysWithValues: windows.map { window in
            let image = PreviewMockWindows.placeholderThumbnail(
                title: window.windowTitle,
                appName: appName,
                bundleID: bundleID
            )
            return (window.id, image)
        })
        self.settings = PreviewMockDockSettings.make(environment: state.environment, language: language, options: options)
    }

    /// 与本体 `DockPreviewView` 同一判定：玻璃开关开且材质不是 opaque。
    private var isGlassActive: Bool {
        settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque
    }

    private var centerEntries: [PluginSlotSurface.Entry] { state.slots[.center] ?? [] }
    private var bottomBarEntries: [PluginSlotSurface.Entry] { state.slots[.bottomBar] ?? [] }

    var body: some View {
        // 内容超过可用高度时浮层内部滚动（本体按屏幕高度限高），而不是被右栏裁掉。
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                header
                if windows.isEmpty {
                    if centerEntries.isEmpty { emptyState }
                } else {
                    windowStrip
                }
                centerSlot
            }
            .frame(width: width)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: MockDockContentHeightKey.self, value: proxy.size.height)
            })
        }
        .onPreferenceChange(MockDockContentHeightKey.self) { contentHeight = $0 }
        // 首帧未量到高度时先按上限给，量到后收到内容高度。
        .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : (maxHeight.isFinite ? maxHeight : nil))
        .frame(width: width)
        .panelGlass(
            isActive: isGlassActive,
            opacity: min(max(settings.panelGlassDensity, 0), 1),
            cornerRadius: GlassPanelCorner.radius,
            material: settings.crystalMaterial
        )
        // 本体由面板窗口把内容裁成 GlassPanelCorner 圆角；这里没有独立窗口，
        // 不透明（玻璃关）分支的底色是直角矩形，必须自己裁，否则玻璃开关会让外形跳变。
        .clipShape(RoundedRectangle(cornerRadius: GlassPanelCorner.radius, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .preferredColorScheme(state.environment.theme.colorScheme)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            appIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.headline)
                    .lineLimit(1)
                Text(String(format: t("%d windows"), windows.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var appIcon: some View {
        Group {
            if let icon = AppIconCache.icon(forBundleIdentifier: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    // MARK: - Window strip

    private var windowStrip: some View {
        let spec = settings.dockPreviewLayout.spec
        let content = Group {
            switch spec.axis {
            case .horizontal:
                HStack(spacing: spec.spacing) { windowCards }
            case .vertical:
                // 与本体同一网格规格；模拟窗口最多 5 个，不需要纵向滚动容器。
                let cardWidth = DockPanelMetrics.cardSize(cardWidth: settings.dockPreviewCardWidth).width
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spec.spacing, alignment: .top),
                                   count: spec.columns(for: windows.count)),
                    alignment: .center,
                    spacing: spec.spacing
                ) { windowCards }
            }
        }
        // 与本体窗口条同一内边距；窗口条比面板窄时居中，使其与下方插件卡片对齐。
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: width, alignment: .center)
        return Group {
            if spec.axis == .horizontal {
                ScrollView(.horizontal, showsIndicators: false) { content.frame(minWidth: width) }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var windowCards: some View {
        ForEach(windows) { window in
            DockWindowCard(
                window: window,
                isSelected: false,
                settings: settings,
                // 本体只把 bottomBar 挂到第一张窗口卡片。
                pluginOverlay: window.id == windows.first?.id ? bottomBarOverlay : nil,
                // 交通灯只作展示：不可点，也不调用 AX。
                trafficLights: AnyView(PreviewMockTrafficLights()),
                initialThumbnail: { window in
                    thumbnails[window.id].map(ThumbnailLoadState.loaded) ?? .loading
                },
                loadThumbnail: { _, _ in throw CocoaError(.featureUnsupported) },
                thumbnailRefresh: { _, _ in nil }
            )
        }
    }

    private var bottomBarOverlay: AnyView? {
        guard !bottomBarEntries.isEmpty else { return nil }
        return AnyView(
            pluginSurface(bottomBarEntries)
                .environment(\.pluginSceneNow, state.virtualNowSeconds.map { now in { now } })
        )
    }

    // MARK: - Center slot

    @ViewBuilder
    private var centerSlot: some View {
        if !centerEntries.isEmpty {
            // 本体不再给 center 套第二层卡片：插件槽位自带材质，只留与窗口条的间距。
            pluginSurface(centerEntries)
                .environment(\.pluginSceneNow, state.virtualNowSeconds.map { now in { now } })
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.sm)
        }
    }

    private func pluginSurface(_ entries: [PluginSlotSurface.Entry]) -> some View {
        PluginSlotSurface(
            entries: entries,
            material: settings.crystalMaterial,
            isGlassActive: isGlassActive,
            artwork: state.artwork,
            fallback: nil
        ) { pluginID, actionID, value in
            // 与平铺预览相同的动作路径：真实进入插件会话。
            state.perform(pluginID: pluginID, actionID: actionID, value: value)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(t("No windows"))
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .accessibilityHidden(true)
    }

    private func t(_ key: String) -> String {
        state.environment.language.localizedString(key)
    }
}

private struct MockDockContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 只展示的交通灯：三个固定系统色圆点，不可点击、不进入可访问树。
private struct PreviewMockTrafficLights: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(nsColor: .systemRed))
            Circle().fill(Color(nsColor: .systemYellow))
            Circle().fill(Color(nsColor: .systemGreen))
        }
        .frame(width: 38, height: 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 预览工具构造 `AppSettings` 的唯一入口：只填入模拟 Dock 需要的字段，
/// 其余沿用模型默认值，避免在视图里散落一套平行设置。
private enum PreviewMockDockSettings {
    static func make(environment: PluginPreviewEnvironment, language: AppLanguage,
                     options: PreviewMockDockOptions) -> AppSettings {
        AppSettings(
            previewStrategy: .allApplications,
            shortcutPrefix: .commandOption,
            globalShortcutKey: nil,
            monitoredApps: [],
            thumbnailSize: .medium,
            showWindowTitles: true,
            refreshInterval: 2,
            enableBackgroundBlur: (options.glassEnabled ?? environment.glassEnabled) && options.glassStyle != .opaque,
            windowCardBackdrop: options.windowCardBackdrop,
            previewDisplayMode: .currentScreen,
            notificationStrategy: .intelligent,
            launchAtLogin: false,
            hideMainWindowOnLaunch: false,
            monitorFrequency: .balanced,
            language: language,
            theme: environment.theme,
            dockPreviewCardWidth: options.cardWidth,
            dockPreviewLayout: options.layout,
            crystalMaterial: options.material(base: environment.material)
        )
    }
}
