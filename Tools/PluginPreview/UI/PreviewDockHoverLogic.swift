import Foundation

/// 预览工具右栏模拟 Dock 的悬停状态机（纯值类型，不依赖 SwiftUI / AppKit）。
///
/// 行为对齐宿主 `DockHoverMonitor`：
/// - 从无浮层进入目标图标后，满 `showDelay` 才显示；
/// - 浮层已显示时切换到另一个目标图标立即生效；
/// - 指针离开图标与浮层后 `hideGrace` 内重新进入可取消隐藏；
/// - 非目标（`isTrigger == false`）图标不显示浮层，并会让已显示的浮层进入隐藏宽限。
///
/// 时间全部由调用方注入，内部不创建 Timer；UI 层根据 `nextDeadline` 安排一次
/// `tick(now:)` 即可，测试可直接快进。
struct PreviewDockHoverState: Equatable {
    /// 显示延迟：来源 `Sources/Models/AppSettings.swift` 的 `dockPreviewHoverDelay`
    /// 默认值 0.4s，宿主 `Sources/Services/DockHoverMonitor.swift` 用该设置安排显示计时。
    static let showDelay: TimeInterval = 0.4
    /// 隐藏宽限：来源 `Sources/Services/DockHoverMonitor.swift` 离开图标与浮层后的 0.3s 计时。
    static let hideGrace: TimeInterval = 0.3

    /// 当前浮层展示的图标；nil 表示浮层不可见。
    private(set) var visibleIconID: String?
    /// 当前指针所在的图标；nil 表示不在任何图标上。
    private(set) var hoveredIconID: String?
    /// 指针是否在浮层内。
    private(set) var isPanelHovered = false

    private var hoveredIconIsTrigger = false
    private var showDeadline: TimeInterval?
    private var hideDeadline: TimeInterval?

    var isVisible: Bool { visibleIconID != nil }

    /// 下一个需要调用 `tick(now:)` 的时间点；UI 层据此安排计时，nil 表示无需计时。
    var nextDeadline: TimeInterval? {
        switch (showDeadline, hideDeadline) {
        case let (show?, hide?): return min(show, hide)
        case let (show?, nil): return show
        case let (nil, hide?): return hide
        case (nil, nil): return nil
        }
    }

    /// 指针进入某个 Dock 图标。只有 `isTrigger` 为真的图标才会显示浮层。
    mutating func hoverEnter(iconID: String, isTrigger: Bool, now: TimeInterval) {
        let isSameIcon = hoveredIconID == iconID
        hoveredIconID = iconID
        hoveredIconIsTrigger = isTrigger

        guard isTrigger else {
            // 非目标图标不触发预览；若浮层正在显示，等同离开原图标。
            if visibleIconID != nil {
                scheduleHideIfNeeded(now: now)
            } else {
                cancelShow()
            }
            return
        }

        // 宽限内重新进入目标图标或浮层时取消隐藏。
        hideDeadline = nil

        if let visibleIconID {
            // 浮层已显示：切换图标即时生效，不再延迟。
            if visibleIconID != iconID {
                self.visibleIconID = iconID
            }
            showDeadline = nil
            return
        }

        // 无浮层：确保显示计时存在；换到另一个目标图标时重新计时。
        if showDeadline == nil || !isSameIcon {
            showDeadline = now + Self.showDelay
        }
    }

    /// 指针离开某个 Dock 图标。
    mutating func hoverExit(iconID: String, now: TimeInterval) {
        guard hoveredIconID == iconID else { return }
        hoveredIconID = nil
        hoveredIconIsTrigger = false

        if visibleIconID != nil {
            scheduleHideIfNeeded(now: now)
        } else {
            cancelShow()
        }
    }

    /// 指针进入浮层：取消待执行的隐藏。
    mutating func panelEnter(now: TimeInterval) {
        isPanelHovered = true
        hideDeadline = nil
    }

    /// 指针离开浮层：按离开时的悬停情况安排隐藏。
    mutating func panelExit(now: TimeInterval) {
        guard isPanelHovered else { return }
        isPanelHovered = false
        if visibleIconID != nil {
            scheduleHideIfNeeded(now: now)
        }
    }

    /// 推进时间：到点显示或隐藏。调用方无需在每次时间变化时调用，
    /// 只需在 `nextDeadline` 时刻调用一次。
    mutating func tick(now: TimeInterval) {
        if let deadline = showDeadline, now >= deadline {
            showDeadline = nil
            if let hoveredIconID, hoveredIconIsTrigger {
                visibleIconID = hoveredIconID
            }
        }

        if let deadline = hideDeadline, now >= deadline {
            hideDeadline = nil
            // 防御：宽限内若已重新进入目标图标或浮层，取消隐藏。
            if !isPanelHovered, !(hoveredIconIsTrigger && hoveredIconID != nil) {
                visibleIconID = nil
            }
        }
    }

    private mutating func cancelShow() {
        showDeadline = nil
    }

    private mutating func scheduleHideIfNeeded(now: TimeInterval) {
        guard !isPanelHovered else {
            hideDeadline = nil
            return
        }
        guard !(hoveredIconIsTrigger && hoveredIconID != nil) else {
            hideDeadline = nil
            return
        }
        hideDeadline = now + Self.hideGrace
    }
}
