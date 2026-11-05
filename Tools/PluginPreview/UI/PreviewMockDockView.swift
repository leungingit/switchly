import AppKit
import SwiftUI

/// 启动器右栏的模拟 Dock：底部一排图标 + 目标图标上方弹出的浮层。
///
/// 只有目标应用图标参与悬停，固定占位图标不弹浮层；计时只作用于这一模拟 Dock，
/// 不证明本体 Dock 的触发延迟与宽限。右栏本身透明，Dock 条与浮层漂浮在桌面上。
struct PreviewMockDockView: View {
    @ObservedObject var model: PreviewLauncherModel
    @ObservedObject var state: PluginPreviewState
    @StateObject private var hover = PreviewDockHoverController()
    @State private var panelSize: CGSize = .zero

    private let targetIconID = "target"

    /// `hoverController` 仅用于离屏渲染与测试注入；正常启动使用新实例。
    init(model: PreviewLauncherModel,
         state: PluginPreviewState,
         hoverController: PreviewDockHoverController? = nil) {
        self.model = model
        self.state = state
        _hover = StateObject(wrappedValue: hoverController ?? PreviewDockHoverController())
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.clear
                dockBar
                    .padding(.bottom, DesignTokens.Spacing.lg)
            }
            .overlayPreferenceValue(MockDockIconAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    panelOverlay(anchors: anchors, proxy: proxy)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: targetBundleID) { _ in
            // 切换插件/目标应用：旧浮层不再对应当前草稿，立即复位并取消计时。
            hover.cancel()
            panelSize = .zero
        }
        .onChange(of: hover.isVisible) { visible in
            if !visible { panelSize = .zero }
        }
        .onDisappear {
            hover.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            // 关窗后 SwiftUI 视图可能不会立即 onDisappear，显式停掉一次性唤醒。
            hover.cancel()
        }
    }

    // MARK: - Dock bar

    private var dockBar: some View {
        HStack(spacing: PreviewDockLayout.iconSpacing) {
            ForEach(items) { item in
                dockIcon(item)
                    .anchorPreference(key: MockDockIconAnchorKey.self, value: .bounds) { [item.id: $0] }
                    .onHover { inside in
                        if inside {
                            hover.hoverEnter(iconID: item.id, isTrigger: item.isTrigger)
                        } else {
                            hover.hoverExit(iconID: item.id)
                        }
                    }
            }
        }
        .padding(PreviewDockLayout.barPadding)
        .cardSurface(
            fill: Color(nsColor: .controlBackgroundColor).opacity(0.42),
            cornerRadius: DesignTokens.Radius.control,
            material: state.environment.material,
            showsBorder: true
        )
    }

    private func dockIcon(_ item: MockDockItem) -> some View {
        let highlighted = hover.visibleIconID == item.id
        return Group {
            if let bundleID = item.bundleID,
               let icon = AppIconCache.icon(forBundleIdentifier: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.systemImage)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: PreviewDockLayout.iconSize, height: PreviewDockLayout.iconSize)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.chip, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(highlighted ? 0.6 : 0.28))
        )
        .scaleEffect(highlighted ? 1.06 : 1)
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: highlighted)
        .accessibilityLabel(Text(item.title))
        .accessibilityHidden(!item.isTrigger)
        .help(item.title)
    }

    // MARK: - Floating panel

    @ViewBuilder
    private func panelOverlay(anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        if let iconID = hover.visibleIconID,
           iconID == targetIconID,
           let anchor = anchors[targetIconID] {
            let iconFrame = proxy[anchor]
            let width = PreviewDockLayout.panelWidth(
                windowCount: model.mockDock.windowCount,
                layout: model.mockDock.layout,
                cardWidth: CGFloat(model.mockDock.cardWidth),
                pluginCardMinWidth: (state.slots[.center] ?? []).isEmpty
                    ? nil : DesignTokens.Plugin.belowCardMinWidth,
                containerWidth: proxy.size.width
            )
            let left = PreviewDockLayout.clampedLeft(
                iconMidX: iconFrame.midX,
                containerWidth: proxy.size.width,
                panelWidth: width
            )
            let bottomDistance = PreviewDockLayout.panelBottomDistance(
                iconMinY: iconFrame.minY,
                containerHeight: proxy.size.height
            )
            // 以底边锚定到图标上方：高度未知的首帧也不会落到图标下方；
            // 量到高度后才按需下移，保证顶边不越出右栏。
            let shift = PreviewDockLayout.panelVerticalShift(
                iconMinY: iconFrame.minY,
                containerHeight: proxy.size.height,
                panelHeight: panelSize.height
            )

            ZStack(alignment: .bottomLeading) {
                PreviewDockPanelView(
                    state: state,
                    appName: targetAppName,
                    bundleID: targetBundleID,
                    width: width,
                    options: model.mockDock,
                    maxHeight: PreviewDockLayout.maxPanelHeight(iconMinY: iconFrame.minY)
                )
                .fixedSize()
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MockDockPanelSizeKey.self, value: geometry.size)
                })
                .onPreferenceChange(MockDockPanelSizeKey.self) { size in
                    if size != panelSize { panelSize = size }
                }
                .onHover { inside in
                    if inside {
                        hover.panelEnter()
                    } else {
                        hover.panelExit()
                    }
                }
                .offset(x: left, y: -(bottomDistance - shift))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
            .transition(MotionTokens.panelContentTransition)
            .animation(MotionTokens.animated(MotionTokens.panelSpring), value: hover.isVisible)
        }
    }

    // MARK: - Data

    private var items: [MockDockItem] {
        [
            MockDockItem(id: targetIconID,
                         title: targetAppName,
                         bundleID: targetBundleID.isEmpty ? nil : targetBundleID,
                         systemImage: "app",
                         isTrigger: hasTarget),
            MockDockItem(id: "placeholder.finder",
                         title: "Finder",
                         bundleID: nil,
                         systemImage: "folder",
                         isTrigger: false),
            MockDockItem(id: "placeholder.safari",
                         title: "Safari",
                         bundleID: nil,
                         systemImage: "safari",
                         isTrigger: false)
        ]
    }

    private var hasTarget: Bool {
        model.hasPlugin && model.displayedDraft != nil
    }

    private var targetBundleID: String {
        model.displayedDraft?.target.bundleID ?? ""
    }

    private var targetAppName: String {
        let draftName = model.displayedDraft?.target.appName ?? ""
        if !draftName.isEmpty { return draftName }
        return model.hasPlugin ? model.displayName(language: model.uiLanguage) : t("Target application")
    }

    private func t(_ key: String) -> String {
        model.t(key)
    }
}

private struct MockDockItem: Identifiable {
    let id: String
    let title: String
    let bundleID: String?
    let systemImage: String
    let isTrigger: Bool
}

private struct MockDockIconAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct MockDockPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
