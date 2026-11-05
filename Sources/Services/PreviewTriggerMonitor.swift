//
//  PreviewTriggerMonitor.swift
//  Switchly
//
//  Pointer-only ways to summon the preview panel:
//
//  · Edge hotspot — rest the pointer against the middle stretch of a screen
//    edge briefly (PreviewHotspotEdge). The middle band, not the whole edge:
//    the corners carry system affordances (menu items, hot corners) and the
//    Dock owns the bottom edge.
//  · Shake — wiggle the pointer back and forth quickly, like macOS's
//    shake-to-find-the-pointer. Detected by counting direction reversals of
//    enough amplitude inside a sliding window (ShakeGestureClassifier).
//
//  Both are open-only: they put the panel on screen but never dismiss it.
//  Dismissal stays with the panel's own paths (ESC, click-away, a committed
//  switch), so an accidental wiggle cannot close what it just opened.
//
//  Same plumbing as DockHoverMonitor: a global mouseMoved monitor for
//  fidelity plus a coarse poll timer as a safety net, with settings cached
//  so the hot path never touches UserDefaults.
//

import Foundation
import AppKit

// MARK: - Hotspot geometry

/// Pure geometry for the hotspot zone so it can be exercised headless:
/// everything is a function over plain rects and points.
enum PreviewHotspotZone {
    /// How deep the zone reaches from the screen edge.
    static let depth: CGFloat = 8
    /// The zone covers the middle stretch of the edge; the rest is left to
    /// the corners and the Dock.
    static let bandFraction: CGFloat = 0.4
    /// The zone reaches a little beyond the screen edge: the cursor reports
    /// exactly the edge coordinate when slammed against the bezel, and a
    /// strict `maxY` comparison would miss it.
    static let outwardReach: CGFloat = 2

    static func zone(screenFrame: CGRect, edge: PreviewHotspotEdge) -> CGRect {
        switch edge {
        case .top:
            let width = screenFrame.width * bandFraction
            return CGRect(x: screenFrame.midX - width / 2,
                          y: screenFrame.maxY - depth,
                          width: width,
                          height: depth + outwardReach)
        case .left:
            let height = screenFrame.height * bandFraction
            return CGRect(x: screenFrame.minX - outwardReach,
                          y: screenFrame.midY - height / 2,
                          width: depth + outwardReach,
                          height: height)
        case .right:
            let height = screenFrame.height * bandFraction
            return CGRect(x: screenFrame.maxX - depth,
                          y: screenFrame.midY - height / 2,
                          width: depth + outwardReach,
                          height: height)
        }
    }

    static func contains(_ point: NSPoint,
                         screenFrames: [CGRect],
                         edge: PreviewHotspotEdge) -> Bool {
        screenFrames.contains { frame in
            zone(screenFrame: frame, edge: edge).contains(point)
        }
    }
}

// MARK: - Shake classifier

/// Sliding-window zig-zag detector: the pointer must reverse direction
/// `reversalsToTrigger` times, each reversal travelling at least
/// `reversalAmplitude`, all inside `window` seconds.
///
/// Per-axis state means only a real back-and-forth along one axis counts —
/// a slow U-turn, a circle, or sub-amplitude jitter never accumulates
/// reversals fast enough to fire.
struct ShakeGestureClassifier {
    let window: TimeInterval
    let reversalAmplitude: CGFloat
    let reversalsToTrigger: Int

    private var reversalTimes: [TimeInterval] = []
    private var xDirection: CGFloat = 0
    private var yDirection: CGFloat = 0
    private var xPending: CGFloat = 0
    private var yPending: CGFloat = 0
    private var lastLocation: NSPoint?

    /// Declared explicitly so the initializer stays internal: the implicit
    /// memberwise initializer is private, because the mutable state above is
    /// private, and PreviewTriggerMonitor builds the classifier from another
    /// type in this file. Swift 5.10 (Xcode 15) rejects the implicit form.
    init(window: TimeInterval, reversalAmplitude: CGFloat, reversalsToTrigger: Int) {
        self.window = window
        self.reversalAmplitude = reversalAmplitude
        self.reversalsToTrigger = reversalsToTrigger
    }

    /// Feeds one sample. Returns true exactly once per completed gesture.
    mutating func add(location: NSPoint, time: TimeInterval) -> Bool {
        guard let last = lastLocation else {
            lastLocation = location
            return false
        }
        lastLocation = location

        // Only reversals inside the window count, so a gesture from a while
        // ago cannot combine with the current wiggle.
        reversalTimes = reversalTimes.filter { time - $0 <= window }

        let reversedX = Self.step(location.x - last.x,
                                  direction: &xDirection,
                                  pending: &xPending,
                                  amplitude: reversalAmplitude)
        let reversedY = Self.step(location.y - last.y,
                                  direction: &yDirection,
                                  pending: &yPending,
                                  amplitude: reversalAmplitude)
        if reversedX || reversedY {
            reversalTimes.append(time)
        }
        return reversalTimes.count >= reversalsToTrigger
    }

    mutating func reset() {
        reversalTimes = []
        xDirection = 0
        yDirection = 0
        xPending = 0
        yPending = 0
        lastLocation = nil
    }

    /// Advances one axis. Returns true when the axis reversed direction,
    /// i.e. it moved `amplitude` against its established direction.
    private static func step(_ delta: CGFloat,
                             direction: inout CGFloat,
                             pending: inout CGFloat,
                             amplitude: CGFloat) -> Bool {
        guard delta != 0 else { return false }

        if direction == 0 {
            // No direction yet: the first sustained stretch establishes it.
            pending += delta
            if abs(pending) >= amplitude {
                direction = pending > 0 ? 1 : -1
                pending = 0
            }
            return false
        }

        if delta * direction > 0 {
            // Back along the established direction: a half-built reversal
            // is abandoned.
            pending = 0
            return false
        }

        pending += delta
        if abs(pending) >= amplitude {
            direction = pending > 0 ? 1 : -1
            pending = 0
            return true
        }
        return false
    }
}

// MARK: - Monitor

final class PreviewTriggerMonitor {
    static let shared = PreviewTriggerMonitor()

    private var moveMonitor: Any?
    private var pollTimer: Timer?
    private var dwellTimer: Timer?
    private var classifier = ShakeGestureClassifier(window: PreviewTriggerMonitor.shakeWindow,
                                                    reversalAmplitude: PreviewTriggerMonitor.shakeAmplitude,
                                                    reversalsToTrigger: PreviewTriggerMonitor.shakeReversals)

    // Cached configuration: the hot path runs on every mouseMoved event.
    private var cachedHotspotEnabled = false
    private var cachedShakeEnabled = false
    private var cachedEdge = PreviewHotspotEdge.left

    private var lastTriggerUptime: TimeInterval = 0

    private let pollInterval: TimeInterval = 0.05

    /// How long the pointer must rest in the zone before the panel opens.
    static let dwellDelay: TimeInterval = 0.3
    /// Silence after any trigger, so the same gesture cannot fire twice.
    static let cooldown: TimeInterval = 1.5
    // Shake detection: three direction reversals of >= 30pt each, all within
    // 0.7s. That is a deliberate wiggle — fast cursor travel in one
    // direction, slow drifting, and drag marqueeing never reach it.
    static let shakeWindow: TimeInterval = 0.7
    static let shakeAmplitude: CGFloat = 30
    static let shakeReversals = 3

    private init() {}

    func updateSettings() {
        let settings = SettingsService.shared.loadSettings()
        cachedHotspotEnabled = settings.previewHotspotEnabled
        cachedShakeEnabled = settings.previewShakeEnabled
        cachedEdge = settings.previewHotspotEdge

        if cachedHotspotEnabled || cachedShakeEnabled {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        if let monitor = moveMonitor {
            NSEvent.removeMonitor(monitor)
            moveMonitor = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
        classifier.reset()
        AppLogger.info("PreviewTriggerMonitor stopped")
    }

    private func start() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.processMouseLocation(location)
            }
        }
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                self?.processMouseLocation(NSEvent.mouseLocation)
            }
        }
        AppLogger.info("PreviewTriggerMonitor started. hotspot=\(cachedHotspotEnabled), shake=\(cachedShakeEnabled), edge=\(cachedEdge.rawValue)")
    }

    private func processMouseLocation(_ location: NSPoint) {
        // Open-only: while the panel is up the pointer belongs to it. A
        // wiggle over the grid must neither re-trigger nor close anything.
        guard !PreviewPanel.shared.isVisible else {
            dwellTimer?.invalidate()
            dwellTimer = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerUptime >= Self.cooldown else { return }

        if cachedHotspotEnabled {
            updateDwell(at: location)
        } else {
            dwellTimer?.invalidate()
            dwellTimer = nil
        }

        guard cachedShakeEnabled else { return }
        // While a button is held the system sends dragged events, not
        // mouseMoved, so marquee selections and window drags never reach the
        // classifier.
        if classifier.add(location: location, time: now) {
            trigger(source: .pointerShake)
        }
    }

    private func updateDwell(at location: NSPoint) {
        let screenFrames = NSScreen.screens.map(\.frame)
        guard PreviewHotspotZone.contains(location, screenFrames: screenFrames, edge: cachedEdge) else {
            dwellTimer?.invalidate()
            dwellTimer = nil
            return
        }
        guard dwellTimer == nil else { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: Self.dwellDelay, repeats: false) { [weak self] _ in
            self?.dwellTimerFired()
        }
    }

    private func dwellTimerFired() {
        dwellTimer = nil
        // The cursor must still be in the zone: brushing past the edge in
        // under the dwell delay leaves the timer pending but must not fire.
        let location = NSEvent.mouseLocation
        let screenFrames = NSScreen.screens.map(\.frame)
        guard PreviewHotspotZone.contains(location, screenFrames: screenFrames, edge: cachedEdge) else {
            return
        }
        trigger(source: .edgeHotspot)
    }

    private func trigger(source: UsageEventSource) {
        lastTriggerUptime = ProcessInfo.processInfo.systemUptime
        classifier.reset()
        dwellTimer?.invalidate()
        dwellTimer = nil
        AppLogger.info("Preview pointer trigger fired. source=\(source.rawValue), edge=\(cachedEdge.rawValue)")
        // The panel records its own .previewPresented event with this source.
        PreviewPanel.shared.show(source: source)
    }
}
