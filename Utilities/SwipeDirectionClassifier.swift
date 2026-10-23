//
//  SwipeDirectionClassifier.swift
//  Switchly
//
//  Eight-direction four-finger swipe recogniser.
//
//  Input is only "finger count + centroid + timestamp" (design spec §12), so
//  the state machine is independent of MultitouchSupport and can be driven by
//  synthetic trajectories in unit tests. The parameters are the ones agreed in
//  docs/desktop-grid-evaluation-2026-10-21.md §11.4 and
//  docs/desktop-grid-tasks.md T13.
//

import Foundation
import CoreGraphics

/// Recogniser defaults. Kept as named constants so the service, the tests and
/// the ledger cannot drift apart.
enum SwipeDefaults {
    static let minimumFingers = 4
    /// Centroid displacement that fires the swipe, in millimetres.
    static let thresholdMM: Double = 12
    /// How long the finger count may stay below the minimum before the
    /// session ends. Absorbs one or two dropped touch frames.
    static let dropoutMS: Double = 80
    /// No new session starts inside this window after a swipe fired.
    static let cooldownMS: Double = 350
    /// Widens the diagonal sectors and narrows the axis sectors, in degrees.
    /// 0 keeps all eight sectors at 45°; T4 on a real trackpad decides whether
    /// the axis gestures need more room.
    static let diagonalBiasDegrees: Double = 0
}

/// One of the eight swipe directions, with the grid step it maps to.
///
/// Angles are measured in the touch surface's millimetre space with y up, so
/// `up` is 90° — the same convention the probe prints as `finalAngleDeg`.
enum SwipeDirection: String, CaseIterable, Equatable {
    case right
    case upRight
    case up
    case upLeft
    case left
    case downLeft
    case down
    case downRight

    var angleDegrees: Double {
        switch self {
        case .right: return 0
        case .upRight: return 45
        case .up: return 90
        case .upLeft: return 135
        case .left: return 180
        case .downLeft: return 225
        case .down: return 270
        case .downRight: return 315
        }
    }

    var isDiagonal: Bool {
        switch self {
        case .upRight, .upLeft, .downLeft, .downRight: return true
        case .right, .up, .left, .down: return false
        }
    }

    /// Column step in the 3×3 grid (positive moves right).
    var columnDelta: Int {
        switch self {
        case .right, .upRight, .downRight: return 1
        case .left, .upLeft, .downLeft: return -1
        case .up, .down: return 0
        }
    }

    /// Row step in the 3×3 grid (positive moves down, matching the overview's
    /// top-to-bottom numbering).
    var rowDelta: Int {
        switch self {
        case .down, .downLeft, .downRight: return 1
        case .up, .upLeft, .upRight: return -1
        case .left, .right: return 0
        }
    }

    var localizedKey: String {
        switch self {
        case .right: return "Right"
        case .upRight: return "Up-right"
        case .up: return "Up"
        case .upLeft: return "Up-left"
        case .left: return "Left"
        case .downLeft: return "Down-left"
        case .down: return "Down"
        case .downRight: return "Down-right"
        }
    }

    func displayName(language: AppLanguage) -> String {
        language.localizedString(localizedKey)
    }
}

/// Tunables for `SwipeDirectionClassifier`.
struct SwipeConfiguration: Equatable {
    var minimumFingers: Int
    var thresholdMM: Double
    var dropoutMS: Double
    var cooldownMS: Double
    var diagonalBiasDegrees: Double

    init(
        minimumFingers: Int = SwipeDefaults.minimumFingers,
        thresholdMM: Double = SwipeDefaults.thresholdMM,
        dropoutMS: Double = SwipeDefaults.dropoutMS,
        cooldownMS: Double = SwipeDefaults.cooldownMS,
        diagonalBiasDegrees: Double = SwipeDefaults.diagonalBiasDegrees
    ) {
        self.minimumFingers = minimumFingers
        self.thresholdMM = thresholdMM
        self.dropoutMS = dropoutMS
        self.cooldownMS = cooldownMS
        self.diagonalBiasDegrees = diagonalBiasDegrees
    }

    static let standard = SwipeConfiguration()
}

/// What a frame produced.
enum SwipeEvent: Equatable {
    /// A gesture crossed the threshold and may switch desktops.
    case fired(SwipeGesture)
    /// A gesture crossed the threshold while the cooldown was still running.
    /// The HUD shows "cooling down"; nothing switches.
    case suppressed(SwipeGesture)
}

/// A swipe that reached the threshold. One session emits at most one gesture.
struct SwipeGesture: Equatable {
    let direction: SwipeDirection
    let angleDegrees: Double
    let displacementMM: Double
    let fingers: Int
    /// Time from the first qualifying frame to the firing frame.
    let duration: TimeInterval
}

/// Frame-by-frame state machine.
///
/// Call `process` for every touch frame, including frames with zero active
/// fingers (they end a session). The classifier is a value type; the service
/// owns one instance behind its lock.
struct SwipeDirectionClassifier {
    let configuration: SwipeConfiguration

    private struct Session {
        let startedAt: TimeInterval
        /// Started inside the cooldown window: report, never switch.
        let suppressed: Bool
        let start: CGPoint
        var last: CGPoint
        var maxFingers: Int
        var belowSince: TimeInterval?
        var fired = false
    }

    private var session: Session?
    private var cooldownUntil: TimeInterval = -.infinity

    init(configuration: SwipeConfiguration = .standard) {
        self.configuration = configuration
    }

    var isInSession: Bool { session != nil }

    func isCoolingDown(at timestamp: TimeInterval) -> Bool {
        timestamp < cooldownUntil
    }

    mutating func reset() {
        session = nil
        cooldownUntil = -.infinity
    }

    /// Feeds one frame.
    ///
    /// - Parameters:
    ///   - fingers: active contact count (states making/touching).
    ///   - centroidMM: centroid in millimetres on the touch surface.
    ///   - timestamp: device timestamp in seconds; only differences matter.
    /// - Returns: the event when this frame crossed the threshold.
    mutating func process(
        fingers: Int,
        centroidMM: CGPoint,
        timestamp: TimeInterval
    ) -> SwipeEvent? {
        guard var current = session else {
            guard fingers >= configuration.minimumFingers else {
                return nil
            }
            session = Session(
                startedAt: timestamp,
                suppressed: timestamp < cooldownUntil,
                start: centroidMM,
                last: centroidMM,
                maxFingers: fingers
            )
            return nil
        }

        if fingers >= configuration.minimumFingers {
            current.belowSince = nil
            current.last = centroidMM
            current.maxFingers = max(current.maxFingers, fingers)
            session = current

            guard !current.fired else { return nil }

            let dx = centroidMM.x - current.start.x
            let dy = centroidMM.y - current.start.y
            let displacement = hypot(dx, dy)
            guard displacement >= configuration.thresholdMM else { return nil }

            let angle = atan2(dy, dx) * 180 / .pi
            let direction = Self.direction(
                forAngleDegrees: angle,
                diagonalBias: configuration.diagonalBiasDegrees
            )
            current.fired = true
            session = current
            let gesture = SwipeGesture(
                direction: direction,
                angleDegrees: angle,
                displacementMM: displacement,
                fingers: fingers,
                duration: timestamp - current.startedAt
            )
            guard !current.suppressed else { return .suppressed(gesture) }
            cooldownUntil = timestamp + configuration.cooldownMS / 1000
            return .fired(gesture)
        }

        // Lifting ends the session at once; a short dropout is tolerated.
        if fingers == 0 {
            session = nil
            return nil
        }
        let belowSince = current.belowSince ?? timestamp
        current.belowSince = belowSince
        session = current
        if (timestamp - belowSince) * 1000 >= configuration.dropoutMS {
            session = nil
        }
        return nil
    }

    // MARK: - Pure helpers

    /// Converts a normalised centroid (0…1, y up) into millimetres using the
    /// device's physical surface size, so an oblong trackpad cannot skew the
    /// angle (evaluation §11.4).
    static func centroidMM(normalized: CGPoint, surfaceSizeMM: CGSize) -> CGPoint {
        CGPoint(
            x: normalized.x * surfaceSizeMM.width,
            y: normalized.y * surfaceSizeMM.height
        )
    }

    /// Maps an angle to the nearest of eight 45° sectors.
    ///
    /// `diagonalBias` widens diagonal sectors and narrows axis sectors by the
    /// same amount; 0 gives every sector ±22.5°.
    static func direction(
        forAngleDegrees degrees: Double,
        diagonalBias: Double = 0
    ) -> SwipeDirection {
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }

        let axisHalf = 22.5 - diagonalBias
        let diagonalHalf = 22.5 + diagonalBias
        for direction in SwipeDirection.allCases {
            let distance = abs(
                (angle - direction.angleDegrees + 540)
                    .truncatingRemainder(dividingBy: 360) - 180
            )
            let half = direction.isDiagonal ? diagonalHalf : axisHalf
            if distance <= half { return direction }
        }
        return .right
    }
}
