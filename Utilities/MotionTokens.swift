//
//  MotionTokens.swift
//  Switchly
//
//  Central motion language for every panel, card and state change.
//
//  All durations, springs and shared transitions resolve through this file so
//  the app animates with one consistent rhythm. Every token honors the system
//  "Reduce motion" preference (System Settings → Accessibility → Display):
//  when it is on, motion collapses to an instant state swap (no movement, no
//  fade) so the UI stays usable for motion-sensitive users.
//

import SwiftUI
import AppKit

/// Shared timing values for the app's motion language.
///
/// - micro: hover / press feedback — must stay ≤120ms to feel instant.
/// - panel: floating panel appear/disappear.
/// - morph: Dock icon → panel growth and inter-icon slides.
/// - stagger: card entrance choreography (per-card delay, capped in total).
enum MotionTokens {

    /// Hover, press and other pointer feedback. Never longer than this.
    static let microDuration: TimeInterval = 0.12

    /// Floating panel appear / disappear.
    static let panelDuration: TimeInterval = 0.22

    /// Dock icon → panel growth, and panel slides between Dock icons.
    static let morphDuration: TimeInterval = 0.28

    /// Workspace → workspace switch (arrow up/down, indicator pill tap).
    /// The strip slide, the header crossfade and the panel width morph all
    /// run at this duration so one gesture reads as one motion instead of
    /// three competing ones. Slightly longer than morphDuration because a
    /// whole card strip travels, not a single panel edge.
    static let workspaceSwitchDuration: TimeInterval = 0.34

    /// Content crossfade when a panel swaps its data (e.g. another app's
    /// windows after the Dock hover moves to a different icon).
    static let contentSwapDuration: TimeInterval = 0.15

    /// State flips that should read as a deliberate change (permission
    /// granted, selection moved). Slightly longer than a content swap.
    static let stateDuration: TimeInterval = 0.25

    /// Per-card entrance delay. Capped by maxStagger so large grids never
    /// take long to settle.
    static let staggerStep: TimeInterval = 0.02
    static let maxStagger: TimeInterval = 0.15

    /// How far a card travels during its entrance.
    static let cardEntranceOffset: CGFloat = 10

    /// How far below its final spot the dock preview starts before springing
    /// up — reads as the panel growing out of the hovered Dock icon.
    static let dockLift: CGFloat = 10

    // MARK: Springs (macOS 12-compatible parameters)

    /// Panels: quick settle with a hint of overshoot.
    static var panelSpring: Animation {
        Animation.spring(response: panelDuration, dampingFraction: 0.82, blendDuration: 0)
    }

    /// Cards lifting on hover / keyboard selection.
    static var cardSpring: Animation {
        Animation.spring(response: 0.25, dampingFraction: 0.78, blendDuration: 0)
    }

    /// Workspace indicator pills (the active one widens, the rest shrink).
    /// Softer than cardSpring so the pill settles just behind the strip slide
    /// it accompanies instead of racing it.
    static var indicatorSpring: Animation {
        Animation.spring(response: 0.30, dampingFraction: 0.76, blendDuration: 0)
    }

    /// Pointer feedback — snappy, essentially no overshoot.
    static var microSpring: Animation {
        Animation.spring(response: microDuration, dampingFraction: 0.9, blendDuration: 0)
    }

    /// Slider-driven live previews; tracks the finger without lag.
    static var interactiveSpring: Animation {
        Animation.interactiveSpring(response: 0.18, dampingFraction: 0.9, blendDuration: 0)
    }

    // MARK: Reduce-motion-aware animation

    /// Wraps an animation so it becomes a no-op under Reduce Motion.
    ///
    /// `.animation(nil, value:)` performs an instant state swap, which is
    /// exactly the behavior motion-sensitive users asked for. Use this for
    /// every SwiftUI animation in the app instead of passing the animation
    /// directly, so the accessibility preference is honored uniformly:
    ///
    /// ```swift
    /// .animation(MotionTokens.animated(.easeOut(duration: 0.2)), value: x)
    /// ```
    static func animated(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    // MARK: Shared transitions

    /// Entrance for a panel's SwiftUI content: gentle rise + fade.
    static var panelContentTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: .center))
    }

    /// Cards entering a grid/strip (stagger, search filtering, app swaps).
    static var cardTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
    }

    /// Thumbnail image replacing a loading placeholder.
    static var thumbnailTransition: AnyTransition {
        .opacity
    }

    /// Horizontal strip content sliding in/out (workspace switches).
    ///
    /// Both sides carry a small scale and a fade on top of the move: a bare
    /// .move reads as a hard cut against the panel’s rounded clip, while the
    /// scale makes the incoming workspace arrive from slightly behind the
    /// panel glass — depth, not a flat slide. Under Reduce Motion every
    /// caller pairs this with MotionTokens.animated(nil), so the strip swaps
    /// instantly.
    static func stripTransition(direction: StripDirection) -> AnyTransition {
        .asymmetric(
            insertion: .move(edge: direction == .forward ? .trailing : .leading)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.96, anchor: .center)),
            removal: .move(edge: direction == .forward ? .leading : .trailing)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.96, anchor: .center))
        )
    }

    enum StripDirection {
        case forward   // next workspace: content slides left
        case backward  // previous workspace: content slides right
    }

    // MARK: Reduce motion

    /// Whether the system asks for reduced motion. When true, callers skip
    /// movement entirely (state swaps still apply, just instantly).
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// AppKit-side animation helpers for NSPanel presentation.
///
/// Borderless floating panels have no SwiftUI window transition, so their
/// show/hide is driven by animating alphaValue (and, for the Dock preview,
/// the frame) through the animator proxy.
enum Motion {

    /// Fades a panel in or out with the shared easing. No-op (instant) when
    /// Reduce Motion is on.
    ///
    /// - Parameters:
    ///   - panel: The panel to fade.
    ///   - value: Target alphaValue (0…1).
    ///   - duration: Duration in seconds; ignored under Reduce Motion.
    ///   - completion: Runs on the main thread after the animation ends, or
    ///     immediately when the animation is skipped.
    static func fadePanel(
        _ panel: NSPanel,
        to value: Double,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        guard !MotionTokens.reduceMotion else {
            panel.alphaValue = value
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            // easeOutExpo-ish: fast start, gentle settle — stays close to the
            // SwiftUI panel spring so both sides feel like one system.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = value
        } completionHandler: {
            completion?()
        }
    }

    /// Animates a panel frame (size and/or position). Used by the Dock preview
    /// to slide between icons and by the workspace bar to refit its width.
    /// No-op (instant) when Reduce Motion is on.
    static func movePanel(
        _ panel: NSPanel,
        to frame: NSRect,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        guard !MotionTokens.reduceMotion else {
            panel.setFrame(frame, display: true)
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            completion?()
        }
    }

    /// Fades a regular window (preferences, workspaces, onboarding) in on
    /// first presentation. No-op under Reduce Motion.
    static func fadeInWindow(_ window: NSWindow, duration: TimeInterval = MotionTokens.panelDuration) {
        guard !MotionTokens.reduceMotion else { return }
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            window.animator().alphaValue = 1
        }
    }
}

/// Modifier that staggers a card's entrance: the card rises into place with a
/// per-index delay (capped), so a grid or strip fills in a wave instead of
/// appearing all at once. Under Reduce Motion the card shows immediately.
struct StaggeredEntranceModifier: ViewModifier {
    /// Position in the list; drives the delay.
    let index: Int

    /// Entrance axis: vertical rise for grids, horizontal for strips.
    let axis: Axis

    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(showContent ? 1 : 0)
            .offset(
                x: axis == .horizontal && !showContent ? -MotionTokens.cardEntranceOffset : 0,
                y: axis == .vertical && !showContent ? MotionTokens.cardEntranceOffset : 0
            )
            .onAppear {
                guard !appeared else { return }
                if MotionTokens.reduceMotion {
                    appeared = true
                    return
                }
                let delay = min(Double(index) * MotionTokens.staggerStep, MotionTokens.maxStagger)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    appeared = true
                }
            }
            .animation(MotionTokens.animated(MotionTokens.cardSpring), value: appeared)
    }

    private var showContent: Bool {
        appeared || MotionTokens.reduceMotion
    }
}

extension View {
    /// Applies a staggered entrance animation to grid/strip cards.
    /// - Parameters:
    ///   - index: Position in the list; drives the entrance delay.
    ///   - axis: .vertical for grids, .horizontal for strips.
    func staggeredEntrance(index: Int, axis: Axis = .vertical) -> some View {
        modifier(StaggeredEntranceModifier(index: index, axis: axis))
    }
}

/// Modifier that gently pulses a view's opacity while it is shown — used by
/// thumbnail loading skeletons so a pending capture reads as "working"
/// instead of a frozen placeholder. No pulse under Reduce Motion.
struct SkeletonPulseModifier: ViewModifier {
    let isActive: Bool

    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(pulse ? 0.55 : 1.0)
            .onAppear(perform: start)
            .onChange(of: isActive) { newValue in
                if newValue {
                    start()
                } else {
                    pulse = false
                }
            }
    }

    private func start() {
        guard isActive, !MotionTokens.reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

extension View {
    /// Pulses opacity while isActive is true (loading skeleton).
    func skeletonPulse(isActive: Bool) -> some View {
        modifier(SkeletonPulseModifier(isActive: isActive))
    }
}

extension Notification.Name {
    /// Posted when a window switch completes without any panel being shown
    /// (auto-switch of a single window, current-app window shortcut). The
    /// status bar item pulses in response so the user gets confirmation —
    /// an LSUIElement app otherwise gives no visible feedback.
    static let switchDidComplete = Notification.Name("com.switchly.switchDidComplete")
}

