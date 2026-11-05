//
//  TrackpadGestureService.swift
//  Switchly
//
//  Owns the trackpad contact listener and turns raw frames into swipe events.
//
//  Responsibilities (docs/desktop-grid-tasks.md T12–T14):
//  - start only while the desktop grid is enabled, stop cleanly on disable/quit;
//  - run the recogniser off the private callback thread and deliver events on
//    the main queue;
//  - report whether the system's own four-finger swipes are on, read-only.
//
//  It never writes a system preference and never posts input events.
//

import Foundation
import CoreGraphics

/// A swipe delivered to the app, with everything the HUD needs to explain it.
struct TrackpadSwipeEvent: Equatable {
    let gesture: SwipeGesture
    /// True when the gesture fired inside the cooldown window.
    let suppressed: Bool

    /// The same swipe pointing the other way, for natural direction.
    var reversed: TrackpadSwipeEvent {
        let g = gesture
        return TrackpadSwipeEvent(
            gesture: SwipeGesture(
                direction: g.direction.opposite,
                angleDegrees: (g.angleDegrees + 180).truncatingRemainder(dividingBy: 360),
                displacementMM: g.displacementMM,
                fingers: g.fingers,
                duration: g.duration
            ),
            suppressed: suppressed
        )
    }
}

protocol TrackpadGestureServiceProtocol: AnyObject {
    var isAvailable: Bool { get }
    var isRunning: Bool { get }
    /// Called on the main queue for every recognised swipe.
    var onSwipe: ((TrackpadSwipeEvent) -> Void)? { get set }
    /// Called on the main queue when four fingers rest still, and when they lift.
    var onHold: ((FourFingerHoldEvent) -> Void)? { get set }
    /// Starts listening. Returns false when the framework or a device is
    /// unavailable; the caller degrades to ⌃1–9.
    @discardableResult
    func start() -> Bool
    func stop()
    /// Re-reads the system four-finger swipe switches.
    func systemGestureState() -> SystemFourFingerGestureState
}

/// Read-only view of the two system switches that compete with the grid.
struct SystemFourFingerGestureState: Equatable {
    var horizontalSwipeEnabled: Bool
    var verticalSwipeEnabled: Bool

    /// The evaluation report found both on by default, and they cannot be
    /// intercepted, so the user has to turn them off by hand.
    var conflictsWithGrid: Bool { horizontalSwipeEnabled || verticalSwipeEnabled }

    static let unknown = SystemFourFingerGestureState(
        horizontalSwipeEnabled: false,
        verticalSwipeEnabled: false
    )
}

/// Reads the trackpad preference domains without writing them.
protocol SystemGesturePreferenceReading {
    func fourFingerHorizontalSwipeEnabled() -> Bool?
    func fourFingerVerticalSwipeEnabled() -> Bool?
}

final class SystemGesturePreferenceReader: SystemGesturePreferenceReading {
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]

    /// `2` means on in both domains (evaluation §11.1). A missing key means
    /// the system default, which is on for these two gestures.
    private func value(for key: String) -> Bool? {
        for domain in Self.domains {
            guard let stored = CFPreferencesCopyAppValue(
                key as CFString,
                domain as CFString
            ) as? NSNumber else {
                continue
            }
            return stored.intValue != 0
        }
        return nil
    }

    func fourFingerHorizontalSwipeEnabled() -> Bool? {
        value(for: "TrackpadFourFingerHorizSwipeGesture")
    }

    func fourFingerVerticalSwipeEnabled() -> Bool? {
        value(for: "TrackpadFourFingerVertSwipeGesture")
    }
}

final class TrackpadGestureService: TrackpadGestureServiceProtocol {
    static let shared = TrackpadGestureService()

    var onSwipe: ((TrackpadSwipeEvent) -> Void)?
    var onHold: ((FourFingerHoldEvent) -> Void)?

    private let bridge: MultitouchSupportBridge
    private let preferences: SystemGesturePreferenceReading
    private var configuration: SwipeConfiguration

    /// Frames arrive on a private framework thread; the recogniser and the
    /// surface size live behind this lock. Only a snapshot leaves the lock.
    private let lock = NSLock()
    private var classifier: SwipeDirectionClassifier
    /// Five-finger recogniser for the overview gesture, fed the same frames.
    private var overviewClassifier = SwipeDirectionClassifier(configuration: .overview)
    private var holdDetector = FourFingerHoldDetector()
    private var surfaceSizes: [UInt: CGSize] = [:]

    private(set) var isRunning = false
    private(set) var isAvailable: Bool

    init(
        bridge: MultitouchSupportBridge = MultitouchSupportBridge(),
        preferences: SystemGesturePreferenceReading = SystemGesturePreferenceReader(),
        configuration: SwipeConfiguration = .standard
    ) {
        self.bridge = bridge
        self.preferences = preferences
        self.configuration = configuration
        self.classifier = SwipeDirectionClassifier(configuration: configuration)
        self.isAvailable = bridge.isAvailable
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard bridge.isAvailable else {
            isAvailable = false
            AppLogger.warning("Trackpad gestures unavailable. reason=framework_unavailable")
            return false
        }

        let devices = bridge.start { [weak self] frame in
            self?.handle(frame)
        }
        guard !devices.isEmpty else {
            isAvailable = false
            AppLogger.warning("Trackpad gestures unavailable. reason=no_started_device")
            return false
        }

        lock.lock()
        surfaceSizes = Dictionary(
            uniqueKeysWithValues: devices.map { ($0.key, $0.surfaceSizeMM) }
        )
        classifier.reset()
        overviewClassifier.reset()
        holdDetector.reset()
        lock.unlock()

        isRunning = true
        isAvailable = true
        let sizes = devices.map { "\(Int($0.surfaceSizeMM.width))x\(Int($0.surfaceSizeMM.height))" }
        AppLogger.info(
            "Trackpad gestures started. devices=\(devices.count), builtIn=\(devices.filter(\.isBuiltIn).count), surfaceMM=\(sizes.joined(separator: ","))"
        )
        return true
    }

    func stop() {
        guard isRunning else { return }
        bridge.stopAll()

        lock.lock()
        classifier.reset()
        overviewClassifier.reset()
        holdDetector.reset()
        surfaceSizes = [:]
        lock.unlock()

        isRunning = false
        AppLogger.info("Trackpad gestures stopped")
    }

    func systemGestureState() -> SystemFourFingerGestureState {
        SystemFourFingerGestureState(
            horizontalSwipeEnabled: preferences.fourFingerHorizontalSwipeEnabled() ?? true,
            verticalSwipeEnabled: preferences.fourFingerVerticalSwipeEnabled() ?? true
        )
    }

    // MARK: - Frame handling

    /// Runs on the framework's callback thread. Never touches UI state here.
    private func handle(_ frame: TrackpadTouchFrame) {
        lock.lock()
        let size = surfaceSizes[frame.deviceKey]
            ?? surfaceSizes.values.first
            ?? CGSize(width: 160, height: 115)
        let centroid = SwipeDirectionClassifier.centroidMM(
            normalized: frame.normalizedCentroid,
            surfaceSizeMM: size
        )
        let event = classifier.process(
            fingers: frame.fingers,
            centroidMM: centroid,
            timestamp: frame.timestamp
        ) ?? overviewClassifier.process(
            fingers: frame.fingers,
            centroidMM: centroid,
            timestamp: frame.timestamp
        )
        let holdEvent = holdDetector.process(
            fingers: frame.fingers,
            centroidMM: centroid,
            timestamp: frame.timestamp
        )
        lock.unlock()

        if let holdEvent {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                AppLogger.debug("Trackpad hold. event=\(holdEvent)")
                self.onHold?(holdEvent)
            }
        }

        guard let event else { return }
        let swipe: TrackpadSwipeEvent
        switch event {
        case .fired(let gesture):
            swipe = TrackpadSwipeEvent(gesture: gesture, suppressed: false)
        case .suppressed(let gesture):
            swipe = TrackpadSwipeEvent(gesture: gesture, suppressed: true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            AppLogger.debug(
                "Trackpad swipe. direction=\(swipe.gesture.direction.rawValue), angle=\(Int(swipe.gesture.angleDegrees)), displacementMM=\(Int(swipe.gesture.displacementMM)), fingers=\(swipe.gesture.fingers), durationMS=\(Int(swipe.gesture.duration * 1000)), suppressed=\(swipe.suppressed)"
            )
            self.onSwipe?(swipe)
        }
    }
}
