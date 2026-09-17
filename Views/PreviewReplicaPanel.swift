//
//  PreviewReplicaPanel.swift
//  Switchly
//
//  The highlighted window, replayed at its own size and place, behind the preview panel.
//

import AppKit

/// A borderless, click-through panel that recreates one window: the captured
/// window drawn 1:1 into a frame of exactly that window's size, at the place the
/// window itself occupies.
///
/// The merged enlarged mode is three layers rather than one bigger panel:
///
///     level 3   PreviewPanel        the thumbnail grid: key, interactive
///     level 2   PreviewReplicaPanel this panel: the window itself, mouse-through
///     level 0   the target app
///
/// Keeping the replica *below* the preview panel is what lets the panel stay in
/// front and keep working (hover, arrow keys, Tab, Enter) while the user sees the
/// whole window behind it, including the parts the panel covers. It also means
/// the replica never becomes key and never swallows a click: `ignoresMouseEvents`
/// passes every event straight through — to the real window underneath, which is
/// the window being replayed.
///
/// Nothing here scales. The size comes from `replicaRect(forWindowBounds:…)`, so
/// a 1440x900 pt window occupies 1440x900 pt of screen at the display's pixel
/// scale. That 1:1 rendering is the whole point of the design: the replica has to
/// read as the window, not as a picture of it.
final class PreviewReplicaPanel: NSPanel {
    static let shared = PreviewReplicaPanel()

    /// Nothing interactive lives here, so it sits below the preview panel's
    /// .floating (3) and above ordinary windows (0).
    static let replicaLevel = NSWindow.Level(rawValue: 2)

    private let imageView = NSImageView()

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = Self.replicaLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Every event goes to whatever is in front of or behind it; the replica
        // is scenery.
        ignoresMouseEvents = true
        hasShadow = false
        // The capture excludes the window's own shadow (`.boundsIgnoreFraming`),
        // and the real window underneath still casts one around the replica, so
        // this panel must paint nothing but the image — not even a black backing.
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = imageView
    }

    /// Never key, never main: the preview panel owns the interaction.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Puts the panel on `rect` and fades `image` in.
    ///
    /// `rect` is the window's own Cocoa rectangle, from `replicaRect`: the panel
    /// changes size with the window it replays, never with the screen.
    func show(image: NSImage?, rect: CGRect, fadeDuration: TimeInterval) {
        guard rect.width >= 1, rect.height >= 1 else {
            dismiss(fadeDuration: fadeDuration)
            return
        }

        imageView.image = image
        // The frame is set directly rather than animated: the replica must land
        // exactly on the window it replays, not slide there.
        setFrame(rect, display: true)

        if !isVisible {
            alphaValue = 0
            orderFront(nil)
        }
        Motion.fadePanel(self, to: 1, duration: fadeDuration)
    }

    /// Swaps the image while the replica is already on screen (a sharper capture
    /// landed, or the highlighted window changed).
    func update(image: NSImage?) {
        guard isVisible else {
            return
        }
        imageView.image = image
    }

    func dismiss(fadeDuration: TimeInterval) {
        guard isVisible else {
            return
        }
        Motion.fadePanel(self, to: 0, duration: fadeDuration) { [weak self] in
            self?.orderOut(nil)
            self?.imageView.image = nil
        }
    }

    // MARK: - Geometry

    /// The rectangle the replica occupies, in Cocoa global screen coordinates.
    ///
    /// The **size** is exactly the window's own size, always. This mode exists to
    /// stop scaling the capture, so nothing here may fit it to the screen: a
    /// window larger than the display produces a replica larger than the display.
    ///
    /// The **position** is the window's own position too, converted from the
    /// window server's top-left space to Cocoa's bottom-left one. The one
    /// adjustment is for a rectangle that falls entirely outside `visibleFrame` —
    /// a window on another Space, on another display, or with coordinates left
    /// over from a display that is gone. Such a replica would be invisible, so it
    /// is centred in the visible frame instead. A window that is merely partly
    /// off-screen keeps its place: the real window is partly off-screen as well,
    /// and moving the replica would misrepresent where that window is.
    static func replicaRect(
        forWindowBounds windowBounds: CGRect,
        primaryScreenHeight: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        guard windowBounds.width >= 1, windowBounds.height >= 1 else {
            return .zero
        }

        var rect = CGRect(
            x: windowBounds.minX,
            // kCGWindowBounds measures y downward from the top of the primary
            // display; Cocoa measures it upward from that display's bottom.
            y: primaryScreenHeight - windowBounds.maxY,
            width: windowBounds.width,
            height: windowBounds.height
        )

        guard visibleFrame.width >= 1, visibleFrame.height >= 1 else {
            return rect
        }

        if !rect.intersects(visibleFrame) {
            rect.origin = CGPoint(
                x: visibleFrame.midX - rect.width / 2,
                y: visibleFrame.midY - rect.height / 2
            )
        }
        return rect
    }
}
