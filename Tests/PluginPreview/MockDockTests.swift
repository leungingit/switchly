import AppKit
import Foundation

/// 模拟 Dock 悬停状态机与 mock 窗口/缩略图的回归。
enum MockDockTests {
    @MainActor
    static func run() {
        showIsDelayed()
        switchWhileVisibleIsImmediate()
        reentryWithinGraceCancelsHide()
        hideGraceExpires()
        nonTriggerIconsAreIgnored()
        mockWindowsAreDeterministic()
        panelStaysInsideColumn()
        panelFallsBackWhenColumnIsTooSmall()
        panelWidthFollowsContentAndColumn()
        dockBarSizeMatchesIcons()
        print("模拟 Dock 悬停与 mock 窗口测试通过")
    }

    private static func showIsDelayed() {
        var state = PreviewDockHoverState()
        state.hoverEnter(iconID: "A", isTrigger: true, now: 0)
        precondition(!state.isVisible)
        precondition(state.nextDeadline == 0.4)

        state.tick(now: 0.39)
        precondition(!state.isVisible, "浮层不应在 0.4s 前显示")

        state.tick(now: 0.4)
        precondition(state.isVisible)
        precondition(state.visibleIconID == "A")
    }

    private static func switchWhileVisibleIsImmediate() {
        var state = PreviewDockHoverState()
        state.hoverEnter(iconID: "A", isTrigger: true, now: 0)
        state.tick(now: 0.4)
        precondition(state.visibleIconID == "A")

        state.hoverEnter(iconID: "B", isTrigger: true, now: 0.5)
        precondition(state.visibleIconID == "B", "已显示时切换目标图标应立即生效")
        precondition(state.nextDeadline == nil)

        state.hoverEnter(iconID: "C", isTrigger: true, now: 0.6)
        precondition(state.visibleIconID == "C")
    }

    private static func reentryWithinGraceCancelsHide() {
        var state = PreviewDockHoverState()
        state.hoverEnter(iconID: "A", isTrigger: true, now: 0)
        state.tick(now: 0.4)

        state.hoverExit(iconID: "A", now: 1.0)
        precondition(state.nextDeadline == 1.3)
        state.hoverEnter(iconID: "A", isTrigger: true, now: 1.2)
        precondition(state.nextDeadline == nil)
        state.tick(now: 1.3)
        precondition(state.visibleIconID == "A", "宽限内重新进入图标应取消隐藏")

        state.hoverExit(iconID: "A", now: 2.0)
        state.panelEnter(now: 2.1)
        precondition(state.nextDeadline == nil)
        state.tick(now: 2.5)
        precondition(state.visibleIconID == "A", "宽限内重新进入浮层应取消隐藏")
    }

    private static func hideGraceExpires() {
        var state = PreviewDockHoverState()
        state.hoverEnter(iconID: "A", isTrigger: true, now: 0)
        state.tick(now: 0.4)

        state.hoverExit(iconID: "A", now: 1.0)
        state.tick(now: 1.29)
        precondition(state.visibleIconID == "A")
        state.tick(now: 1.3)
        precondition(!state.isVisible, "离开图标宽限满 0.3s 后应隐藏")

        var panelState = PreviewDockHoverState()
        panelState.hoverEnter(iconID: "A", isTrigger: true, now: 0)
        panelState.tick(now: 0.4)
        panelState.hoverExit(iconID: "A", now: 1.0)
        panelState.panelEnter(now: 1.1)
        panelState.panelExit(now: 2.0)
        panelState.tick(now: 2.29)
        precondition(panelState.visibleIconID == "A")
        panelState.tick(now: 2.3)
        precondition(!panelState.isVisible, "离开浮层宽限满 0.3s 后应隐藏")
    }

    private static func nonTriggerIconsAreIgnored() {
        var state = PreviewDockHoverState()
        state.hoverEnter(iconID: "B", isTrigger: false, now: 0)
        state.tick(now: 5)
        precondition(!state.isVisible, "非目标图标不应显示浮层")

        state.hoverEnter(iconID: "A", isTrigger: true, now: 6)
        state.hoverEnter(iconID: "B", isTrigger: false, now: 6.1)
        state.tick(now: 6.5)
        precondition(!state.isVisible, "从目标图标移到非目标图标应取消待显示")

        var showing = PreviewDockHoverState()
        showing.hoverEnter(iconID: "A", isTrigger: true, now: 0)
        showing.tick(now: 0.4)
        showing.hoverEnter(iconID: "B", isTrigger: false, now: 1.0)
        showing.tick(now: 1.29)
        precondition(showing.visibleIconID == "A")
        showing.tick(now: 1.3)
        precondition(!showing.isVisible, "进入非目标图标应让已显示的浮层进入隐藏宽限")
    }

    private static func mockWindowsAreDeterministic() {
        let first = PreviewMockWindows.make(appName: "Example App", bundleID: "com.example.app")
        let second = PreviewMockWindows.make(appName: "Example App", bundleID: "com.example.app")

        precondition(first.count == 1 && first.first?.id == PreviewMockWindows.firstWindowID)
        let three = PreviewMockWindows.make(appName: "Example App", bundleID: "com.example.app", count: 3)
        precondition(three.map(\.id) == (0..<3).map { PreviewMockWindows.firstWindowID + CGWindowID($0) })
        precondition(PreviewMockWindows.make(appName: "A", bundleID: "b", count: 0).isEmpty)
        precondition(PreviewMockWindows.make(appName: "A", bundleID: "b", count: 99).count == 5)
        precondition(three[0].windowTitle != three[1].windowTitle)
        for (index, window) in first.enumerated() {
            precondition(window.id == PreviewMockWindows.firstWindowID + CGWindowID(index))
            precondition(window.ownerName == "Example App")
            precondition(window.windowTitle == "Example Window \(index + 1)")
            precondition(window.bounds == CGRect(x: 0, y: 0, width: 1440, height: 900))
            precondition(window.isOnCurrentSpace)
            precondition(window.windowNumber == Int(window.id))
            precondition(!window.isMinimized && !window.isHidden && !window.isOnOtherSpace)
        }
        for (lhs, rhs) in zip(first, second) {
            precondition(lhs.id == rhs.id)
            precondition(lhs.ownerPID == rhs.ownerPID)
            precondition(lhs.ownerName == rhs.ownerName)
            precondition(lhs.windowTitle == rhs.windowTitle)
            precondition(lhs.bounds == rhs.bounds)
            precondition(lhs.isOnCurrentSpace == rhs.isOnCurrentSpace)
            precondition(lhs.windowNumber == rhs.windowNumber)
            precondition(lhs.isMinimized == rhs.isMinimized)
            precondition(lhs.isHidden == rhs.isHidden)
            precondition(lhs.isOnOtherSpace == rhs.isOnOtherSpace)
        }

        let image = PreviewMockWindows.placeholderThumbnail(
            title: first[0].windowTitle,
            appName: "Example App",
            bundleID: "com.example.app"
        )
        let repeated = PreviewMockWindows.placeholderThumbnail(
            title: first[0].windowTitle,
            appName: "Example App",
            bundleID: "com.example.app"
        )
        precondition(image.size == PreviewMockWindows.thumbnailSize)
        precondition(image.size.width / image.size.height == 200.0 / 125.0)
        let firstBitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        let repeatedBitmap = repeated.representations.compactMap { $0 as? NSBitmapImageRep }.first
        precondition(firstBitmap != nil && repeatedBitmap != nil)
        if let firstBitmap, let repeatedBitmap {
            precondition(firstBitmap.pixelsWide == Int(PreviewMockWindows.thumbnailSize.width * 2))
            precondition(firstBitmap.pixelsHigh == Int(PreviewMockWindows.thumbnailSize.height * 2))
            precondition(firstBitmap.pixelsWide == repeatedBitmap.pixelsWide)
            precondition(firstBitmap.pixelsHigh == repeatedBitmap.pixelsHigh)
            for (x, y) in [(2, 2), (20, 20), (100, 100)] {
                precondition(colorsEqual(firstBitmap.colorAt(x: x, y: y),
                                         repeatedBitmap.colorAt(x: x, y: y)),
                             "占位缩略图在 (\(x), \(y)) 应确定")
            }
        }
    }

    private static func panelStaysInsideColumn() {
        let container = CGSize(width: 520, height: 640)
        let panelWidth: CGFloat = 460

        // 图标居中：浮层左右对称。
        let centeredIcon = CGRect(x: 228, y: 520, width: 44, height: 44)
        let centeredLeft = PreviewDockLayout.clampedLeft(iconMidX: centeredIcon.midX,
                                                         containerWidth: container.width,
                                                         panelWidth: panelWidth)
        precondition(abs(centeredLeft - (centeredIcon.midX - panelWidth / 2)) < 0.001)

        // 底边锚定在图标上方 8 pt，不依赖浮层高度。
        let bottomDistance = PreviewDockLayout.panelBottomDistance(iconMinY: centeredIcon.minY,
                                                                   containerHeight: container.height)
        precondition(abs(bottomDistance - (container.height - centeredIcon.minY + PreviewDockLayout.panelGap)) < 0.001)

        // 靠右图标：右边缘贴住 8 pt 边距。
        let rightIcon = CGRect(x: 470, y: 520, width: 44, height: 44)
        let rightLeft = PreviewDockLayout.clampedLeft(iconMidX: rightIcon.midX,
                                                      containerWidth: container.width,
                                                      panelWidth: panelWidth)
        precondition(abs(rightLeft - (container.width - PreviewDockLayout.panelMargin - panelWidth)) < 0.001)
        precondition(rightLeft + panelWidth <= container.width)

        // 靠左图标：左边缘贴住 8 pt 边距。
        let leftIcon = CGRect(x: 0, y: 520, width: 44, height: 44)
        let leftLeft = PreviewDockLayout.clampedLeft(iconMidX: leftIcon.midX,
                                                     containerWidth: container.width,
                                                     panelWidth: panelWidth)
        precondition(abs(leftLeft - PreviewDockLayout.panelMargin) < 0.001)
        precondition(leftLeft >= 0)

        // 上方空间足够：不下移。
        precondition(PreviewDockLayout.panelVerticalShift(iconMinY: 520,
                                                          containerHeight: 640,
                                                          panelHeight: 280) == 0)

        // 上方空间不足：下移，且底边仍留在右栏内。
        let shift = PreviewDockLayout.panelVerticalShift(iconMinY: 520,
                                                         containerHeight: 640,
                                                         panelHeight: 520)
        precondition(shift > 0)
        let bottom = 520 - PreviewDockLayout.panelGap + shift
        precondition(bottom <= 640 - PreviewDockLayout.panelMargin)
    }

    private static func panelFallsBackWhenColumnIsTooSmall() {
        // 浮层比右栏还宽：水平居中，而不是把一侧推到栏外。
        let left = PreviewDockLayout.clampedLeft(iconMidX: 0,
                                                 containerWidth: 380,
                                                 panelWidth: 460)
        precondition(abs(left - (380 - 460) / 2) < 0.001)

        // 高度未知时不下移，避免首帧把浮层推到图标下方。
        precondition(PreviewDockLayout.panelVerticalShift(iconMinY: 4,
                                                          containerHeight: 100,
                                                          panelHeight: 0) == 0)
    }

    private static func panelWidthFollowsContentAndColumn() {
        // 与本体同口径：窗口数越少浮层越窄，且不再写死两张卡片的宽度。
        let wide: CGFloat = 1200
        let minPlugin: CGFloat = 300
        let one = PreviewDockLayout.panelWidth(windowCount: 1, layout: .horizontal, cardWidth: 200,
                                               pluginCardMinWidth: nil, containerWidth: wide)
        let two = PreviewDockLayout.panelWidth(windowCount: 2, layout: .horizontal, cardWidth: 200,
                                               pluginCardMinWidth: nil, containerWidth: wide)
        precondition(one < two, "1 个窗口的浮层必须比 2 个窄")
        // 有插件卡片时不窄于本体的 belowCardMinWidth。
        let oneWithPlugin = PreviewDockLayout.panelWidth(windowCount: 1, layout: .horizontal, cardWidth: 100,
                                                         pluginCardMinWidth: minPlugin, containerWidth: wide)
        precondition(oneWithPlugin >= minPlugin)
        // 无窗口时只由插件卡片撑开。
        precondition(PreviewDockLayout.panelWidth(windowCount: 0, layout: .horizontal, cardWidth: 200,
                                                  pluginCardMinWidth: minPlugin, containerWidth: wide)
                     == minPlugin)
        // 纵向布局的宽度不随窗口数增长。
        precondition(PreviewDockLayout.panelWidth(windowCount: 1, layout: .vertical, cardWidth: 200,
                                                  pluginCardMinWidth: nil, containerWidth: wide)
                     == PreviewDockLayout.panelWidth(windowCount: 3, layout: .vertical, cardWidth: 200,
                                                     pluginCardMinWidth: nil, containerWidth: wide))
        // 右栏更窄时使用可用宽度。
        precondition(PreviewDockLayout.panelWidth(windowCount: 5, layout: .horizontal, cardWidth: 200,
                                                  pluginCardMinWidth: minPlugin, containerWidth: 380)
                     == 380 - PreviewDockLayout.panelMargin * 2)
    }

    private static func dockBarSizeMatchesIcons() {
        let one = PreviewDockLayout.dockBarSize(iconCount: 1)
        precondition(one.width == PreviewDockLayout.iconSize + PreviewDockLayout.barPadding * 2)
        let three = PreviewDockLayout.dockBarSize(iconCount: 3)
        precondition(three.width == 3 * PreviewDockLayout.iconSize
                     + 2 * PreviewDockLayout.iconSpacing
                     + 2 * PreviewDockLayout.barPadding)
        precondition(three.height == PreviewDockLayout.iconSize + PreviewDockLayout.barPadding * 2)
    }

    private static func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let left = lhs?.usingColorSpace(.deviceRGB),
              let right = rhs?.usingColorSpace(.deviceRGB) else {
            return lhs == nil && rhs == nil
        }
        return abs(left.redComponent - right.redComponent) < 0.001
            && abs(left.greenComponent - right.greenComponent) < 0.001
            && abs(left.blueComponent - right.blueComponent) < 0.001
            && abs(left.alphaComponent - right.alphaComponent) < 0.001
    }
}
