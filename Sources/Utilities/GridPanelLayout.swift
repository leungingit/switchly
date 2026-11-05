//
//  GridPanelLayout.swift
//  Switchly
//
//  Pure geometry for the two desktop-grid panels.
//
//  Every frame is derived from the target screen's `visibleFrame`, so a
//  second display, a different scale or a Dock on the left all work without
//  a second code path (docs/desktop-grid-tasks.md T23, R8). Kept free of
//  AppKit screens so it can be unit tested with fabricated rectangles.
//

import CoreGraphics

enum GridPanelLayout {

    /// The screen the pointer is on, as an index into `frames`.
    ///
    /// Menu bar and Dock live outside `visibleFrame`, so the pointer often
    /// sits in a gap between two visible frames; falling back to the closest
    /// screen keeps the panels on the display the user is actually using
    /// instead of jumping to the primary one.
    static func screenIndex(
        containing point: CGPoint,
        frames: [CGRect],
        fallback: Int = 0
    ) -> Int {
        guard !frames.isEmpty else { return fallback }
        if let exact = frames.firstIndex(where: { $0.contains(point) }) {
            return exact
        }
        let clampedFallback = min(max(0, fallback), frames.count - 1)
        var bestIndex = clampedFallback
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, frame) in frames.enumerated() {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Overview frame inside one visible frame.
    ///
    /// Style C fills the visible frame; style B is a centred panel capped at
    /// the shared B width/height and always inset by a margin so it never
    /// touches the screen edges on a small display.
    static func overviewFrame(
        style: GridStyle,
        visibleFrame: CGRect,
        margin: CGFloat = 0
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return .zero }

        switch style {
        case .c:
            return visibleFrame
        case .b:
            let inset = max(0, margin)
            let available = CGSize(
                width: max(1, visibleFrame.width - inset * 2),
                height: max(1, visibleFrame.height - inset * 2)
            )
            let size = CGSize(
                width: min(DesignTokens.Grid.styleBMaxWidth, available.width),
                height: min(DesignTokens.Grid.styleBMaxHeight, available.height)
            )
            return CGRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }

    /// HUD frame: top centre of the visible frame, never wider or taller than
    /// the screen allows.
    static func hudFrame(
        visibleFrame: CGRect,
        fittingSize: CGSize,
        topInset: CGFloat = DesignTokens.Spacing.xl * 2,
        minimumHeight: CGFloat = 88
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return .zero }

        let maxWidth = max(1, min(DesignTokens.Grid.HUD.maxWidth, visibleFrame.width - DesignTokens.Spacing.xl * 2))
        let width = min(max(1, fittingSize.width), maxWidth)
        let height = min(
            max(minimumHeight, fittingSize.height),
            max(minimumHeight, visibleFrame.height - topInset)
        )
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.maxY - height - topInset,
            width: width,
            height: height
        )
    }
}
