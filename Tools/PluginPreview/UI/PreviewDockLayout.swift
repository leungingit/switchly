import CoreGraphics

/// 模拟 Dock 的纯几何计算（不依赖 SwiftUI / AppKit），供视图与测试共用。
///
/// 判定集中在两个地方，避免视图里散落夹取逻辑：
/// - 浮层宽度沿用本体的窗口数/布局/卡片宽度口径，并夹在右栏内；
/// - 浮层从目标图标上方居中弹出，水平与垂直方向都不越出右栏。
enum PreviewDockLayout {
    /// 图标边长：与 Dock 图标的常见视觉尺寸一致。
    static let iconSize: CGFloat = 44
    static let iconSpacing: CGFloat = 10
    /// Dock 条内部留白。
    static let barPadding: CGFloat = 10
    /// 浮层与目标图标之间的间隙。
    static let panelGap: CGFloat = 8
    /// 浮层与右栏边缘的最小距离。
    static let panelMargin: CGFloat = 8
    /// Dock 条尺寸（图标数已知）。
    static func dockBarSize(iconCount: Int) -> CGSize {
        let count = max(iconCount, 1)
        return CGSize(
            width: CGFloat(count) * iconSize + CGFloat(count - 1) * iconSpacing + barPadding * 2,
            height: iconSize + barPadding * 2
        )
    }

    /// 浮层宽度：与本体 `DockPreviewViewModel.updatePanelWidth` 同一口径 ——
    /// 由窗口数、布局和卡片宽度决定，有插件卡片时不窄于 `belowCardMinWidth`；
    /// 最后夹在右栏可用宽度内。窗口数变化时宽度随之收缩，不再写死两张卡片的宽度。
    static func panelWidth(windowCount: Int,
                           layout: DockPreviewLayout,
                           cardWidth: CGFloat,
                           pluginCardMinWidth: CGFloat?,
                           containerWidth: CGFloat) -> CGFloat {
        let hostSize = DockPanelMetrics.panelSize(
            spec: layout.spec,
            count: windowCount,
            cardWidth: cardWidth,
            visibleSize: CGSize(width: 1_000_000, height: 1_000_000)
        )
        var desired = hostSize.width
        // 非 nil 表示有插件卡片，值为本体的 `DesignTokens.Plugin.belowCardMinWidth`。
        if let minimum = pluginCardMinWidth {
            desired = windowCount == 0 ? minimum : max(desired, minimum)
        }
        return min(desired, max(containerWidth - panelMargin * 2, 1))
    }

    /// 右栏顶部被透明标题栏覆盖的高度，浮层不应延伸到那里。
    static let titlebarInset = PreviewLauncherLayout.windowTitlebarInset

    /// 浮层最大高度：图标上缘之上、右栏顶部（避开标题栏）以下。
    /// 超过时浮层内部滚动，与本体按屏幕高度限高一致。
    static func maxPanelHeight(iconMinY: CGFloat) -> CGFloat {
        max(iconMinY - panelGap - panelMargin - titlebarInset, 120)
    }

    /// 浮层左边缘：以图标中线居中，左右边都不越出右栏；浮层比右栏还宽时居中。
    ///
    /// 用左边缘而不是中心点定位，视图可以直接以 `.bottomLeading` 对齐、无需先量高度。
    static func clampedLeft(iconMidX: CGFloat,
                            containerWidth: CGFloat,
                            panelWidth: CGFloat) -> CGFloat {
        let margin = panelMargin
        let available = containerWidth - margin * 2
        guard panelWidth < available else { return (containerWidth - panelWidth) / 2 }
        return min(max(iconMidX - panelWidth / 2, margin), containerWidth - margin - panelWidth)
    }

    /// 浮层底边距容器底部的距离：底边位于图标上缘之上 `panelGap`。
    static func panelBottomDistance(iconMinY: CGFloat, containerHeight: CGFloat) -> CGFloat {
        max(containerHeight - (iconMinY - panelGap), 0)
    }

    /// 垂直方向的下移量：浮层顶边不足 `panelMargin` 时向下挪，但不把底边推出右栏。
    ///
    /// 高度未知（0）时不移动，靠底边锚定保证首帧也在图标上方。
    static func panelVerticalShift(iconMinY: CGFloat,
                                   containerHeight: CGFloat,
                                   panelHeight: CGFloat) -> CGFloat {
        guard panelHeight > 0 else { return 0 }
        let bottom = iconMinY - panelGap
        let top = bottom - panelHeight
        guard top < panelMargin else { return 0 }
        let desired = panelMargin - top
        let maximum = max(containerHeight - panelMargin - bottom, 0)
        return min(desired, maximum)
    }
}
